module cache

import errno
import klock
import memory
import resource

// Cache filesystem reads in page-sized blocks. Four ways keep lookup and
// replacement bounded while avoiding the worst direct-mapped collisions.
pub const block_size = u64(4096)
pub const capacity = u64(4 * 1024 * 1024)

const set_count = u64(256)
const way_count = u64(4)
const entry_count = 1024

struct Entry {
mut:
	physical        voidptr
	data            voidptr
	block           u64
	last_used       u64
	load_generation u64
	valid_bytes     u64
	valid           bool
	loading         bool
}

pub struct Stats {
pub:
	hits           u64
	misses         u64
	evictions      u64
	bypasses       u64
	resident_pages u64
}

pub struct Cache {
mut:
	l           klock.Lock
	device      &resource.Resource
	device_size u64
	generation  u64
	clock       u64
	entries     [entry_count]Entry

	hits           u64
	misses         u64
	evictions      u64
	bypasses       u64
	resident_pages u64
}

pub fn new(device &resource.Resource) ?&Cache {
	if device == unsafe { nil } || device.stat.size <= 0 || device.stat.blksize <= 0 {
		errno.set(errno.einval)
		return none
	}

	logical_block_size := u64(device.stat.blksize)
	device_size := u64(device.stat.size)
	if logical_block_size > block_size || block_size % logical_block_size != 0
		|| device_size % logical_block_size != 0 {
		print('block cache: unsupported device geometry: size=${device_size}, block=${logical_block_size}\n')
		errno.set(errno.einval)
		return none
	}

	// Avoid constructing the large fixed entry table as a temporary on the
	// kernel stack. The cache metadata itself is heap-backed; data pages remain
	// lazy and are allocated one at a time on first use.
	mut cache := unsafe { &Cache(memory.malloc(sizeof(Cache))) }
	unsafe { C.memset(cache, 0, sizeof(Cache)) }
	cache.device = unsafe { device }
	cache.device_size = device_size
	return cache
}

fn (mut cache Cache) touch(mut entry Entry) {
	cache.clock++
	if cache.clock == 0 {
		// A wrap is practically unreachable, but zero is kept as the cold-entry
		// stamp so reset the live entry ordering if it ever happens.
		cache.clock = 1
		for mut candidate in cache.entries {
			if candidate.valid {
				candidate.last_used = 1
			}
		}
	}
	entry.last_used = cache.clock
}

fn (mut cache Cache) read_backing_block(block u64, data voidptr) ?u64 {
	start := block * block_size
	if start >= cache.device_size {
		errno.set(errno.eio)
		return none
	}

	mut count := block_size
	if count > cache.device_size - start {
		count = cache.device_size - start
	}
	read_count := cache.device.read(unsafe { nil }, data, start, count) or { return none }
	if read_count != i64(count) {
		errno.set(errno.eio)
		return none
	}
	return count
}

fn (mut cache Cache) read_uncached_piece(destination voidptr, block u64, offset u64, count u64) ? {
	physical := memory.pmm_alloc(1)
	data := voidptr(u64(physical) + memory.get_hhdm_offset())
	valid_bytes := cache.read_backing_block(block, data) or {
		memory.pmm_free(physical, 1)
		return none
	}
	if offset > valid_bytes || count > valid_bytes - offset {
		memory.pmm_free(physical, 1)
		errno.set(errno.eio)
		return none
	}
	unsafe { C.memcpy(destination, voidptr(u64(data) + offset), count) }
	memory.pmm_free(physical, 1)
}

fn (mut cache Cache) read_piece(destination voidptr, block u64, offset u64, count u64) ? {
	set_start := (block % set_count) * way_count
	mut victim := i64(-1)
	mut oldest_stamp := u64(0xffffffffffffffff)

	cache.l.acquire()
	for way := u64(0); way < way_count; way++ {
		index := set_start + way
		mut entry := &cache.entries[index]
		if entry.valid && entry.block == block {
			if offset > entry.valid_bytes || count > entry.valid_bytes - offset {
				cache.l.release()
				errno.set(errno.eio)
				return none
			}
			cache.hits++
			cache.touch(mut entry)
			unsafe { C.memcpy(destination, voidptr(u64(entry.data) + offset), count) }
			cache.l.release()
			return
		}
		if entry.loading && entry.block == block {
			// Do not wait while another CPU performs device I/O. A duplicate
			// uncached read is rare and avoids holding an IRQ-disabling spinlock
			// across a potentially interrupt-driven operation.
			cache.bypasses++
			cache.l.release()
			return cache.read_uncached_piece(destination, block, offset, count)
		}
		if !entry.loading && !entry.valid {
			victim = i64(index)
			break
		}
		if !entry.loading && entry.last_used < oldest_stamp {
			oldest_stamp = entry.last_used
			victim = i64(index)
		}
	}

	if victim < 0 {
		cache.bypasses++
		cache.l.release()
		return cache.read_uncached_piece(destination, block, offset, count)
	}

	mut entry := &cache.entries[u64(victim)]
	if entry.valid {
		cache.evictions++
	}
	entry.valid = false
	entry.loading = true
	entry.block = block
	entry.load_generation = cache.generation
	load_generation := entry.load_generation
	mut physical := entry.physical
	mut data := entry.data
	cache.misses++
	cache.l.release()

	if data == unsafe { nil } {
		physical = memory.pmm_alloc(1)
		data = voidptr(u64(physical) + memory.get_hhdm_offset())
		cache.l.acquire()
		entry.physical = physical
		entry.data = data
		cache.resident_pages++
		cache.l.release()
	}

	valid_bytes := cache.read_backing_block(block, data) or {
		cache.l.acquire()
		entry.loading = false
		entry.valid = false
		cache.l.release()
		return none
	}
	if offset > valid_bytes || count > valid_bytes - offset {
		cache.l.acquire()
		entry.loading = false
		entry.valid = false
		cache.l.release()
		errno.set(errno.eio)
		return none
	}

	cache.l.acquire()
	entry.valid_bytes = valid_bytes
	entry.loading = false
	entry.valid = load_generation == cache.generation
	if entry.valid {
		cache.touch(mut entry)
	}
	unsafe { C.memcpy(destination, voidptr(u64(data) + offset), count) }
	cache.l.release()
}

pub fn (mut cache Cache) read(destination voidptr, location u64, count u64) ?i64 {
	if count == 0 {
		return 0
	}
	if location > cache.device_size || count > cache.device_size - location {
		errno.set(errno.eio)
		return none
	}

	for completed := u64(0); completed < count; {
		position := location + completed
		block := position / block_size
		offset := position % block_size
		mut piece_size := count - completed
		if piece_size > block_size - offset {
			piece_size = block_size - offset
		}
		cache.read_piece(voidptr(u64(destination) + completed), block, offset, piece_size) or {
			return none
		}
		completed += piece_size
	}
	return i64(count)
}

// Invalidate before and after future writes. Incrementing the generation also
// prevents a read that was already in flight from publishing stale data.
pub fn (mut cache Cache) invalidate(location u64, count u64) {
	if count == 0 {
		return
	}
	first_block := location / block_size
	mut last_block := u64(0xffffffffffffffff)
	if count - 1 <= u64(0xffffffffffffffff) - location {
		last_block = (location + count - 1) / block_size
	}

	cache.l.acquire()
	cache.generation++
	for mut entry in cache.entries {
		if entry.valid && entry.block >= first_block && entry.block <= last_block {
			entry.valid = false
		}
	}
	cache.l.release()
}

pub fn (mut cache Cache) stats() Stats {
	cache.l.acquire()
	result := Stats{
		hits: cache.hits
		misses: cache.misses
		evictions: cache.evictions
		bypasses: cache.bypasses
		resident_pages: cache.resident_pages
	}
	cache.l.release()
	return result
}
