module ioctl

// Native Vinix seat lease ABI. A seat lease owns capabilities, not a specific
// display server protocol, so the same interface can be used by an X adapter,
// a Wayland compositor, or a standalone graphical program.
pub const seat_acquire = u64(0x5300)
pub const seat_release = u64(0x5301)
pub const seat_get_state = u64(0x5302)
pub const seat_get_display_info = u64(0x5303)
pub const seat_present = u64(0x5304)
pub const seat_attach_input = u64(0x5305)

pub const seat_cap_display = u32(1 << 0)
pub const seat_cap_keyboard = u32(1 << 1)
pub const seat_cap_pointer = u32(1 << 2)
pub const seat_cap_all = seat_cap_display | seat_cap_keyboard | seat_cap_pointer

pub const seat_state_idle = u32(0)
pub const seat_state_active = u32(1)
pub const seat_state_revoked = u32(2)

pub const seat_event_acquired = u16(1)
pub const seat_event_revoked = u16(2)
pub const seat_event_released = u16(3)
pub const seat_event_keyboard = u16(4)
pub const seat_event_pointer = u16(5)

pub const seat_source_system = u16(0)
pub const seat_source_ps2_keyboard = u16(1)
pub const seat_source_ps2_pointer = u16(2)

pub struct SeatAcquire {
pub mut:
	terminal_id u32
	capabilities u32
}

pub struct SeatState {
pub mut:
	state        u32
	terminal_id  u32
	capabilities u32
	reserved     u32
	generation   u64
}

pub struct SeatAttachInput {
pub mut:
	lease_fd int
	reserved u32
}

pub struct SeatDisplayInfo {
pub mut:
	width          u32
	height         u32
	pitch          u32
	bits_per_pixel u32
	buffer_size    u64
	red_size       u32
	red_shift      u32
	green_size     u32
	green_shift    u32
	blue_size      u32
	blue_shift     u32
}

// A zero width or height presents the entire scanout buffer. Non-zero values
// describe one damage rectangle in framebuffer coordinates.
pub struct SeatPresent {
pub mut:
	x      u32
	y      u32
	width  u32
	height u32
}

// Input codes are source-specific at this layer. The source field explicitly
// names that namespace; a future input service can publish normalized key and
// pointer events without changing lease ownership semantics.
pub struct SeatEvent {
pub mut:
	sequence u64
	kind     u16
	source   u16
	flags    u32
	code     u32
	reserved u32
	value0   i64
	value1   i64
}
