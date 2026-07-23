module userland

import errno
import event
import katomic
import proc
import sched

@[markused]
pub fn current_thread_is_terminating() bool {
	current_thread := proc.current_thread()
	return current_thread != unsafe { nil }
		&& katomic.load(&current_thread.terminating)
}

// A terminating thread switches away from its userspace page table before it
// advertises completion. This ordering is what makes it safe for exec/exit to
// reclaim the old address space after waiting on Thread.exited.
@[markused; noreturn]
pub fn terminate_current_thread() {
	mut current_thread := proc.current_thread()
	kernel_pagemap.switch_to()
	current_thread.process = kernel_process
	sched.detach_thread_address_space(current_thread)
	katomic.store(mut &current_thread.terminated, true)
	sched.dequeue_thread(current_thread)
	event.trigger(mut &current_thread.exited, false)
	sched.dequeue_and_die()
}

fn mark_sibling_threads(mut process proc.Process, current_thread &proc.Thread) []&proc.Thread {
	mut siblings := []&proc.Thread{}
	for sibling_entry in process.threads {
		mut sibling := unsafe { sibling_entry }
		if voidptr(sibling) == voidptr(current_thread) {
			continue
		}
		katomic.store(mut &sibling.terminating, true)
		siblings << sibling
	}
	return siblings
}

fn wait_for_sibling_threads(mut siblings []&proc.Thread) {
	// Waking an event-blocked syscall makes it unwind its listeners and other
	// syscall-local state. Threads currently in userspace are stopped by the
	// scheduler's terminating check.
	for sibling in siblings {
		sched.enqueue_thread(sibling, true)
	}
	for sibling in siblings {
		if katomic.load(&sibling.terminated) {
			continue
		}
		mut events := [&sibling.exited]
		event.await(mut events, true) or {}
		unsafe {
			events.free()
		}
	}
}

// Establish the irreversible exec commit boundary. New thread creation checks
// Process.execing while holding the same lock, so every thread is either
// rejected or included in this snapshot.
pub fn begin_exec_and_stop_siblings(_process &proc.Process,
	current_thread &proc.Thread) ? {
	mut process := unsafe { _process }
	process.threads_lock.acquire()
	if process.execing || katomic.load(&process.exiting) {
		process.threads_lock.release()
		errno.set(errno.ebusy)
		return none
	}

	mut caller_found := false
	for thrd in process.threads {
		if voidptr(thrd) == voidptr(current_thread) {
			caller_found = true
			break
		}
	}
	if !caller_found {
		process.threads_lock.release()
		errno.set(errno.esrch)
		return none
	}

	process.execing = true
	mut siblings := mark_sibling_threads(mut process, current_thread)
	process.threads_lock.release()
	defer {
		unsafe {
			siblings.free()
		}
	}

	wait_for_sibling_threads(mut siblings)
}

// Process exit uses the same cooperative stop protocol after winning the
// Process.exiting compare/exchange.
pub fn stop_process_siblings(_process &proc.Process, current_thread &proc.Thread) {
	mut process := unsafe { _process }
	process.threads_lock.acquire()
	mut siblings := mark_sibling_threads(mut process, current_thread)
	process.threads_lock.release()
	defer {
		unsafe {
			siblings.free()
		}
	}
	wait_for_sibling_threads(mut siblings)
}

// Publish the one replacement thread only after every old sibling has stopped.
// The old array storage can then be reclaimed without racing thread creation.
pub fn finish_exec(_process &proc.Process, replacement &proc.Thread) {
	mut process := unsafe { _process }
	process.threads_lock.acquire()
	if !process.execing {
		process.threads_lock.release()
		panic('finish_exec called without an active exec transaction')
	}

	mut old_threads := unsafe { process.threads }
	process.threads = []&proc.Thread{}
	mut new_thread := unsafe { replacement }
	new_thread.tid = 0
	proc.thread_ref(new_thread)
	process.threads << new_thread
	process.execing = false
	process.threads_lock.release()

	for old_thread in old_threads {
		proc.thread_unref(old_thread)
	}
	unsafe {
		old_threads.free()
	}
}

// Remove the process registry's ownership after every sibling has stopped.
// Each retiring thread retains its scheduler-lifecycle reference until the
// reaper has released its stacks and FPU state.
pub fn detach_process_threads(_process &proc.Process) {
	mut process := unsafe { _process }
	process.threads_lock.acquire()
	mut old_threads := unsafe { process.threads }
	process.threads = []&proc.Thread{}
	process.threads_lock.release()

	for old_thread in old_threads {
		proc.thread_unref(old_thread)
	}
	unsafe {
		old_threads.free()
	}
}
