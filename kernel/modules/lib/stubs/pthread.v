module stubs

import lib
import sched
import event
import proc
import errno

struct C.__thread_data {}

struct C.__threadattr {}

@[export: 'pthread_create']
pub fn pthread_create(t &&C.__thread_data, attr &C.__threadattr, start_routine fn (voidptr) voidptr, arg voidptr) int {
	if attr != unsafe { nil } {
		lib.kpanic(unsafe { nil }, c'pthread_create() called with non-NULL attr')
	}

	mut thrd := sched.new_kernel_thread(voidptr(start_routine), arg, false)
	// The returned pthread_t is an owning descriptor handle. Take its
	// reference before enqueueing, since another CPU may run and retire the
	// new thread immediately.
	proc.thread_ref(thrd)
	unsafe {
		mut ptr := &voidptr(t)
		*ptr = thrd
	}
	if !sched.enqueue_thread(thrd, false) {
		unsafe {
			mut ptr := &voidptr(t)
			*ptr = nil
		}
		proc.thread_unref(thrd)
		sched.discard_unstarted_thread(thrd)
		return errno.eagain
	}
	return 0
}

@[export: 'pthread_detach']
pub fn pthread_detach(t &C.__thread_data) int {
	thrd := unsafe { &proc.Thread(t) }
	proc.thread_unref(thrd)
	return 0
}

@[export: 'pthread_join']
pub fn pthread_join(t &C.__thread_data, mut retval voidptr) int {
	thrd := unsafe { &proc.Thread(t) }
	exit_value := event.pthread_wait(thrd)
	unsafe {
		if retval != nil {
			*retval = exit_value
		}
	}
	proc.thread_unref(thrd)
	return 0
}

@[export: 'pthread_exit']
@[noreturn]
pub fn pthread_exit(retval voidptr) {
	event.pthread_exit(retval)
	for {}
}
