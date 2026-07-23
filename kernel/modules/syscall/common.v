module syscall

import aarch64.cpu
import aarch64.cpu.local as cpulocal
import userland

@[markused]
fn leave(context &cpulocal.GPRState) {
	cpu.interrupt_toggle(false)
	if userland.current_thread_is_terminating() {
		userland.terminate_current_thread()
	}
	userland.dispatch_a_signal(context)
}
