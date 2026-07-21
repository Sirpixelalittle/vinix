@[has_globals]
module partition

import memory
import stat
import klock
import event.eventstruct
import resource
import lib
import fs

const gpt_signature = u64(0x5452415020494645)
const gpt_header_min_size = u32(92)
const max_gpt_entries = u32(4096)
const max_partitions = 128

__global (
	partition_list  [max_partitions]&Partition
	partition_count u64
)

struct Partition {
pub mut:
	stat     stat.Stat
	refcount int
	l        klock.Lock
	event    eventstruct.Event
	status   int
	can_mmap bool

	parent_device &resource.Resource
	device_offset u64
	sector_cnt    u64
	part_uuid     string
	device_path   string
}

@[packed]
struct MBRPartition {
pub mut:
	drive_status   u8
	starting_chs   [3]u8
	partition_type u8
	ending_chs     [3]u8
	starting_lba   u32
	sector_cnt     u32
}

struct GPTPartitionEntry {
pub mut:
	partition_type_guid [2]u64
	partition_guid      [2]u64
	starting_lba        u64
	last_lba            u64
	flags               u64
	name                [9]u64
}

@[packed]
struct GPTPartitionTableHDR {
pub mut:
	identifier            u64
	version               u32
	hdr_size              u32
	checksum              u32
	reserved0             u32
	hdr_lba               u64
	alt_hdr_lba           u64
	first_block           u64
	last_block            u64
	guid                  [2]u64
	partition_array_lba   u64
	partition_entry_cnt   u32
	partition_entry_size  u32
	crc32_partition_array u32
}

fn (mut this Partition) write(handle voidptr, buffer voidptr, loc u64, count u64) ?i64 {
	partition_size := this.sector_cnt * this.parent_device.stat.blksize
	if loc > partition_size || count > partition_size - loc {
		return none
	}

	return this.parent_device.write(handle, buffer, loc + this.device_offset, count)
}

fn (mut this Partition) read(handle voidptr, buffer voidptr, loc u64, count u64) ?i64 {
	partition_size := this.sector_cnt * this.parent_device.stat.blksize
	if loc > partition_size || count > partition_size - loc {
		return none
	}

	return this.parent_device.read(handle, buffer, loc + this.device_offset, count)
}

fn (mut this Partition) ioctl(handle voidptr, request u64, argp voidptr) ?int {
	return this.parent_device.ioctl(handle, request, argp)
}

fn (mut this Partition) unref(handle voidptr) ? {
	return this.parent_device.unref(handle)
}

fn (mut this Partition) link(handle voidptr) ? {
}

fn (mut this Partition) unlink(handle voidptr) ? {
}

fn (mut this Partition) grow(handle voidptr, new_size u64) ? {
	return this.parent_device.grow(handle, new_size)
}

fn (mut this Partition) mmap(page u64, flags int) voidptr {
	return this.parent_device.mmap(page, flags)
}

fn crc32(buffer voidptr, length u64) u32 {
	mut crc := u32(0xffffffff)
	for i := u64(0); i < length; i++ {
		crc ^= unsafe { (&u8(buffer))[i] }
		for _ in 0 .. 8 {
			mask := u32(0) - (crc & 1)
			crc = (crc >> 1) ^ (0xedb88320 & mask)
		}
	}
	return ~crc
}

fn format_gpt_uuid(uuid [2]u64) string {
	// GPT stores the first three UUID fields little-endian and the remaining
	// eight bytes in network order.
	byte_order := [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
	hyphens := [4, 6, 8, 10]
	hex := '0123456789abcdef'
	bytes := unsafe { &u8(&uuid[0]) }
	mut output := []u8{cap: 36}
	for i, source_index in byte_order {
		if i in hyphens {
			output << `-`
		}
		value := unsafe { bytes[source_index] }
		output << hex[int(value >> 4)]
		output << hex[int(value & 0xf)]
	}
	return output.bytestr()
}

fn remember_partition(partition &Partition) {
	if partition_count >= max_partitions {
		print('block: too many partitions; root lookup will ignore ${partition.device_path}\n')
		return
	}
	partition_list[partition_count] = unsafe { partition }
	partition_count++
}

fn uuid_equal(left string, right string) bool {
	if left.len != right.len {
		return false
	}
	for i, left_char in left {
		mut right_char := right[i]
		if right_char >= `A` && right_char <= `F` {
			right_char += 32
		}
		if left_char != right_char {
			return false
		}
	}
	return true
}

pub fn find_by_uuid(uuid string) string {
	for i := u64(0); i < partition_count; i++ {
		partition := partition_list[i]
		if partition != unsafe { nil } && uuid_equal(partition.part_uuid, uuid) {
			return partition.device_path
		}
	}
	return ''
}

pub fn scan_partitions(mut parent_device resource.Resource, prefix string) int {
	if parent_device.stat.blksize < 512 || parent_device.stat.size < parent_device.stat.blksize * 2 {
		print('block: device is too small to contain a partition table\n')
		return -1
	}

	block_size := u64(parent_device.stat.blksize)
	device_size := u64(parent_device.stat.size)
	device_blocks := u64(parent_device.stat.blocks)
	lba_buffer := memory.malloc(block_size)
	defer {
		memory.free(lba_buffer)
	}

	parent_device.read(0, lba_buffer, block_size, block_size) or {
		print('block: unable to read from device\n')
		return -1
	}

	gpt_hdr := unsafe { *&GPTPartitionTableHDR(lba_buffer) }

	if gpt_hdr.identifier == gpt_signature {
		if gpt_hdr.hdr_size < gpt_header_min_size || gpt_hdr.hdr_size > block_size
			|| gpt_hdr.hdr_lba != 1 || gpt_hdr.alt_hdr_lba >= device_blocks {
			print('gpt: invalid header geometry\n')
			return -1
		}

		checksum_location := unsafe { &u32(u64(lba_buffer) + 16) }
		stored_checksum := unsafe { *checksum_location }
		unsafe {
			*checksum_location = 0
		}
		calculated_checksum := crc32(lba_buffer, gpt_hdr.hdr_size)
		unsafe {
			*checksum_location = stored_checksum
		}
		if calculated_checksum != stored_checksum {
			print('gpt: header CRC32 mismatch\n')
			return -1
		}

		entry_list_lba := gpt_hdr.partition_array_lba
		entry_cnt := gpt_hdr.partition_entry_cnt
		entry_data_size := u64(gpt_hdr.partition_entry_size) * u64(entry_cnt)
		entry_list_size := lib.align_up(entry_data_size, block_size)
		entry_list_offset := entry_list_lba * block_size

		if entry_cnt == 0 || entry_cnt > max_gpt_entries
			|| gpt_hdr.partition_entry_size != sizeof(GPTPartitionEntry)
			|| entry_list_lba >= device_blocks || entry_list_offset > device_size
			|| entry_list_size > device_size - entry_list_offset {
			print('gpt: fatal parsing error\n')
			return -1
		}

		partition_entry_buffer := memory.malloc(entry_list_size)
		defer {
			memory.free(partition_entry_buffer)
		}

		parent_device.read(0, partition_entry_buffer, entry_list_offset, entry_list_size) or {
			print('block: unable to read from device\n')
			return -1
		}
		if crc32(partition_entry_buffer, entry_data_size) != gpt_hdr.crc32_partition_array {
			print('gpt: partition array CRC32 mismatch\n')
			return -1
		}

		partition_entry_list := unsafe { &GPTPartitionEntry(partition_entry_buffer) }

		for i := 0; i < entry_cnt; i++ {
			partition_entry := unsafe { &GPTPartitionEntry(&partition_entry_list[i]) }

			if partition_entry.partition_type_guid[0] == 0
				&& partition_entry.partition_type_guid[1] == 0 {
				continue
			}
			if partition_entry.starting_lba < gpt_hdr.first_block
				|| partition_entry.last_lba > gpt_hdr.last_block
				|| partition_entry.starting_lba > partition_entry.last_lba {
				print('gpt: ignoring partition ${i} with invalid bounds\n')
				continue
			}

			device_name := '${prefix}${i}'
			part_uuid := format_gpt_uuid(partition_entry.partition_guid)

			mut partition := &Partition{
				device_offset: partition_entry.starting_lba * block_size
				sector_cnt:    partition_entry.last_lba - partition_entry.starting_lba + 1
				parent_device: unsafe { parent_device }
				part_uuid:     part_uuid
				device_path:   '/dev/${device_name}'
			}

			partition.stat.blocks = partition.sector_cnt
			partition.stat.blksize = parent_device.stat.blksize
			partition.stat.size = i64(partition.sector_cnt * block_size)
			partition.stat.rdev = resource.create_dev_id()
			partition.stat.mode = 0o644 | stat.ifblk

			print('gpt: partition detected [start: ${partition.device_offset:x} sector cnt: ${partition.sector_cnt} uuid: ${part_uuid}]\n')

			fs.devtmpfs_add_device(partition, device_name)
			remember_partition(partition)
		}

		return 0
	}

	parent_device.read(0, lba_buffer, 0, block_size) or {
		print('block: unable to read from device\n')
		return -1
	}

	mbr_signature := unsafe { &u16(lba_buffer)[255] }

	if mbr_signature == 0xaa55 {
		partitions := unsafe { &MBRPartition(u64(lba_buffer) + 0x1be) }

		for i := 0; i < 4; i++ {
			if unsafe { partitions[i].partition_type } == 0
				|| unsafe { partitions[i].partition_type } == 0xee {
				continue
			}

			partition_entry := unsafe { &MBRPartition(&partitions[i]) }
			if partition_entry.starting_lba >= device_blocks || partition_entry.sector_cnt == 0
				|| u64(partition_entry.sector_cnt) > device_blocks - partition_entry.starting_lba {
				print('mbr: ignoring partition ${i} with invalid bounds\n')
				continue
			}

			device_name := '${prefix}${i}'

			mut partition := &Partition{
				device_offset: u64(partition_entry.starting_lba) * block_size
				sector_cnt:    partition_entry.sector_cnt
				parent_device: unsafe { parent_device }
				device_path:   '/dev/${device_name}'
			}

			partition.stat.blocks = partition.sector_cnt
			partition.stat.blksize = parent_device.stat.blksize
			partition.stat.size = i64(partition.sector_cnt * block_size)
			partition.stat.rdev = resource.create_dev_id()
			partition.stat.mode = 0o644 | stat.ifblk

			print('mbr: partition detected [start: ${partition.device_offset:x} sector cnt: ${partition.sector_cnt}]\n')

			fs.devtmpfs_add_device(partition, device_name)
		}

		return 0
	}

	return -1
}
