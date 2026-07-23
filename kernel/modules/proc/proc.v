@[has_globals]
module proc

import klock
import memory
import katomic
import event.eventstruct

pub const max_fds = 256

pub const max_events = 32

pub struct Process {
pub mut:
	pid                      int
	ppid                     int
	pgid                     int
	sid                      int
	pagemap                  &memory.Pagemap = unsafe { nil }
	thread_stack_top         u64
	threads_lock             klock.Lock
	threads                  []&Thread
	fds_lock                 klock.Lock
	fds                      [max_fds]voidptr
	children                 []&Process
	mmap_anon_non_fixed_base u64
	current_directory        voidptr
	controlling_terminal     voidptr
	event                    eventstruct.Event
	status                   int
	name                     string
	itimer_real_value_us     i64
	itimer_real_interval_us  i64
	execing                  bool
	exiting                  bool
}

// Return a stable thread pointer without exposing the Process.threads array
// while another CPU may replace its backing storage during exec.
pub fn first_thread(_process &Process) &Thread {
	mut process := unsafe { _process }
	process.threads_lock.acquire()
	defer {
		process.threads_lock.release()
	}
	if process.threads.len == 0 {
		return unsafe { nil }
	}
	return process.threads[0]
}

pub struct SigAction {
pub mut:
	sa_sigaction voidptr
	sa_mask      u64
	sa_flags     int
	sa_restorer  voidptr // SA_RESTORER trampoline (musl: __restore_rt)
}

// Native Vinix userspace deliberately has no sa_restorer field. Keep this
// syscall ABI structure separate from SigAction: the latter also stores the
// Linux/AArch64 restorer internally and is therefore eight bytes larger.
pub struct UserSigAction {
pub mut:
	sa_sigaction voidptr
	sa_mask      u64
	sa_flags     int
}

__global (
	processes [65536]&Process
)

pub fn allocate_pid(process &Process) ?int {
	for i := int(1); i < 65536; i++ {
		if katomic.cas_ptr[Process](&processes[i], unsafe { nil }, process) {
			return i
		}
	}
	return none
}

pub fn free_pid(pid int) {
	katomic.store_ptr[Process](&processes[pid], unsafe { nil })
}
