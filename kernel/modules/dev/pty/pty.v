@[has_globals]
module pty

import errno
import event
import event.eventstruct
import file
import fs
import ioctl
import katomic
import klock
import proc
import resource
import stat
import termios
import userland

const max_ptys = 64
const pty_buffer_size = 16384
const canonical_buffer_size = 4096

struct ByteQueue {
mut:
	data      [pty_buffer_size]u8
	read_ptr  u64
	write_ptr u64
	used      u64
}

fn (mut queue ByteQueue) push(value u8) bool {
	if queue.used == pty_buffer_size {
		return false
	}
	queue.data[queue.write_ptr] = value
	queue.write_ptr = (queue.write_ptr + 1) % pty_buffer_size
	queue.used++
	return true
}

fn (mut queue ByteQueue) pop_into(buf voidptr, count u64) u64 {
	actual := if count < queue.used { count } else { queue.used }
	mut bytes := unsafe { &u8(buf) }
	for i := u64(0); i < actual; i++ {
		unsafe {
			bytes[i] = queue.data[queue.read_ptr]
		}
		queue.read_ptr = (queue.read_ptr + 1) % pty_buffer_size
	}
	queue.used -= actual
	return actual
}

struct PtyState {
mut:
	l               klock.Lock
	index           int
	active          bool
	locked          bool
	master_open     bool
	slave_open      bool
	input           ByteQueue
	output          ByteQueue
	canonical       [canonical_buffer_size]u8
	canonical_used  u64
	eof_pending     bool
	termios         termios.Termios
	winsize         ioctl.WinSize
	foreground_pgid int
	master          &PtyMaster = unsafe { nil }
	slave           &PtySlave  = unsafe { nil }
}

struct Ptmx {
mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool
}

struct PtyMaster {
mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool
	state    &PtyState = unsafe { nil }
}

struct PtySlave {
mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool
	state    &PtyState = unsafe { nil }
}

__global (
	ptmx           = &Ptmx(unsafe { nil })
	pty_table      [max_ptys]&PtyState
	pty_table_lock klock.Lock
)

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

fn update_status(mut state PtyState) {
	if state.output.used != 0 {
		state.master.status |= file.pollin
	} else {
		state.master.status &= ~file.pollin
	}
	if state.input.used != 0 || state.eof_pending {
		state.slave.status |= file.pollin
	} else {
		state.slave.status &= ~file.pollin
	}
	state.master.status |= file.pollout
	state.slave.status |= file.pollout
	if !state.slave_open {
		state.master.status |= file.pollhup
	} else {
		state.master.status &= ~file.pollhup
	}
	if !state.master_open {
		state.slave.status |= file.pollhup
	} else {
		state.slave.status &= ~file.pollhup
	}
	event.trigger(mut state.master.event, false)
	event.trigger(mut state.slave.event, false)
}

fn queue_output_byte(mut state PtyState, value u8) bool {
	if value == `\n` && state.termios.c_oflag & termios.opost != 0
		&& state.termios.c_oflag & termios.onlcr != 0 {
		if state.output.used > pty_buffer_size - 2 {
			return false
		}
		state.output.push(`\r`)
	}
	return state.output.push(value)
}

fn echo_input_byte(mut state PtyState, value u8) {
	if state.termios.c_lflag & termios.echo == 0 && !(value == `\n`
		&& state.termios.c_lflag & termios.echonl != 0) {
		return
	}
	if value < 0x20 && value != `\n` && value != `\t`
		&& state.termios.c_lflag & termios.echoctl != 0 {
		queue_output_byte(mut state, `^`)
		queue_output_byte(mut state, value + 0x40)
		return
	}
	queue_output_byte(mut state, value)
}

fn flush_canonical(mut state PtyState) {
	for i := u64(0); i < state.canonical_used; i++ {
		if !state.input.push(state.canonical[i]) {
			break
		}
	}
	state.canonical_used = 0
}

fn process_input_byte(mut state PtyState, original u8) bool {
	mut value := original
	if value == `\r` {
		if state.termios.c_iflag & termios.igncr != 0 {
			return true
		}
		if state.termios.c_iflag & termios.icrnl != 0 {
			value = `\n`
		}
	} else if value == `\n` && state.termios.c_iflag & termios.inlcr != 0 {
		value = `\r`
	}

	if state.termios.c_lflag & termios.isig != 0 {
		mut signal := 0
		if value == state.termios.c_cc[termios.vintr] {
			signal = userland.sigint
		} else if value == state.termios.c_cc[termios.vquit] {
			signal = userland.sigquit
		} else if value == state.termios.c_cc[termios.vsusp] {
			signal = userland.sigtstp
		}
		if signal != 0 {
			if state.foreground_pgid > 0 {
				userland.signal_process_group(state.foreground_pgid, signal)
			}
			if state.termios.c_lflag & termios.noflsh == 0 {
				state.input.used = 0
				state.input.read_ptr = 0
				state.input.write_ptr = 0
				state.canonical_used = 0
			}
			echo_input_byte(mut state, value)
			queue_output_byte(mut state, `\n`)
			return true
		}
	}

	if state.termios.c_lflag & termios.icanon == 0 {
		if !state.input.push(value) {
			return false
		}
		echo_input_byte(mut state, value)
		return true
	}

	if value == state.termios.c_cc[termios.verase] {
		if state.canonical_used != 0 {
			state.canonical_used--
			if state.termios.c_lflag & termios.echo != 0
				&& state.termios.c_lflag & termios.echoe != 0 {
				queue_output_byte(mut state, `\b`)
				queue_output_byte(mut state, ` `)
				queue_output_byte(mut state, `\b`)
			}
		}
		return true
	}
	if value == state.termios.c_cc[termios.vkill] {
		for state.canonical_used != 0 {
			state.canonical_used--
			if state.termios.c_lflag & termios.echo != 0
				&& state.termios.c_lflag & termios.echoke != 0 {
				queue_output_byte(mut state, `\b`)
				queue_output_byte(mut state, ` `)
				queue_output_byte(mut state, `\b`)
			}
		}
		return true
	}
	if value == state.termios.c_cc[termios.veof] {
		if state.input.used + state.canonical_used > pty_buffer_size {
			return false
		}
		if state.canonical_used == 0 {
			state.eof_pending = true
		}
		flush_canonical(mut state)
		return true
	}
	if value == `\n` && state.input.used + state.canonical_used + 1 > pty_buffer_size {
		return false
	}

	if state.canonical_used < canonical_buffer_size {
		state.canonical[state.canonical_used] = value
		state.canonical_used++
	}
	echo_input_byte(mut state, value)
	if value == `\n` {
		flush_canonical(mut state)
	}
	return true
}

pub fn initialise() {
	ptmx = &Ptmx{}
	ptmx.stat.mode = stat.ifchr | 0o666
	ptmx.stat.blksize = 512
	ptmx.stat.rdev = resource.create_dev_id()
	ptmx.status = file.pollout
	fs.devtmpfs_add_device(ptmx, 'ptmx')
}

fn (mut this Ptmx) open(flags int) ?&resource.Resource {
	pty_table_lock.acquire()
	defer {
		pty_table_lock.release()
	}

	mut index := -1
	for i := 0; i < max_ptys; i++ {
		if pty_table[i] == unsafe { nil } || !pty_table[i].active {
			index = i
			break
		}
	}
	if index < 0 {
		errno.set(errno.enospc)
		return none
	}

	mut state := &PtyState{
		index:       index
		active:      true
		locked:      true
		master_open: true
	}
	init_termios(mut state.termios)
	state.winsize.ws_row = 24
	state.winsize.ws_col = 80

	mut master := &PtyMaster{
		state: state
	}
	master.stat.mode = stat.ifchr | 0o666
	master.stat.blksize = 512
	master.stat.rdev = resource.create_dev_id()
	master.status = file.pollout

	mut slave := &PtySlave{
		state: state
	}
	slave.stat.mode = stat.ifchr | 0o620
	slave.stat.blksize = 512
	slave.stat.rdev = resource.create_dev_id()
	slave.status = file.pollout

	state.master = master
	state.slave = slave
	pty_table[index] = state
	fs.devtmpfs_add_device(slave, 'pts/${index}')

	return &resource.Resource(*master)
}

fn (mut this PtySlave) open(flags int) ?&resource.Resource {
	this.state.l.acquire()
	defer {
		this.state.l.release()
	}
	if !this.state.active || this.state.locked || !this.state.master_open {
		errno.set(errno.eio)
		return none
	}
	this.state.slave_open = true
	update_status(mut this.state)
	return &resource.Resource(this)
}

fn (this PtySlave) is_terminal() bool {
	return true
}

fn (mut this Ptmx) mmap(page u64, flags int) voidptr {
	return 0
}

fn (mut this Ptmx) read(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	errno.set(errno.eio)
	return none
}

fn (mut this Ptmx) write(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	errno.set(errno.eio)
	return none
}

fn (mut this Ptmx) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	return resource.default_ioctl(handle, request, argp)
}

fn (mut this Ptmx) unref(handle voidptr) ? {
	katomic.dec(mut &this.refcount)
}

fn (mut this Ptmx) link(handle voidptr) ? {
	katomic.inc(mut &this.stat.nlink)
}

fn (mut this Ptmx) unlink(handle voidptr) ? {
	katomic.dec(mut &this.stat.nlink)
}

fn (mut this Ptmx) grow(handle voidptr, new_size u64) ? {
	errno.set(errno.einval)
	return none
}

fn (mut this PtyMaster) mmap(page u64, flags int) voidptr {
	return 0
}

fn (mut this PtyMaster) read(_handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	mut handle := unsafe { &file.Handle(_handle) }
	mut state := this.state
	state.l.acquire()
	for state.output.used == 0 {
		if !state.slave_open {
			state.l.release()
			return 0
		}
		if handle.flags & resource.o_nonblock != 0 {
			state.l.release()
			errno.set(errno.ewouldblock)
			return none
		}
		state.l.release()
		mut events := [&this.event]
		event.await(mut events, true) or {
			unsafe { events.free() }
			errno.set(errno.eintr)
			return none
		}
		unsafe { events.free() }
		state.l.acquire()
	}
	ret := state.output.pop_into(buf, count)
	update_status(mut state)
	state.l.release()
	return i64(ret)
}

fn (mut this PtyMaster) write(_handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	mut handle := unsafe { &file.Handle(_handle) }
	mut state := this.state
	state.l.acquire()
	if !state.slave_open {
		state.l.release()
		errno.set(errno.eio)
		return none
	}
	mut bytes := unsafe { &u8(buf) }
	mut written := u64(0)
	for written < count {
		if !process_input_byte(mut state, unsafe { bytes[written] }) {
			if written != 0 {
				break
			}
			if handle.flags & resource.o_nonblock != 0 {
				state.l.release()
				errno.set(errno.ewouldblock)
				return none
			}
			state.l.release()
			mut events := [&this.event]
			event.await(mut events, true) or {
				unsafe { events.free() }
				errno.set(errno.eintr)
				return none
			}
			unsafe { events.free() }
			state.l.acquire()
			continue
		}
		written++
	}
	update_status(mut state)
	state.l.release()
	return i64(written)
}

fn pty_ioctl(mut state PtyState, master bool, handle voidptr, request u64, argp voidptr) ?int {
	if argp == unsafe { nil } && request != ioctl.tiocsctty {
		errno.set(errno.efault)
		return none
	}
	match request {
		ioctl.tiocgptn {
			unsafe {
				*&u32(argp) = u32(state.index)
			}
			return 0
		}
		ioctl.tiocsptlck {
			if !master {
				errno.set(errno.enotty)
				return none
			}
			state.locked = unsafe { *&int(argp) } != 0
			return 0
		}
		ioctl.tiocgwinsz {
			unsafe {
				*&ioctl.WinSize(argp) = state.winsize
			}
			return 0
		}
		ioctl.tiocswinsz {
			state.winsize = unsafe { *&ioctl.WinSize(argp) }
			return 0
		}
		ioctl.tcgets {
			unsafe {
				*&termios.Termios(argp) = state.termios
			}
			return 0
		}
		ioctl.tcsets, ioctl.tcsetsw, ioctl.tcsetsf {
			state.termios = unsafe { *&termios.Termios(argp) }
			return 0
		}
		ioctl.tiocgpgrp {
			if state.foreground_pgid == 0 {
				state.foreground_pgid = proc.current_thread().process.pgid
			}
			unsafe {
				*&int(argp) = state.foreground_pgid
			}
			return 0
		}
		ioctl.tiocspgrp {
			pgid := unsafe { *&int(argp) }
			current := proc.current_thread().process
			if pgid <= 0 || !userland.process_group_exists(pgid, current.sid) {
				errno.set(errno.eperm)
				return none
			}
			state.foreground_pgid = pgid
			return 0
		}
		ioctl.tiocsctty {
			return 0
		}
		ioctl.fionread {
			available := if master { state.output.used } else { state.input.used }
			unsafe {
				*&int(argp) = int(available)
			}
			return 0
		}
		else {
			return resource.default_ioctl(handle, request, argp)
		}
	}
}

fn (mut this PtyMaster) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	this.state.l.acquire()
	defer {
		this.state.l.release()
	}
	return pty_ioctl(mut this.state, true, handle, request, argp)
}

fn (mut this PtyMaster) unref(handle voidptr) ? {
	katomic.dec(mut &this.refcount)
	if this.refcount == 0 {
		this.state.l.acquire()
		this.state.master_open = false
		update_status(mut this.state)
		if !this.state.slave_open {
			this.state.active = false
		}
		this.state.l.release()
	}
}

fn (mut this PtyMaster) link(handle voidptr) ? {
	katomic.inc(mut &this.stat.nlink)
}

fn (mut this PtyMaster) unlink(handle voidptr) ? {
	katomic.dec(mut &this.stat.nlink)
}

fn (mut this PtyMaster) grow(handle voidptr, new_size u64) ? {
	errno.set(errno.einval)
	return none
}

fn (mut this PtySlave) mmap(page u64, flags int) voidptr {
	return 0
}

fn (mut this PtySlave) read(_handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	mut handle := unsafe { &file.Handle(_handle) }
	mut state := this.state
	state.l.acquire()
	for state.input.used == 0 && !state.eof_pending {
		if !state.master_open {
			state.l.release()
			return 0
		}
		if handle.flags & resource.o_nonblock != 0 {
			state.l.release()
			errno.set(errno.ewouldblock)
			return none
		}
		state.l.release()
		mut events := [&this.event]
		event.await(mut events, true) or {
			unsafe { events.free() }
			errno.set(errno.eintr)
			return none
		}
		unsafe { events.free() }
		state.l.acquire()
	}
	if state.input.used == 0 && state.eof_pending {
		state.eof_pending = false
		update_status(mut state)
		state.l.release()
		return 0
	}
	ret := state.input.pop_into(buf, count)
	update_status(mut state)
	state.l.release()
	return i64(ret)
}

fn (mut this PtySlave) write(_handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	mut handle := unsafe { &file.Handle(_handle) }
	mut state := this.state
	state.l.acquire()
	if !state.master_open {
		state.l.release()
		errno.set(errno.eio)
		return none
	}
	mut bytes := unsafe { &u8(buf) }
	mut written := u64(0)
	for written < count {
		if !queue_output_byte(mut state, unsafe { bytes[written] }) {
			if written != 0 {
				break
			}
			if handle.flags & resource.o_nonblock != 0 {
				state.l.release()
				errno.set(errno.ewouldblock)
				return none
			}
			state.l.release()
			mut events := [&this.event]
			event.await(mut events, true) or {
				unsafe { events.free() }
				errno.set(errno.eintr)
				return none
			}
			unsafe { events.free() }
			state.l.acquire()
			continue
		}
		written++
	}
	update_status(mut state)
	state.l.release()
	return i64(written)
}

fn (mut this PtySlave) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	if request == ioctl.tiocsctty {
		fd_handle := unsafe { &file.Handle(handle) }
		mut process := proc.current_thread().process
		if process.pid != process.sid
			|| (process.controlling_terminal != unsafe { nil }
			&& process.controlling_terminal != fd_handle.node) {
			errno.set(errno.eperm)
			return none
		}
		process.controlling_terminal = fd_handle.node
	}
	this.state.l.acquire()
	defer {
		this.state.l.release()
	}
	return pty_ioctl(mut this.state, false, handle, request, argp)
}

fn (mut this PtySlave) unref(handle voidptr) ? {
	katomic.dec(mut &this.refcount)
	if this.refcount == 0 {
		this.state.l.acquire()
		this.state.slave_open = false
		update_status(mut this.state)
		if !this.state.master_open {
			this.state.active = false
		}
		this.state.l.release()
	}
}

fn (mut this PtySlave) link(handle voidptr) ? {
	katomic.inc(mut &this.stat.nlink)
}

fn (mut this PtySlave) unlink(handle voidptr) ? {
	katomic.dec(mut &this.stat.nlink)
}

fn (mut this PtySlave) grow(handle voidptr, new_size u64) ? {
	errno.set(errno.einval)
	return none
}
