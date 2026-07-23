module uacpi

import klock
import event
import event.eventstruct
import time
import x86.kio
import memory
import lib
import kprint
import lib.stubs
import x86.hpet
import x86.idt
import x86.apic
import x86.cpu.local as cpulocal
import pci
import proc
import sched

pub enum UACPIStatus {
	ok                      = 0
	mapping_failed          = 1
	out_of_memory           = 2
	bad_checksum            = 3
	invalid_signature       = 4
	invalid_table_length    = 5
	not_found               = 6
	invalid_argument        = 7
	unimplemented           = 8
	already_exists          = 9
	internal_error          = 10
	type_mismatch           = 11
	init_level_mismatch     = 12
	namespace_node_dangling = 13
	no_handler              = 14
	no_resource_end_tag     = 15
	compiled_out            = 16
	hardware_timeout        = 17
	timeout                 = 18
	overridden              = 19
	denied                  = 20
}

pub enum InterruptModel {
	pic     = 0
	ioapic  = 1
	iosapic = 2
}

@[c_extern]
fn C.uacpi_initialize(flags u64) UACPIStatus
@[c_extern]
fn C.uacpi_namespace_load() UACPIStatus
@[c_extern]
fn C.uacpi_namespace_initialize() UACPIStatus
@[c_extern]
fn C.uacpi_set_interrupt_model(InterruptModel) UACPIStatus
@[c_extern]
fn C.uacpi_status_to_string(UACPIStatus) charptr
fn C.vinix_call_void_fn_with_arg(handler voidptr, arg voidptr)
fn C.vinix_call_u32_fn_with_arg(handler voidptr, arg voidptr) u32

const uacpi_infinite_timeout = u16(0xffff)
const uacpi_work_queue_capacity = u64(256)

struct UACPIMutex {
mut:
	state_lock klock.Lock
	wake       eventstruct.Event
	held       bool
	owner      voidptr
}

struct UACPIEvent {
mut:
	state_lock klock.Lock
	wake       eventstruct.Event
	count      u64
}

struct UACPIWorkItem {
	handler   voidptr
	ctx       voidptr
	work_type int
}

struct UACPIInterrupt {
mut:
	irq       u32
	vector    u8
	handler   voidptr
	ctx       voidptr
	installed bool
	in_flight u64
}

struct UACPIIOHandle {
	base u16
	len  u32
}

struct UACPIFirmwareRequest {
	request_type u8
	padding0     [7]u8
	fatal_type   u8
	padding1     [3]u8
	fatal_code   u32
	fatal_arg    u64
}

__global (
	uacpi_work_lock            klock.Lock
	uacpi_work_available       eventstruct.Event
	uacpi_work_completed       eventstruct.Event
	uacpi_work_queue           [256]UACPIWorkItem
	uacpi_work_head            u64
	uacpi_work_tail            u64
	uacpi_work_count           u64
	uacpi_work_outstanding     u64
	uacpi_work_runtime_started bool
	uacpi_interrupt_lock       klock.Lock
	uacpi_interrupt_completed  eventstruct.Event
	uacpi_interrupts_by_vector [256]voidptr
	uacpi_interrupts_in_flight u64
	uacpi_interrupt_thread_ids [256]u8
)

pub fn initialise() {
	runtime_status := start_runtime()
	if runtime_status != UACPIStatus.ok {
		panic('uACPI host runtime: ${runtime_status}')
	}

	mut status := C.uacpi_initialize(0)
	if status != UACPIStatus.ok {
		panic('uacpi_initialize(): ${C.uacpi_status_to_string(status)}')
	}

	status = C.uacpi_namespace_load()
	if status != UACPIStatus.ok {
		panic('uacpi_namespace_load(): ${C.uacpi_status_to_string(status)}')
	}

	status = C.uacpi_set_interrupt_model(InterruptModel.ioapic)
	if status != UACPIStatus.ok {
		panic('uacpi_set_interrupt_model(): ${C.uacpi_status_to_string(status)}')
	}

	status = C.uacpi_namespace_initialize()
	if status != UACPIStatus.ok {
		panic('uacpi_namespace_initialize(): ${C.uacpi_status_to_string(status)}')
	}
}

@[export: 'uacpi_kernel_log']
pub fn uacpi_kernel_log(level int, str charptr) {
	kprint.kwrite(str, stubs.strlen(str))
}

@[export: 'uacpi_kernel_get_rsdp']
pub fn uacpi_kernel_get_rsdp(phys &u64) UACPIStatus {
	unsafe {
		*phys = u64(rsdp) - higher_half
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_create_spinlock']
pub fn uacpi_kernel_create_spinlock() voidptr {
	mut l := &klock.Lock{}
	return unsafe { voidptr(l) }
}

@[export: 'uacpi_kernel_free_spinlock']
pub fn uacpi_kernel_free_spinlock(handle voidptr) {
	mut l := unsafe { &klock.Lock(handle) }
	unsafe {
		l.free()
		free(l)
	}
}

@[export: 'uacpi_kernel_lock_spinlock']
pub fn uacpi_kernel_lock_spinlock(handle voidptr) u64 {
	mut l := unsafe { &klock.Lock(handle) }
	l.acquire()
	return if l.ints { u64(1) } else { u64(0) }
}

@[export: 'uacpi_kernel_unlock_spinlock']
pub fn uacpi_kernel_unlock_spinlock(handle voidptr, cpu_flags u64) {
	_ = cpu_flags
	mut l := unsafe { &klock.Lock(handle) }
	l.release()
}

fn timeout_to_timespec(timeout u16) time.TimeSpec {
	return time.TimeSpec{
		tv_sec:  i64(timeout) / 1000
		tv_nsec: (i64(timeout) % 1000) * 1000000
	}
}

fn acquire_mutex_forever(mut mutex UACPIMutex, owner voidptr) UACPIStatus {
	mut events := [&mutex.wake]
	defer {
		unsafe {
			events.free()
		}
	}

	for {
		mutex.state_lock.acquire()
		if !mutex.held {
			mutex.held = true
			mutex.owner = owner
			mutex.state_lock.release()
			return UACPIStatus.ok
		}
		if mutex.owner == owner {
			mutex.state_lock.release()
			return UACPIStatus.denied
		}

		event.await_interlocked(mut events, true, mut mutex.state_lock) or {}
	}

	return UACPIStatus.internal_error
}

fn acquire_mutex_until_timeout(mut mutex UACPIMutex, owner voidptr, timeout u16) UACPIStatus {
	mut timer := time.new_timer(timeout_to_timespec(timeout))
	mut events := [&mutex.wake, &timer.event]
	defer {
		timer.disarm()
		unsafe {
			events.free()
			timer.free()
			free(timer)
		}
	}

	for {
		mutex.state_lock.acquire()
		if !mutex.held {
			mutex.held = true
			mutex.owner = owner
			mutex.state_lock.release()
			return UACPIStatus.ok
		}
		if mutex.owner == owner {
			mutex.state_lock.release()
			return UACPIStatus.denied
		}

		which := event.await_interlocked(mut events, true, mut mutex.state_lock) or { continue }
		if which == 1 {
			mutex.state_lock.acquire()
			if !mutex.held {
				mutex.held = true
				mutex.owner = owner
				mutex.state_lock.release()
				return UACPIStatus.ok
			}
			mutex.state_lock.release()
			return UACPIStatus.timeout
		}
	}

	return UACPIStatus.internal_error
}

@[export: 'uacpi_kernel_acquire_mutex']
pub fn uacpi_kernel_acquire_mutex(handle voidptr, timeout u16) UACPIStatus {
	if handle == unsafe { nil } {
		return UACPIStatus.invalid_argument
	}

	mut mutex := unsafe { &UACPIMutex(handle) }
	owner := uacpi_kernel_get_thread_id()

	mutex.state_lock.acquire()
	if !mutex.held {
		mutex.held = true
		mutex.owner = owner
		mutex.state_lock.release()
		return UACPIStatus.ok
	}
	if mutex.owner == owner {
		mutex.state_lock.release()
		return UACPIStatus.denied
	}
	mutex.state_lock.release()

	if timeout == 0 {
		return UACPIStatus.timeout
	}
	if timeout == uacpi_infinite_timeout {
		return acquire_mutex_forever(mut mutex, owner)
	}
	return acquire_mutex_until_timeout(mut mutex, owner, timeout)
}

@[export: 'uacpi_kernel_release_mutex']
pub fn uacpi_kernel_release_mutex(handle voidptr) {
	if handle == unsafe { nil } {
		return
	}

	mut mutex := unsafe { &UACPIMutex(handle) }
	mutex.state_lock.acquire()
	if !mutex.held || mutex.owner != uacpi_kernel_get_thread_id() {
		mutex.state_lock.release()
		return
	}
	mutex.held = false
	mutex.owner = unsafe { nil }
	mutex.state_lock.release()
	event.trigger(mut mutex.wake, true)
}

@[export: 'uacpi_kernel_create_mutex']
pub fn uacpi_kernel_create_mutex() voidptr {
	mut mutex := &UACPIMutex{}
	return voidptr(mutex)
}

@[export: 'uacpi_kernel_free_mutex']
pub fn uacpi_kernel_free_mutex(handle voidptr) {
	if handle == unsafe { nil } {
		return
	}
	mut mutex := unsafe { &UACPIMutex(handle) }
	unsafe {
		mutex.free()
		free(mutex)
	}
}

@[export: 'uacpi_kernel_create_event']
pub fn uacpi_kernel_create_event() voidptr {
	mut e := &UACPIEvent{}
	return voidptr(e)
}

@[export: 'uacpi_kernel_free_event']
pub fn uacpi_kernel_free_event(handle voidptr) {
	if handle == unsafe { nil } {
		return
	}
	mut e := unsafe { &UACPIEvent(handle) }
	unsafe {
		e.free()
		free(e)
	}
}

@[export: 'uacpi_kernel_signal_event']
pub fn uacpi_kernel_signal_event(handle voidptr) {
	if handle == unsafe { nil } {
		return
	}
	mut e := unsafe { &UACPIEvent(handle) }
	e.state_lock.acquire()
	if e.count != u64(-1) {
		e.count++
	}
	e.state_lock.release()
	event.trigger(mut e.wake, true)
}

fn wait_for_event_until_timeout(mut e UACPIEvent, timeout u16) bool {
	mut timer := time.new_timer(timeout_to_timespec(timeout))
	mut events := [&e.wake, &timer.event]
	defer {
		timer.disarm()
		unsafe {
			events.free()
			timer.free()
			free(timer)
		}
	}

	for {
		e.state_lock.acquire()
		if e.count > 0 {
			e.count--
			e.state_lock.release()
			return true
		}

		which := event.await_interlocked(mut events, true, mut e.state_lock) or { continue }
		if which == 1 {
			e.state_lock.acquire()
			if e.count > 0 {
				e.count--
				e.state_lock.release()
				return true
			}
			e.state_lock.release()
			return false
		}
	}

	return false
}

fn wait_for_event_forever(mut e UACPIEvent) bool {
	mut events := [&e.wake]
	defer {
		unsafe {
			events.free()
		}
	}

	for {
		e.state_lock.acquire()
		if e.count > 0 {
			e.count--
			e.state_lock.release()
			return true
		}
		event.await_interlocked(mut events, true, mut e.state_lock) or {}
	}

	return false
}

@[export: 'uacpi_kernel_wait_for_event']
pub fn uacpi_kernel_wait_for_event(handle voidptr, timeout u16) bool {
	if handle == unsafe { nil } {
		return false
	}

	mut e := unsafe { &UACPIEvent(handle) }
	e.state_lock.acquire()
	if e.count > 0 {
		e.count--
		e.state_lock.release()
		return true
	}
	e.state_lock.release()
	if timeout == 0 {
		return false
	}
	if timeout == uacpi_infinite_timeout {
		return wait_for_event_forever(mut e)
	}
	return wait_for_event_until_timeout(mut e, timeout)
}

@[export: 'uacpi_kernel_reset_event']
pub fn uacpi_kernel_reset_event(handle voidptr) {
	if handle == unsafe { nil } {
		return
	}
	mut e := unsafe { &UACPIEvent(handle) }
	e.state_lock.acquire()
	e.count = 0
	e.state_lock.release()
}

@[export: 'uacpi_kernel_stall']
pub fn uacpi_kernel_stall(usec u8) {
	deadline := uacpi_kernel_get_nanoseconds_since_boot() + u64(usec) * 1000
	for uacpi_kernel_get_nanoseconds_since_boot() < deadline {
		asm volatile amd64 {
			pause
			; ; ; memory
		}
	}
}

@[export: 'uacpi_kernel_sleep']
pub fn uacpi_kernel_sleep(msec u64) {
	target_time := time.TimeSpec{
		tv_sec:  u64(msec) / 1000
		tv_nsec: (u64(msec) % 1000) * 1000000
	}
	mut timer := time.new_timer(target_time)
	defer {
		timer.disarm()
		unsafe {
			timer.free()
			free(timer)
		}
	}
	mut events := [&timer.event]
	event.await(mut events, true) or {}
}

@[export: 'uacpi_kernel_alloc']
pub fn uacpi_kernel_alloc(size u64) voidptr {
	return unsafe { malloc(size) }
}

@[export: 'uacpi_kernel_free']
pub fn uacpi_kernel_free(ptr voidptr) {
	unsafe { free(ptr) }
}

fn uacpi_work_thread(_ voidptr) {
	mut available_events := [&uacpi_work_available]
	for {
		uacpi_work_lock.acquire()
		for uacpi_work_count == 0 {
			event.await_interlocked(mut available_events, true, mut uacpi_work_lock) or {}
			uacpi_work_lock.acquire()
		}

		item := uacpi_work_queue[uacpi_work_head]
		uacpi_work_head = (uacpi_work_head + 1) % uacpi_work_queue_capacity
		uacpi_work_count--
		uacpi_work_lock.release()

		C.vinix_call_void_fn_with_arg(item.handler, item.ctx)

		uacpi_work_lock.acquire()
		if uacpi_work_outstanding == 0 {
			uacpi_work_lock.release()
			panic('uACPI work accounting underflow')
		}
		uacpi_work_outstanding--
		completed := uacpi_work_outstanding == 0
		uacpi_work_lock.release()
		if completed {
			event.trigger(mut uacpi_work_completed, true)
		}
	}
}

fn start_runtime() UACPIStatus {
	uacpi_work_lock.acquire()
	if uacpi_work_runtime_started {
		uacpi_work_lock.release()
		return UACPIStatus.already_exists
	}
	uacpi_work_lock.release()

	mut worker := sched.new_kernel_thread(voidptr(uacpi_work_thread), unsafe { nil }, false)
	worker.affinity = 0
	if !sched.enqueue_thread(worker, false) {
		return UACPIStatus.out_of_memory
	}

	uacpi_work_lock.acquire()
	uacpi_work_runtime_started = true
	uacpi_work_lock.release()
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_schedule_work']
pub fn uacpi_kernel_schedule_work(work_type int, work_handler voidptr, handle voidptr) UACPIStatus {
	if work_handler == unsafe { nil } || work_type < 0 || work_type > 1 {
		return UACPIStatus.invalid_argument
	}

	uacpi_work_lock.acquire()
	if !uacpi_work_runtime_started {
		uacpi_work_lock.release()
		return UACPIStatus.init_level_mismatch
	}
	if uacpi_work_count == uacpi_work_queue_capacity {
		uacpi_work_lock.release()
		return UACPIStatus.out_of_memory
	}

	uacpi_work_queue[uacpi_work_tail] = UACPIWorkItem{
		handler:   work_handler
		ctx:       handle
		work_type: work_type
	}
	uacpi_work_tail = (uacpi_work_tail + 1) % uacpi_work_queue_capacity
	uacpi_work_count++
	uacpi_work_outstanding++
	uacpi_work_lock.release()

	event.trigger(mut uacpi_work_available, true)
	return UACPIStatus.ok
}

fn wait_for_interrupt_completion() {
	mut events := [&uacpi_interrupt_completed]
	defer {
		unsafe {
			events.free()
		}
	}
	for {
		uacpi_interrupt_lock.acquire()
		if uacpi_interrupts_in_flight == 0 {
			uacpi_interrupt_lock.release()
			return
		}

		event.await_interlocked(mut events, true, mut uacpi_interrupt_lock) or {}
	}
}

fn wait_for_scheduled_work() {
	mut events := [&uacpi_work_completed]
	defer {
		unsafe {
			events.free()
		}
	}
	for {
		uacpi_work_lock.acquire()
		if uacpi_work_outstanding == 0 {
			uacpi_work_lock.release()
			return
		}

		event.await_interlocked(mut events, true, mut uacpi_work_lock) or {}
	}
}

@[export: 'uacpi_kernel_wait_for_work_completion']
pub fn uacpi_kernel_wait_for_work_completion() UACPIStatus {
	wait_for_interrupt_completion()
	wait_for_scheduled_work()
	return UACPIStatus.ok
}

fn invoke_uacpi_interrupt(vector u32) bool {
	uacpi_interrupt_lock.acquire()
	handle := uacpi_interrupts_by_vector[vector]
	if handle == unsafe { nil } {
		uacpi_interrupt_lock.release()
		return false
	}

	mut irq_handle := unsafe { &UACPIInterrupt(handle) }
	if !irq_handle.installed {
		uacpi_interrupt_lock.release()
		return false
	}
	irq_handle.in_flight++
	uacpi_interrupts_in_flight++
	handler := irq_handle.handler
	ctx := irq_handle.ctx
	uacpi_interrupt_lock.release()

	C.vinix_call_u32_fn_with_arg(handler, ctx)

	uacpi_interrupt_lock.acquire()
	irq_handle.in_flight--
	uacpi_interrupts_in_flight--
	uacpi_interrupt_lock.release()
	event.trigger(mut uacpi_interrupt_completed, true)

	return true
}

fn uacpi_irq_dispatch(vector u32, _ voidptr) {
	invoke_uacpi_interrupt(vector)
	apic.lapic_eoi()
}

fn interrupt_source_is_installed(irq u32) bool {
	for handle in uacpi_interrupts_by_vector {
		if handle == unsafe { nil } {
			continue
		}
		irq_handle := unsafe { &UACPIInterrupt(handle) }
		if irq_handle.installed && irq_handle.irq == irq {
			return true
		}
	}
	return false
}

fn install_interrupt_handler(irq u32, interrupt_handler voidptr, ctx voidptr,
	out_irq_handle &voidptr, route_hardware bool) UACPIStatus {
	if interrupt_handler == unsafe { nil } || out_irq_handle == unsafe { nil } {
		return UACPIStatus.invalid_argument
	}
	if route_hardware && !apic.io_apic_can_route_irq(irq) {
		return UACPIStatus.not_found
	}

	mut irq_handle := &UACPIInterrupt{
		irq:       irq
		handler:   interrupt_handler
		ctx:       ctx
		installed: true
	}

	uacpi_interrupt_lock.acquire()
	if interrupt_source_is_installed(irq) {
		uacpi_interrupt_lock.release()
		unsafe {
			irq_handle.free()
			free(irq_handle)
		}
		return UACPIStatus.already_exists
	}

	vector := idt.allocate_vector()
	irq_handle.vector = vector
	uacpi_interrupts_by_vector[vector] = voidptr(irq_handle)
	interrupt_table[vector] = voidptr(uacpi_irq_dispatch)
	unsafe {
		*out_irq_handle = voidptr(irq_handle)
	}
	uacpi_interrupt_lock.release()

	if route_hardware {
		apic.io_apic_set_irq_redirect_u32(cpu_locals[0].lapic_id, vector, irq, true)
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_install_interrupt_handler']
pub fn uacpi_kernel_install_interrupt_handler(irq u32, interrupt_handler voidptr,
	ctx voidptr, out_irq_handle &voidptr) UACPIStatus {
	return install_interrupt_handler(irq, interrupt_handler, ctx, out_irq_handle, true)
}

fn uninstall_interrupt_handler(interrupt_handler voidptr, irq_handle voidptr,
	route_hardware bool) UACPIStatus {
	if interrupt_handler == unsafe { nil } || irq_handle == unsafe { nil } {
		return UACPIStatus.invalid_argument
	}

	mut installed_irq := unsafe { &UACPIInterrupt(irq_handle) }
	uacpi_interrupt_lock.acquire()
	if !installed_irq.installed || installed_irq.handler != interrupt_handler
		|| uacpi_interrupts_by_vector[installed_irq.vector] != irq_handle {
		uacpi_interrupt_lock.release()
		return UACPIStatus.not_found
	}
	installed_irq.installed = false
	uacpi_interrupt_lock.release()

	if route_hardware {
		apic.io_apic_set_irq_redirect_u32(cpu_locals[0].lapic_id, installed_irq.vector,
			installed_irq.irq, false)
	}

	mut completion_events := [&uacpi_interrupt_completed]
	defer {
		unsafe {
			completion_events.free()
		}
	}
	for {
		uacpi_interrupt_lock.acquire()
		if installed_irq.in_flight == 0 {
			uacpi_interrupts_by_vector[installed_irq.vector] = unsafe { nil }
			interrupt_table[installed_irq.vector] = unsafe { nil }
			uacpi_interrupt_lock.release()
			break
		}

		event.await_interlocked(mut completion_events, true, mut uacpi_interrupt_lock) or {}
	}

	idt.free_vector(installed_irq.vector)
	unsafe {
		installed_irq.free()
		free(installed_irq)
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_uninstall_interrupt_handler']
pub fn uacpi_kernel_uninstall_interrupt_handler(interrupt_handler voidptr, irq_handle voidptr) UACPIStatus {
	return uninstall_interrupt_handler(interrupt_handler, irq_handle, true)
}

@[export: 'uacpi_kernel_handle_firmware_request']
pub fn uacpi_kernel_handle_firmware_request(req voidptr) UACPIStatus {
	if req == unsafe { nil } {
		return UACPIStatus.invalid_argument
	}
	request := unsafe { &UACPIFirmwareRequest(req) }
	match request.request_type {
		0 {
			print('uACPI: AML Breakpoint request\n')
			return UACPIStatus.ok
		}
		1 {
			C.printf(c'uACPI: AML Fatal request type=0x%x code=0x%x arg=0x%llx\n',
				request.fatal_type, request.fatal_code, request.fatal_arg)
			return UACPIStatus.ok
		}
		else {
			return UACPIStatus.invalid_argument
		}
	}
}

@[export: 'uacpi_kernel_map']
pub fn uacpi_kernel_map(phys u64, len u64) voidptr {
	if len == 0 || phys > u64(-1) - len {
		return unsafe { nil }
	}

	aligned_phys := lib.align_down(phys, page_size)
	offset := phys - aligned_phys
	aligned_len := lib.align_up(len + offset, page_size)

	for i := u64(0); i < aligned_len; i += page_size {
		kernel_pagemap.map_page(higher_half + aligned_phys + i, aligned_phys + i,
			memory.pte_present | memory.pte_noexec | memory.pte_writable) or {
			return unsafe { nil }
		}
	}

	return voidptr(higher_half + phys)
}

@[export: 'uacpi_kernel_unmap']
pub fn uacpi_kernel_unmap(addr voidptr, len u64) {
	// uACPI mappings use Vinix's shared higher-half physical direct map.
	// Its page-table entries are kernel-global and intentionally live for the
	// lifetime of the kernel, so unmapping one consumer would invalidate other
	// users of the same physical page.
	_ = addr
	_ = len
}

@[export: 'uacpi_kernel_get_nanoseconds_since_boot']
pub fn uacpi_kernel_get_nanoseconds_since_boot() u64 {
	counter := hpet.read_counter()
	seconds := counter / hpet_frequency
	remainder := counter % hpet_frequency
	return seconds * 1000000000 + remainder * 1000000000 / hpet_frequency
}

@[export: 'uacpi_kernel_io_map']
pub fn uacpi_kernel_io_map(base u64, len u64, out_handle &voidptr) UACPIStatus {
	if out_handle == unsafe { nil } || len == 0 || base > 0xffff || len > 0x10000
		|| base + len > 0x10000 {
		return UACPIStatus.invalid_argument
	}
	mut handle := &UACPIIOHandle{
		base: u16(base)
		len:  u32(len)
	}
	unsafe {
		*out_handle = voidptr(handle)
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_io_unmap']
pub fn uacpi_kernel_io_unmap(handle voidptr) {
	if handle == unsafe { nil } {
		return
	}
	mut io_handle := unsafe { &UACPIIOHandle(handle) }
	unsafe {
		io_handle.free()
		free(io_handle)
	}
}

fn io_access_is_valid(handle voidptr, offset u64, width u64) bool {
	if handle == unsafe { nil } {
		return false
	}
	io_handle := unsafe { &UACPIIOHandle(handle) }
	return offset <= io_handle.len && width <= u64(io_handle.len) - offset
}

@[export: 'uacpi_kernel_io_read8']
pub fn uacpi_kernel_io_read8(handle voidptr, offset u64, out_value &u8) UACPIStatus {
	if out_value == unsafe { nil } || !io_access_is_valid(handle, offset, 1) {
		return UACPIStatus.invalid_argument
	}
	io_handle := unsafe { &UACPIIOHandle(handle) }
	unsafe {
		*out_value = kio.port_in[u8](u16(u64(io_handle.base) + offset))
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_io_read16']
pub fn uacpi_kernel_io_read16(handle voidptr, offset u64, out_value &u16) UACPIStatus {
	if out_value == unsafe { nil } || !io_access_is_valid(handle, offset, 2) {
		return UACPIStatus.invalid_argument
	}
	io_handle := unsafe { &UACPIIOHandle(handle) }
	unsafe {
		*out_value = kio.port_in[u16](u16(u64(io_handle.base) + offset))
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_io_read32']
pub fn uacpi_kernel_io_read32(handle voidptr, offset u64, out_value &u32) UACPIStatus {
	if out_value == unsafe { nil } || !io_access_is_valid(handle, offset, 4) {
		return UACPIStatus.invalid_argument
	}
	io_handle := unsafe { &UACPIIOHandle(handle) }
	unsafe {
		*out_value = kio.port_in[u32](u16(u64(io_handle.base) + offset))
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_io_write8']
pub fn uacpi_kernel_io_write8(handle voidptr, offset u64, value u8) UACPIStatus {
	if !io_access_is_valid(handle, offset, 1) {
		return UACPIStatus.invalid_argument
	}
	io_handle := unsafe { &UACPIIOHandle(handle) }
	kio.port_out[u8](u16(u64(io_handle.base) + offset), value)
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_io_write16']
pub fn uacpi_kernel_io_write16(handle voidptr, offset u64, value u16) UACPIStatus {
	if !io_access_is_valid(handle, offset, 2) {
		return UACPIStatus.invalid_argument
	}
	io_handle := unsafe { &UACPIIOHandle(handle) }
	kio.port_out[u16](u16(u64(io_handle.base) + offset), value)
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_io_write32']
pub fn uacpi_kernel_io_write32(handle voidptr, offset u64, value u32) UACPIStatus {
	if !io_access_is_valid(handle, offset, 4) {
		return UACPIStatus.invalid_argument
	}
	io_handle := unsafe { &UACPIIOHandle(handle) }
	kio.port_out[u32](u16(u64(io_handle.base) + offset), value)
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_get_thread_id']
pub fn uacpi_kernel_get_thread_id() voidptr {
	current := proc.current_thread()
	if current != unsafe { nil } {
		return voidptr(current)
	}

	cpu_number := cpulocal.current().cpu_number
	return voidptr(&uacpi_interrupt_thread_ids[cpu_number])
}

struct UACPIPCIAddress {
	segment  u16
	bus      u8
	device   u8
	function u8
}

@[export: 'uacpi_kernel_pci_device_open']
pub fn uacpi_kernel_pci_device_open(addr UACPIPCIAddress, out_handle &voidptr) UACPIStatus {
	if out_handle == unsafe { nil } || addr.segment != 0 || addr.device >= 32 || addr.function >= 8 {
		return UACPIStatus.invalid_argument
	}
	mut pci_device := &pci.PCIDevice{
		bus:      addr.bus
		slot:     addr.device
		function: addr.function
	}
	unsafe {
		*out_handle = voidptr(pci_device)
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_pci_device_close']
pub fn uacpi_kernel_pci_device_close(handle voidptr) {
	if handle == unsafe { nil } {
		return
	}
	mut pci_device := unsafe { &pci.PCIDevice(handle) }
	unsafe {
		pci_device.free()
		free(pci_device)
	}
}

@[export: 'uacpi_kernel_pci_read8']
pub fn uacpi_kernel_pci_read8(handle voidptr, offset u64, value &u8) UACPIStatus {
	if handle == unsafe { nil } || value == unsafe { nil } || offset >= 256 {
		return UACPIStatus.invalid_argument
	}
	mut pci_device := unsafe { &pci.PCIDevice(handle) }
	unsafe {
		*value = pci_device.read[u8](u32(offset))
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_pci_read16']
pub fn uacpi_kernel_pci_read16(handle voidptr, offset u64, value &u16) UACPIStatus {
	if handle == unsafe { nil } || value == unsafe { nil } || offset > 254 || offset & 3 > 2 {
		return UACPIStatus.invalid_argument
	}
	mut pci_device := unsafe { &pci.PCIDevice(handle) }
	unsafe {
		*value = pci_device.read[u16](u32(offset))
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_pci_read32']
pub fn uacpi_kernel_pci_read32(handle voidptr, offset u64, value &u32) UACPIStatus {
	if handle == unsafe { nil } || value == unsafe { nil } || offset > 252 || offset & 3 != 0 {
		return UACPIStatus.invalid_argument
	}
	mut pci_device := unsafe { &pci.PCIDevice(handle) }
	unsafe {
		*value = pci_device.read[u32](u32(offset))
	}
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_pci_write8']
pub fn uacpi_kernel_pci_write8(handle voidptr, offset u64, value u8) UACPIStatus {
	if handle == unsafe { nil } || offset >= 256 {
		return UACPIStatus.invalid_argument
	}
	mut pci_device := unsafe { &pci.PCIDevice(handle) }
	pci_device.write[u8](u32(offset), value)
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_pci_write16']
pub fn uacpi_kernel_pci_write16(handle voidptr, offset u64, value u16) UACPIStatus {
	if handle == unsafe { nil } || offset > 254 || offset & 3 > 2 {
		return UACPIStatus.invalid_argument
	}
	mut pci_device := unsafe { &pci.PCIDevice(handle) }
	pci_device.write[u16](u32(offset), value)
	return UACPIStatus.ok
}

@[export: 'uacpi_kernel_pci_write32']
pub fn uacpi_kernel_pci_write32(handle voidptr, offset u64, value u32) UACPIStatus {
	if handle == unsafe { nil } || offset > 252 || offset & 3 != 0 {
		return UACPIStatus.invalid_argument
	}
	mut pci_device := unsafe { &pci.PCIDevice(handle) }
	pci_device.write[u32](u32(offset), value)
	return UACPIStatus.ok
}
