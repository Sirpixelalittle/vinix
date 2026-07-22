@[has_globals]
module mouse

import resource
import stat
import fs
import file
import event
import event.eventstruct
import klock
import katomic
import errno
import ioctl
import x86.kio
import x86.apic
import x86.idt
import dev.seat

const mouse_queue_size = 1024

@[inline]
fn wait(t int) {
	mut timeout := 100000
	if t == 0 {
		for ; timeout != 0; timeout-- {
			if kio.port_in[u8](0x64) & (1 << 0) != 0 {
				return
			}
		}
	} else {
		for ; timeout != 0; timeout-- {
			if kio.port_in[u8](0x64) & (1 << 1) == 0 {
				return
			}
		}
	}
}

@[inline]
fn write(val u8) {
	wait(1)
	kio.port_out[u8](0x64, 0xd4)
	wait(1)
	kio.port_out[u8](0x60, val)
}

@[inline]
fn read() u8 {
	wait(0)
	return kio.port_in[u8](0x60)
}

struct MousePacket {
pub mut:
	flags u8
	x_mov u32
	y_mov u32
}

struct Mouse {
pub mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool

	queue      [mouse_queue_size]MousePacket
	read_ptr   u64
	write_ptr  u64
	used       u64
	lease_owner voidptr
	lease_token voidptr
}

fn (mut this Mouse) clear_queue_locked() {
	this.read_ptr = this.write_ptr
	this.used = 0
	this.status &= ~int(file.pollin)
	this.event.@lock.acquire()
	this.event.pending = 0
	this.event.@lock.release()
}

fn (mut this Mouse) mmap(page u64, flags int) voidptr {
	panic('')
}

fn (mut this Mouse) read(_handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	if count != sizeof(MousePacket) {
		errno.set(errno.einval)
		return none
	}

	handle := unsafe { &file.Handle(_handle) }

	mouse_res.l.acquire()
	if seat.capability_is_leased(ioctl.seat_cap_pointer)
		|| mouse_res.lease_owner != unsafe { nil } {
		if mouse_res.lease_owner != _handle
			|| !seat.attachment_is_active(mouse_res.lease_token,
				ioctl.seat_cap_pointer) {
			mouse_res.l.release()
			errno.set(errno.eacces)
			return none
		}
	}

	for mouse_res.used == 0 {
		mouse_res.l.release()

		if handle.flags & resource.o_nonblock != 0 {
			errno.set(errno.ewouldblock)
			return none
		}

		mut events := [&mouse_res.event]
		event.await(mut events, true) or {}
		unsafe { events.free() }

		mouse_res.l.acquire()
	}

	unsafe {
		C.memcpy(buf, &mouse_res.queue[mouse_res.read_ptr], sizeof(MousePacket))
	}
	mouse_res.read_ptr = (mouse_res.read_ptr + 1) % mouse_queue_size
	mouse_res.used--
	if mouse_res.used == 0 {
		mouse_res.status &= ~int(file.pollin)
	}

	mouse_res.l.release()

	return sizeof(MousePacket)
}

fn (mut this Mouse) write(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	return i64(count)
}

fn (mut this Mouse) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	if request == ioctl.seat_attach_input {
		if argp == unsafe { nil } {
			errno.set(errno.efault)
			return none
		}
		attachment := unsafe { *&ioctl.SeatAttachInput(argp) }
		token := seat.attach_fd(attachment.lease_fd, ioctl.seat_cap_pointer) or {
			return none
		}
		this.l.acquire()
		if this.lease_token != unsafe { nil }
			&& !seat.attachment_is_active(this.lease_token,
				ioctl.seat_cap_pointer) {
			seat.detach(this.lease_token)
			this.lease_token = unsafe { nil }
			this.lease_owner = unsafe { nil }
			this.clear_queue_locked()
		}
		if this.lease_owner != unsafe { nil } && this.lease_owner != handle {
			this.l.release()
			seat.detach(token)
			errno.set(errno.ebusy)
			return none
		}
		if this.lease_token != unsafe { nil } {
			seat.detach(this.lease_token)
		}
		this.lease_owner = handle
		this.lease_token = token
		this.clear_queue_locked()
		this.l.release()
		return 0
	}
	return resource.default_ioctl(handle, request, argp)
}

fn (mut this Mouse) unref(handle voidptr) ? {
	katomic.dec(mut &this.refcount)
	file_handle := unsafe { &file.Handle(handle) }
	if katomic.load(&file_handle.descriptor_refcount) == 0 {
		this.l.acquire()
		if this.lease_owner == handle {
			seat.detach(this.lease_token)
			this.lease_owner = unsafe { nil }
			this.lease_token = unsafe { nil }
		}
		this.l.release()
	}
}

fn (mut this Mouse) link(handle voidptr) ? {
	katomic.inc(mut &this.stat.nlink)
}

fn (mut this Mouse) unlink(handle voidptr) ? {
	katomic.dec(mut &this.stat.nlink)
}

fn (mut this Mouse) grow(handle voidptr, new_size u64) ? {
}

__global (
	mouse_res        Mouse
	ps2_mouse_vector u8
)

fn handler() {
	mut handler_cycle := 0
	mut current_packet := MousePacket{}
	mut discard_packet := false

	for {
		mut events := [&int_events[ps2_mouse_vector]]
		event.await(mut events, true) or {}
		unsafe { events.free() }

		// we will get some spurious packets at the beginning and they will screw
		// up the alignment of the handler cycle so just ignore everything in
		// the first 250 milliseconds after boot
		if monotonic_clock.tv_sec == 0 && monotonic_clock.tv_nsec < 250000000 {
			kio.port_in[u8](0x60)
		}

		match handler_cycle {
			0 {
				current_packet.flags = read()
				handler_cycle++
				if current_packet.flags & (1 << 6) != 0 || current_packet.flags & (1 << 7) != 0 {
					discard_packet = true
				}
				if current_packet.flags & (1 << 3) == 0 {
					discard_packet = true
				}
				continue
			}
			1 {
				current_packet.x_mov = read()
				handler_cycle++
				continue
			}
			2 {
				current_packet.y_mov = read()
				handler_cycle = 0

				if discard_packet {
					discard_packet = false
					continue
				}
			}
			else {}
		}

		if current_packet.flags & (1 << 4) != 0 {
			current_packet.x_mov = u32(i8(u8(current_packet.x_mov)))
		}
		if current_packet.flags & (1 << 5) != 0 {
			current_packet.y_mov = u32(i8(u8(current_packet.y_mov)))
		}

		seat.submit_pointer(current_packet.flags, i32(current_packet.x_mov),
			i32(current_packet.y_mov))

		mouse_res.l.acquire()
		if mouse_res.lease_token != unsafe { nil }
			&& !seat.attachment_is_active(mouse_res.lease_token,
				ioctl.seat_cap_pointer) {
			// Preserve a deny-only binding for the revoked handle. A later
			// active attachment or close will release the retained lease token.
			mouse_res.clear_queue_locked()
			mouse_res.l.release()
			continue
		}
		// Preserve every button transition and movement packet. A single-slot
		// buffer can lose a short click when its release arrives before X reads
		// the press. If a reader stalls for an entire queue, retain the newest
		// input by dropping the oldest packet.
		if mouse_res.used == mouse_queue_size {
			mouse_res.read_ptr = (mouse_res.read_ptr + 1) % mouse_queue_size
			mouse_res.used--
		}
		mouse_res.queue[mouse_res.write_ptr] = current_packet
		mouse_res.write_ptr = (mouse_res.write_ptr + 1) % mouse_queue_size
		mouse_res.used++
		mouse_res.status |= file.pollin
		mouse_res.l.release()

		// Readiness is level-triggered by status/used. Do not accumulate stale
		// wake credits while no poller is attached.
		event.trigger(mut mouse_res.event, true)
	}
}

pub fn initialise() {
	write(0xf6)
	read()

	write(0xf4)
	read()

	mouse_res.stat.size = 0
	mouse_res.stat.blocks = 0
	mouse_res.stat.blksize = 512
	mouse_res.stat.rdev = resource.create_dev_id()
	mouse_res.stat.mode = 0o644 | stat.ifchr

	mouse_res.status |= file.pollout

	fs.devtmpfs_add_device(&mouse_res, 'mouse')

	ps2_mouse_vector = idt.allocate_vector()
	apic.io_apic_set_irq_redirect(cpu_locals[0].lapic_id, ps2_mouse_vector, 12, true)

	spawn handler()
}
