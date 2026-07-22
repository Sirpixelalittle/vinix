@[has_globals]
module sched

import proc

const stack_size = u64(0x200000)

const max_running_threads = int(512)

__global (
	scheduler_vector        u8
	scheduler_running_queue [512]&proc.Thread
	kernel_process          &proc.Process
	uart_poll_callback      voidptr // Set by console module for HVF UART polling
)

// Thread IDs exposed to userspace must be non-zero: mlibc uses zero as the
// unlocked value in its futex-backed mutexes. Kernel Thread.tid values remain
// zero-based indices into Process.threads, so translate them at the ABI edge.
pub fn syscall_gettid(_ voidptr) (u64, u64) {
	return u64(proc.current_thread().tid + 1), 0
}
