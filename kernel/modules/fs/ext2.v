module fs

import stat
import klock
import resource as kres
import lib
import event.eventstruct
import memory
import errno
import block.cache

const supported_incompatible_features = u32(0x2) // directory entry file types
const supported_readonly_features = u32(0x3) // sparse superblocks and large files
const max_symlink_size = u64(4096)

@[packed]
struct EXT2Superblock {
pub mut:
	inode_cnt          u32
	block_cnt          u32
	sb_reserved        u32
	unallocated_blocks u32
	unallocated_inodes u32
	sb_block           u32
	block_size         u32
	frag_size          u32
	blocks_per_group   u32
	frags_per_group    u32
	inodes_per_group   u32
	last_mnt_time      u32
	last_written_time  u32
	mnt_cnt            u16
	mnt_allowed        u16
	signature          u16
	fs_state           u16
	error_response     u16
	version_min        u16
	last_fsck          u32
	forced_fsck        u32
	os_id              u32
	version_maj        u32
	user_id            u16
	group_id           u16

	first_inode            u32
	inode_size             u16
	sb_bgd                 u16
	opt_features           u32
	req_features           u32
	non_supported_features u32
	uuid                   [2]u64
	volume_name            [2]u64
	last_mnt_path          [8]u64
}

@[packed]
struct EXT2BlockGroupDescriptor {
pub mut:
	block_addr_bitmap  u32
	block_addr_inode   u32
	inode_table_block  u32
	unallocated_blocks u16
	unallocated_inodes u16
	dir_cnt            u16
	reserved           [7]u16
}

@[packed]
struct EXT2Inode {
pub mut:
	permissions   u16
	user_id       u16
	size32l       u32
	access_time   u32
	creation_time u32
	mod_time      u32
	del_time      u32
	group_id      u16
	hard_link_cnt u16
	sector_cnt    u32
	flags         u32
	oss1          u32
	blocks        [15]u32
	gen_num       u32
	eab           u32
	size32h       u32
	frag_addr     u32
}

@[packed]
struct EXT2DirectoryEntry {
pub mut:
	inode_index u32
	entry_size  u16
	name_length u8
	dir_type    u8
}

struct EXT2Resource {
pub mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool

	filesystem &EXT2Filesystem
}

fn (mut this EXT2Resource) mmap(page u64, flags int) voidptr {
	return 0
}

fn (mut this EXT2Resource) read(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	mut current_inode := &EXT2Inode{}

	current_inode.read_entry(mut this.filesystem, u32(this.stat.ino)) or { return none }

	return current_inode.read(mut this.filesystem, buf, loc, count)
}

fn (mut this EXT2Resource) write(handle voidptr, buf voidptr, loc u64, count u64) ?i64 {
	if this.filesystem.read_only {
		errno.set(errno.erofs)
		return none
	}
	mut current_inode := &EXT2Inode{}

	current_inode.read_entry(mut this.filesystem, u32(this.stat.ino)) or { return none }

	return current_inode.write(mut this.filesystem, buf, u32(this.stat.ino), loc, count)
}

fn (mut this EXT2Resource) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	return kres.default_ioctl(handle, request, argp)
}

fn (mut this EXT2Resource) unref(handle voidptr) ? {
	this.refcount--
}

fn (mut this EXT2Resource) link(handle voidptr) ? {
	if this.filesystem.read_only {
		errno.set(errno.erofs)
		return none
	}
}

fn (mut this EXT2Resource) unlink(handle voidptr) ? {
	if this.filesystem.read_only {
		errno.set(errno.erofs)
		return none
	}
}

fn (mut this EXT2Resource) grow(handle voidptr, new_size u64) ? {
	if this.filesystem.read_only {
		errno.set(errno.erofs)
		return none
	}
	this.l.acquire()
	defer {
		this.l.release()
	}

	mut current_inode := &EXT2Inode{}

	current_inode.read_entry(mut this.filesystem, u32(this.stat.ino)) or { return none }

	current_inode.resize(mut this.filesystem, u32(this.stat.ino), 0, new_size) or { return none }
}

struct EXT2Filesystem {
pub mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool

	dev_id u64

	superblock &EXT2Superblock
	root_inode &EXT2Inode

	block_size u64
	frag_size  u64
	bgd_cnt    u64
	read_only  bool

	backing_device &VFSNode
	block_cache    &cache.Cache
}

fn (inode &EXT2Inode) file_size() u64 {
	if (inode.permissions & stat.ifmt) == stat.ifreg {
		return u64(inode.size32l) | (u64(inode.size32h) << 32)
	}
	return inode.size32l
}

fn (mut inode EXT2Inode) read_symlink(mut filesystem EXT2Filesystem) ?string {
	size := inode.file_size()
	if size == 0 || size > max_symlink_size {
		return none
	}
	buffer := memory.calloc(size + 1, 1)
	if size <= 60 {
		unsafe {
			C.memcpy(buffer, voidptr(&inode.blocks[0]), size)
		}
	} else {
		inode.read(mut filesystem, buffer, 0, size) or {
			memory.free(buffer)
			return none
		}
	}
	return unsafe { tos(&u8(buffer), int(size)) }
}

fn (mut this EXT2Filesystem) populate(node &VFSNode) {
	mut parent := &EXT2Inode{}
	parent.read_entry(mut this, u32(node.resource.stat.ino)) or { return }

	buffer := &voidptr(memory.calloc(parent.size32l, 1))
	defer {
		memory.free(buffer)
	}
	parent.read(mut this, buffer, 0, parent.size32l) or { return }

	for i := u32(0); i < parent.size32l; {
		dir_entry := unsafe { &EXT2DirectoryEntry(voidptr(u64(buffer) + i)) }
		if dir_entry.entry_size < sizeof(EXT2DirectoryEntry)
			|| u64(i) + dir_entry.entry_size > parent.size32l
			|| u16(dir_entry.name_length) > dir_entry.entry_size - sizeof(EXT2DirectoryEntry) {
			print('ext2: invalid directory entry\n')
			return
		}
		if dir_entry.inode_index == 0 {
			i += dir_entry.entry_size
			continue
		}

		name_buffer := memory.calloc(dir_entry.name_length + 1, 1)
		unsafe {
			C.memcpy(name_buffer, voidptr(u64(dir_entry) + sizeof(EXT2DirectoryEntry)),
				u64(dir_entry.name_length))
		}
		name := unsafe { tos(&u8(name_buffer), dir_entry.name_length) }

		if name == '.' || name == '..' {
			memory.free(name_buffer)
			i += dir_entry.entry_size
			continue
		}

		mut inode := &EXT2Inode{}
		inode.read_entry(mut this, dir_entry.inode_index) or { return }

		mut mode := inode.permissions

		if mode & stat.ifmt == 0 {
			match dir_entry.dir_type {
				1 { mode |= stat.ifreg }
				2 { mode |= stat.ifdir }
				3 { mode |= stat.ifchr }
				4 { mode |= stat.ifblk }
				5 { mode |= stat.ififo }
				6 { mode |= stat.ifsock }
				7 { mode |= stat.iflnk }
				else {}
			}
		}

		mut vfs_node := create_node(this, node, name, stat.isdir(mode))
		mut resource := &EXT2Resource{
			filesystem: unsafe { this }
		}

		resource.stat.mode = mode
		resource.stat.ino = dir_entry.inode_index
		resource.stat.size = i64(inode.file_size())
		resource.stat.nlink = inode.hard_link_cnt
		resource.stat.uid = inode.user_id
		resource.stat.gid = inode.group_id
		resource.stat.blksize = this.block_size
		resource.stat.blocks = inode.sector_cnt

		resource.stat.atim = realtime_clock
		resource.stat.ctim = realtime_clock
		resource.stat.mtim = realtime_clock

		vfs_node.resource = resource
		if stat.islnk(resource.stat.mode) {
			vfs_node.symlink_target = inode.read_symlink(mut this) or {
				print('ext2: unable to read symlink ${name}\n')
				''
			}
		}

		unsafe {
			vfs_node.parent.children[name] = vfs_node
		}
		i += dir_entry.entry_size
	}
}

fn (mut this EXT2Filesystem) initialise(source &VFSNode) bool {
	this.backing_device = unsafe { source }
	this.superblock = &EXT2Superblock{}
	this.root_inode = &EXT2Inode{}
	this.read_only = true
	this.block_cache = unsafe { nil }

	this.raw_device_read(this.superblock, 1024, sizeof(EXT2Superblock)) or {
		print('ext2: unable to read superblock\n')
		return false
	}
	if this.superblock.signature != 0xef53 {
		return false
	}
	if this.superblock.req_features & ~supported_incompatible_features != 0
		|| this.superblock.non_supported_features & ~supported_readonly_features != 0 {
		print('ext2: filesystem uses unsupported features\n')
		return false
	}
	if this.superblock.block_size > 6 || this.superblock.frag_size > 6
		|| this.superblock.blocks_per_group == 0 || this.superblock.inodes_per_group == 0
		|| this.superblock.inode_size < sizeof(EXT2Inode) {
		print('ext2: invalid superblock geometry\n')
		return false
	}

	this.block_size = 1024 << this.superblock.block_size
	this.frag_size = 1024 << this.superblock.frag_size
	this.bgd_cnt = lib.div_roundup(this.superblock.block_cnt, this.superblock.blocks_per_group)
	this.block_cache = cache.new(this.backing_device.resource) or {
		print('ext2: unable to initialise block cache\n')
		return false
	}

	print('ext2: filesystem detected on device ${pathname(this.backing_device)}\n')
	print('ext2: inode count: ${this.superblock.inode_cnt}\n')
	print('ext2: inodes per group: ${this.superblock.inodes_per_group:x}\n')
	print('ext2: block count: ${this.superblock.block_cnt:x}\n')
	print('ext2: blocks per group: ${this.superblock.blocks_per_group:x}\n')
	print('ext2: block size: ${this.block_size:x}\n')
	print('ext2: bgd count: ${this.bgd_cnt:x}\n')
	print('ext2: block cache: ${cache.capacity / 1024 / 1024} MiB maximum, allocated lazily\n')

	this.root_inode.read_entry(mut this, 2) or {
		print('ext2: unable to read root inode\n')
		return false
	}
	if this.root_inode.permissions & stat.ifmt != stat.ifdir {
		print('ext2: root inode is not a directory\n')
		return false
	}
	return true
}

fn (mut this EXT2Filesystem) instantiate() &FileSystem {
	return &EXT2Filesystem{
		backing_device: unsafe { nil }
		superblock:     unsafe { nil }
		root_inode:     unsafe { nil }
		block_cache:    unsafe { nil }
		read_only:      true
	}
}

pub fn register_ext2() {
	add_filesystem(&EXT2Filesystem{
		backing_device: unsafe { nil }
		superblock:     unsafe { nil }
		root_inode:     unsafe { nil }
		block_cache:    unsafe { nil }
		read_only:      true
	}, 'ext2')
}

fn (mut this EXT2Filesystem) symlink(parent &VFSNode, dest string, target string) &VFSNode {
	if this.read_only {
		errno.set(errno.erofs)
		return unsafe { nil }
	}
	mut new_node := create_node(this, parent, target, false)

	mut resource := &EXT2Resource{
		filesystem: unsafe { this }
	}

	resource.stat.size = target.len
	resource.stat.blocks = 0
	resource.stat.blksize = 512
	resource.stat.dev = this.dev_id
	resource.stat.ino = parent.resource.stat.ino
	resource.stat.nlink = 1

	resource.stat.atim = realtime_clock
	resource.stat.ctim = realtime_clock
	resource.stat.mtim = realtime_clock

	new_node.symlink_target = dest.clone()
	new_node.resource = resource

	return new_node
}

fn (mut this EXT2Filesystem) create(parent &VFSNode, name string, mode u32) &VFSNode {
	if this.read_only {
		errno.set(errno.erofs)
		return unsafe { nil }
	}
	mut new_node := create_node(this, parent, name, stat.isdir(mode))

	mut resource := &EXT2Resource{
		filesystem: unsafe { this }
	}

	resource.stat.size = 0
	resource.stat.blocks = 0
	resource.stat.blksize = this.block_size
	resource.stat.dev = this.dev_id
	resource.stat.mode = mode
	resource.stat.nlink = 1

	resource.stat.atim = realtime_clock
	resource.stat.ctim = realtime_clock
	resource.stat.mtim = realtime_clock

	resource.stat.ino = this.allocate_inode() or { return 0 }

	mut parent_inode := &EXT2Inode{}
	parent_inode.read_entry(mut this, u32(parent.resource.stat.ino)) or { return 0 }

	mut file_type := u8(0)

	if stat.isreg(mode) {
		file_type = 1
	} else if stat.isdir(mode) {
		file_type = 2
	} else if stat.ischr(mode) {
		file_type = 3
	} else if stat.isblk(mode) {
		file_type = 4
	} else if stat.isifo(mode) {
		file_type = 5
	} else if stat.issock(mode) {
		file_type = 6
	} else if stat.islnk(mode) {
		file_type = 7
	}

	this.dir_create_entry(mut parent_inode, u32(parent.resource.stat.ino), u32(resource.stat.ino),
		file_type, name) or { return 0 }

	new_node.resource = resource

	return new_node
}

fn (mut this EXT2Filesystem) link(parent &VFSNode, path string, mut old_node VFSNode) ?&VFSNode {
	errno.set(errno.erofs)
	return none
}

fn (mut this EXT2Filesystem) mount(parent &VFSNode, name string, source &VFSNode) ?&VFSNode {
	if unsafe { source == nil } || !this.initialise(source) {
		return none
	}
	this.dev_id = kres.create_dev_id()

	mut target := create_node(this, parent, name, true)

	mut resource := &EXT2Resource{
		filesystem: unsafe { this }
	}

	resource.stat.size = i64(this.root_inode.file_size())
	resource.stat.blksize = this.block_size
	resource.stat.blocks = this.root_inode.sector_cnt
	resource.stat.dev = this.dev_id
	resource.stat.mode = this.root_inode.permissions
	resource.stat.uid = this.root_inode.user_id
	resource.stat.gid = this.root_inode.group_id
	resource.stat.nlink = this.root_inode.hard_link_cnt
	resource.stat.ino = 2

	resource.stat.atim = realtime_clock
	resource.stat.ctim = realtime_clock
	resource.stat.mtim = realtime_clock

	target.filesystem = unsafe { this }
	target.resource = resource

	return target
}

fn (mut filesystem EXT2Filesystem) dir_create_entry(mut parent EXT2Inode, parent_inode_index u32, new_inode u32, dir_type u8, name string) ?int {
	buffer := &voidptr(memory.calloc(parent.size32l, 1))
	parent.read(mut filesystem, buffer, 0, parent.size32l) or { return none }

	mut found := false

	for i := u32(0); i < parent.size32l; {
		mut dir_entry := unsafe { &EXT2DirectoryEntry(voidptr(u64(buffer) + i)) }

		if found == true {
			dir_entry.inode_index = new_inode
			dir_entry.dir_type = dir_type
			dir_entry.name_length = u8(name.len)
			dir_entry.entry_size = u16(parent.size32l - i)

			unsafe {
				C.memcpy(voidptr(u64(dir_entry) + sizeof(EXT2DirectoryEntry)), name.str, name.len)
			}

			parent.write(mut filesystem, buffer, parent_inode_index, 0, parent.size32l) or {
				return none
			}

			return 0
		}

		expected_size := lib.align_up(sizeof(EXT2DirectoryEntry) + dir_entry.name_length, 4)
		if dir_entry.entry_size != expected_size {
			dir_entry.entry_size = u16(expected_size)
			i += u32(expected_size)

			found = true

			continue
		}

		i += dir_entry.entry_size
	}

	memory.free(buffer)

	return none
}

fn (mut inode EXT2Inode) read(mut filesystem EXT2Filesystem, buf voidptr, off u64, cnt u64) ?i64 {
	mut count := cnt
	total_size := inode.file_size()

	if off > total_size {
		return 0
	}

	if count > total_size - off {
		count = total_size - off
	}

	for headway := u64(0); headway < count; {
		iblock := (off + headway) / filesystem.block_size

		mut size := count - headway
		offset := (off + headway) % filesystem.block_size

		if size > (filesystem.block_size - offset) {
			size = filesystem.block_size - offset
		}

		disk_block := inode.get_block(mut filesystem, u32(iblock)) or { return none }

		if disk_block == 0 {
			unsafe { C.memset(voidptr(u64(buf) + headway), 0, size) }
		} else {
			filesystem.raw_device_read(voidptr(u64(buf) + headway),

				disk_block * filesystem.block_size + offset, size) or { return none }
		}

		headway += size
	}

	return i64(count)
}

fn (mut inode EXT2Inode) resize(mut filesystem EXT2Filesystem, inode_index u32, start u64, cnt u64) ?int {
	sector_size := u64(filesystem.backing_device.resource.stat.blksize)

	if (start + cnt) < (inode.sector_cnt * sector_size) {
		return 0
	}

	iblock_start := lib.div_roundup(inode.sector_cnt * sector_size, filesystem.block_size)
	iblock_end := lib.div_roundup(start + cnt, filesystem.block_size)

	if inode.size32l < (start + cnt) {
		inode.size32l = u32(start + cnt)
	}

	for i := iblock_start; i < iblock_end; i++ {
		disk_block := filesystem.allocate_block() or { return none }

		inode.sector_cnt = u32(filesystem.block_size / sector_size)

		inode.set_block(mut filesystem, inode_index, u32(i), disk_block) or { return none }
	}

	inode.write_entry(mut filesystem, inode_index) or { return none }

	return 0
}

fn (mut inode EXT2Inode) write(mut filesystem EXT2Filesystem, buf voidptr, inode_index u32, off u64, cnt u64) ?i64 {
	inode.resize(mut filesystem, inode_index, off, cnt) or { return none }

	for headway := u64(0); headway < cnt; {
		iblock := (off + headway) / filesystem.block_size

		mut size := cnt - headway
		offset := (off + headway) % filesystem.block_size

		if size > (filesystem.block_size - offset) {
			size = filesystem.block_size - offset
		}

		disk_block := inode.get_block(mut filesystem, u32(iblock)) or { return none }

		filesystem.raw_device_write(voidptr(u64(buf) + headway),

			disk_block * filesystem.block_size + offset, size) or { return none }

		headway += size
	}

	return i64(cnt)
}

fn (mut inode EXT2Inode) free_entry(mut filesystem EXT2Filesystem, inode_index u32) ?int {
	for i := u64(0); i < lib.div_roundup(inode.sector_cnt * u64(filesystem.backing_device.resource.stat.blksize),
		filesystem.block_size); i++ {
		block_index := inode.get_block(mut filesystem, u32(i)) or { return none }

		filesystem.free_block(block_index) or { return none }

		inode.set_block(mut filesystem, inode_index, u32(i), 0) or { return none }
	}

	filesystem.free_inode(inode_index) or { return none }

	return 0
}

fn (mut inode EXT2Inode) set_block(mut filesystem EXT2Filesystem, inode_index u32, iblock u32, disk_block u32) ?u32 {
	mut block := iblock
	blocks_per_level := u32(filesystem.block_size / 4)

	if block < 12 {
		inode.blocks[block] = disk_block
		return disk_block
	}

	block -= 12

	if block >= blocks_per_level {
		block -= blocks_per_level

		single_index := block / blocks_per_level
		mut indirect_offset := block % blocks_per_level
		mut indirect_block := u32(0)

		if single_index >= blocks_per_level {
			block -= blocks_per_level * blocks_per_level

			double_indirect_index := block / blocks_per_level
			indirect_offset = block % blocks_per_level
			mut single_indirect_index := u32(0)

			if inode.blocks[14] == 0 {
				inode.blocks[14] = filesystem.allocate_block() or { return none }

				inode.write_entry(mut filesystem, inode_index) or { return none }
			}

			filesystem.raw_device_read(voidptr(&single_indirect_index),

				inode.blocks[14] * filesystem.block_size + double_indirect_index * 4, 4) or {
				return none
			}

			if single_indirect_index == 0 {
				new_block := filesystem.allocate_block() or { return none }

				filesystem.raw_device_write(voidptr(&new_block),

					inode.blocks[14] * filesystem.block_size + double_indirect_index * 4, 4) or {
					return none
				}

				single_indirect_index = new_block
			}

			filesystem.raw_device_read(voidptr(&indirect_block),

				double_indirect_index * filesystem.block_size + single_indirect_index * 4, 4) or {
				return none
			}

			if indirect_block == 0 {
				new_block := filesystem.allocate_block() or { return none }

				filesystem.raw_device_write(voidptr(&indirect_block),

					double_indirect_index * filesystem.block_size + single_indirect_index * 4, 4) or {
					return none
				}

				indirect_block = new_block
			}

			filesystem.raw_device_write(voidptr(&disk_block),

				indirect_block * filesystem.block_size + indirect_offset * 4, 4) or { return none }

			return disk_block
		}

		if inode.blocks[13] == 0 {
			inode.blocks[13] = filesystem.allocate_block() or { return none }

			inode.write_entry(mut filesystem, inode_index) or { return none }
		}

		filesystem.raw_device_read(voidptr(&indirect_block),

			inode.blocks[13] * filesystem.block_size + single_index * 4, 4) or { return none }

		if indirect_block == 0 {
			new_block := filesystem.allocate_block() or { return none }

			filesystem.raw_device_write(voidptr(&new_block),

				inode.blocks[13] * filesystem.block_size + single_index * 4, 4) or { return none }

			indirect_block = new_block
		}

		filesystem.raw_device_write(voidptr(&disk_block), indirect_block * filesystem.block_size +
			indirect_offset * 4, 4) or { return none }

		return disk_block
	} else {
		if inode.blocks[12] == 0 {
			inode.blocks[12] = filesystem.allocate_block() or { return none }

			inode.write_entry(mut filesystem, inode_index) or { return none }
		}

		filesystem.raw_device_write(voidptr(&disk_block),

			inode.blocks[12] * filesystem.block_size + block * 4, 4) or { return none }
	}

	return disk_block
}

fn (mut inode EXT2Inode) get_block(mut filesystem EXT2Filesystem, iblock u32) ?u32 {
	mut disk_block_index := u32(0)
	mut block := iblock
	blocks_per_level := u32(filesystem.block_size / 4)

	if block < 12 {
		disk_block_index = inode.blocks[iblock]
		return disk_block_index
	}

	block -= 12

	if block >= blocks_per_level {
		block -= blocks_per_level

		single_index := block / blocks_per_level
		mut indirect_offset := block % blocks_per_level
		indirect_block := u32(0)

		if single_index >= blocks_per_level {
			block -= blocks_per_level * blocks_per_level

			double_indirect_index := block / blocks_per_level
			indirect_offset = block % blocks_per_level
			single_indirect_index := u32(0)

			filesystem.raw_device_read(voidptr(&single_indirect_index),

				inode.blocks[14] * filesystem.block_size + double_indirect_index * 4, 4) or {
				return none
			}

			filesystem.raw_device_read(voidptr(&indirect_block),

				double_indirect_index * filesystem.block_size + single_indirect_index * 4, 4) or {
				return none
			}

			filesystem.raw_device_read(voidptr(&disk_block_index),

				indirect_block * filesystem.block_size + indirect_offset * 4, 4) or { return none }

			return disk_block_index
		}

		filesystem.raw_device_read(voidptr(&indirect_block),

			inode.blocks[13] * filesystem.block_size + single_index * 4, 4) or { return none }

		filesystem.raw_device_read(voidptr(&disk_block_index),

			indirect_block * filesystem.block_size + indirect_offset * 4, 4) or { return none }

		return disk_block_index
	}

	filesystem.raw_device_read(voidptr(&disk_block_index),

		inode.blocks[12] * filesystem.block_size + block * 4, 4) or { return none }

	return disk_block_index
}

fn (mut filesystem EXT2Filesystem) allocate_block() ?u32 {
	mut bgd := &EXT2BlockGroupDescriptor{}

	for i := u32(0); i < filesystem.bgd_cnt; i++ {
		bgd.read_entry(mut filesystem, i)

		block_index := bgd.allocate_block(mut filesystem, i) or { continue }

		return u32(block_index + i * filesystem.superblock.blocks_per_group)
	}

	return none
}

fn (mut filesystem EXT2Filesystem) allocate_inode() ?u64 {
	mut bgd := &EXT2BlockGroupDescriptor{}

	for i := u32(0); i < filesystem.bgd_cnt; i++ {
		bgd.read_entry(mut filesystem, i)

		inode_index := bgd.allocate_inode(mut filesystem, i) or { continue }

		return inode_index + i * filesystem.superblock.blocks_per_group
	}

	return none
}

fn (mut filesystem EXT2Filesystem) free_block(block u32) ?int {
	bgd_index := block / filesystem.superblock.blocks_per_group
	bitmap_index := block - bgd_index * filesystem.superblock.blocks_per_group
	bitmap := memory.calloc(lib.div_roundup(filesystem.block_size, u64(8)), 1)

	mut bgd := &EXT2BlockGroupDescriptor{}
	bgd.read_entry(mut filesystem, bgd_index)

	filesystem.raw_device_read(bitmap, bgd.block_addr_bitmap * filesystem.block_size,
		filesystem.block_size) or {
		print('ext2: unable to read bgd bitmap\n')
		return none
	}

	if lib.bittest(bitmap, bitmap_index) == false {
		memory.free(bitmap)
		return 0
	}

	lib.bitreset(bitmap, bitmap_index)

	filesystem.raw_device_write(bitmap, bgd.block_addr_bitmap * filesystem.block_size,
		filesystem.block_size) or {
		print('ext2: unable to write bgd bitmap\n')
		return none
	}

	bgd.unallocated_blocks++
	bgd.write_entry(mut filesystem, bgd_index)

	memory.free(bitmap)

	return 0
}

fn (mut filesystem EXT2Filesystem) free_inode(inode u32) ?int {
	bgd_index := inode / filesystem.superblock.inodes_per_group
	bitmap_index := inode - bgd_index * filesystem.superblock.inodes_per_group
	bitmap := memory.calloc(lib.div_roundup(filesystem.block_size, u64(8)), 1)

	mut bgd := &EXT2BlockGroupDescriptor{}
	bgd.read_entry(mut filesystem, bgd_index)

	filesystem.raw_device_read(bitmap, bgd.block_addr_inode * filesystem.block_size,
		filesystem.block_size) or {
		print('ext2: unable to read inode bitmap\n')
		return none
	}

	if lib.bittest(bitmap, bitmap_index) == false {
		memory.free(bitmap)
		return 0
	}

	lib.bitreset(bitmap, bitmap_index)

	filesystem.raw_device_write(bitmap, bgd.block_addr_inode * filesystem.block_size,
		filesystem.block_size) or {
		print('ext2: unable to write inode bitmap\n')
		return none
	}

	bgd.unallocated_inodes++
	bgd.write_entry(mut filesystem, bgd_index)

	memory.free(bitmap)

	return 0
}

fn (mut bgd EXT2BlockGroupDescriptor) read_entry(mut filesystem EXT2Filesystem, bgd_index u32) int {
	mut bgd_offset := u64(0)

	if filesystem.block_size >= 2048 {
		bgd_offset = filesystem.block_size
	} else {
		bgd_offset = filesystem.block_size * 2
	}

	filesystem.raw_device_read(voidptr(&bgd), bgd_offset +
		sizeof(EXT2BlockGroupDescriptor) * bgd_index, sizeof(EXT2BlockGroupDescriptor)) or {
		print('ext2: unable to read bgd entry\n')
		return -1
	}

	return 0
}

fn (mut bgd EXT2BlockGroupDescriptor) write_entry(mut filesystem EXT2Filesystem, bgd_index u32) int {
	mut bgd_offset := u64(0)

	if filesystem.block_size >= 2048 {
		bgd_offset = filesystem.block_size
	} else {
		bgd_offset = filesystem.block_size * 2
	}

	filesystem.raw_device_write(voidptr(&bgd), bgd_offset +
		sizeof(EXT2BlockGroupDescriptor) * bgd_index, sizeof(EXT2BlockGroupDescriptor)) or {
		print('ext2: unable to read bgd entry\n')
		return -1
	}

	return 0
}

fn (mut bgd EXT2BlockGroupDescriptor) allocate_block(mut filesystem EXT2Filesystem, bgd_index u32) ?u64 {
	if bgd.unallocated_blocks == 0 {
		return none
	}

	bitmap := memory.calloc(lib.div_roundup(filesystem.block_size, u64(8)), 1)

	filesystem.raw_device_read(bitmap, bgd.block_addr_bitmap * filesystem.block_size,
		filesystem.block_size) or {
		print('ext2: unable to read bgd bitmap\n')
		return none
	}

	for i := u64(0); i < filesystem.block_size; i++ {
		if lib.bittest(bitmap, i) == false {
			lib.bitset(bitmap, i)

			filesystem.raw_device_write(bitmap, bgd.block_addr_bitmap * filesystem.block_size,
				filesystem.block_size) or {
				print('ext2: unable to write bgd bitmap\n')
				return none
			}

			bgd.unallocated_blocks--
			bgd.write_entry(mut filesystem, bgd_index)

			memory.free(bitmap)

			return i
		}
	}

	memory.free(bitmap)

	return none
}

fn (mut bgd EXT2BlockGroupDescriptor) allocate_inode(mut filesystem EXT2Filesystem, bgd_index u32) ?u64 {
	if bgd.unallocated_blocks == 0 {
		return none
	}

	bitmap := memory.calloc(lib.div_roundup(filesystem.block_size, u64(8)), 1)

	filesystem.raw_device_read(bitmap, bgd.block_addr_inode * filesystem.block_size,
		filesystem.block_size) or {
		print('ext2: unable to read inode bitmap\n')
		return none
	}

	for i := u64(0); i < filesystem.block_size; i++ {
		if lib.bittest(bitmap, i) == false {
			lib.bitset(bitmap, i)

			filesystem.raw_device_write(bitmap, bgd.block_addr_inode * filesystem.block_size,
				filesystem.block_size) or {
				print('ext2: unable to write inode bitmap\n')
				return none
			}

			bgd.unallocated_inodes--
			bgd.write_entry(mut filesystem, bgd_index)

			memory.free(bitmap)

			return i
		}
	}

	memory.free(bitmap)

	return none
}

fn (mut inode EXT2Inode) read_entry(mut filesystem EXT2Filesystem, inode_index u32) ?int {
	inode_table_index := (inode_index - 1) % filesystem.superblock.inodes_per_group
	bgd_index := (inode_index - 1) / filesystem.superblock.inodes_per_group

	mut bgd := &EXT2BlockGroupDescriptor{}
	bgd.read_entry(mut filesystem, bgd_index)

	filesystem.raw_device_read(voidptr(&inode), bgd.inode_table_block * filesystem.block_size +
		filesystem.superblock.inode_size * inode_table_index, sizeof(EXT2Inode)) or {
		print('ext2: unable to read inode entry\n')
		return none
	}

	return 0
}

fn (mut inode EXT2Inode) write_entry(mut filesystem EXT2Filesystem, inode_index u32) ?int {
	inode_table_index := (inode_index - 1) % filesystem.superblock.inodes_per_group
	bgd_index := (inode_index - 1) / filesystem.superblock.inodes_per_group

	mut bgd := &EXT2BlockGroupDescriptor{}
	bgd.read_entry(mut filesystem, bgd_index)

	filesystem.raw_device_write(voidptr(&inode), bgd.inode_table_block * filesystem.block_size +
		filesystem.superblock.inode_size * inode_table_index, sizeof(EXT2Inode)) or {
		print('ext2: unable to read inode entry\n')
		return none
	}

	return 0
}

fn (mut filesystem EXT2Filesystem) raw_device_read(buf voidptr, loc u64, count u64) ?i64 {
	if count == 0 {
		return 0
	}
	if filesystem.block_cache != unsafe { nil } {
		return filesystem.block_cache.read(buf, loc, count)
	}
	lba_size := u64(filesystem.backing_device.resource.stat.blksize)
	lba_start := loc / lba_size
	lba_offset := loc % lba_size
	lba_cnt := lib.div_roundup(lba_offset + count, lba_size)
	page_count := lib.div_roundup(lba_cnt * lba_size, page_size)

	buffer := voidptr(u64(memory.pmm_alloc(page_count)) + higher_half)
	defer {
		memory.pmm_free(voidptr(u64(buffer) - higher_half), page_count)
	}

	filesystem.backing_device.resource.read(0, buffer, lba_start * lba_size, lba_cnt * lba_size) or {
		print('ext2: unable to read from device\n')
		return none
	}

	unsafe { C.memcpy(buf, voidptr(u64(buffer) + lba_offset), count) }

	return i64(count)
}

fn (mut filesystem EXT2Filesystem) raw_device_write(buf voidptr, loc u64, count u64) ?i64 {
	if filesystem.read_only {
		errno.set(errno.erofs)
		return none
	}
	if count == 0 {
		return 0
	}
	if filesystem.block_cache != unsafe { nil } {
		filesystem.block_cache.invalidate(loc, count)
		defer {
			filesystem.block_cache.invalidate(loc, count)
		}
	}
	lba_size := u64(filesystem.backing_device.resource.stat.blksize)
	lba_start := loc / lba_size
	lba_offset := loc % lba_size
	lba_cnt := lib.div_roundup(lba_offset + count, lba_size)
	page_count := lib.div_roundup(lba_cnt * lba_size, page_size)

	buffer := voidptr(u64(memory.pmm_alloc(page_count)) + higher_half)
	defer {
		memory.pmm_free(voidptr(u64(buffer) - higher_half), page_count)
	}

	filesystem.backing_device.resource.read(0, buffer, lba_start * lba_size, lba_cnt * lba_size) or {
		print('ext2: unable to read from device\n')
		return none
	}

	unsafe { C.memcpy(voidptr(u64(buffer) + lba_offset), buf, count) }

	filesystem.backing_device.resource.write(0, buffer, lba_start * lba_size, lba_cnt * lba_size) or {
		print('ext2: unable to write to device\n')
		return none
	}

	return i64(count)
}
