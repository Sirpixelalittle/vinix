@[has_globals]
module term

import klock
import dev.fbdev.api
import dev.fbdev.simple
import limine
import flanterm as _
import memory

__global (
	flanterm_ctx        voidptr
	active_flanterm_ctx voidptr
	active_text_mode    = true
	terminal_print_lock klock.Lock
	terminal_rows       = u64(0)
	terminal_cols       = u64(0)
	framebuffer_tag     = &limine.LimineFramebuffer(unsafe { nil })
	framebuffer_width   = u64(0)
	framebuffer_height  = u64(0)
)

fn stage_color(stage u32) u32 {
	return match stage & 0x7 {
		0 { u32(0x00ff0000) } // red
		1 { u32(0x0000ff00) } // green
		2 { u32(0x000000ff) } // blue
		3 { u32(0x00ffff00) } // yellow
		4 { u32(0x0000ffff) } // cyan
		5 { u32(0x00ff00ff) } // magenta
		6 { u32(0x00ffffff) } // white
		else { u32(0x00808080) } // gray
	}
}

// Early boot marker that writes directly to the first Limine framebuffer.
// Safe to call before terminal initialisation; no allocations performed.
pub fn early_stage_mark(stage u32) {
	if fb_req.response == unsafe { nil } {
		return
	}
	if fb_req.response.framebuffer_count == 0 || fb_req.response.framebuffers == unsafe { nil } {
		return
	}
	fb := unsafe { fb_req.response.framebuffers[0] }
	if fb == unsafe { nil } || fb.address == unsafe { nil } {
		return
	}
	if fb.width == 0 || fb.height == 0 || fb.pitch == 0 || fb.bpp < 24 {
		return
	}

	color := stage_color(stage)
	bar_h := if fb.height > 48 { u64(48) } else { fb.height }
	for y := u64(0); y < bar_h; y++ {
		row := u64(fb.address) + y * fb.pitch
		for x := u64(0); x < fb.width; x++ {
			unsafe {
				*&u32(row + x * 4) = color
			}
		}
	}
}

@[_linker_section: '.requests']
@[cinit]
__global (
	volatile fb_req = limine.LimineFramebufferRequest{
		response: unsafe { nil }
	}
)

fn create_flanterm_context() voidptr {
	return unsafe {
		C.flanterm_fb_init(voidptr(memory.malloc), voidptr(memory.free), framebuffer_tag.address,
			framebuffer_width, framebuffer_height, framebuffer_tag.pitch, framebuffer_tag.red_mask_size,
			framebuffer_tag.red_mask_shift, framebuffer_tag.green_mask_size, framebuffer_tag.green_mask_shift,
			framebuffer_tag.blue_mask_size, framebuffer_tag.blue_mask_shift, nil, nil,
			nil, nil, nil, nil, nil, nil, 0, 0, 1, 0, 0, 0)
	}
}

pub fn initialise() {
	if fb_req.response == unsafe { nil } {
		// No framebuffer available (headless/serial-only mode)
		return
	}
	if fb_req.response.framebuffer_count == 0 || fb_req.response.framebuffers == unsafe { nil } {
		// No framebuffer available (headless/serial-only mode)
		return
	}
	framebuffer_tag = unsafe { fb_req.response.framebuffers[0] }
	if framebuffer_tag == unsafe { nil } || framebuffer_tag.address == unsafe { nil } {
		framebuffer_tag = unsafe { nil }
		return
	}
	if framebuffer_tag.width == 0 || framebuffer_tag.height == 0 || framebuffer_tag.pitch == 0 {
		framebuffer_tag = unsafe { nil }
		return
	}
	framebuffer_width = framebuffer_tag.width
	framebuffer_height = framebuffer_tag.height

	flanterm_ctx = create_flanterm_context()
	active_flanterm_ctx = flanterm_ctx

	C.flanterm_get_dimensions(flanterm_ctx, &terminal_cols, &terminal_rows)
}

pub fn framebuffer_init() {
	if framebuffer_tag == unsafe { nil } {
		return
	}
	sfb_config := simple.SimpleFBConfig{
		physical_address: u64(framebuffer_tag.address)
		width:            u32(framebuffer_width)
		height:           u32(framebuffer_height)
		stride:           u32(framebuffer_tag.pitch)
		bits_per_pixel:   u32(framebuffer_tag.bpp)
		red:              api.FBBitfield{
			offset:    framebuffer_tag.red_mask_shift
			length:    framebuffer_tag.red_mask_size
			msb_right: 0
		}
		green:            api.FBBitfield{
			offset:    framebuffer_tag.green_mask_shift
			length:    framebuffer_tag.green_mask_size
			msb_right: 0
		}
		blue:             api.FBBitfield{
			offset:    framebuffer_tag.blue_mask_shift
			length:    framebuffer_tag.blue_mask_size
			msb_right: 0
		}
		transp:           api.FBBitfield{
			offset:    0
			length:    0
			msb_right: 0
		}
	}

	simple.register_simple_framebuffer(sfb_config)
}

pub fn print(s voidptr, len u64) {
	print_to(flanterm_ctx, s, len)
}

// Allocate an independent terminal parser and cell grid. It shares the
// physical framebuffer but starts with autoflush disabled, so inactive VT
// output only updates its private flanterm state.
pub fn create_context() voidptr {
	if framebuffer_tag == unsafe { nil } {
		return unsafe { nil }
	}

	terminal_print_lock.acquire()
	context := create_flanterm_context()
	if context != unsafe { nil } {
		C.flanterm_set_autoflush(context, false)
	}
	terminal_print_lock.release()
	return context
}

pub fn print_to(context voidptr, s voidptr, len u64) {
	if context == unsafe { nil } {
		return
	}
	terminal_print_lock.acquire()
	C.flanterm_write(context, s, len)
	terminal_print_lock.release()
}

// Select the context whose grid owns the display. Pending output is first
// folded into its cell grid, then the complete grid is redrawn so no pixels
// from the previous VT remain.
pub fn activate_context(context voidptr, text_mode bool) {
	if context == unsafe { nil } {
		return
	}

	terminal_print_lock.acquire()
	if active_flanterm_ctx != unsafe { nil } {
		C.flanterm_set_autoflush(active_flanterm_ctx, false)
	}
	active_flanterm_ctx = context
	active_text_mode = text_mode
	if text_mode {
		C.flanterm_set_autoflush(context, true)
		C.flanterm_flush(context)
		C.flanterm_full_refresh(context)
	}
	terminal_print_lock.release()
}

pub fn set_context_text_mode(context voidptr, text_mode bool) {
	terminal_print_lock.acquire()
	if active_flanterm_ctx == context {
		active_text_mode = text_mode
		C.flanterm_set_autoflush(context, text_mode)
		if text_mode {
			C.flanterm_flush(context)
			C.flanterm_full_refresh(context)
		}
	}
	terminal_print_lock.release()
}

pub fn framebuffer_width_value() u64 {
	return framebuffer_width
}

pub fn framebuffer_height_value() u64 {
	return framebuffer_height
}

pub fn framebuffer_pitch_value() u64 {
	if framebuffer_tag == unsafe { nil } {
		return 0
	}
	return framebuffer_tag.pitch
}

pub fn framebuffer_bpp_value() u16 {
	if framebuffer_tag == unsafe { nil } {
		return 0
	}
	return framebuffer_tag.bpp
}

pub fn framebuffer_red_size_value() u8 {
	return if framebuffer_tag == unsafe { nil } { u8(0) } else { framebuffer_tag.red_mask_size }
}

pub fn framebuffer_red_shift_value() u8 {
	return if framebuffer_tag == unsafe { nil } { u8(0) } else { framebuffer_tag.red_mask_shift }
}

pub fn framebuffer_green_size_value() u8 {
	return if framebuffer_tag == unsafe { nil } { u8(0) } else { framebuffer_tag.green_mask_size }
}

pub fn framebuffer_green_shift_value() u8 {
	return if framebuffer_tag == unsafe { nil } { u8(0) } else { framebuffer_tag.green_mask_shift }
}

pub fn framebuffer_blue_size_value() u8 {
	return if framebuffer_tag == unsafe { nil } { u8(0) } else { framebuffer_tag.blue_mask_size }
}

pub fn framebuffer_blue_shift_value() u8 {
	return if framebuffer_tag == unsafe { nil } { u8(0) } else { framebuffer_tag.blue_mask_shift }
}

pub fn framebuffer_size() u64 {
	return framebuffer_pitch_value() * framebuffer_height
}

// Copy one damage rectangle from a lease-owned scanout buffer to the physical
// framebuffer. The lease buffer uses the hardware pitch and format returned by
// framebuffer_*_value(), so presentation requires no format conversion.
pub fn present_framebuffer(buffer voidptr, _x u32, _y u32, _width u32, _height u32) bool {
	if framebuffer_tag == unsafe { nil } || buffer == unsafe { nil } {
		return false
	}

	mut x := u64(_x)
	mut y := u64(_y)
	mut width := u64(_width)
	mut height := u64(_height)
	if width == 0 || height == 0 {
		x = 0
		y = 0
		width = framebuffer_width
		height = framebuffer_height
	}
	if x >= framebuffer_width || y >= framebuffer_height
		|| width > framebuffer_width - x || height > framebuffer_height - y {
		return false
	}

	bytes_per_pixel := u64(framebuffer_tag.bpp) / 8
	if bytes_per_pixel == 0 || u64(framebuffer_tag.bpp) % 8 != 0 {
		return false
	}
	pitch := framebuffer_tag.pitch
	row_bytes := width * bytes_per_pixel
	terminal_print_lock.acquire()
	for row := u64(0); row < height; row++ {
		offset := (y + row) * pitch + x * bytes_per_pixel
		unsafe {
			C.memcpy(voidptr(u64(framebuffer_tag.address) + offset),
				voidptr(u64(buffer) + offset), row_bytes)
		}
	}
	terminal_print_lock.release()
	return true
}
