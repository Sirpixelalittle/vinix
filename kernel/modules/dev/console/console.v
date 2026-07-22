@[has_globals]
module console

import x86.idt
import x86.apic
import x86.kio
import dev.keyboard
import dev.seat
import event
import event.eventstruct
import klock
import stat
import term
import fs
import ioctl
import resource
import errno
import termios
import file
import userland
import proc
import katomic
import flanterm as _

const capslock = 0x3a
const numlock = 0x45
const left_alt = 0x38
const left_alt_rel = 0xb8
const right_shift = 0x36
const left_shift = 0x2a
const right_shift_rel = 0xb6
const left_shift_rel = 0xaa
const ctrl = 0x1d
const ctrl_rel = 0x9d
const console_buffer_size = 1024
const console_bigbuf_size = 4096
const virtual_terminal_count = 6

__global (
	console_convtab_numpad_numlock map[u8]u8
	console_res                    = &Console(unsafe { nil })
	virtual_terminals              [virtual_terminal_count]&Console
	active_terminal_index          = int(0)
	virtual_terminal_lock          klock.Lock
	console_numlock_active         = bool(false)
	console_capslock_active        = bool(false)
	console_shift_active           = bool(false)
	console_ctrl_active            = bool(false)
	console_alt_active             = bool(false)
	vt_switch_ctrl_active          = bool(false)
	vt_switch_alt_active           = bool(false)
	console_extra_scancodes        = bool(false)
	console_keyboard_grabbed       = bool(false)
	active_console_device          ActiveConsoleDevice
)

fn is_printable(c u8) bool {
	return c >= 0x20 && c <= 0x7e
}

fn active_terminal() &Console {
	return virtual_terminals[active_terminal_index]
}

fn terminal_echo(mut terminal Console, data voidptr, count u64) {
	term.print_to(terminal.context, data, count)
}

fn add_to_buf_char(mut terminal Console, _c u8, echo bool) {
	mut c := _c

	if c == `\r` && terminal.termios.c_iflag & termios.igncr != 0 {
		return
	}

	if c == `\n` && terminal.termios.c_iflag & termios.icrnl == 0 {
		c = `\r`
	} else if c == `\r` && terminal.termios.c_iflag & termios.icrnl != 0 {
		c = `\n`
	} else if c == `\r` && terminal.termios.c_iflag & termios.inlcr == 0 {
		c = `\n`
	} else if c == `\n` && terminal.termios.c_iflag & termios.inlcr != 0 {
		c = `\r`
	}

	if terminal.termios.c_lflag & termios.icanon != 0 {
		match c {
			`\n` {
				if terminal.input_buffer_i == console_buffer_size {
					return
				}
				terminal.input_buffer[terminal.input_buffer_i] = c
				terminal.input_buffer_i++
				if echo && terminal.termios.c_lflag & termios.echo != 0 {
					terminal_echo(mut terminal, &c, 1)
				}
				for i := u64(0); i < terminal.input_buffer_i; i++ {
					if terminal.status & file.pollin == 0 {
						terminal.status |= file.pollin
						event.trigger(mut terminal.event, false)
					}
					if terminal.read_buffer_i == console_bigbuf_size {
						return
					}
					terminal.read_buffer[terminal.read_buffer_i] = terminal.input_buffer[i]
					terminal.read_buffer_i++
				}
				terminal.input_buffer_i = 0
				return
			}
			`\b` {
				if terminal.input_buffer_i == 0 {
					return
				}
				terminal.input_buffer_i--
				to_backspace := if terminal.input_buffer[terminal.input_buffer_i] >= 0x01
					&& terminal.input_buffer[terminal.input_buffer_i] <= 0x1f {
					2
				} else {
					1
				}
				terminal.input_buffer[terminal.input_buffer_i] = 0
				if echo && terminal.termios.c_lflag & termios.echo != 0 {
					for i := 0; i < to_backspace; i++ {
						terminal_echo(mut terminal, c'\b \b', 3)
					}
				}
				return
			}
			else {}
		}

		if terminal.input_buffer_i == console_buffer_size {
			return
		}
		terminal.input_buffer[terminal.input_buffer_i] = c
		terminal.input_buffer_i++
	} else {
		if terminal.status & file.pollin == 0 {
			terminal.status |= file.pollin
			event.trigger(mut terminal.event, false)
		}
		if terminal.read_buffer_i == console_bigbuf_size {
			return
		}
		terminal.read_buffer[terminal.read_buffer_i] = c
		terminal.read_buffer_i++
	}

	if echo && terminal.termios.c_lflag & termios.echo != 0 {
		if is_printable(c) {
			terminal_echo(mut terminal, &c, 1)
		} else if c >= 0x01 && c <= 0x1f {
			control_echo := [u8(`^`), c + 0x40]
			terminal_echo(mut terminal, &control_echo[0], 2)
		}
	}
}

fn add_to_buf(mut terminal Console, ptr &u8, count u64, echo bool) {
	terminal.read_lock.acquire()
	defer {
		terminal.read_lock.release()
	}

	for i := u64(0); i < count; i++ {
		c := unsafe { ptr[i] }
		if terminal.termios.c_lflag & termios.isig != 0 {
			if c == terminal.termios.c_cc[termios.vintr] {
				if terminal.foreground_pgid == 0
					|| !userland.signal_process_group(terminal.foreground_pgid, userland.sigint) {
					if terminal.latest_thread != unsafe { nil } {
						userland.sendsig(terminal.latest_thread, userland.sigint)
					}
				}
			}
		}
		add_to_buf_char(mut terminal, c, echo)
	}

	event.trigger(mut terminal.input_event, false)
}

fn switch_terminal(index int) bool {
	if index < 0 || index >= virtual_terminal_count {
		return false
	}

	virtual_terminal_lock.acquire()
	target := virtual_terminals[index]
	if target == unsafe { nil } {
		virtual_terminal_lock.release()
		return false
	}
	if index == active_terminal_index {
		virtual_terminal_lock.release()
		return true
	}

	seat.revoke_for_terminal_switch()
	active_terminal_index = index
	term.activate_context(target.context, true)
	seat.set_active_terminal(u32(index + 1), target.context)
	virtual_terminal_lock.release()

	reset_keyboard_translation_state()
	return true
}

fn reset_keyboard_translation_state() {
	console_numlock_active = false
	console_capslock_active = false
	console_shift_active = false
	console_ctrl_active = false
	console_alt_active = false
	console_extra_scancodes = false
}

fn keyboard_handler() {
	vect := idt.allocate_vector()

	print('console: PS/2 keyboard vector is 0x${vect:x}\n')

	apic.io_apic_set_irq_redirect(cpu_locals[0].lapic_id, vect, 1, true)

	// Disable primary and secondary PS/2 ports
	write_ps2(0x64, 0xad)
	write_ps2(0x64, 0xa7)

	// Read from port 0x60 to flush the PS/2 controller buffer
	for kio.port_in[u8](0x64) & 1 != 0 {
		kio.port_in[u8](0x60)
	}

	mut ps2_config := read_ps2_config()

	// Enable keyboard interrupt and keyboard scancode translation
	ps2_config |= (1 << 0) | (1 << 6)

	// Enable mouse interrupt if any
	if ps2_config & (1 << 5) != 0 {
		ps2_config |= (1 << 1)
	}

	write_ps2_config(ps2_config)

	// Enable keyboard port
	write_ps2(0x64, 0xae)

	// Enable mouse port if any
	if ps2_config & (1 << 5) != 0 {
		write_ps2(0x64, 0xa8)
	}

	console_convtab_numpad_numlock = {
		u8(0x37): u8(`*`)
		u8(0x4a): u8(`-`)
		u8(0x4e): u8(`+`)
		u8(0x47): u8(`7`)
		u8(0x48): u8(`8`)
		u8(0x49): u8(`9`)
		u8(0x4b): u8(`4`)
		u8(0x4c): u8(`5`)
		u8(0x4d): u8(`6`)
		u8(0x4f): u8(`1`)
		u8(0x50): u8(`2`)
		u8(0x51): u8(`3`)
		u8(0x52): u8(`0`)
		u8(0x53): u8(`.`)
	}

	for {
		mut events := [&int_events[vect]]
		event.await(mut events, true) or {}
		unsafe { events.free() }
		input_byte := read_ps2()

		// Track the switch chord independently of the text translator so it
		// remains available while a graphical application owns raw input.
		match input_byte {
			left_alt { vt_switch_alt_active = true }
			left_alt_rel { vt_switch_alt_active = false }
			ctrl { vt_switch_ctrl_active = true }
			ctrl_rel { vt_switch_ctrl_active = false }
			else {}
		}

		mut terminal := active_terminal()
		if input_byte >= 0x3b && input_byte < 0x3b + virtual_terminal_count
			&& vt_switch_alt_active && (!seat.has_active_lease() || vt_switch_ctrl_active) {
			switch_terminal(int(input_byte - 0x3b))
			continue
		}

		keyboard_leased := seat.submit_keyboard(input_byte)
		keyboard_grabbed := keyboard.submit_scancode(input_byte)

		// An explicit raw-input grab, rather than the device's open count, owns
		// routing while Xorg is active.
		if keyboard_leased || keyboard_grabbed {
			if !console_keyboard_grabbed {
				reset_keyboard_translation_state()
				console_keyboard_grabbed = true
			}
			continue
		}
		if console_keyboard_grabbed {
			// Modifier releases consumed by X must not leave the console's
			// translator with stale state when control returns.
			reset_keyboard_translation_state()
			console_keyboard_grabbed = false
		}

		if input_byte == 0xe0 {
			console_extra_scancodes = true
			continue
		}

		if console_extra_scancodes == true {
			console_extra_scancodes = false

			match input_byte {
				ctrl {
					console_ctrl_active = true
					continue
				}
				ctrl_rel {
					console_ctrl_active = false
					continue
				}
				0x1c {
					add_to_buf(mut terminal, c'\n', 1, true)
					continue
				}
				0x35 {
					add_to_buf(mut terminal, c'/', 1, true)
					continue
				}
				0x48 {
					// Up arrow
					if terminal.decckm == false {
						add_to_buf(mut terminal, c'\e[A', 3, true)
					} else {
						add_to_buf(mut terminal, c'\eOA', 3, true)
					}
					continue
				}
				0x4b {
					// Left arrow
					if terminal.decckm == false {
						add_to_buf(mut terminal, c'\e[D', 3, true)
					} else {
						add_to_buf(mut terminal, c'\eOD', 3, true)
					}
					continue
				}
				0x50 {
					// Down arrow
					if terminal.decckm == false {
						add_to_buf(mut terminal, c'\e[B', 3, true)
					} else {
						add_to_buf(mut terminal, c'\eOB', 3, true)
					}
					continue
				}
				0x4d {
					// Right arrow
					if terminal.decckm == false {
						add_to_buf(mut terminal, c'\e[C', 3, true)
					} else {
						add_to_buf(mut terminal, c'\eOC', 3, true)
					}
					continue
				}
				0x47 {
					// Home
					add_to_buf(mut terminal, c'\e[1~', 4, true)
					continue
				}
				0x4f {
					// End
					add_to_buf(mut terminal, c'\e[4~', 4, true)
					continue
				}
				0x49 {
					// PG UP
					add_to_buf(mut terminal, c'\e[5~', 4, true)
					continue
				}
				0x51 {
					// PG DOWN
					add_to_buf(mut terminal, c'\e[6~', 4, true)
					continue
				}
				0x53 {
					// Delete
					add_to_buf(mut terminal, c'\e[3~', 4, true)
					continue
				}
				else {}
			}
		}

		match input_byte {
			numlock {
				console_numlock_active = true
				continue
			}
			left_alt {
				console_alt_active = true
				continue
			}
			left_alt_rel {
				console_alt_active = false
				continue
			}
			left_shift, right_shift {
				console_shift_active = true
				continue
			}
			left_shift_rel, right_shift_rel {
				console_shift_active = false
				continue
			}
			ctrl {
				console_ctrl_active = true
				continue
			}
			ctrl_rel {
				console_ctrl_active = false
				continue
			}
			capslock {
				console_capslock_active = !console_capslock_active
				continue
			}
			else {}
		}

		mut c := u8(0)

		if input_byte in console_convtab_numpad_numlock {
			c = console_convtab_numpad_numlock[input_byte]
		} else {
			c = keyboard.translate(input_byte, console_shift_active, console_capslock_active, console_ctrl_active)
			if c == 0 {
				continue
			}
		}

		add_to_buf(mut terminal, &c, 1, true)
	}
}

fn read_ps2() u8 {
	for kio.port_in[u8](0x64) & 1 == 0 {}
	return kio.port_in[u8](0x60)
}

fn write_ps2(port u16, value u8) {
	for kio.port_in[u8](0x64) & 2 != 0 {}
	kio.port_out[u8](port, value)
}

fn read_ps2_config() u8 {
	write_ps2(0x64, 0x20)
	return read_ps2()
}

fn write_ps2_config(value u8) {
	write_ps2(0x64, 0x60)
	write_ps2(0x60, value)
}

fn terminal_from_context(context voidptr) &Console {
	for i := 0; i < virtual_terminal_count; i++ {
		if virtual_terminals[i] != unsafe { nil } && virtual_terminals[i].context == context {
			return virtual_terminals[i]
		}
	}
	return unsafe { nil }
}

fn dec_private(mut terminal Console, esc_val_count u64, esc_values &u32, final u64) {
	match unsafe { esc_values[0] } {
		1 {
			match final {
				u64(`h`) {
					terminal.decckm = true
				}
				u64(`l`) {
					terminal.decckm = false
				}
				else {}
			}
		}
		else {}
	}
}

pub fn flanterm_callback(p voidptr, t u64, a u64, b u64, c u64) {
	mut terminal := terminal_from_context(p)
	if terminal == unsafe { nil } {
		return
	}

	match t {
		10 {
			dec_private(mut terminal, a, unsafe { &u32(b) }, c)
		}
		else {}
	}
}

fn init_termios(mut attributes termios.Termios) {
	attributes.c_iflag = termios.brkint | termios.icrnl | termios.ixon | termios.imaxbel
	attributes.c_oflag = termios.opost | termios.onlcr
	attributes.c_cflag = termios.cs8 | termios.cread | termios.b38400
	attributes.c_lflag = termios.isig | termios.icanon | termios.iexten | termios.echo | termios.echoe | termios.echok | termios.echoctl | termios.echoke
	attributes.c_cc[termios.vintr] = termios.ctrl(`C`)
	attributes.c_cc[termios.vquit] = termios.ctrl(`\\`)
	attributes.c_cc[termios.verase] = 0x7f
	attributes.c_cc[termios.vkill] = termios.ctrl(`U`)
	attributes.c_cc[termios.veof] = termios.ctrl(`D`)
	attributes.c_cc[termios.vstart] = termios.ctrl(`Q`)
	attributes.c_cc[termios.vstop] = termios.ctrl(`S`)
	attributes.c_cc[termios.vsusp] = termios.ctrl(`Z`)
	attributes.c_cc[termios.vreprint] = termios.ctrl(`R`)
	attributes.c_cc[termios.vwerase] = termios.ctrl(`W`)
	attributes.c_cc[termios.vlnext] = termios.ctrl(`V`)
	attributes.c_cc[termios.vdiscard] = termios.ctrl(`O`)
	attributes.c_cc[termios.vmin] = 1
}

fn init_alias(mut alias ActiveConsoleDevice) {
	alias.stat.blksize = 512
	alias.stat.rdev = resource.create_dev_id()
	alias.stat.mode = 0o620 | stat.ifchr
	alias.status = file.pollout
}

pub fn initialise() {
	for i := 0; i < virtual_terminal_count; i++ {
		mut context := flanterm_ctx
		if i != 0 {
			context = term.create_context()
		}
		mut terminal := &Console{
			index:   i
			context: context
		}
		terminal.stat.blksize = 512
		terminal.stat.rdev = resource.create_dev_id()
		terminal.stat.mode = 0o620 | stat.ifchr
		terminal.status = file.pollout
		init_termios(mut terminal.termios)

		virtual_terminals[i] = terminal
		C.flanterm_set_callback(context, voidptr(flanterm_callback))
		fs.devtmpfs_add_device(terminal, 'tty${i + 1}')
	}

	console_res = virtual_terminals[0]
	active_terminal_index = 0
	init_alias(mut active_console_device)
	fs.devtmpfs_add_device(&active_console_device, 'tty0')
	fs.devtmpfs_add_device(console_res, 'console')
	term.activate_context(console_res.context, true)
	seat.set_active_terminal(1, console_res.context)

	keyboard.initialise_device()

	spawn keyboard_handler()
}

struct Console {
pub mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool

	index            int
	context          voidptr
	termios         termios.Termios
	foreground_pgid int
	read_lock        klock.Lock
	input_event      eventstruct.Event
	input_buffer     [console_buffer_size]u8
	input_buffer_i   u64
	read_buffer      [console_bigbuf_size]u8
	read_buffer_i    u64
	decckm           bool
	latest_thread    &proc.Thread = unsafe { nil }
}

fn (this Console) is_terminal() bool {
	return true
}

fn (mut this Console) mmap(page u64, flags int) voidptr {
	return 0
}

fn (mut this Console) read(handle voidptr, void_buf voidptr, loc u64, count u64) ?i64 {
	this.latest_thread = proc.current_thread()

	mut buf := unsafe { &u8(void_buf) }

	for this.read_lock.test_and_acquire() == false {
		mut events := [&this.input_event]
		event.await(mut events, true) or {
			unsafe { events.free() }
			errno.set(errno.eintr)
			return none
		}
		unsafe { events.free() }
	}

	mut wait := true

	for i := u64(0); i < count; {
		if this.read_buffer_i != 0 {
			unsafe {
				buf[i] = this.read_buffer[0]
			}
			i++
			this.read_buffer_i--
			for j := u64(0); j < this.read_buffer_i; j++ {
				this.read_buffer[j] = this.read_buffer[j + 1]
			}
			if this.read_buffer_i == 0 && this.status & file.pollin != 0 {
				this.status &= ~file.pollin
				event.trigger(mut this.event, false)
			}
			wait = false
		} else {
			if wait == true {
				this.read_lock.release()
				for {
					mut events := [&this.input_event]
					event.await(mut events, true) or {
						unsafe { events.free() }
						errno.set(errno.eintr)
						return none
					}
					unsafe { events.free() }
					if this.read_lock.test_and_acquire() == true {
						break
					}
				}
			} else {
				this.read_lock.release()
				return i64(i)
			}
		}
	}

	this.read_lock.release()
	return i64(count)
}

fn (mut this Console) write(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	this.latest_thread = proc.current_thread()

	copy := unsafe { malloc(count) }
	defer {
		unsafe { free(copy) }
	}
	unsafe { C.memcpy(copy, buf, count) }
	term.print_to(this.context, copy, count)
	return i64(count)
}

fn (mut this Console) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	this.latest_thread = proc.current_thread()

	match request {
		ioctl.tiocsctty {
			fd_handle := unsafe { &file.Handle(handle) }
			mut process := proc.current_thread().process
			if process.pid != process.sid
				|| (process.controlling_terminal != unsafe { nil }
				&& process.controlling_terminal != fd_handle.node) {
				errno.set(errno.eperm)
				return none
			}
			process.controlling_terminal = fd_handle.node
			return 0
		}
		ioctl.tiocgpgrp {
			mut pgrp := unsafe { &int(argp) }
			if pgrp == unsafe { nil } {
				errno.set(errno.efault)
				return none
			}
			if this.foreground_pgid == 0 {
				this.foreground_pgid = proc.current_thread().process.pgid
			}
			unsafe {
				*pgrp = this.foreground_pgid
			}
			return 0
		}
		ioctl.tiocspgrp {
			pgrp := unsafe { &int(argp) }
			if pgrp == unsafe { nil } || *pgrp <= 0 {
				errno.set(errno.einval)
				return none
			}
			current := proc.current_thread().process
			if !userland.process_group_exists(*pgrp, current.sid) {
				errno.set(errno.eperm)
				return none
			}
			this.foreground_pgid = *pgrp
			return 0
		}
		ioctl.tiocgwinsz {
			mut w := unsafe { &ioctl.WinSize(argp) }
			w.ws_row = u16(terminal_rows)
			w.ws_col = u16(terminal_cols)
			w.ws_xpixel = u16(framebuffer_width)
			w.ws_ypixel = u16(framebuffer_height)
			return 0
		}
		ioctl.tcgets {
			mut t := unsafe { &termios.Termios(argp) }
			unsafe {
				*t = this.termios
			}
			return 0
		}
		// TODO: handle these differently
		ioctl.tcsets, ioctl.tcsetsw, ioctl.tcsetsf {
			mut t := unsafe { &termios.Termios(argp) }
			unsafe {
				this.termios = *t
			}
			return 0
		}
		else {
			return resource.default_ioctl(handle, request, argp)
		}
	}
}

fn (mut this Console) unref(handle voidptr) ? {
	katomic.dec(mut &this.refcount)
}

fn (mut this Console) link(handle voidptr) ? {
	katomic.inc(mut &this.stat.nlink)
}

fn (mut this Console) unlink(handle voidptr) ? {
	katomic.dec(mut &this.stat.nlink)
}

fn (mut this Console) grow(handle voidptr, new_size u64) ? {
	return none
}

struct ActiveConsoleDevice {
mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool
}

fn (mut this ActiveConsoleDevice) open(flags int) ?&resource.Resource {
	mut terminal := active_terminal()
	return &resource.Resource(terminal)
}

fn (mut this ActiveConsoleDevice) mmap(page u64, flags int) voidptr {
	return unsafe { nil }
}

fn (mut this ActiveConsoleDevice) read(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	mut terminal := active_terminal()
	return terminal.read(handle, buf, loc, count)
}

fn (mut this ActiveConsoleDevice) write(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	mut terminal := active_terminal()
	return terminal.write(handle, buf, loc, count)
}

fn (mut this ActiveConsoleDevice) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	mut terminal := active_terminal()
	return terminal.ioctl(handle, request, argp)
}

fn (mut this ActiveConsoleDevice) unref(handle voidptr) ? {
	katomic.dec(mut &this.refcount)
}

fn (mut this ActiveConsoleDevice) link(handle voidptr) ? {
	katomic.inc(mut &this.stat.nlink)
}

fn (mut this ActiveConsoleDevice) unlink(handle voidptr) ? {
	katomic.dec(mut &this.stat.nlink)
}

fn (mut this ActiveConsoleDevice) grow(handle voidptr, new_size u64) ? {
	return none
}
