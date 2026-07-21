module katomic

// Pointer slots need to be accessed through their address. Instantiating the
// generic atomics with a pointer type makes V dereference the stored pointer
// when it emits an x86 memory operand (for example, **here instead of *here).
// Reinterpreting the slot as a machine-sized integer keeps the atomic access
// on the slot itself on both supported 64-bit architectures.
pub fn cas_ptr[T](slot &&T, expected &T, desired &T) bool {
	mut raw_slot := unsafe { &u64(slot) }
	return cas[u64](mut raw_slot, u64(expected), u64(desired))
}

pub fn store_ptr[T](slot &&T, value &T) {
	mut raw_slot := unsafe { &u64(slot) }
	store[u64](mut raw_slot, u64(value))
}
