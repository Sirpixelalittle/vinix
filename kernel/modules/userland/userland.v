module userland

import fs
import memory
import memory.mmap
import elf
import sched
import file
import proc
import x86.cpu.local as cpulocal
import x86.cpu
import katomic
import event
import event.eventstruct
import errno
import lib
import strings
import resource
import klock
import time

pub const wnohang = 1

pub const sig_block = 1

pub const sig_unblock = 2

pub const sig_setmask = 3

pub const sighup = 1

pub const sigint = 2

pub const sigquit = 3

pub const sigill = 4

pub const sigtrap = 5

pub const sigabrt = 6

pub const sigbus = 7

pub const sigfpe = 8

pub const sigkill = 9

pub const sigusr1 = 10

pub const sigsegv = 11

pub const sigusr2 = 12

pub const sigpipe = 13

pub const sigalrm = 14

pub const sigterm = 15

pub const sigstkflt = 16

pub const sigchld = 17

pub const sigcont = 18

pub const sigstop = 19

pub const sigtstp = 20

pub const sigttin = 21

pub const sigttou = 22

pub const sigurg = 23

pub const sigxcpu = 24

pub const sigxfsz = 25

pub const sigvtalrm = 26

pub const sigprof = 27

pub const sigwinch = 28

pub const sigio = 29

pub const sigpoll = sigio

pub const sigpwr = 30

pub const sigsys = 31

pub const sigrtmin = 32

pub const sigrtmax = 33

pub const sigcancel = 34

pub const sig_err = voidptr(-1)

pub const sig_dfl = voidptr(-2)

pub const sig_ign = voidptr(-3)

const max_itimer_real = 512

struct TimeVal {
mut:
	tv_sec  i64
	tv_usec i64
}

struct ITimerVal {
mut:
	it_interval TimeVal
	it_value    TimeVal
}

__global (
	itimer_real_processes [max_itimer_real]&proc.Process
	itimer_real_lock      klock.Lock
)

pub const sa_nocldstop = 1 << 0

pub const sa_onstack = 1 << 1

pub const sa_resethand = 1 << 2

pub const sa_restart = 1 << 3

pub const sa_siginfo = 1 << 4

pub const sa_nocldwait = 1 << 5

pub const sa_nodefer = 1 << 6

union SigVal {
	sival_int int
	sival_ptr voidptr
}

pub struct SigInfo {
pub mut:
	si_signo  int
	si_code   int
	si_errno  int
	si_pid    int
	si_uid    int
	si_addr   voidptr
	si_status int
	si_value  SigVal
}

pub fn syscall_getpid(_ voidptr) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: getpid()\n', process.name.str)
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	mut t := unsafe { proc.current_thread() }

	return u64(t.process.pid), 0
}

pub fn syscall_getppid(_ voidptr) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: getppid()\n', process.name.str)
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	mut t := unsafe { proc.current_thread() }

	return u64(t.process.ppid), 0
}

pub fn syscall_getpgid(_ voidptr, pid int) (u64, u64) {
	mut current := proc.current_thread().process
	target_pid := if pid == 0 { current.pid } else { pid }
	if target_pid < 1 || target_pid >= 65536 {
		return errno.err, errno.esrch
	}
	target := processes[target_pid]
	if target == unsafe { nil } {
		return errno.err, errno.esrch
	}
	return u64(target.pgid), 0
}

pub fn syscall_setpgid(_ voidptr, pid int, pgid int) (u64, u64) {
	mut current := proc.current_thread().process
	target_pid := if pid == 0 { current.pid } else { pid }
	if target_pid < 1 || target_pid >= 65536 || pgid < 0 {
		return errno.err, errno.einval
	}

	mut target := processes[target_pid]
	if target == unsafe { nil } || (target != current && target.ppid != current.pid) {
		return errno.err, errno.esrch
	}
	if target.sid != current.sid || target.pid == target.sid {
		return errno.err, errno.eperm
	}

	new_pgid := if pgid == 0 { target.pid } else { pgid }
	if new_pgid != target.pid {
		mut group_exists := false
		for i := 1; i < 65536; i++ {
			member := processes[i]
			if member != unsafe { nil } && member.pgid == new_pgid && member.sid == target.sid {
				group_exists = true
				break
			}
		}
		if !group_exists {
			return errno.err, errno.eperm
		}
	}

	target.pgid = new_pgid
	return 0, 0
}

pub fn syscall_getgroups(_ voidptr, size int, list &u32) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: getgroups(%d, 0x%llx)\n', process.name.str, size, voidptr(list))
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	return 0, 0
}

pub fn syscall_sigentry(_ voidptr, sigentry u64) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: sigentry(0x%llx)\n', process.name.str, sigentry)
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	mut t := proc.current_thread()

	t.sigentry = sigentry

	return 0, 0
}

pub fn syscall_sigreturn(syscall_context &cpulocal.GPRState, context &cpulocal.GPRState, old_mask u64) (u64, u64) {
	mut t := unsafe { proc.current_thread() }
	if syscall_context == unsafe { nil } || context == unsafe { nil } {
		return errno.err, errno.efault
	}

	t.masked_signals = old_mask
	unsafe {
		*syscall_context = *context
	}
	// syscall_entry stores these return values into the restored frame before
	// returning to userspace, so preserve the interrupted values explicitly.
	return syscall_context.rax, syscall_context.rdx
}

pub fn syscall_sigaction(_ voidptr, signum int, act &proc.SigAction, oldact &proc.SigAction) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: sigaction(%d, 0x%llx, 0x%llx)\n', process.name.str, signum,
		voidptr(act), voidptr(oldact))
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	if signum <= 0 || signum > sigcancel || signum == sigkill || signum == sigstop {
		return errno.err, errno.einval
	}

	mut t := proc.current_thread()

	if oldact != unsafe { nil } {
		unsafe {
			*oldact = t.sigactions[signum]
		}
	}

	if act != unsafe { nil } {
		t.sigactions[signum] = *act
	}

	return 0, 0
}

pub fn syscall_sigprocmask(_ voidptr, how int, set &u64, oldset &u64) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: sigprocmask(%d, 0x%llx, 0x%llx)\n', process.name.str, how,
		voidptr(set), voidptr(oldset))
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	mut t := proc.current_thread()

	if oldset != unsafe { nil } {
		unsafe {
			*oldset = t.masked_signals
		}
	}

	if set != unsafe { nil } {
		match how {
			sig_block {
				t.masked_signals |= *set
			}
			sig_unblock {
				t.masked_signals &= ~*set
			}
			sig_setmask {
				t.masked_signals = *set
			}
			else {
				return errno.err, errno.einval
			}
		}
		t.masked_signals &= ~((u64(1) << sigkill) | (u64(1) << sigstop))
	}

	return 0, 0
}

// Atomically replace the signal mask and sleep until a signal allowed by the
// temporary mask becomes pending. The original mask is restored by
// dispatch_a_signal() as part of returning from the signal handler.
pub fn syscall_sigsuspend(_ voidptr, set &u64) (u64, u64) {
	if set == unsafe { nil } {
		return errno.err, errno.efault
	}

	mut t := proc.current_thread()
	oldmask := t.masked_signals
	// SIGKILL and SIGSTOP cannot be blocked.
	t.masked_signals = *set & ~((u64(1) << sigkill) | (u64(1) << sigstop))

	for t.pending_signals & ~t.masked_signals == 0 {
		mut events := [&t.signal_event]
		event.await(mut events, true) or {}
		unsafe { events.free() }
	}

	// Leave the temporary mask installed until signal dispatch. This is what
	// makes sigsuspend atomic with respect to delivery of the waking signal.
	t.sigsuspend_oldmask = oldmask
	t.sigsuspend_restore = true
	return errno.err, errno.eintr
}

fn valid_timeval(value TimeVal) bool {
	return value.tv_sec >= 0 && value.tv_usec >= 0 && value.tv_usec < 1000000
}

fn timeval_to_us(value TimeVal) i64 {
	return value.tv_sec * 1000000 + value.tv_usec
}

fn us_to_timeval(value i64) TimeVal {
	if value <= 0 {
		return TimeVal{}
	}
	return TimeVal{
		tv_sec:  value / 1000000
		tv_usec: value % 1000000
	}
}

fn remove_itimer_process(process &proc.Process) {
	for i := 0; i < max_itimer_real; i++ {
		// V's generated equality for two pointers to a struct compares the
		// pointed-to values. Timer slots are identities, and an empty slot must
		// never be dereferenced, so compare the addresses explicitly.
		if voidptr(itimer_real_processes[i]) == voidptr(process) {
			itimer_real_processes[i] = unsafe { nil }
		}
	}
}

fn disarm_itimer_real(_process &proc.Process) {
	mut process := unsafe { _process }
	itimer_real_lock.acquire()
	remove_itimer_process(process)
	process.itimer_real_value_us = 0
	process.itimer_real_interval_us = 0
	itimer_real_lock.release()
}

// Called from the 1 kHz PIT interrupt on AMD64.
@[markused]
pub fn tick_itimers() {
	if !itimer_real_lock.test_and_acquire() {
		return
	}

	for i := 0; i < max_itimer_real; i++ {
		mut process := itimer_real_processes[i]
		if process == unsafe { nil } || process.itimer_real_value_us <= 0 {
			continue
		}

		process.itimer_real_value_us -= 1000000 / i64(time.timer_frequency)
		if process.itimer_real_value_us > 0 {
			continue
		}

		if process.itimer_real_interval_us > 0 {
			// Preserve elapsed time if a tick arrives slightly after expiry.
			for process.itimer_real_value_us <= 0 {
				process.itimer_real_value_us += process.itimer_real_interval_us
			}
		} else {
			process.itimer_real_value_us = 0
			itimer_real_processes[i] = unsafe { nil }
		}

		if process.threads.len > 0 {
			sendsig(process.threads[0], u8(sigalrm))
		}
	}

	itimer_real_lock.release()
}

pub fn syscall_getitimer(_ voidptr, which int, current &ITimerVal) (u64, u64) {
	if which != 0 {
		return errno.err, errno.einval
	}
	if current == unsafe { nil } {
		return errno.err, errno.efault
	}

	mut process := proc.current_thread().process
	itimer_real_lock.acquire()
	unsafe {
		current.it_value = us_to_timeval(process.itimer_real_value_us)
		current.it_interval = us_to_timeval(process.itimer_real_interval_us)
	}
	itimer_real_lock.release()
	return 0, 0
}

pub fn syscall_setitimer(_ voidptr, which int, new_value &ITimerVal, old_value &ITimerVal) (u64, u64) {
	if which != 0 {
		return errno.err, errno.einval
	}
	if new_value == unsafe { nil } {
		return errno.err, errno.efault
	}
	if !valid_timeval(new_value.it_value) || !valid_timeval(new_value.it_interval) {
		return errno.err, errno.einval
	}

	value_us := timeval_to_us(new_value.it_value)
	interval_us := timeval_to_us(new_value.it_interval)
	mut process := proc.current_thread().process

	itimer_real_lock.acquire()
	if old_value != unsafe { nil } {
		unsafe {
			old_value.it_value = us_to_timeval(process.itimer_real_value_us)
			old_value.it_interval = us_to_timeval(process.itimer_real_interval_us)
		}
	}

	mut slot := -1
	mut free_slot := -1
	for i := 0; i < max_itimer_real; i++ {
		if voidptr(itimer_real_processes[i]) == voidptr(process) {
			slot = i
			break
		}
		if free_slot == -1 && itimer_real_processes[i] == unsafe { nil } {
			free_slot = i
		}
	}

	if value_us > 0 && slot == -1 {
		if free_slot == -1 {
			itimer_real_lock.release()
			return errno.err, errno.eagain
		}
		slot = free_slot
		itimer_real_processes[slot] = process
	} else if value_us == 0 && slot != -1 {
		itimer_real_processes[slot] = unsafe { nil }
	}

	process.itimer_real_value_us = value_us
	process.itimer_real_interval_us = interval_us
	itimer_real_lock.release()
	return 0, 0
}

// Dispatch a signal to _self_, this is called from the scheduler, at the
// end of syscalls, or from exception handlers.
pub fn dispatch_a_signal(context &cpulocal.GPRState) {
	mut t := unsafe { proc.current_thread() }

	if t.sigentry == 0 {
		return
	}

	mut which := -1

	for i := u8(0); i < 64; i++ {
		if t.masked_signals & (u64(1) << i) != 0 {
			continue
		}
		if katomic.btr(mut &t.pending_signals, i) == true {
			which = i
			break
		}
	}

	if which == -1 {
		return
	}

	sigaction := t.sigactions[which]

	previous_mask := if t.sigsuspend_restore {
		t.sigsuspend_restore = false
		t.sigsuspend_oldmask
	} else {
		t.masked_signals
	}

	t.masked_signals |= sigaction.sa_mask
	if sigaction.sa_flags & sa_nodefer == 0 {
		t.masked_signals |= u64(1) << which
	}

	// Build the signal frame from the current trap/syscall context. t.gpr_state
	// may describe an older scheduler preemption and must not be used as the
	// source of the user stack pointer here.
	mut signal_sp := context.rsp - 128 // Respect the AMD64 red zone.
	signal_sp = lib.align_down(signal_sp, 16)
	signal_sp -= sizeof(cpulocal.GPRState)
	signal_sp = lib.align_down(signal_sp, 16)
	mut return_context := unsafe { &cpulocal.GPRState(signal_sp) }

	unsafe {
		*return_context = *context
	}
	// Siginfo
	signal_sp -= sizeof(SigInfo)
	signal_sp = lib.align_down(signal_sp, 16)
	mut siginfo := unsafe { &SigInfo(signal_sp) }

	unsafe { C.memset(voidptr(siginfo), 0, sizeof(SigInfo)) }
	siginfo.si_signo = which

	// Alignment
	signal_sp -= 8
	// Modify the active return frame directly. This works both at syscall exit
	// and when returning from a scheduler interrupt without a nested context
	// switch.
	mut active_context := unsafe { context }
	active_context.rsp = signal_sp
	active_context.rip = t.sigentry
	active_context.rdi = u64(which)
	active_context.rsi = u64(siginfo)
	active_context.rdx = u64(sigaction.sa_sigaction)
	active_context.rcx = u64(return_context)
	active_context.r8 = previous_mask
}

pub fn sendsig(_thread &proc.Thread, signal u8) {
	mut t := unsafe { _thread }

	katomic.bts(mut &t.pending_signals, signal)
	event.trigger(mut &t.signal_event, false)

	// Try to stop an event_await()
	sched.enqueue_thread(t, true)
}

pub fn process_group_exists(pgid int, sid int) bool {
	if pgid <= 0 {
		return false
	}
	for i := 1; i < 65536; i++ {
		member := processes[i]
		if member != unsafe { nil } && member.pgid == pgid && (sid == 0 || member.sid == sid) {
			return true
		}
	}
	return false
}

pub fn signal_process_group(pgid int, signal int) bool {
	mut delivered := false
	for i := 1; i < 65536; i++ {
		member := processes[i]
		if member == unsafe { nil } || member.pgid != pgid || member.threads.len == 0 {
			continue
		}
		delivered = true
		if signal != 0 {
			sendsig(member.threads[0], u8(signal))
		}
	}
	return delivered
}

pub fn syscall_kill(_ voidptr, pid int, signal int) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: kill(%d, %d)\n', process.name.str, pid, signal)
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	if signal < 0 || signal >= 64 {
		return errno.err, errno.einval
	}

	mut delivered := false
	if pid > 0 {
		if pid >= 65536 {
			return errno.err, errno.esrch
		}
		target := processes[pid]
		if target == unsafe { nil } || target.threads.len == 0 {
			return errno.err, errno.esrch
		}
		if signal != 0 {
			sendsig(target.threads[0], u8(signal))
		}
		return 0, 0
	}

	target_pgid := if pid == 0 {
		process.pgid
	} else if pid < -1 {
		-pid
	} else {
		-1
	}
	for i := 1; i < 65536; i++ {
		target := processes[i]
		if target == unsafe { nil } || target.threads.len == 0 {
			continue
		}
		if pid == -1 {
			if target.pid == 1 {
				continue
			}
		} else if target.pgid != target_pgid {
			continue
		}

		delivered = true
		if signal != 0 {
			sendsig(target.threads[0], u8(signal))
		}
	}

	if !delivered {
		return errno.err, errno.esrch
	}
	return 0, 0
}

pub fn syscall_execve(_ voidptr, _path charptr, _argv &charptr, _envp &charptr) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: execve(%s, [omit], [omit])\n', process.name.str, _path)
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	path := unsafe { cstring_to_vstring(_path) }
	mut argv := []string{}
	for i := 0; true; i++ {
		unsafe {
			if _argv[i] == nil {
				break
			}
			argv << cstring_to_vstring(_argv[i])
		}
	}
	mut envp := []string{}
	for i := 0; true; i++ {
		unsafe {
			if _envp[i] == nil {
				break
			}
			envp << cstring_to_vstring(_envp[i])
		}
	}

	start_program(true, proc.current_thread().process.current_directory, path, argv, envp,
		'', '', '') or { return errno.err, errno.get() }

	return errno.err, errno.get()
}

pub fn syscall_waitpid(_ voidptr, pid int, _status &int, options int) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut current_process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: waitpid(%d, 0x%llx, %d)\n', current_process.name.str, pid,
		_status, options)
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', current_process.name.str)
	}

	mut status := unsafe { _status }

	mut events := []&eventstruct.Event{}
	defer {
		unsafe { events.free() }
	}
	mut child := &proc.Process(unsafe { nil })

	if pid == -1 {
		if current_process.children.len == 0 {
			return errno.err, errno.echild
		}
		for c in current_process.children {
			events << &c.event
		}
	} else if pid < -1 || pid == 0 {
		print('\nwaitpid: value of pid not supported\n')
		return errno.err, errno.einval
	} else {
		if current_process.children.len == 0 {
			return errno.err, errno.echild
		}
		child = processes[pid]
		if child == unsafe { nil } || child.ppid != current_process.pid {
			return errno.err, errno.echild
		}
		events << &child.event
	}

	block := options & wnohang == 0
	which := event.await(mut events, block) or {
		// WNOHANG reports that matching children exist but none have changed
		// state by returning zero; it is not an interrupted wait.
		if !block {
			return 0, 0
		}
		return errno.err, errno.eintr
	}

	if child == unsafe { nil } {
		child = current_process.children[which]
	}

	if status != unsafe { nil } {
		unsafe {
			*status = child.status
		}
	}
	ret := child.pid

	proc.free_pid(ret)

	current_process.children.delete(current_process.children.index(child))

	return u64(ret), 0
}

@[markused]
pub fn current_thread_is_terminating() bool {
	current_thread := proc.current_thread()
	return katomic.load(&current_thread.terminating)
}

// Complete a sibling's cooperative exit after its active syscall has unwound.
// Switch to the kernel pagemap before waking the process leader so it cannot
// tear down a CR3 that this CPU is still using.
@[markused; noreturn]
pub fn terminate_current_thread() {
	mut current_thread := proc.current_thread()
	kernel_pagemap.switch_to()
	current_thread.process = kernel_process
	sched.dequeue_thread(current_thread)
	event.trigger(mut &current_thread.exited, false)
	sched.yield(false)
	for {}
}

@[noreturn]
pub fn syscall_exit(_ voidptr, status int) {
	mut current_thread := proc.current_thread()
	mut current_process := current_thread.process

	// exit() terminates the whole process, not just its calling thread. Only
	// one thread performs process teardown; concurrent callers stop after
	// unwinding their own syscall state.
	if !katomic.cas[bool](mut &current_process.exiting, false, true) {
		katomic.store(mut &current_thread.terminating, true)
		terminate_current_thread()
	}

	C.printf(c'\n\e[32m%s\e[m: exit(%d)\n', current_process.name.str, status)
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', current_process.name.str)
	}

	disarm_itimer_real(current_process)

	mut siblings := []&proc.Thread{}
	defer {
		unsafe { siblings.free() }
	}
	for sibling_entry in current_process.threads {
		mut sibling := unsafe { sibling_entry }
		if voidptr(sibling) == voidptr(current_thread) {
			continue
		}
		katomic.store(mut &sibling.terminating, true)
		siblings << sibling
	}

	// Wake blocked syscalls. Each sibling unwinds its event listeners and other
	// syscall-local state, then terminate_current_thread() signals exited.
	for sibling in siblings {
		sched.enqueue_thread(sibling, true)
	}
	for sibling in siblings {
		mut events := [&sibling.exited]
		event.await(mut events, true) or {}
		unsafe { events.free() }
	}

	mut old_pagemap := current_process.pagemap

	kernel_pagemap.switch_to()
	current_thread.process = kernel_process

	// Close all FDs
	for i := 0; i < proc.max_fds; i++ {
		if current_process.fds[i] == unsafe { nil } {
			continue
		}

		file.fdnum_close(current_process, i, true) or {}
	}

	// PID 1 inherits children
	if current_process.pid != 1 {
		for child in current_process.children {
			processes[1].children << child
		}
	}

	mmap.delete_pagemap(mut old_pagemap) or {}

	katomic.store(mut &current_process.status, int(u32(status) << 8))
	event.trigger(mut &current_process.event, false)

	sched.dequeue_and_die()
}

pub fn syscall_fork(gpr_state &cpulocal.GPRState) (u64, u64) {
	mut current_thread := proc.current_thread()
	mut process := current_thread.process

	C.printf(c'\n\e[32m%s\e[m: fork()\n', process.name.str)
	defer {
		C.printf(c'\e[32m%s\e[m: returning\n', process.name.str)
	}

	old_thread := proc.current_thread()
	mut old_process := old_thread.process

	mut new_process := sched.new_process(old_process, unsafe { nil }) or {
		return errno.err, errno.get()
	}

	new_process.name = '${old_process.name}[${new_process.pid}]'

	// Dup all FDs
	for i := 0; i < proc.max_fds; i++ {
		if old_process.fds[i] == unsafe { nil } {
			continue
		}

		file.fdnum_dup(old_process, i, new_process, i, 0, true, false) or { panic('') }
	}

	stack_size := u64(0x200000)

	mut stacks := []voidptr{}

	kernel_stack_phys := memory.pmm_alloc(stack_size / page_size)
	stacks << kernel_stack_phys
	kernel_stack := u64(kernel_stack_phys) + stack_size + higher_half

	pf_stack_phys := memory.pmm_alloc(stack_size / page_size)
	stacks << pf_stack_phys
	pf_stack := u64(pf_stack_phys) + stack_size + higher_half

	mut new_thread := &proc.Thread{
		gpr_state:      gpr_state
		process:        new_process
		timeslice:      old_thread.timeslice
		gs_base:        cpu.get_kernel_gs_base()
		fs_base:        cpu.get_fs_base()
		kernel_stack:   kernel_stack
		pf_stack:       pf_stack
		running_on:     u64(-1)
		cr3:            u64(new_process.pagemap.top_level)
		sigentry:       old_thread.sigentry
		sigactions:     old_thread.sigactions
		masked_signals: old_thread.masked_signals
		stacks:         stacks
		fpu_storage:    unsafe { malloc(fpu_storage_size) }
	}

	unsafe { stacks.free() }

	new_thread.self = voidptr(new_thread)

	unsafe { C.memcpy(new_thread.fpu_storage, old_thread.fpu_storage, fpu_storage_size) }

	new_thread.gpr_state.rax = u64(0)
	new_thread.gpr_state.rdx = u64(0)

	old_process.children << new_process
	new_process.threads << new_thread

	sched.enqueue_thread(new_thread, false)

	return u64(new_process.pid), u64(0)
}

pub fn start_program(execve bool, dir &fs.VFSNode, path string, argv []string, envp []string, stdin string, stdout string, stderr string) ?&proc.Process {
	prog_node := fs.get_node(dir, path, true)?
	mut prog := prog_node.resource

	mut new_pagemap := memory.new_pagemap()

	// Check for shebang before proceeding as if it was an ELF.
	mut shebang := [2]char{}
	prog.read(0, &shebang[0], 0, 2)?
	if shebang[0] == char(`#`) && shebang[1] == char(`!`) {
		real_path, arg := parse_shebang(mut prog)?
		mut final_argv := [real_path]
		if arg != '' {
			final_argv << arg
		}
		final_argv << path
		final_argv << argv[1..]

		return start_program(execve, dir, real_path, final_argv, envp, stdin, stdout,
			stderr)
	}

	auxval, ld_path := elf.load(new_pagemap, prog, 0) or { return none }

	mut entry_point := unsafe { nil }

	if ld_path == '' {
		entry_point = voidptr(auxval.at_entry)
	} else {
		ld_node := fs.get_node(vfs_root, ld_path, true)?
		ld := ld_node.resource

		ld_auxval, interp := elf.load(new_pagemap, ld, 0x40000000) or { return none }

		if interp != '' {
			unsafe { interp.free() }
		}

		entry_point = voidptr(ld_auxval.at_entry)

		unsafe { ld_path.free() }
	}

	if execve == false {
		mut new_process := sched.new_process(unsafe { nil }, new_pagemap)?

		new_process.name = '${path}[${new_process.pid}]'

		stdin_node := fs.get_node(vfs_root, stdin, true)?
		stdin_handle := &file.Handle{
			resource: stdin_node.resource
			node:     stdin_node
			refcount: 1
		}
		stdin_fd := &file.FD{
			handle: stdin_handle
		}
		new_process.fds[0] = voidptr(stdin_fd)

		stdout_node := fs.get_node(vfs_root, stdout, true)?
		stdout_handle := &file.Handle{
			resource: stdout_node.resource
			node:     stdout_node
			refcount: 1
		}
		stdout_fd := &file.FD{
			handle: stdout_handle
		}
		new_process.fds[1] = voidptr(stdout_fd)

		stderr_node := fs.get_node(vfs_root, stderr, true)?
		stderr_handle := &file.Handle{
			resource: stderr_node.resource
			node:     stderr_node
			refcount: 1
		}
		stderr_fd := &file.FD{
			handle: stderr_handle
		}
		new_process.fds[2] = voidptr(stderr_fd)

		sched.new_user_thread(new_process, true, entry_point, unsafe { nil }, 0, argv,
			envp, auxval, true)?

		return new_process
	} else {
		mut t := proc.current_thread()
		mut process := t.process
		old_mask := t.masked_signals
		old_pending := t.pending_signals
		old_sigactions := t.sigactions

		mut old_pagemap := process.pagemap

		process.pagemap = new_pagemap

		process.name = '${path}[${process.pid}]'

		kernel_pagemap.switch_to()
		t.process = kernel_process

		mmap.delete_pagemap(mut old_pagemap)?

		process.thread_stack_top = u64(0x70000000000)
		process.mmap_anon_non_fixed_base = u64(0x80000000000)

		// TODO: Kill old threads
		// old_threads := process.threads
		process.threads = []&proc.Thread{}

		mut new_thread := sched.new_user_thread(process, true, entry_point, unsafe { nil }, 0,
			argv, envp, auxval, true)?
		// POSIX exec semantics: the signal mask and pending set survive. Caught
		// dispositions are reset, while dispositions set to SIG_IGN remain
		// ignored. Xorg's xinit readiness handshake relies on this behavior.
		new_thread.masked_signals = old_mask
		new_thread.pending_signals = old_pending
		for i := 0; i < old_sigactions.len; i++ {
			if old_sigactions[i].sa_sigaction == sig_ign {
				new_thread.sigactions[i] = old_sigactions[i]
			}
		}

		unsafe {
			argv.free()
			envp.free()
		}
		sched.dequeue_and_die()
	}
}

pub fn parse_shebang(mut res resource.Resource) ?(string, string) {
	// Parse the shebang that we already know is there.
	// Syntax: #![whitespace]interpreter [single arg]new line
	mut index := u64(2)
	mut build_path := strings.new_builder(512)
	mut build_arg := strings.new_builder(512)

	mut c := char(0)
	res.read(0, &c, index, 1)?
	if c == char(` `) {
		index++
	}

	for {
		res.read(0, &c, index, 1)?
		index++
		if c == char(` `) {
			break
		}
		if c == char(`\n`) {
			unsafe {
				goto ret
			}
		}
		build_path.write_rune(rune(c))
	}

	for {
		res.read(0, &c, index, 1)?
		index++
		if c == char(` `) || c == char(`\n`) {
			break
		}
		build_arg.write_rune(rune(c))
	}

	ret:
	final_path := build_path.str()
	final_arg := build_arg.str()
	unsafe {
		build_path.free()
		build_arg.free()
	}
	return final_path, final_arg
}
