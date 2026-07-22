@[has_globals]
module futex

import event
import event.eventstruct
import klock
import errno
import proc
import katomic

__global (
	futex_lock klock.Lock
	futexes    map[u64]&eventstruct.Event
)

const futex_alignment = u64(sizeof(int))
const page_offset_mask = u64(0xfff)

pub fn initialise() {
	futexes = map[u64]&eventstruct.Event{}
}

fn key_for(process &proc.Process, ptr &int) ?u64 {
	address := u64(ptr)
	if address & (futex_alignment - 1) != 0 {
		errno.set(errno.einval)
		return none
	}

	// virt2phys returns the physical page base. Include the byte offset so
	// independent futex words on the same page do not share a wait queue.
	page := process.pagemap.virt2phys(address) or { return none }
	return page | (address & page_offset_mask)
}

pub fn syscall_futex_wait(_ voidptr, ptr &int, expected int) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: futex_wait(0x%llx, %d)\n', process.name.str, voidptr(ptr),
		expected)
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	mut e := &eventstruct.Event(unsafe { nil })

	// Resolve lazy mappings before taking the interlock. WAIT and WAKE both
	// take futex_lock around the value check / waiter registration boundary.
	// That makes the userspace value check and sleeping atomic with respect to
	// a matching wake and closes the classic lost-wakeup window.
	katomic.load(ptr)
	key := key_for(process, ptr) or {
		return errno.err, errno.get()
	}

	futex_lock.acquire()

	if katomic.load(ptr) != expected {
		futex_lock.release()
		return errno.err, errno.eagain
	}

	if key !in futexes {
		e = &eventstruct.Event{}
		futexes[key] = e
	} else {
		e = unsafe { futexes[key] } // will always be present
	}

	mut events := [e]
	defer {
		unsafe { events.free() }
	}
	event.await_interlocked(mut events, true, mut futex_lock) or {
		return errno.err, errno.eintr
	}

	return 0, 0
}

pub fn syscall_futex_wake(_ voidptr, ptr &int) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: futex_wake(0x%llx)\n', process.name.str, voidptr(ptr))
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	// Ensure this page is not lazily mapped
	katomic.load(ptr)

	key := key_for(process, ptr) or {
		return errno.err, errno.get()
	}

	futex_lock.acquire()
	defer {
		futex_lock.release()
	}

	if key !in futexes {
		return 0, 0
	}

	mut e := unsafe { futexes[key] }
	ret := event.trigger(mut e, true)

	return ret, 0
}
