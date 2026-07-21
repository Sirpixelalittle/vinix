# Vinix

Vinix is an effort to write a modern, fast, and useful operating system in [the V programming language](https://vlang.io).

Join the [Discord chat](https://discord.gg/S5Nm6ZDU38).

## What is Vinix all about?

- Keeping the code as simple and easy to understand as possible, while not sacrificing
performance and prioritising code correctness.
- Making a *usable* OS which can *run on real hardware*, not just on emulators or
virtual machines.
- Targeting modern 64-bit architectures, CPU features, and multi-core computing.
- Maintaining good source-level compatibility with Linux to allow to easily port programs over.
- Exploring V capabilities in bare metal programming and improving the compiler in response to the uncommon needs of bare metal programming.
- Having fun.

**Note: Vinix is still pre-alpha software not meant for daily or production usage!**

![Screenshot 0](/screenshot0.png?raw=true "Screenshot 0")
![Screenshot 1](/screenshot1.png?raw=true "Screenshot 1")

## Download latest nightly image

You can grab a pre-built nightly Vinix image at https://github.com/vlang/vinix/releases

The ISO is a small recovery environment. The installed system uses a GPT disk
image with a disk-backed ext2 root, so its memory use does not scale with the
size of the package sysroot.

## Roadmap

- [x] mlibc
- [x] bash
- [x] gcc/g++
- [x] V
- [x] nano
- [x] storage drivers
- [x] ext2
- [x] X.org
- [x] X window manager
- [ ] Networking
- [ ] Wayland 
- [ ] Hypervisor
- [ ] V-UI
- [ ] Intel HD graphics driver (Linux port)
## Build instructions

### Distro-agnostic build prerequisites

The following is a distro-agnostic list of packages needed to build Vinix.

Skip to a paragraph for your host distro if there is any.

`GNU make`, `findutils`, `curl`, `git`, `xz`, `rsync`, `xorriso`, `util-linux`,
`e2fsprogs`, `dosfstools`, `mtools`, `qemu` to test it, and a working C compiler
(`cc`) need to be present.

### Build prerequisites for Ubuntu, Debian, and derivatives
```bash
sudo apt install -y build-essential make findutils curl git xz-utils rsync xorriso util-linux e2fsprogs dosfstools mtools qemu-system-x86
```

### Build prerequisites for Arch Linux and derivatives
```bash
sudo pacman -S --needed gcc make findutils curl git xz rsync xorriso util-linux e2fsprogs dosfstools mtools qemu
```

### Build prerequisites for Red Hat Linux and derivatives
```bash
sudo yum install -y gcc make findutils curl git xz rsync xorriso util-linux e2fsprogs dosfstools mtools qemu
```
### Build prerequisites for Void Linux and derivatives
```bash
sudo xbps-install -Suv gcc make findutils curl git xz rsync xorriso util-linux e2fsprogs dosfstools mtools qemu
```
### Building the distro

To build the distro, which includes the cross toolchain necessary
to build kernel and ports, as well as the kernel itself, run:

```bash
make image   # Build the base distro and a bootable GPT disk image.
make all     # Build the small recovery ISO.
```

The disk image contains a 64 MiB EFI system partition and a root partition
sized from the generated sysroot with additional growth space. The root is
currently mounted read-only while Vinix's ext2 mutation and sync paths are
being hardened. Runtime paths such as `/dev`, `/run`, `/tmp`, `/root`, and the
Xorg log/XKB state directories are separate writable filesystems.

*Note:* on certain distros, like Ubuntu 24.04, one may get an error like:
```
.../.jinx-cache/rbrt: failed to open or write to /proc/self/setgroups at line 186: Permission denied
```
In that case, it likely means apparmor is preventing the use of user namespaces,
causing `jinx` to fail to work. One can enable user namespaces by running:
```sh
sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
```
This is not permanent across reboots. To make it so, one can do:
```sh
sudo sh -c 'echo "kernel.apparmor_restrict_unprivileged_userns = 0" >/etc/sysctl.d/99-userns.conf'
```

This will build a minimal distro image. Setting the `PKGS_TO_INSTALL` env
variable will allow one to specify a custom set of packages to build/install.
For example:

```bash
PKGS_TO_INSTALL='*' make image
```
This will build all packages (may take some time). Or:

```bash
PKGS_TO_INSTALL='python sqlite' make image
```
This will install the base system plus the `python` and `sqlite` packages into
the disk-backed root. `make all` always emits the deliberately small recovery
ISO, even when extra packages were needed while constructing its sysroot.

The `xorg` meta-package installs the server, standard clients, framebuffer
video driver, and Vinix keyboard and mouse drivers as one complete environment:

```bash
PKGS_TO_INSTALL='xorg' make image
```

### To test

To boot the installed disk image on Linux with KVM, run

```
make run-image-kvm
```

To boot it with UEFI firmware, run

```
make run-image-uefi
```

To boot the recovery ISO on Linux with KVM, run

```
make run-kvm
```

In macOS, if hvf is available, run with

```
make run-hvf
```

To run without any acceleration, run with

```
make run
```


```
  === Vinix aarch64 booting ===
  vinit → exceptions → term → vmm → timer → gic → sched
  → scheduler spawns kmain_thread
  → polling mode timer fires, scheduler switches context via
  eret
  → kmain_thread: framebuffer, socket, pipe, futex, fs,
  initramfs
  → *** aarch64: Kernel initialisation complete ***
```
