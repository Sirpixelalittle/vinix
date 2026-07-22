@[has_globals]
module main

import memory
import term
import lib.stubs
import acpi
import uacpi
import x86.gdt
import x86.idt
import x86.isr
import x86.smp
import initramfs
import fs
import sched
import stat
import dev.console
import dev.seat
import userland
import pipe
import futex
import pci
import dev.ata
import dev.fbdev
import dev.fbdev.simple
import dev.nvme
import dev.serial
import dev.streams
import dev.ahci
import dev.hda
import dev.random
import dev.mouse
import dev.pty
import block.partition
import syscall.table
import socket
import time
import x86.hpet
import limine

@[_linker_section: '.requests']
@[cinit]
__global (
	volatile executable_cmdline_req = limine.LimineExecutableCmdlineRequest{
		response: unsafe { nil }
	}
)

struct BootOptions {
mut:
	root       string
	rootfstype string = 'ext2'
	read_only  bool
}

fn parse_boot_options() BootOptions {
	mut options := BootOptions{}
	if executable_cmdline_req.response == unsafe { nil } {
		print('boot: executable command-line response missing\n')
		return options
	}
	if executable_cmdline_req.response.cmdline == unsafe { nil } {
		print('boot: executable command line is empty\n')
		return options
	}

	cmdline := unsafe { cstring_to_vstring(executable_cmdline_req.response.cmdline) }
	print('boot: command line: ${cmdline}\n')
	for argument in cmdline.fields() {
		if argument.starts_with('root=') {
			options.root = argument[5..]
		} else if argument.starts_with('rootfstype=') {
			options.rootfstype = argument[11..]
		} else if argument == 'ro' {
			options.read_only = true
		} else if argument == 'rw' {
			options.read_only = false
		}
	}
	return options
}

fn resolve_root_device(specification string) string {
	if specification.starts_with('PARTUUID=') {
		return partition.find_by_uuid(specification[9..])
	}
	return specification
}

fn mount_real_root(options BootOptions) bool {
	if options.rootfstype != 'ext2' {
		print('root: unsupported filesystem ${options.rootfstype}\n')
		return false
	}
	if !options.read_only {
		print('root: ext2 write support is not yet safe; refusing a writable root\n')
		return false
	}

	root_device := resolve_root_device(options.root)
	if root_device.len == 0 {
		print('root: device ${options.root} was not found\n')
		return false
	}
	print('root: mounting ${root_device} as ${options.rootfstype}\n')

	fs.create(vfs_root, '/newroot', 0o755 | stat.ifdir) or {
		print('root: unable to create staging mount point\n')
		return false
	}
	fs.mount(vfs_root, root_device, '/newroot', options.rootfstype) or {
		print('root: unable to mount root filesystem\n')
		return false
	}

	fs.mount(vfs_root, '', '/newroot/dev', 'devtmpfs') or {
		print('root: unable to mount /dev\n')
		return false
	}
	fs.mount(vfs_root, '', '/newroot/run', 'tmpfs') or {
		print('root: unable to mount /run\n')
		return false
	}
	fs.mount(vfs_root, '', '/newroot/tmp', 'tmpfs') or {
		print('root: unable to mount /tmp\n')
		return false
	}
	fs.mount(vfs_root, '', '/newroot/root', 'tmpfs') or {
		print('root: unable to mount /root\n')
		return false
	}
	fs.mount(vfs_root, '', '/newroot/var/log', 'tmpfs') or {
		print('root: unable to mount /var/log\n')
		return false
	}
	fs.mount(vfs_root, '', '/newroot/var/lib/xkb', 'tmpfs') or {
		print('root: unable to mount /var/lib/xkb\n')
		return false
	}

	old_root := fs.switch_root(vfs_root, '/newroot') or {
		print('root: unable to switch root\n')
		return false
	}
	fs.destroy_detached_tree(old_root)
	print('root: switched to disk-backed filesystem\n')
	return true
}

fn kmain_thread() {
	term.framebuffer_init()

	table.init_syscall_table()
	socket.initialise()
	pipe.initialise()
	futex.initialise()
	fs.initialise()
	fs.register_ext2()

	fs.mount(vfs_root, '', '/', 'tmpfs') or {}
	fs.create(vfs_root, '/dev', 0o644 | stat.ifdir) or {}
	fs.mount(vfs_root, '', '/dev', 'devtmpfs') or {}

	boot_options := parse_boot_options()
	if boot_options.root.len == 0 {
		initramfs.initialise()
	}

	streams.initialise()
	pty.initialise()
	random.initialise()
	fbdev.initialise()
	fbdev.register_driver(simple.get_driver())
	console.initialise()
	seat.initialise()
	serial.initialise()
	mouse.initialise()
	hda.initialize()

	ata.initialise()
	nvme.initialise()
	ahci.initialise()

	if boot_options.root.len != 0 && !mount_real_root(boot_options) {
		panic('Could not mount the requested root filesystem')
	}

	userland.start_program(false, vfs_root, '/sbin/init', ['/sbin/init'], [], '/dev/console',
		'/dev/console', '/dev/console') or { panic('Could not start init process') }

	sched.dequeue_and_die()
}

fn kmain() {
	// Ensure the base revision is supported.
	if limine_base_revision.revision != 0 {
		for {}
	}

	// Initialize the memory allocator.
	memory.pmm_init()

	// Call Vinit to initialise the runtime
	C._vinit(0, 0)

	// Initialize the earliest arch structures.
	gdt.initialise()
	idt.initialise()
	isr.initialise()

	x2apic_mode = smp_req.response.flags & 1 != 0

	// Init terminal
	term.initialise()
	serial.early_initialise()

	// a dummy call to avoid V warning about an unused `stubs` module
	_ := stubs.toupper(0)

	memory.vmm_init()

	// ACPI init
	acpi.initialise()
	hpet.initialise()

	pci.initialise()

	mut uacpi_status := uacpi.UACPIStatus.ok

	uacpi_status = C.uacpi_initialize(0)
	if uacpi_status != uacpi.UACPIStatus.ok {
		panic('uacpi_initialize(): ${C.uacpi_status_to_string(uacpi_status)}')
	}

	uacpi_status = C.uacpi_namespace_load()
	if uacpi_status != uacpi.UACPIStatus.ok {
		panic('uacpi_namespace_load(): ${C.uacpi_status_to_string(uacpi_status)}')
	}

	uacpi_status = C.uacpi_set_interrupt_model(uacpi.InterruptModel.ioapic)
	if uacpi_status != uacpi.UACPIStatus.ok {
		panic('uacpi_interrupt_model(): ${C.uacpi_status_to_string(uacpi_status)}')
	}

	uacpi_status = C.uacpi_namespace_initialize()
	if uacpi_status != uacpi.UACPIStatus.ok {
		panic('uacpi_namespace_initialize(): ${C.uacpi_status_to_string(uacpi_status)}')
	}

	smp.initialise()

	time.initialise()

	sched.initialise()

	spawn kmain_thread()

	sched.await()
}
