@[has_globals]
module sched

import proc
import katomic
import lib
import memory

const stack_size = u64(0x200000)

const max_running_threads = int(512)

__global (
	scheduler_vector        u8
	scheduler_running_queue [512]&proc.Thread
	scheduler_retired_queue [512]&proc.Thread
	retired_thread_reaper   &proc.Thread
	kernel_process          &proc.Process
	uart_poll_callback      voidptr // Set by console module for HVF UART polling
)

// Publish a dying thread for deferred reclamation. The extra scheduler epoch
// ensures that its CPU has completed a context switch and can no longer be
// executing on the thread's kernel stack before that stack is returned to the
// physical allocator.
pub fn retire_current_thread(_thread &proc.Thread, cpu_number u64, switch_count u64) {
	mut t := unsafe { _thread }
	if t.retirement_queued {
		return
	}
	t.retirement_queued = true
	t.retire_cpu = cpu_number
	t.retire_epoch = switch_count + 1

	for i := 0; i < scheduler_retired_queue.len; i++ {
		if katomic.cas_ptr[proc.Thread](&scheduler_retired_queue[i], unsafe { nil },
			t)
		{
			if retired_thread_reaper != unsafe { nil } {
				enqueue_thread(retired_thread_reaper, false)
			}
			return
		}
	}
	panic('Scheduler retired-thread queue exhausted')
}

// Called at scheduler entry. Reaching the recorded epoch means the retiring
// thread's stack has not been active since the preceding context switch.
pub fn mark_retired_threads_quiescent(cpu_number u64, switch_count u64) {
	for i := 0; i < scheduler_retired_queue.len; i++ {
		mut t := scheduler_retired_queue[i]
		if voidptr(t) == unsafe { nil } || t.retire_cpu != cpu_number
			|| t.retire_epoch > switch_count {
			continue
		}
		katomic.store(mut &t.running_on, u64(-1))
		katomic.store(mut &t.runtime_quiesced, true)
	}
}

fn retired_queue_has_work() bool {
	for t in scheduler_retired_queue {
		if voidptr(t) != unsafe { nil } {
			return true
		}
	}
	return false
}

fn reclaim_quiesced_threads() bool {
	mut found_work := false
	for i := 0; i < scheduler_retired_queue.len; i++ {
		mut t := scheduler_retired_queue[i]
		if voidptr(t) == unsafe { nil } {
			continue
		}
		found_work = true
		if !katomic.load(&t.runtime_quiesced) {
			continue
		}
		if !katomic.cas_ptr[proc.Thread](&scheduler_retired_queue[i], t,
			unsafe { nil })
		{
			continue
		}

		for stack_phys in t.stacks {
			memory.pmm_free(stack_phys, stack_size / page_size)
		}
		if t.fpu_storage != unsafe { nil } {
			memory.pmm_free(voidptr(u64(t.fpu_storage) - higher_half),
				lib.div_roundup(fpu_storage_size, page_size))
			t.fpu_storage = unsafe { nil }
		}
		unsafe {
			t.stacks.free()
		}
		t.stacks = []voidptr{}
		// Keep the small descriptor as a non-runnable tombstone. Console,
		// timer, and signal paths still cache borrowed Thread pointers; those
		// users need reference management before the descriptor itself can be
		// freed safely.
		katomic.store(mut &t.runtime_reclaimed, true)
	}
	return found_work
}

// Physical stack release can zero tens of MiB when exec retires many threads.
// Keep that work out of the timer ISR and perform it on an ordinary kernel
// thread instead.
fn retired_thread_reaper_main(_ voidptr) {
	for {
		if reclaim_quiesced_threads() {
			yield(true)
			continue
		}

		mut current_thread := proc.current_thread()
		dequeue_thread(current_thread)
		// Close the queue-vs-sleep race: a publisher either sees us dequeued
		// and enqueues us, or its work is visible in this second check.
		if retired_queue_has_work() {
			enqueue_thread(current_thread, false)
			continue
		}
		yield(true)
	}
}

// Thread IDs exposed to userspace must be non-zero: mlibc uses zero as the
// unlocked value in its futex-backed mutexes. Kernel Thread.tid values remain
// zero-based indices into Process.threads, so translate them at the ABI edge.
pub fn syscall_gettid(_ voidptr) (u64, u64) {
	return u64(proc.current_thread().tid + 1), 0
}
