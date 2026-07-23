module unix

import stat
import klock
import event.eventstruct
import errno
import proc
import fs
import socket.public as sock_pub
import event
import file
import resource
import katomic
import ioctl

pub const sock_buf = 0x100000

pub struct SockaddrUn {
pub mut:
	sun_family u16
	sun_path   [108]u8
}

// Abstract UNIX socket registry — sockets bound with sun_path[0]=='\0'
// are stored here instead of in the filesystem.
struct AbstractSocketEntry {
mut:
	in_use   bool
	name_len u32
	name     [108]u8
	socket   &UnixSocket = unsafe { nil }
}

__global (
	abstract_sockets      [64]AbstractSocketEntry
	abstract_sockets_lock klock.Lock
	unix_connection_lock  klock.Lock
)

pub struct UnixSocket {
pub mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	status   int
	can_mmap bool
	event    eventstruct.Event

	name      SockaddrUn
	listening bool
	backlog   []&UnixSocket

	connection_event eventstruct.Event
	connected        bool
	peer_closed      bool
	closed           bool
	connect_error    u64
	abstract_bound   bool
	peer             &UnixSocket = unsafe { nil }

	data      &u8 = unsafe { nil }
	read_ptr  u64
	write_ptr u64
	capacity  u64
	used      u64
}

fn (mut this UnixSocket) mmap(page u64, flags int) voidptr {
	return 0
}

fn (mut this UnixSocket) read(_handle voidptr, buf voidptr, loc u64, _count u64) ?i64 {
	mut count := _count

	this.l.acquire()
	defer {
		this.l.release()
	}

	handle := unsafe { &file.Handle(_handle) }

	// If pipe is empty, block or return if nonblock
	for katomic.load(&this.used) == 0 {
		// A disconnected stream remains readable and returns EOF. This is what
		// lets poll-driven servers tear down all state owned by a dead client.
		if this.peer_closed {
			return 0
		}
		if !this.connected {
			errno.set(errno.enotconn)
			return none
		}
		if handle.flags & resource.o_nonblock != 0 {
			errno.set(errno.ewouldblock)
			return none
		}
		this.l.release()
		mut events := [&this.event]
		event.await(mut events, true) or {
			unsafe { events.free() }
			errno.set(errno.eintr)
			return none
		}
		unsafe { events.free() }
		this.l.acquire()
	}

	if this.used < count {
		count = this.used
	}

	// Calculate sizes before and after wrap-around and new ptr location
	mut before_wrap := u64(0)
	mut after_wrap := u64(0)
	mut new_ptr_loc := u64(0)
	if this.read_ptr + count > this.capacity {
		before_wrap = this.capacity - this.read_ptr
		after_wrap = count - before_wrap
		new_ptr_loc = after_wrap
	} else {
		before_wrap = count
		after_wrap = 0
		new_ptr_loc = this.read_ptr + count
		if new_ptr_loc == this.capacity {
			new_ptr_loc = 0
		}
	}

	unsafe { C.memcpy(buf, &this.data[this.read_ptr], before_wrap) }
	if after_wrap != 0 {
		unsafe { C.memcpy(voidptr(u64(buf) + before_wrap), this.data, after_wrap) }
	}

	this.read_ptr = new_ptr_loc
	this.used -= count

	if this.peer != unsafe { nil } {
		this.peer.status |= file.pollout
		event.trigger(mut this.peer.event, false)
	}

	if this.used == 0 && !this.peer_closed {
		this.status &= ~file.pollin
	}

	return i64(count)
}

fn (mut this UnixSocket) write(_handle voidptr, buf voidptr, loc u64, _count u64) ?i64 {
	mut count := _count

	interrupts_were_enabled := unix_connection_lock.acquire_irqsave()
	if !this.connected || this.peer_closed || this.peer == unsafe { nil } {
		unix_connection_lock.release_irqrestore(interrupts_were_enabled)
		errno.set(errno.epipe)
		return none
	}

	mut peer := this.peer
	peer.l.acquire()
	if peer.closed || peer.peer_closed || peer.peer == unsafe { nil } {
		peer.l.release()
		unix_connection_lock.release_irqrestore(interrupts_were_enabled)
		errno.set(errno.epipe)
		return none
	}
	unix_connection_lock.release_irqrestore(interrupts_were_enabled)
	defer {
		peer.l.release()
	}

	handle := unsafe { &file.Handle(_handle) }

	// If pipe is full, block or return if nonblock
	for katomic.load(&peer.used) == peer.capacity {
		if peer.closed || voidptr(peer.peer) != voidptr(this) {
			errno.set(errno.epipe)
			return none
		}
		if handle.flags & resource.o_nonblock != 0 {
			errno.set(errno.ewouldblock)
			return none
		}

		peer.l.release()
		mut events := [&peer.event]
		event.await(mut events, true) or {
			unsafe { events.free() }
			errno.set(errno.eintr)
			return none
		}
		unsafe { events.free() }
		peer.l.acquire()
	}
	if peer.closed || voidptr(peer.peer) != voidptr(this) {
		errno.set(errno.epipe)
		return none
	}

	if peer.used + count > peer.capacity {
		count = peer.capacity - peer.used
	}

	// Calculate sizes before and after wrap-around and new ptr location
	mut before_wrap := u64(0)
	mut after_wrap := u64(0)
	mut new_ptr_loc := u64(0)
	if peer.write_ptr + count > peer.capacity {
		before_wrap = peer.capacity - peer.write_ptr
		after_wrap = count - before_wrap
		new_ptr_loc = after_wrap
	} else {
		before_wrap = count
		after_wrap = 0
		new_ptr_loc = peer.write_ptr + count
		if new_ptr_loc == peer.capacity {
			new_ptr_loc = 0
		}
	}

	unsafe { C.memcpy(&peer.data[peer.write_ptr], buf, before_wrap) }
	if after_wrap != 0 {
		unsafe { C.memcpy(peer.data, voidptr(u64(buf) + before_wrap), after_wrap) }
	}

	peer.write_ptr = new_ptr_loc
	peer.used += count

	peer.status |= file.pollin
	event.trigger(mut peer.event, false)

	return i64(count)
}

fn (mut this UnixSocket) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	match request {
		ioctl.fionread {
			if this.listening {
				errno.set(errno.einval)
				return none
			}
			if argp == unsafe { nil } {
				errno.set(errno.efault)
				return none
			}
			// FIONREAD's userspace ABI returns an int.  Writing a u64 here
			// overwrites four bytes beyond the caller's object; xterm keeps
			// that object immediately below a saved frame pointer.
			mut retp := unsafe { &int(argp) }
			unsafe {
				*retp = int(this.used)
			}
			return 0
		}
		else {
			return resource.default_ioctl(handle, request, argp)
		}
	}
}

fn (mut this UnixSocket) unref(_handle voidptr) ? {
	katomic.dec(mut &this.refcount)

	// Temporary FD references never reach the resource. A resource unref with
	// a live descriptor count is therefore a non-final duplicate close.
	if _handle == unsafe { nil } {
		return
	}
	handle := unsafe { &file.Handle(_handle) }
	if katomic.load(&handle.descriptor_refcount) != 0 {
		return
	}

	mut peer := &UnixSocket(unsafe { nil })
	mut rejected := []&UnixSocket{}
	mut data_to_free := &u8(unsafe { nil })
	interrupts_were_enabled := unix_connection_lock.acquire_irqsave()
	this.l.acquire()
	if this.closed {
		this.l.release()
		unix_connection_lock.release_irqrestore(interrupts_were_enabled)
		unsafe {
			rejected.free()
		}
		return
	}

	this.closed = true
	this.listening = false
	this.status &= ~file.pollout
	this.status |= file.pollhup | file.pollrdhup

	peer = this.peer
	if peer != unsafe { nil } {
		peer.l.acquire()
		if voidptr(peer.peer) == voidptr(this) {
			peer.peer = unsafe { nil }
			peer.connected = false
			peer.peer_closed = true
			peer.status &= ~file.pollout
			// EOF is readable, and HUP must be reported even if the caller
			// requested only POLLIN.
			peer.status |= file.pollin | file.pollhup | file.pollrdhup
		}
		peer.l.release()
	}
	this.peer = unsafe { nil }
	this.connected = false
	data_to_free = this.data
	this.data = unsafe { nil }
	this.capacity = 0
	this.used = 0
	this.read_ptr = 0
	this.write_ptr = 0

	for this.backlog.len > 0 {
		mut pending := this.backlog.pop()
		pending.connect_error = errno.econnrefused
		rejected << pending
	}
	this.status &= ~file.pollin
	this.l.release()
	unix_connection_lock.release_irqrestore(interrupts_were_enabled)

	if peer != unsafe { nil } {
		event.trigger(mut peer.event, false)
	}
	for mut pending in rejected {
		event.trigger(mut pending.connection_event, false)
	}
	unsafe {
		rejected.free()
		if data_to_free != nil {
			free(data_to_free)
		}
	}

	if this.abstract_bound {
		abstract_interrupts_were_enabled := abstract_sockets_lock.acquire_irqsave()
		for i := 0; i < abstract_sockets.len; i++ {
			if abstract_sockets[i].in_use
				&& voidptr(abstract_sockets[i].socket) == voidptr(this) {
				abstract_sockets[i].in_use = false
				abstract_sockets[i].name_len = 0
				abstract_sockets[i].socket = unsafe { nil }
				break
			}
		}
		this.abstract_bound = false
		abstract_sockets_lock.release_irqrestore(abstract_interrupts_were_enabled)
	}
}

fn (mut this UnixSocket) link(handle voidptr) ? {
	return none
}

fn (mut this UnixSocket) unlink(handle voidptr) ? {
	return none
}

fn (mut this UnixSocket) grow(handle voidptr, new_size u64) ? {
	return none
}

fn (mut this UnixSocket) peername(handle voidptr, _addr voidptr, addrlen &u32) ? {
	if this.connected == false {
		errno.set(errno.enotconn)
		return none
	}

	mut actual_size := unsafe { *addrlen }
	if actual_size < sizeof(SockaddrUn) {
		actual_size = sizeof(SockaddrUn)
	}

	unsafe { C.memcpy(_addr, voidptr(&this.peer.name), actual_size) }
	unsafe {
		*addrlen = actual_size
	}
}

fn (mut this UnixSocket) accept(_handle voidptr) ?&resource.Resource {
	if this.listening == false || this.closed {
		errno.set(errno.einval)
		return none
	}

	this.l.acquire()
	defer {
		this.l.release()
	}

	handle := unsafe { &file.Handle(_handle) }

	for this.backlog.len == 0 {
		if this.closed || !this.listening {
			errno.set(errno.econnaborted)
			return none
		}
		this.status &= ~file.pollin
		if handle.flags & resource.o_nonblock != 0 {
			errno.set(errno.ewouldblock)
			return none
		}
		print('unix accept: waiting for connection\n')
		this.l.release()
		mut events := [&this.event]
		event.await(mut events, true) or {
			unsafe { events.free() }
			errno.set(errno.eintr)
			return none
		}
		unsafe { events.free() }
		this.l.acquire()
	}

	print('unix accept: got connection, setting up peer\n')

	mut peer := this.backlog.pop()

	mut connection_socket := &UnixSocket{
		refcount:  1
		peer:      peer
		connected: true
		name:      peer.name
		data:      unsafe { malloc(sock_buf) }
		capacity:  sock_buf
		status:    file.pollout
	}

	interrupts_were_enabled := unix_connection_lock.acquire_irqsave()
	peer.peer = connection_socket
	peer.connected = true
	peer.peer_closed = false
	peer.connect_error = 0
	unix_connection_lock.release_irqrestore(interrupts_were_enabled)

	if this.backlog.len == 0 {
		this.status &= ~file.pollin
	}

	print('unix accept: triggering client connection_event\n')
	event.trigger(mut peer.connection_event, false)

	print('unix accept: done\n')
	return connection_socket
}

fn (mut this UnixSocket) connect(handle voidptr, _addr voidptr, addrlen u32) ? {
	addr := unsafe { &SockaddrUn(_addr) }

	if addr.sun_family != sock_pub.af_unix {
		errno.set(errno.einval)
		return none
	}

	// Validate the caller-supplied address length before deriving a copy size
	// from it below. An unchecked addrlen lets name_len exceed the fixed-size
	// abstract-socket name buffers, causing out-of-bounds access.
	if addrlen < u32(sizeof(u16)) || addrlen > u32(sizeof(SockaddrUn)) {
		errno.set(errno.einval)
		return none
	}

	mut socket := &UnixSocket(unsafe { nil })

	// Abstract socket: sun_path[0] == '\0'
	if addrlen > 2 && addr.sun_path[0] == 0 {
		name_len := addrlen - 2
		interrupts_were_enabled := abstract_sockets_lock.acquire_irqsave()
		for i in 0 .. 64 {
			if abstract_sockets[i].in_use && abstract_sockets[i].name_len == name_len {
				if unsafe { C.memcmp(&abstract_sockets[i].name[0], &addr.sun_path[0], name_len) } == 0 {
					socket = abstract_sockets[i].socket
					break
				}
			}
		}
		abstract_sockets_lock.release_irqrestore(interrupts_were_enabled)
		if socket == unsafe { nil } {
			errno.set(errno.econnrefused)
			return none
		}
	} else {
		mut t := proc.current_thread()
		path := unsafe { cstring_to_vstring(&addr.sun_path[0]) }

		mut target := fs.get_node(t.process.current_directory, path, true) or {
			return none
		}

		mut target_res := target.resource

		if mut target_res is UnixSocket {
			socket = target_res
		} else {
			errno.set(errno.econnrefused)
			return none
		}
	}

	socket.l.acquire()
	if socket.closed || !socket.listening {
		socket.l.release()
		errno.set(errno.econnrefused)
		return none
	}

	this.connect_error = 0
	socket.backlog << this

	socket.status |= file.pollin
	event.trigger(mut socket.event, false)

	socket.l.release()

	mut events := [&this.connection_event]
	event.await(mut events, true) or {
		socket.l.acquire()
		for i, pending in socket.backlog {
			if voidptr(pending) == voidptr(this) {
				socket.backlog.delete(i)
				if socket.backlog.len == 0 {
					socket.status &= ~file.pollin
				}
				break
			}
		}
		socket.l.release()
		unsafe { events.free() }
		errno.set(errno.eintr)
		return none
	}
	unsafe { events.free() }

	if !this.connected {
		errno.set(if this.connect_error != 0 { this.connect_error } else { errno.econnrefused })
		return none
	}
	this.status |= file.pollout
	event.trigger(mut this.event, false)
}

fn (mut this UnixSocket) bind(handle voidptr, _addr voidptr, addrlen u32) ? {
	addr := unsafe { &SockaddrUn(_addr) }

	if addr.sun_family != sock_pub.af_unix {
		errno.set(errno.einval)
		return none
	}

	// Validate the caller-supplied address length before deriving a copy size
	// from it below. An unchecked addrlen lets name_len exceed the fixed-size
	// abstract-socket name buffers, causing an out-of-bounds write.
	if addrlen < u32(sizeof(u16)) || addrlen > u32(sizeof(SockaddrUn)) {
		errno.set(errno.einval)
		return none
	}

	// Abstract socket: sun_path[0] == '\0', name is in sun_path[1..addrlen-2]
	if addrlen > 2 && addr.sun_path[0] == 0 {
		name_len := addrlen - 2 // subtract sizeof(sun_family)
		interrupts_were_enabled := abstract_sockets_lock.acquire_irqsave()
		defer {
			abstract_sockets_lock.release_irqrestore(interrupts_were_enabled)
		}
		// Check for duplicate
		for i in 0 .. 64 {
			if abstract_sockets[i].in_use && abstract_sockets[i].name_len == name_len {
				if unsafe { C.memcmp(&abstract_sockets[i].name[0], &addr.sun_path[0], name_len) } == 0 {
					errno.set(errno.eaddrinuse)
					return none
				}
			}
		}
		// Find free slot
		for i in 0 .. 64 {
			if !abstract_sockets[i].in_use {
				abstract_sockets[i].in_use = true
				abstract_sockets[i].name_len = name_len
				unsafe { C.memcpy(&abstract_sockets[i].name[0], &addr.sun_path[0], name_len) }
				abstract_sockets[i].socket = unsafe { this }
				this.abstract_bound = true
				this.name = *addr
				return
			}
		}
		// No free slots
		errno.set(errno.enomem)
		return none
	}

	mut t := proc.current_thread()

	path := unsafe { cstring_to_vstring(&addr.sun_path[0]) }

	mut node := fs.create(t.process.current_directory, path, stat.ifsock | 0o777) or {
		return none
	}

	this.stat = node.resource.stat
	node.resource = unsafe { this }

	this.name = *addr
}

fn (mut this UnixSocket) listen(handle voidptr, backlog int) ? {
	this.backlog = []&UnixSocket{cap: backlog}
	this.listening = true
}

fn (mut this UnixSocket) recvmsg(_handle voidptr, msg &sock_pub.MsgHdr, flags int) ?u64 {
	if flags != 0 {
		panic('UNIX socket recv does not support flags')
	}

	this.l.acquire()
	defer {
		this.l.release()
	}

	handle := unsafe { &file.Handle(_handle) }

	mut count := u64(0)
	for i := u64(0); i < msg.msg_iovlen; i++ {
		count += unsafe { msg.msg_iov[i].iov_len }
	}

	C.printf(c'%d iovecs, %llu bytes\n', msg.msg_iovlen, count)

	// If pipe is empty, block or return if nonblock
	for katomic.load(&this.used) == 0 {
		if this.peer_closed {
			unsafe {
				msg.msg_controllen = 0
				msg.msg_flags = 0
			}
			return 0
		}
		if !this.connected {
			errno.set(errno.enotconn)
			return none
		}
		if this.peer != unsafe { nil } {
			this.peer.status |= file.pollout
			event.trigger(mut this.peer.event, false)
		}
		if handle.flags & resource.o_nonblock != 0 {
			errno.set(errno.ewouldblock)
			return none
		}
		this.l.release()
		mut events := [&this.event]
		event.await(mut events, true) or {
			unsafe { events.free() }
			errno.set(errno.eintr)
			return none
		}
		unsafe { events.free() }
		this.l.acquire()
	}

	if this.used < count {
		count = this.used
	}

	// Calculate sizes before and after wrap-around and new ptr location
	mut before_wrap := u64(0)
	mut after_wrap := u64(0)
	mut new_ptr_loc := u64(0)
	if this.read_ptr + count > this.capacity {
		before_wrap = this.capacity - this.read_ptr
		after_wrap = count - before_wrap
		new_ptr_loc = after_wrap
	} else {
		before_wrap = count
		after_wrap = 0
		new_ptr_loc = this.read_ptr + count
		if new_ptr_loc == this.capacity {
			new_ptr_loc = 0
		}
	}

	mut tmpbuf := unsafe { &u8(malloc(before_wrap + after_wrap)) }
	unsafe { C.memcpy(tmpbuf, &this.data[this.read_ptr], before_wrap) }
	if after_wrap != 0 {
		unsafe { C.memcpy(voidptr(u64(tmpbuf) + before_wrap), this.data, after_wrap) }
	}

	mut transferred := u64(0)
	mut left := before_wrap + after_wrap
	for i := u64(0); i < msg.msg_iovlen; i++ {
		iov := unsafe { &msg.msg_iov[i] }

		to_transfer := if iov.iov_len < left { iov.iov_len } else { left }

		unsafe {
			C.memcpy(iov.iov_base, voidptr(u64(tmpbuf) + transferred), to_transfer)
		}

		transferred += to_transfer
		left -= to_transfer
	}

	unsafe { free(tmpbuf) }

	this.read_ptr = new_ptr_loc
	this.used -= transferred

	if this.peer != unsafe { nil } {
		this.peer.status |= file.pollout
		event.trigger(mut this.peer.event, false)
	}

	if msg.msg_name != unsafe { nil } && this.connected {
		buffer_size := msg.msg_namelen
		actual_size := u32(sizeof(SockaddrUn))
		copy_size := if buffer_size < actual_size { buffer_size } else { actual_size }

		unsafe { C.memcpy(msg.msg_name, voidptr(&this.peer.name), copy_size) }
		unsafe {
			msg.msg_namelen = actual_size
		}
	}

	// Unix sockets do not support ancillary data yet. recvmsg() still has to
	// report the amount of control data produced; leaving the input capacity in
	// msg_controllen makes callers parse uninitialised bytes as cmsghdrs.
	unsafe {
		msg.msg_controllen = 0
		msg.msg_flags = 0
	}

	C.printf(c'Successfully received %llu bytes\n', transferred)

	if this.used == 0 && !this.peer_closed {
		this.status &= ~file.pollin
	}

	return transferred
}

pub fn create(@type int) ?&UnixSocket {
	mut ret := &UnixSocket{
		refcount: 1
		peer:     unsafe { nil }
		data:     unsafe { malloc(sock_buf) }
		capacity: sock_buf
	}
	ret.name.sun_family = sock_pub.af_unix
	return ret
}

pub fn create_pair(@type int) ?(&UnixSocket, &UnixSocket) {
	mut a := &UnixSocket{
		refcount: 1
		data:     unsafe { malloc(sock_buf) }
		capacity: sock_buf
		connected: true
		status:    file.pollout
	}
	a.name.sun_family = sock_pub.af_unix
	mut b := &UnixSocket{
		refcount: 1
		data:     unsafe { malloc(sock_buf) }
		capacity: sock_buf
		connected: true
		status:    file.pollout
	}
	b.name.sun_family = sock_pub.af_unix
	a.peer = b
	b.peer = a
	return a, b
}
