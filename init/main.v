module main

import os

#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

fn C.sethostname(name charptr, len u64) int
fn C.fchmod(fd int, mode u32) int
fn C.fork() int
fn C.setsid() int
fn C.dup2(old_fd int, new_fd int) int
fn C.ioctl(fd int, request u64, argp voidptr) int
fn C.waitpid(pid int, status &int, options int) int
fn C._exit(status int)

const virtual_terminal_count = 6
const tiocsctty = u64(0x540e)

fn prepare_runtime_directory(path string) ! {
	if !os.is_dir(path) && unsafe { C.mkdir(&char(path.str), u32(0o1777)) } != 0 {
		return error('could not create ${path}')
	}

	fd := unsafe { C.open(&char(path.str), C.O_RDONLY, 0) }
	if fd < 0 {
		return error('could not open ${path}')
	}
	defer {
		C.close(fd)
	}

	if C.fchmod(fd, u32(0o1777)) != 0 {
		return error('could not set permissions on ${path}')
	}
}

// A terminal worker stays as the session leader for one VT and respawns its
// login shell whenever that shell exits. Keeping the session leader alive also
// gives every shell on the VT a stable controlling-terminal lifetime.
fn terminal_worker(index int) {
	if C.setsid() < 0 {
		C._exit(1)
	}

	tty_path := '/dev/tty${index + 1}'
	tty_fd := unsafe { C.open(&char(tty_path.str), C.O_RDWR, 0) }
	if tty_fd < 0 {
		C._exit(1)
	}

	// Opening a terminal as a session leader already acquires it on Vinix.
	// Make that relationship explicit so the worker does not depend on the
	// open-time convenience behavior.
	if C.ioctl(tty_fd, tiocsctty, unsafe { nil }) < 0 {
		C.close(tty_fd)
		C._exit(1)
	}

	for target_fd := 0; target_fd <= 2; target_fd++ {
		if C.dup2(tty_fd, target_fd) < 0 {
			C.close(tty_fd)
			C._exit(1)
		}
	}
	if tty_fd > 2 {
		C.close(tty_fd)
	}

	os.chdir('/root') or { C._exit(1) }
	for {
		os.system("exec -a '-bash' bash --login")
	}
}

fn start_terminal_worker(index int) int {
	pid := C.fork()
	if pid == 0 {
		terminal_worker(index)
		C._exit(1)
	}
	return pid
}

fn main() {
	println('Vinix Init started')

	// These directories live on the volatile root filesystem. Package archive
	// metadata is not enough to preserve their sticky mode across each boot.
	prepare_runtime_directory('/tmp') or { panic(err) }
	prepare_runtime_directory('/tmp/.X11-unix') or { panic(err) }

	os.setenv('HOME', '/root', true)
	os.setenv('TERM', 'linux', true)
	os.setenv('PATH', '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin', true)
	os.setenv('USER', 'root', true)
	os.setenv('LOGNAME', 'root', true)
	os.setenv('SHELL', '/bin/bash', true)
	os.setenv('MAIL', '/var/mail', true)
	os.setenv('XDG_RUNTIME_DIR', '/run', true)

	// Read hostname from /etc/hostname and pass to the kernel.
	hostname_file := os.read_file('/etc/hostname') or { 'vinix' }
	mut length := u64(0)
	for length < hostname_file.len && hostname_file[length] != `\n` {
		length++
	}
	C.sethostname(hostname_file[..length].str, length)

	mut workers := [virtual_terminal_count]int{}
	for index := 0; index < virtual_terminal_count; index++ {
		workers[index] = start_terminal_worker(index)
		if workers[index] < 0 {
			panic('Could not start terminal worker for tty${index + 1}')
		}
	}

	// PID 1 owns supervision. A failed terminal worker is replaced without
	// disturbing sessions on the other VTs.
	for {
		mut status := 0
		pid := C.waitpid(-1, &status, 0)
		if pid < 0 {
			continue
		}
		for index := 0; index < virtual_terminal_count; index++ {
			if workers[index] == pid {
				workers[index] = start_terminal_worker(index)
				break
			}
		}
	}
}
