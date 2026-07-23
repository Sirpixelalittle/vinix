module klock

import katomic
import x86.cpu

pub struct Lock {
pub mut:
	l    bool
	ints bool
}

fn C.__builtin_return_address(int) voidptr

pub fn (mut l Lock) acquire() {
	for {
		if l.test_and_acquire() == true {
			return
		}
		asm volatile amd64 {
			pause
			; ; ; memory
		}
	}
}

// Acquire a lock while keeping the saved interrupt state in the caller.
// Unlike acquire(), this is safe when different CPUs can contend for the same
// lock because a later owner cannot overwrite the previous owner's restore
// token.
pub fn (mut l Lock) acquire_irqsave() bool {
	interrupts_were_enabled := cpu.interrupt_toggle(false)
	for !katomic.cas(mut &l.l, false, true) {
		asm volatile amd64 {
			pause
			; ; ; memory
		}
	}
	return interrupts_were_enabled
}

pub fn (mut l Lock) try_acquire_irqsave() (bool, bool) {
	interrupts_were_enabled := cpu.interrupt_toggle(false)
	if katomic.cas(mut &l.l, false, true) {
		return true, interrupts_were_enabled
	}
	cpu.interrupt_toggle(interrupts_were_enabled)
	return false, false
}

pub fn (mut l Lock) release() {
	// Capture the previous interrupt state while this CPU still owns the lock.
	// Once l.l becomes false, a new owner may immediately overwrite l.ints.
	interrupts_were_enabled := l.ints
	katomic.store(mut &l.l, false)
	cpu.interrupt_toggle(interrupts_were_enabled)
}

pub fn (mut l Lock) release_irqrestore(interrupts_were_enabled bool) {
	katomic.store(mut &l.l, false)
	cpu.interrupt_toggle(interrupts_were_enabled)
}

pub fn (mut l Lock) test_and_acquire() bool {
	ints := cpu.interrupt_toggle(false)

	ret := katomic.cas(mut &l.l, false, true)
	if ret == true {
		l.ints = ints
	} else {
		cpu.interrupt_toggle(ints)
	}

	return ret
}
