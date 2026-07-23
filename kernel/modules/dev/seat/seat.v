@[has_globals]
module seat

import errno
import event
import event.eventstruct
import file
import fs
import ioctl
import katomic
import klock
import lib
import memory
import resource
import stat
import term

const event_queue_size = 256
const terminal_limit = 64

struct SeatDevice {
mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool
}

@[heap]
struct SeatLease {
mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool

	state        u32
	terminal_id  u32
	capabilities u32
	generation   u64
	sequence     u64
	events       [event_queue_size]ioctl.SeatEvent
	read_index   u64
	write_index  u64
	used         u64
	display_phys voidptr
	display_pages u64
}

__global (
	seat_device             SeatDevice
	seat_lock               klock.Lock
	active_lease            = &SeatLease(unsafe { nil })
	active_terminal_id      = u32(0)
	active_terminal_context voidptr
	next_generation         = u64(1)
	terminal_leases         [terminal_limit]&SeatLease
)

fn queue_event_locked(mut lease SeatLease, seat_event ioctl.SeatEvent) {
	lease.sequence++
	mut queued_event := seat_event
	queued_event.sequence = lease.sequence
	if lease.used == event_queue_size {
		lease.read_index = (lease.read_index + 1) % event_queue_size
		lease.used--
	}
	lease.events[lease.write_index] = queued_event
	lease.write_index = (lease.write_index + 1) % event_queue_size
	lease.used++
	lease.status |= file.pollin
	event.trigger(mut lease.event, false)
}

fn state_event(kind u16, generation u64) ioctl.SeatEvent {
	return ioctl.SeatEvent{
		kind:   kind
		source: ioctl.seat_source_system
		value0: i64(generation)
	}
}

fn terminal_slot(terminal_id u32) int {
	if terminal_id == 0 || terminal_id > u32(terminal_limit) {
		return -1
	}
	return int(terminal_id - 1)
}

fn suspend_locked(mut lease SeatLease) {
	if lease.state != ioctl.seat_state_active {
		return
	}

	if lease.capabilities & ioctl.seat_cap_display != 0
		&& lease.terminal_id == active_terminal_id {
		term.set_context_text_mode(active_terminal_context, true)
	}

	if voidptr(active_lease) == voidptr(&lease) {
		active_lease = unsafe { nil }
	}
	lease.state = ioctl.seat_state_suspended
	lease.l.acquire()
	queue_event_locked(mut lease, state_event(ioctl.seat_event_suspended,
		lease.generation))
	lease.l.release()
}

fn resume_locked(mut lease SeatLease, context voidptr) {
	if lease.state != ioctl.seat_state_suspended {
		return
	}

	lease.state = ioctl.seat_state_active
	active_lease = &lease
	if lease.capabilities & ioctl.seat_cap_display != 0 {
		term.set_context_text_mode(context, false)
		if lease.display_phys != unsafe { nil } {
			term.present_framebuffer(voidptr(u64(lease.display_phys) + higher_half), 0,
				0, 0, 0)
		}
	}
	lease.l.acquire()
	queue_event_locked(mut lease, state_event(ioctl.seat_event_resumed,
		lease.generation))
	lease.l.release()
}

fn release_locked(mut lease SeatLease, revoked bool) {
	if lease.state != ioctl.seat_state_active
		&& lease.state != ioctl.seat_state_suspended {
		return
	}

	if lease.state == ioctl.seat_state_active
		&& lease.capabilities & ioctl.seat_cap_display != 0
		&& lease.terminal_id == active_terminal_id {
		term.set_context_text_mode(active_terminal_context, true)
	}

	if voidptr(active_lease) == voidptr(&lease) {
		active_lease = unsafe { nil }
	}
	slot := terminal_slot(lease.terminal_id)
	if slot >= 0 && voidptr(terminal_leases[slot]) == voidptr(&lease) {
		terminal_leases[slot] = unsafe { nil }
	}
	lease.state = if revoked { ioctl.seat_state_revoked } else { ioctl.seat_state_idle }
	lease.l.acquire()
	queue_event_locked(mut lease, state_event(if revoked {
		ioctl.seat_event_revoked
	} else {
		ioctl.seat_event_released
	}, lease.generation))
	lease.l.release()
	lease.terminal_id = 0
	lease.capabilities = 0
}

pub fn set_active_terminal(terminal_id u32, context voidptr) {
	seat_lock.acquire()
	if active_lease != unsafe { nil } && active_lease.terminal_id != terminal_id {
		mut old_lease := active_lease
		suspend_locked(mut old_lease)
	}
	active_terminal_id = terminal_id
	active_terminal_context = context
	slot := terminal_slot(terminal_id)
	if slot >= 0 && terminal_leases[slot] != unsafe { nil } {
		mut lease := terminal_leases[slot]
		resume_locked(mut lease, context)
	}
	seat_lock.release()
}

pub fn has_active_lease() bool {
	seat_lock.acquire()
	active := active_lease != unsafe { nil }
	seat_lock.release()
	return active
}

pub fn capability_is_leased(capability u32) bool {
	seat_lock.acquire()
	leasing := active_lease != unsafe { nil }
		&& active_lease.state == ioctl.seat_state_active
		&& active_lease.capabilities & capability != 0
	seat_lock.release()
	return leasing
}

// Retain the lease named by a descriptor so a compatibility input handle can
// be bound to the same native ownership object. The returned token is opaque
// outside this module and carries no authority without the original lease FD.
pub fn attach_fd(lease_fd int, capability u32) ?voidptr {
	if capability != ioctl.seat_cap_keyboard && capability != ioctl.seat_cap_pointer {
		errno.set(errno.einval)
		return none
	}
	mut fd := file.fd_from_fdnum(unsafe { nil }, lease_fd) or { return none }
	defer {
		fd.unref()
	}
	mut lease_resource := fd.handle.resource
	if mut lease_resource is SeatLease {
		mut lease := &SeatLease(unsafe { nil })
		lease = lease_resource
		seat_lock.acquire()
		if voidptr(active_lease) != voidptr(lease)
			|| lease.state != ioctl.seat_state_active
			|| lease.capabilities & capability == 0 {
			seat_lock.release()
			errno.set(errno.eacces)
			return none
		}
		katomic.inc(mut &lease.refcount)
		seat_lock.release()
		return voidptr(lease)
	}
	errno.set(errno.enotty)
	return none
}

pub fn attachment_is_active(token voidptr, capability u32) bool {
	if token == unsafe { nil } {
		return false
	}
	lease := unsafe { &SeatLease(token) }
	seat_lock.acquire()
	active := voidptr(active_lease) == voidptr(lease)
		&& lease.state == ioctl.seat_state_active
		&& lease.capabilities & capability != 0
	seat_lock.release()
	return active
}

pub fn detach(token voidptr) {
	if token == unsafe { nil } {
		return
	}
	mut lease := unsafe { &SeatLease(token) }
	lease.unref(unsafe { nil }) or {}
}

// Switching away suspends ownership. The client retains its terminal binding
// and private scanout allocation, but cannot present or receive input until
// that terminal becomes active again.
pub fn suspend_for_terminal_switch() {
	seat_lock.acquire()
	if active_lease != unsafe { nil } {
		mut lease := active_lease
		suspend_locked(mut lease)
	}
	seat_lock.release()
}

pub fn submit_keyboard(scancode u8) bool {
	seat_lock.acquire()
	mut lease := active_lease
	if lease == unsafe { nil } || lease.state != ioctl.seat_state_active
		|| lease.capabilities & ioctl.seat_cap_keyboard == 0 {
		seat_lock.release()
		return false
	}
	lease.l.acquire()
	queue_event_locked(mut lease, ioctl.SeatEvent{
		kind:   ioctl.seat_event_keyboard
		source: ioctl.seat_source_ps2_keyboard
		code:   u32(scancode)
	})
	lease.l.release()
	seat_lock.release()
	return true
}

pub fn submit_pointer(flags u8, x i32, y i32) bool {
	seat_lock.acquire()
	mut lease := active_lease
	if lease == unsafe { nil } || lease.state != ioctl.seat_state_active
		|| lease.capabilities & ioctl.seat_cap_pointer == 0 {
		seat_lock.release()
		return false
	}
	lease.l.acquire()
	queue_event_locked(mut lease, ioctl.SeatEvent{
		kind:   ioctl.seat_event_pointer
		source: ioctl.seat_source_ps2_pointer
		flags:  u32(flags)
		value0: i64(x)
		value1: i64(y)
	})
	lease.l.release()
	seat_lock.release()
	return true
}

pub fn initialise() {
	seat_device.stat.blksize = 1
	seat_device.stat.rdev = resource.create_dev_id()
	seat_device.stat.mode = stat.ifchr | 0o600
	fs.devtmpfs_add_device(&seat_device, 'seat0')
}

fn (mut this SeatDevice) open(flags int) ?&resource.Resource {
	mut lease := &SeatLease{
		state: ioctl.seat_state_idle
	}
	lease.stat.blksize = 1
	lease.stat.rdev = resource.create_dev_id()
	lease.stat.mode = stat.ifchr | 0o600
	lease.can_mmap = true
	return &resource.Resource(lease)
}

fn (mut this SeatDevice) mmap(page u64, flags int) voidptr {
	return unsafe { nil }
}

fn (mut this SeatDevice) read(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	errno.set(errno.enxio)
	return none
}

fn (mut this SeatDevice) write(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	errno.set(errno.enxio)
	return none
}

fn (mut this SeatDevice) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	return resource.default_ioctl(handle, request, argp)
}

fn (mut this SeatDevice) unref(handle voidptr) ? {
	katomic.dec(mut &this.refcount)
}

fn (mut this SeatDevice) link(handle voidptr) ? {
	katomic.inc(mut &this.stat.nlink)
}

fn (mut this SeatDevice) unlink(handle voidptr) ? {
	katomic.dec(mut &this.stat.nlink)
}

fn (mut this SeatDevice) grow(handle voidptr, new_size u64) ? {
	errno.set(errno.einval)
	return none
}

fn (mut this SeatLease) mmap(page u64, flags int) voidptr {
	seat_lock.acquire()
	allowed := voidptr(active_lease) == voidptr(this)
		&& this.state == ioctl.seat_state_active
		&& this.capabilities & ioctl.seat_cap_display != 0
		&& page < this.display_pages
	phys := this.display_phys
	seat_lock.release()
	if !allowed {
		return unsafe { nil }
	}
	return voidptr(u64(phys) + page * page_size)
}

fn (mut this SeatLease) read(_handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	if count < sizeof(ioctl.SeatEvent) {
		errno.set(errno.einval)
		return none
	}

	handle := unsafe { &file.Handle(_handle) }
	this.l.acquire()
	for this.used == 0 {
		this.l.release()
		if handle.flags & resource.o_nonblock != 0 {
			errno.set(errno.ewouldblock)
			return none
		}
		mut events := [&this.event]
		event.await(mut events, true) or {
			unsafe { events.free() }
			errno.set(errno.eintr)
			return none
		}
		unsafe { events.free() }
		this.l.acquire()
	}

	max_events := count / sizeof(ioctl.SeatEvent)
	actual := if max_events < this.used { max_events } else { this.used }
	mut output := unsafe { &ioctl.SeatEvent(buf) }
	for i := u64(0); i < actual; i++ {
		unsafe { output[i] = this.events[this.read_index] }
		this.read_index = (this.read_index + 1) % event_queue_size
	}
	this.used -= actual
	if this.used == 0 {
		this.status &= ~file.pollin
	}
	this.l.release()
	return i64(actual * sizeof(ioctl.SeatEvent))
}

fn (mut this SeatLease) write(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	errno.set(errno.einval)
	return none
}

fn (mut this SeatLease) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	match request {
		ioctl.seat_acquire {
			if argp == unsafe { nil } {
				errno.set(errno.efault)
				return none
			}
			acquire := unsafe { *&ioctl.SeatAcquire(argp) }
			if acquire.capabilities == 0
				|| acquire.capabilities & ~ioctl.seat_cap_all != 0 {
				errno.set(errno.einval)
				return none
			}

			seat_lock.acquire()
			if active_lease != unsafe { nil }
				&& voidptr(active_lease) != voidptr(this) {
				seat_lock.release()
				errno.set(errno.ebusy)
				return none
			}
			slot := terminal_slot(acquire.terminal_id)
			if slot < 0 || acquire.terminal_id != active_terminal_id {
				seat_lock.release()
				errno.set(errno.eacces)
				return none
			}
			if terminal_leases[slot] != unsafe { nil }
				&& voidptr(terminal_leases[slot]) != voidptr(this) {
				seat_lock.release()
				errno.set(errno.ebusy)
				return none
			}
			if this.state == ioctl.seat_state_active {
				seat_lock.release()
				errno.set(errno.ealready)
				return none
			}

			if acquire.capabilities & ioctl.seat_cap_display != 0
				&& this.display_phys == unsafe { nil } {
				size := term.framebuffer_size()
				if size == 0 {
					seat_lock.release()
					errno.set(errno.enodev)
					return none
				}
				this.display_pages = lib.div_roundup[u64](size, page_size)
				this.display_phys = memory.pmm_alloc(this.display_pages)
				if this.display_phys == unsafe { nil } {
					this.display_pages = 0
					seat_lock.release()
					errno.set(errno.enomem)
					return none
				}
			}

			this.state = ioctl.seat_state_active
			this.terminal_id = acquire.terminal_id
			this.capabilities = acquire.capabilities
			this.generation = next_generation
			next_generation++
			terminal_leases[slot] = &this
			active_lease = &this
			if this.capabilities & ioctl.seat_cap_display != 0 {
				term.set_context_text_mode(active_terminal_context, false)
			}
			this.l.acquire()
			queue_event_locked(mut this, state_event(ioctl.seat_event_acquired,
				this.generation))
			this.l.release()
			seat_lock.release()
			return 0
		}
		ioctl.seat_release {
			seat_lock.acquire()
			if this.state != ioctl.seat_state_active
				&& this.state != ioctl.seat_state_suspended {
				seat_lock.release()
				errno.set(errno.einval)
				return none
			}
			release_locked(mut this, false)
			seat_lock.release()
			return 0
		}
		ioctl.seat_get_state {
			if argp == unsafe { nil } {
				errno.set(errno.efault)
				return none
			}
			seat_lock.acquire()
			mut state := unsafe { &ioctl.SeatState(argp) }
			state.state = this.state
			state.terminal_id = if this.state == ioctl.seat_state_active
				|| this.state == ioctl.seat_state_suspended {
				this.terminal_id
			} else {
				active_terminal_id
			}
			state.capabilities = this.capabilities
			state.reserved = 0
			state.generation = this.generation
			seat_lock.release()
			return 0
		}
		ioctl.seat_get_display_info {
			if argp == unsafe { nil } {
				errno.set(errno.efault)
				return none
			}
			seat_lock.acquire()
			allowed := voidptr(active_lease) == voidptr(this)
				&& this.state == ioctl.seat_state_active
				&& this.capabilities & ioctl.seat_cap_display != 0
			seat_lock.release()
			if !allowed {
				errno.set(errno.eacces)
				return none
			}
			mut info := unsafe { &ioctl.SeatDisplayInfo(argp) }
			info.width = u32(term.framebuffer_width_value())
			info.height = u32(term.framebuffer_height_value())
			info.pitch = u32(term.framebuffer_pitch_value())
			info.bits_per_pixel = u32(term.framebuffer_bpp_value())
			info.buffer_size = term.framebuffer_size()
			info.red_size = u32(term.framebuffer_red_size_value())
			info.red_shift = u32(term.framebuffer_red_shift_value())
			info.green_size = u32(term.framebuffer_green_size_value())
			info.green_shift = u32(term.framebuffer_green_shift_value())
			info.blue_size = u32(term.framebuffer_blue_size_value())
			info.blue_shift = u32(term.framebuffer_blue_shift_value())
			return 0
		}
		ioctl.seat_present {
			if argp == unsafe { nil } {
				errno.set(errno.efault)
				return none
			}
			seat_lock.acquire()
			allowed := voidptr(active_lease) == voidptr(this)
				&& this.state == ioctl.seat_state_active
				&& this.capabilities & ioctl.seat_cap_display != 0
			phys := this.display_phys
			if !allowed {
				seat_lock.release()
				errno.set(errno.eacces)
				return none
			}
			present := unsafe { *&ioctl.SeatPresent(argp) }
			if !term.present_framebuffer(voidptr(u64(phys) + higher_half), present.x,
				present.y, present.width, present.height) {
				seat_lock.release()
				errno.set(errno.einval)
				return none
			}
			seat_lock.release()
			return 0
		}
		else {
			return resource.default_ioctl(handle, request, argp)
		}
	}
}

fn (mut this SeatLease) unref(handle voidptr) ? {
	// Closing the lease descriptor revokes an active or suspended binding
	// immediately. Memory maps retain their resource reference and therefore
	// keep the private scanout allocation alive without retaining access to the
	// physical display.
	if handle != unsafe { nil } {
		file_handle := unsafe { &file.Handle(handle) }
		if katomic.load(&file_handle.descriptor_refcount) == 0 {
			seat_lock.acquire()
			if this.state == ioctl.seat_state_active
				|| this.state == ioctl.seat_state_suspended {
				release_locked(mut this, true)
			}
			seat_lock.release()
		}
	}
	if katomic.dec(mut &this.refcount) {
		return
	}
	if this.display_phys != unsafe { nil } {
		memory.pmm_free(this.display_phys, this.display_pages)
	}
	unsafe { free(this) }
}

fn (mut this SeatLease) link(handle voidptr) ? {
	katomic.inc(mut &this.stat.nlink)
}

fn (mut this SeatLease) unlink(handle voidptr) ? {
	katomic.dec(mut &this.stat.nlink)
}

fn (mut this SeatLease) grow(handle voidptr, new_size u64) ? {
	errno.set(errno.einval)
	return none
}
