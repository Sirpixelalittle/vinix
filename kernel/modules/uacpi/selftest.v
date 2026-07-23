module uacpi

const self_test_mutex_rounds = 32
const self_test_work_items = 200
const self_test_chained_items = 128
const self_test_interrupt_rounds = 32
const self_test_interrupts_per_round = 256
const self_test_irq = u32(-1)

struct UACPIHostSelfTest {
mut:
	mutex                 voidptr
	started               voidptr
	signalled              voidptr
	main_thread_id         voidptr
	worker_thread_id       voidptr
	mutex_status           UACPIStatus
	work_count             u64
	chain_remaining        u64
	chain_count            u64
	chain_status           UACPIStatus
	interrupt_vector       u8
	interrupt_count        u64
	interrupt_misses       u64
}

fn self_test_require(condition bool, description string) {
	if !condition {
		panic('uACPI host self-test failed: ${description}')
	}
}

fn self_test_signal_event(ctx voidptr) {
	mut test := unsafe { &UACPIHostSelfTest(ctx) }
	test.worker_thread_id = uacpi_kernel_get_thread_id()
	uacpi_kernel_signal_event(test.signalled)
}

fn self_test_mutex_timeout(ctx voidptr) {
	mut test := unsafe { &UACPIHostSelfTest(ctx) }
	test.worker_thread_id = uacpi_kernel_get_thread_id()
	uacpi_kernel_signal_event(test.started)
	test.mutex_status = uacpi_kernel_acquire_mutex(test.mutex, 10)
	if test.mutex_status == UACPIStatus.ok {
		uacpi_kernel_release_mutex(test.mutex)
	}
}

fn self_test_mutex_acquire(ctx voidptr) {
	mut test := unsafe { &UACPIHostSelfTest(ctx) }
	test.worker_thread_id = uacpi_kernel_get_thread_id()
	uacpi_kernel_signal_event(test.started)
	test.mutex_status = uacpi_kernel_acquire_mutex(test.mutex, uacpi_infinite_timeout)
	if test.mutex_status == UACPIStatus.ok {
		uacpi_kernel_release_mutex(test.mutex)
	}
}

fn self_test_count_work(ctx voidptr) {
	mut test := unsafe { &UACPIHostSelfTest(ctx) }
	test.work_count++
}

fn self_test_chain_work(ctx voidptr) {
	mut test := unsafe { &UACPIHostSelfTest(ctx) }
	test.chain_count++
	if test.chain_remaining == 0 {
		return
	}
	test.chain_remaining--
	status := uacpi_kernel_schedule_work(0, voidptr(self_test_chain_work), ctx)
	if status != UACPIStatus.ok {
		test.chain_status = status
	}
}

fn self_test_interrupt_handler(ctx voidptr) u32 {
	mut test := unsafe { &UACPIHostSelfTest(ctx) }
	test.interrupt_count++
	return 1
}

fn self_test_deliver_interrupts(ctx voidptr) {
	mut test := unsafe { &UACPIHostSelfTest(ctx) }
	for _ in 0 .. self_test_interrupts_per_round {
		if !invoke_uacpi_interrupt(test.interrupt_vector) {
			test.interrupt_misses++
		}
	}
}

fn run_event_self_test(mut test UACPIHostSelfTest) {
	for _ in 0 .. 1024 {
		uacpi_kernel_signal_event(test.signalled)
	}
	for _ in 0 .. 1024 {
		self_test_require(uacpi_kernel_wait_for_event(test.signalled, 0),
			'counting event lost a signal')
	}
	self_test_require(!uacpi_kernel_wait_for_event(test.signalled, 0),
		'counting event reported a spurious signal')

	uacpi_kernel_signal_event(test.signalled)
	uacpi_kernel_reset_event(test.signalled)
	self_test_require(!uacpi_kernel_wait_for_event(test.signalled, 0),
		'event reset did not clear pending signals')

	status := uacpi_kernel_schedule_work(0, voidptr(self_test_signal_event), voidptr(&test))
	self_test_require(status == UACPIStatus.ok, 'could not schedule event signal')
	self_test_require(uacpi_kernel_wait_for_event(test.signalled, uacpi_infinite_timeout),
		'event did not wake a blocked thread')
	uacpi_kernel_wait_for_work_completion()
}

fn run_mutex_self_test(mut test UACPIHostSelfTest) {
	for _ in 0 .. self_test_mutex_rounds {
		self_test_require(uacpi_kernel_acquire_mutex(test.mutex, 0) == UACPIStatus.ok,
			'main thread could not acquire mutex')
		test.mutex_status = UACPIStatus.internal_error
		mut status := uacpi_kernel_schedule_work(0, voidptr(self_test_mutex_timeout),
			voidptr(&test))
		self_test_require(status == UACPIStatus.ok, 'could not schedule timed mutex waiter')
		self_test_require(uacpi_kernel_wait_for_event(test.started, uacpi_infinite_timeout),
			'timed mutex waiter did not start')
		uacpi_kernel_sleep(20)
		uacpi_kernel_release_mutex(test.mutex)
		uacpi_kernel_wait_for_work_completion()
		self_test_require(test.mutex_status == UACPIStatus.timeout,
			'contended mutex did not time out')

		self_test_require(uacpi_kernel_acquire_mutex(test.mutex, 0) == UACPIStatus.ok,
			'main thread could not reacquire mutex')
		test.mutex_status = UACPIStatus.internal_error
		status = uacpi_kernel_schedule_work(0, voidptr(self_test_mutex_acquire), voidptr(&test))
		self_test_require(status == UACPIStatus.ok, 'could not schedule blocking mutex waiter')
		self_test_require(uacpi_kernel_wait_for_event(test.started, uacpi_infinite_timeout),
			'blocking mutex waiter did not start')
		uacpi_kernel_sleep(2)
		uacpi_kernel_release_mutex(test.mutex)
		uacpi_kernel_wait_for_work_completion()
		self_test_require(test.mutex_status == UACPIStatus.ok,
			'blocking mutex waiter did not acquire after release')
	}

	self_test_require(test.worker_thread_id != unsafe { nil },
		'deferred worker has no stable thread identity')
	self_test_require(test.worker_thread_id != test.main_thread_id,
		'deferred worker reused the caller thread identity')
}

fn run_work_self_test(mut test UACPIHostSelfTest) {
	test.work_count = 0
	for _ in 0 .. self_test_work_items {
		status := uacpi_kernel_schedule_work(0, voidptr(self_test_count_work), voidptr(&test))
		self_test_require(status == UACPIStatus.ok, 'deferred work queue rejected an item')
	}
	uacpi_kernel_wait_for_work_completion()
	self_test_require(test.work_count == self_test_work_items,
		'deferred work completion count is incorrect')

	test.chain_count = 0
	test.chain_remaining = self_test_chained_items - 1
	test.chain_status = UACPIStatus.ok
	status := uacpi_kernel_schedule_work(0, voidptr(self_test_chain_work), voidptr(&test))
	self_test_require(status == UACPIStatus.ok, 'could not start chained deferred work')
	uacpi_kernel_wait_for_work_completion()
	self_test_require(test.chain_status == UACPIStatus.ok,
		'chained deferred work could not schedule its successor')
	self_test_require(test.chain_count == self_test_chained_items,
		'completion returned before chained deferred work finished')
}

fn run_interrupt_self_test(mut test UACPIHostSelfTest) {
	handler := voidptr(self_test_interrupt_handler)
	for _ in 0 .. self_test_interrupt_rounds {
		mut irq_handle := voidptr(unsafe { nil })
		status := install_interrupt_handler(self_test_irq, handler, voidptr(&test),
			&irq_handle, false)
		self_test_require(status == UACPIStatus.ok,
			'could not install synthetic interrupt handler')
		self_test_require(irq_handle != unsafe { nil },
			'interrupt installation returned no handle')

		installed_irq := unsafe { &UACPIInterrupt(irq_handle) }
		test.interrupt_vector = installed_irq.vector
		test.interrupt_count = 0
		test.interrupt_misses = 0
		schedule_status := uacpi_kernel_schedule_work(0, voidptr(self_test_deliver_interrupts),
			voidptr(&test))
		self_test_require(schedule_status == UACPIStatus.ok,
			'could not schedule synthetic interrupt delivery')
		uacpi_kernel_wait_for_work_completion()
		self_test_require(test.interrupt_misses == 0,
			'installed interrupt handler was missing during delivery')
		self_test_require(test.interrupt_count == self_test_interrupts_per_round,
			'interrupt handler delivery count is incorrect')

		uninstall_status := uninstall_interrupt_handler(handler, irq_handle, false)
		self_test_require(uninstall_status == UACPIStatus.ok,
			'could not uninstall synthetic interrupt handler')
		self_test_require(!invoke_uacpi_interrupt(test.interrupt_vector),
			'uninstalled interrupt handler remained reachable')
	}
}

pub fn run_self_tests() {
	print('uACPI host self-test: starting\n')
	uacpi_kernel_wait_for_work_completion()

	mut test := &UACPIHostSelfTest{
		mutex:           uacpi_kernel_create_mutex()
		started:         uacpi_kernel_create_event()
		signalled:       uacpi_kernel_create_event()
		main_thread_id:  uacpi_kernel_get_thread_id()
		mutex_status:    UACPIStatus.internal_error
		chain_status:    UACPIStatus.internal_error
	}
	defer {
		uacpi_kernel_free_event(test.signalled)
		uacpi_kernel_free_event(test.started)
		uacpi_kernel_free_mutex(test.mutex)
		unsafe {
			test.free()
			free(test)
		}
	}

	self_test_require(test.mutex != unsafe { nil }, 'mutex allocation failed')
	self_test_require(test.started != unsafe { nil }, 'event allocation failed')
	self_test_require(test.signalled != unsafe { nil }, 'event allocation failed')
	self_test_require(test.main_thread_id != unsafe { nil }, 'caller has no stable thread identity')

	run_event_self_test(mut test)
	print('uACPI host self-test: events passed\n')
	run_mutex_self_test(mut test)
	print('uACPI host self-test: mutexes passed\n')
	run_work_self_test(mut test)
	print('uACPI host self-test: deferred work passed\n')
	run_interrupt_self_test(mut test)
	print('uACPI host self-test: interrupts passed\n')
	print('uACPI host self-test: PASS\n')
}
