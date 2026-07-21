module fs

import stat
import klock
import memory
import memory.mmap
import resource
import lib
import event.eventstruct
import katomic

@[heap]
struct TmpFSResource {
pub mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool

	storage  &u8
	capacity u64
}

fn (mut this TmpFSResource) mmap(page u64, flags int) voidptr {
	this.l.acquire()
	defer {
		this.l.release()
	}

	if flags & mmap.map_shared != 0 {
		unsafe {
			return voidptr(u64(&this.storage[page * page_size]) - higher_half)
		}
	}

	copy_page := memory.pmm_alloc(1)

	unsafe {
		C.memcpy(voidptr(u64(copy_page) + higher_half), &this.storage[page * page_size],
			page_size)
	}

	return copy_page
}

fn (mut this TmpFSResource) read(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	this.l.acquire()
	defer {
		this.l.release()
	}

	size := u64(this.stat.size)

	// Reads starting at or beyond EOF return 0 bytes.
	if loc >= size {
		return i64(0)
	}

	// Clamp to the bytes actually available. Computing `size - loc` only after
	// the `loc >= size` guard avoids the u64 underflow/overflow that a crafted
	// loc/count pair (e.g. count near 2^64) would otherwise trigger.
	mut actual_count := count
	if actual_count > size - loc {
		actual_count = size - loc
	}

	unsafe { C.memcpy(buf, &this.storage[loc], actual_count) }

	return i64(actual_count)
}

fn (mut this TmpFSResource) write(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	this.l.acquire()
	defer {
		this.l.release()
	}

	// Reject requests whose end offset would overflow u64. Without this, the
	// wrapped value bypasses the capacity check below and leads to an
	// out-of-bounds memcpy into the storage buffer.
	if loc + count < loc {
		return none
	}

	end := loc + count

	if end > this.capacity {
		mut new_capacity := if this.capacity == 0 { u64(1) } else { this.capacity }

		for new_capacity < end {
			// Stop doubling before it overflows to 0 and loops forever; jump
			// straight to the needed size instead.
			if new_capacity > (~u64(0)) / 2 {
				new_capacity = end
				break
			}
			new_capacity *= 2
		}

		new_storage := memory.realloc(this.storage, new_capacity)

		if new_storage == 0 {
			return none
		}

		this.storage = new_storage
		this.capacity = new_capacity
	}

	unsafe { C.memcpy(&this.storage[loc], buf, count) }

	if end > u64(this.stat.size) {
		this.stat.size = i64(end)
		this.stat.blocks = lib.div_roundup(this.stat.size, this.stat.blksize)
	}

	return i64(count)
}

fn (mut this TmpFSResource) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	return resource.default_ioctl(handle, request, argp)
}

fn (mut this TmpFSResource) unref(handle voidptr) ? {
	katomic.dec(mut &this.refcount)

	if this.refcount != 0 {
		return
	}

	if stat.isreg(this.stat.mode) {
		memory.free(this.storage)
	}

	unsafe { free(this) }
}

fn (mut this TmpFSResource) link(handle voidptr) ? {
	katomic.inc(mut &this.stat.nlink)
}

fn (mut this TmpFSResource) unlink(handle voidptr) ? {
	katomic.dec(mut &this.stat.nlink)
}

fn (mut this TmpFSResource) grow(handle voidptr, new_size u64) ? {
	this.l.acquire()
	defer {
		this.l.release()
	}

	mut new_capacity := this.capacity
	for new_size > new_capacity {
		new_capacity *= 2
	}

	new_storage := memory.realloc(this.storage, new_capacity)

	if new_storage == 0 {
		return none
	}

	this.storage = new_storage
	this.capacity = new_capacity

	this.stat.size = new_size
	this.stat.blocks = lib.div_roundup(new_size, u64(this.stat.blksize))
}

struct TmpFS {
pub mut:
	dev_id        u64
	inode_counter u64
}

fn (this TmpFS) instantiate() &FileSystem {
	new := &TmpFS{}
	return new
}

fn (this TmpFS) populate(node &VFSNode) {}

fn (mut this TmpFS) mount(parent &VFSNode, name string, source &VFSNode) ?&VFSNode {
	this.dev_id = resource.create_dev_id()
	return this.create(parent, name, 0o755 | stat.ifdir)
}

fn (mut this TmpFS) create(parent &VFSNode, name string, mode u32) &VFSNode {
	mut new_node := create_node(this, parent, name, stat.isdir(mode))

	mut new_resource := &TmpFSResource{
		storage:  unsafe { nil }
		refcount: 1
	}

	if stat.isreg(mode) {
		new_resource.capacity = 4096
		new_resource.storage = memory.malloc(new_resource.capacity)
		new_resource.can_mmap = true
	}

	new_resource.stat.size = 0
	new_resource.stat.blocks = 0
	new_resource.stat.blksize = 512
	new_resource.stat.dev = this.dev_id
	new_resource.stat.ino = this.inode_counter++
	new_resource.stat.mode = mode
	new_resource.stat.nlink = 1

	new_resource.stat.atim = realtime_clock
	new_resource.stat.ctim = realtime_clock
	new_resource.stat.mtim = realtime_clock

	new_node.resource = new_resource

	return new_node
}

fn (mut this TmpFS) link(parent &VFSNode, path string, mut old_node VFSNode) ?&VFSNode {
	mut new_node := create_node(this, parent, path, false)

	katomic.inc(mut &old_node.resource.refcount)

	new_node.resource = old_node.resource
	new_node.children = old_node.children

	return new_node
}

fn (mut this TmpFS) symlink(parent &VFSNode, dest string, target string) &VFSNode {
	mut new_node := create_node(this, parent, target, false)

	mut new_resource := &TmpFSResource{
		storage:  unsafe { nil }
		refcount: 1
	}

	new_resource.stat.size = u64(target.len)
	new_resource.stat.blocks = 0
	new_resource.stat.blksize = 512
	new_resource.stat.dev = this.dev_id
	new_resource.stat.ino = this.inode_counter++
	new_resource.stat.mode = stat.iflnk | 0o777
	new_resource.stat.nlink = 1

	new_resource.stat.atim = realtime_clock
	new_resource.stat.ctim = realtime_clock
	new_resource.stat.mtim = realtime_clock

	new_node.resource = new_resource

	new_node.symlink_target = dest.clone()

	return new_node
}
