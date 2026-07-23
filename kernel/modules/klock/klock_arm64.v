module klock

// AArch64 spinlock implementation using WFE for power-efficient spinning.
// This file provides the same API as klock_amd64.v but for ARM64.
// The build system selects between this and the x86 version.
//
// IMPORTANT: Lock.l must be u64 (not u32). V's inline asm generates 64-bit
// register operands (X registers) for CAS and STLR even when the V type is u32.
// This causes 8-byte atomic ops on a 4-byte field, corrupting the adjacent
// `ints` field. Using u64 makes the field size match the actual operation width.

import katomic
import aarch64.cpu

pub struct Lock {
pub mut:
	l    u64
	ints bool
}

pub fn (mut l Lock) acquire() {
	for {
		if l.test_and_acquire() == true {
			return
		}
		asm volatile aarch64 {
			wfe
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
	for !katomic.cas(mut &l.l, u64(0), u64(1)) {
		asm volatile aarch64 {
			wfe
			; ; ; memory
		}
	}
	return interrupts_were_enabled
}

pub fn (mut l Lock) try_acquire_irqsave() (bool, bool) {
	interrupts_were_enabled := cpu.interrupt_toggle(false)
	if katomic.cas(mut &l.l, u64(0), u64(1)) {
		return true, interrupts_were_enabled
	}
	cpu.interrupt_toggle(interrupts_were_enabled)
	return false, false
}

pub fn (mut l Lock) release() {
	// Capture the previous interrupt state while this CPU still owns the lock.
	// Once l.l becomes zero, a new owner may immediately overwrite l.ints.
	interrupts_were_enabled := l.ints
	katomic.store(mut &l.l, u64(0))
	// Send event to wake up any WFE-spinning CPUs
	asm volatile aarch64 {
		sev
		; ; ; memory
	}
	cpu.interrupt_toggle(interrupts_were_enabled)
}

pub fn (mut l Lock) release_irqrestore(interrupts_were_enabled bool) {
	katomic.store(mut &l.l, u64(0))
	asm volatile aarch64 {
		sev
		; ; ; memory
	}
	cpu.interrupt_toggle(interrupts_were_enabled)
}

pub fn (mut l Lock) test_and_acquire() bool {
	ints := cpu.interrupt_toggle(false)

	ret := katomic.cas(mut &l.l, u64(0), u64(1))
	if ret == true {
		l.ints = ints
	} else {
		cpu.interrupt_toggle(ints)
	}

	return ret
}
