@[has_globals]
module keyboard

import errno
import event
import event.eventstruct
import file
import fs
import ioctl
import katomic
import klock
import resource
import stat

const scancode_queue_size = 1024

struct KeyboardDevice {
mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool

	queue     [scancode_queue_size]u8
	read_ptr  u64
	write_ptr u64
	used      u64
	grab_owner voidptr
}

__global (
	keyboard_device KeyboardDevice
)

pub fn initialise_device() {
	keyboard_device.stat.blksize = 1
	keyboard_device.stat.rdev = resource.create_dev_id()
	keyboard_device.stat.mode = stat.ifchr | 0o644
	fs.devtmpfs_add_device(&keyboard_device, 'keyboard')
}

// Queue one raw scancode and return whether an exclusive raw-input owner held
// the device at the instant the scancode arrived. Returning the routing
// decision under the same lock as the queue update prevents console/X races
// during ownership transitions.
pub fn submit_scancode(scancode u8) bool {
	keyboard_device.l.acquire()

	// Keep the newest input if a reader stalls long enough to fill the queue.
	// Normal operation drains this on every readable event.
	if keyboard_device.used == scancode_queue_size {
		keyboard_device.read_ptr = (keyboard_device.read_ptr + 1) % scancode_queue_size
		keyboard_device.used--
	}
	keyboard_device.queue[keyboard_device.write_ptr] = scancode
	keyboard_device.write_ptr = (keyboard_device.write_ptr + 1) % scancode_queue_size
	keyboard_device.used++
	keyboard_device.status |= file.pollin
	grabbed := keyboard_device.grab_owner != unsafe { nil }

	keyboard_device.l.release()
	event.trigger(mut keyboard_device.event, false)
	return grabbed
}

fn (mut this KeyboardDevice) clear_queue_locked() {
	this.read_ptr = this.write_ptr
	this.used = 0
	this.status &= ~file.pollin
	this.event.@lock.acquire()
	this.event.pending = 0
	this.event.@lock.release()
}

fn (mut this KeyboardDevice) read(_handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	if count == 0 {
		return 0
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

	actual := if count < this.used { count } else { this.used }
	mut bytes := unsafe { &u8(buf) }
	for i := u64(0); i < actual; i++ {
		unsafe {
			bytes[i] = this.queue[this.read_ptr]
		}
		this.read_ptr = (this.read_ptr + 1) % scancode_queue_size
	}
	this.used -= actual
	if this.used == 0 {
		this.status &= ~file.pollin
	}
	this.l.release()
	return i64(actual)
}

fn (mut this KeyboardDevice) write(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	errno.set(errno.eio)
	return none
}

fn (mut this KeyboardDevice) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	if request != ioctl.eviocgrab {
		return resource.default_ioctl(handle, request, argp)
	}

	mut file_handle := unsafe { &file.Handle(handle) }
	if katomic.load(&file_handle.descriptor_refcount) == 0 {
		errno.set(errno.ebadf)
		return none
	}

	acquire := argp != unsafe { nil }
	this.l.acquire()
	defer {
		this.l.release()
	}

	if acquire {
		if this.grab_owner != unsafe { nil } && this.grab_owner != handle {
			errno.set(errno.ebusy)
			return none
		}
		if this.grab_owner == unsafe { nil } {
			this.clear_queue_locked()
			this.grab_owner = handle
		}
		return 0
	}

	// Releasing an already released grab is intentionally idempotent because
	// Xorg may deliver both DEVICE_OFF and DEVICE_CLOSE callbacks.
	if this.grab_owner == unsafe { nil } {
		return 0
	}
	if this.grab_owner != handle {
		errno.set(errno.eperm)
		return none
	}
	this.grab_owner = unsafe { nil }
	this.clear_queue_locked()
	return 0
}

fn (mut this KeyboardDevice) unref(handle voidptr) ? {
	katomic.dec(mut &this.refcount)

	// A grab belongs to an open file description, not to the device node's
	// aggregate open count. Forked or duplicated descriptors therefore keep the
	// grab until their shared description's final descriptor is closed.
	file_handle := unsafe { &file.Handle(handle) }
	if katomic.load(&file_handle.descriptor_refcount) == 0 {
		this.l.acquire()
		if this.grab_owner == handle {
			this.grab_owner = unsafe { nil }
			this.clear_queue_locked()
		}
		this.l.release()
	}
}

fn (mut this KeyboardDevice) link(handle voidptr) ? {
	katomic.inc(mut &this.stat.nlink)
}

fn (mut this KeyboardDevice) unlink(handle voidptr) ? {
	katomic.dec(mut &this.stat.nlink)
}

fn (mut this KeyboardDevice) grow(handle voidptr, new_size u64) ? {
	errno.set(errno.einval)
	return none
}

fn (mut this KeyboardDevice) mmap(page u64, flags int) voidptr {
	return unsafe { nil }
}
