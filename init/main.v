module main

import os

#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

fn C.sethostname(name charptr, len u64) int
fn C.fchmod(fd int, mode u32) int

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

	os.chdir('/root') or { panic('Could not move to root') }

	// Read hostname from /etc/hostname and pass to the kernel.
	hostname_file := os.read_file('/etc/hostname') or { 'vinix' }
	mut length := u64(0)
	for length < hostname_file.len && hostname_file[length] != `\n` {
		length++
	}
	C.sethostname(hostname_file[..length].str, length)

	for {
		os.system("exec -a '-bash' bash --login")
	}
}
