# Vinix TODO and Stub Tracker

Last audited: 2026-07-23

This document tracks known TODOs, stubs, fake-success compatibility
implementations, and deliberately incomplete interfaces in Vinix.

The initial audit covered the kernel, init and Vinix utilities, the active
Vinix mlibc sysdeps, and Vinix-specific package patches. Vendored upstream
TODOs, generated configure scripts, defensive unsupported-input checks, and
valid no-op resource hooks were excluded.

Initial audit baseline:

- 15 explicit `TODO`, `XXX`, or `HACK` comments in tracked first-party code.
- 22 explicit stub or unimplemented sites in tracked first-party code.
- Additional unmarked semantic stubs that return success or silently do
  nothing.
- No tracked tests currently cover these contracts.

## Priority 1: correctness and kernel safety

### uACPI host interface

- [x] Implement kernel-backed uACPI mutex creation, acquisition, release, and
  timeout behavior.
- [x] Return stable, non-null thread identities from
  `uacpi_kernel_get_thread_id()`.
- [x] Implement uACPI work scheduling and completion waits.
- [x] Implement interrupt-handler installation and removal instead of
  returning false success.
- [x] Implement event reset semantics.
- [x] Implement or explicitly reject firmware requests.
- [x] Audit mapping lifetime and implement `uacpi_kernel_unmap()` where
  mappings are not intentionally permanent.
- [x] Add concurrency and interrupt-delivery tests for the host interface.

Evidence:

- [`kernel/modules/uacpi/uacpi.v`](kernel/modules/uacpi/uacpi.v) now provides
  counting events, timed mutexes, stable thread identities, a CPU-0 deferred
  work queue, and tracked I/O APIC interrupt handlers.
- ACPI mappings use the kernel-global higher-half physical direct map. Their
  page-table entries intentionally have kernel lifetime, so per-consumer
  unmapping would invalidate unrelated users of the same physical pages.
- Runtime initialization now occurs after SMP, timers, and the scheduler are
  available.
- Booting with `uacpi.selftest=1` runs counting-event, timed-mutex,
  deferred-work, stable-thread-identity, and interrupt lifecycle/accounting
  stress tests before userspace starts. The interrupt test uses a synthetic
  source so it cannot interfere with a real device IRQ.

Completion criteria:

- uACPI never receives success for an operation the kernel did not perform.
- AML work can safely execute concurrently.
- Installed ACPI interrupt handlers receive and acknowledge real interrupts.
- ACPI initialization and shutdown survive repeated SMP boot testing.

### `execve()` sibling-thread teardown

- [x] Prevent new sibling threads from appearing once `execve()` commits.
- [x] Stop and dequeue every sibling thread.
- [x] Wait until sibling threads can no longer execute in the old address
  space.
- [x] Preserve rollback behavior while the new image is still being prepared.
- [x] Free the old page map only after all old threads are gone.
- [x] Cover both x86-64 and ARM64 through shared lifecycle logic where
  possible.
- [x] Add a multithreaded `execve()` stress test.

Evidence:

- [`kernel/modules/userland/lifecycle.v`](kernel/modules/userland/lifecycle.v)
  provides the shared exec/exit stop barrier. Thread creation and exec commit
  serialize on `Process.threads_lock`, and each sibling acknowledges
  termination only after switching to the kernel page map.
- Both architecture-specific exec paths fully construct the candidate image
  and replacement thread before entering the irreversible barrier. The old
  page map is reclaimed only after all sibling acknowledgements.
- The scheduler defers kernel-stack and FPU-state reclamation until a later
  context-switch epoch, then releases them from a dedicated reaper thread so
  no CPU can still be using a retired stack and timer interrupts stay bounded.
- [`tests/execve-sibling-stress/main.c`](tests/execve-sibling-stress/main.c)
  races exec against userspace and syscall spinners, an event-blocked thread,
  and concurrent thread creation. It also verifies that a failed exec leaves
  the multithreaded process usable. The final implementation passed a
  128-round run plus the 16-round rollback probe on a 4-vCPU, 2 GiB QEMU
  guest.

Completion criteria:

- A successful `execve()` leaves exactly the calling thread in the process.
- No old thread can run after the old page map is destroyed.
- Failed image construction leaves the original process intact.

### Thread descriptor reference management

- [x] Replace long-lived borrowed `Thread` pointers in console and timer state
  with reference-counted handles or process-level identifiers.
- [x] Reclaim retired `Thread` descriptors after the last external reference
  is released.

Evidence:

- `Thread` descriptors now carry explicit references for scheduler lifetime,
  process registries, kernel pthread handles, console caches, and transient
  signal delivery. Process lookup returns an acquired handle rather than a
  borrowed pointer.
- Console caches use irq-safe locks and own the descriptor they publish.
  ARM64 interval timers retain a process identity and resolve its current
  thread at delivery time, so `execve()` cannot leave a stale timer target.
- The scheduler reaper removes descriptors from its locked retirement queue,
  releases stacks and FPU storage after the context-switch grace period, and
  then drops the scheduler's final runtime reference. The descriptor is freed
  as soon as all remaining owners release it.
- The 4-vCPU, 2 GiB QEMU image passed 256 rounds of
  `execve-sibling-stress`; a console Ctrl-C probe then exercised the retained
  console target and returned cleanly to the shell.

### ARM64 false-success syscall compatibility

- [ ] Move architecture-independent syscall semantics into shared kernel
  implementations.
- [ ] Keep the ARM64 layer limited to ABI number and structure translation.
- [ ] Implement real `flock()` behavior.
- [ ] Implement real `ftruncate()` behavior.
- [ ] Implement timestamp updates for `utimensat()`.
- [ ] Implement or correctly reject supported `prctl()` operations.
- [ ] Implement socket option storage and reporting.
- [ ] Implement socket shutdown state transitions.
- [ ] Implement credential-changing calls when Vinix gains credentials.
- [ ] Report actual filesystem information from `fstatfs()`.
- [ ] Route `renameat()` to the shared VFS implementation.
- [ ] Implement process priorities or return an honest unsupported error.
- [ ] Replace hard-coded `sysinfo()` and `getrusage()` results.
- [ ] Audit partial wrappers including `clone()`, `getsockname()`,
  `rt_sigsuspend()`, `prlimit64()`, and interval timers.
- [ ] Add ABI tests that compare observable behavior across x86-64 and ARM64.

Evidence:

- [`kernel/modules/syscall/table/syscall_table_arm64.v`](kernel/modules/syscall/table/syscall_table_arm64.v#L288)
  contains at least 18 explicitly hard-coded, partial, or fake-success syscall
  handlers.
- [Socket-option and shutdown stubs](kernel/modules/syscall/table/syscall_table_arm64.v#L431)
  return success without applying the requested behavior.
- [`fstatfs()` and `renameat()`](kernel/modules/syscall/table/syscall_table_arm64.v#L698)
  return fabricated state or success.

Completion criteria:

- No syscall reports success unless its specified state transition occurred.
- Unsupported operations return an appropriate error.
- Shared syscall tests pass on both architectures.

## Priority 2: userland ABI and core services

### Vinix mlibc thread lifecycle and credentials

- [ ] Add a real thread-exit syscall and connect `sys_thread_exit()` to it.
- [ ] Reclaim detached-thread kernel and userspace resources.
- [ ] Map thread stacks with guard pages.
- [ ] Implement UID, EUID, GID, and EGID through kernel credential state.
- [ ] Implement credential-changing sysdeps when the kernel supports them.
- [ ] Add pthread create/join/detach/exit stress tests.

Evidence:

- [`sys_thread_exit()`](sources/mlibc-workdir/sysdeps/vinix/generic/generic.cpp#L63)
  spins forever after a thread function returns.
- [Thread stack preparation](sources/mlibc-workdir/sysdeps/vinix/generic/thread.cpp#L28)
  explicitly omits guard pages.
- [Credential sysdeps](sources/mlibc-workdir/sysdeps/vinix/generic/generic.cpp#L508)
  return hard-coded root identities.

Completion criteria:

- Returned and explicitly exited threads stop consuming CPU.
- Joined and detached threads release all resources exactly once.
- Thread stack overflow faults in the guard region.

### Vinix mlibc socket options

- [ ] Define the kernel socket-option model and supported option set.
- [ ] Send `getsockopt()` and `setsockopt()` through kernel syscalls.
- [ ] Implement `SO_ERROR`, `SO_TYPE`, `SO_PEERCRED`, buffer sizes,
  `SO_KEEPALIVE`, and `SO_REUSEADDR`.
- [ ] Return appropriate errors for unsupported levels and options rather than
  panicking or fabricating values.
- [ ] Add socket-option and connection-state tests.

Evidence:

- [`sys_getsockopt()`](sources/mlibc-workdir/sysdeps/vinix/generic/generic.cpp#L727)
  hard-codes five option values.
- [`sys_setsockopt()`](sources/mlibc-workdir/sysdeps/vinix/generic/generic.cpp#L759)
  silently accepts seven options.

Completion criteria:

- Reported socket state matches the corresponding kernel socket.
- Invalid options fail without terminating the process.

### `inotify`

- [ ] Define watches, watch descriptors, masks, and event records.
- [ ] Connect VFS mutations to inotify event production.
- [ ] Implement blocking and nonblocking reads.
- [ ] Implement poll status and wakeups.
- [ ] Implement reference counting and teardown.
- [ ] Validate creation flags.
- [ ] Add create/modify/rename/delete watch tests.

Evidence:

- [`kernel/modules/fs/inotify.v`](kernel/modules/fs/inotify.v#L3) creates a file
  descriptor, but its read, write, mapping, and lifetime operations are stubs.

Completion criteria:

- A returned inotify descriptor can observe documented VFS events.
- Polling and nonblocking behavior match the descriptor state.

### `signalfd`

- [ ] Queue masked signals for matching signalfd instances.
- [ ] Serialize complete `signalfd_siginfo` records.
- [ ] Implement blocking and nonblocking reads.
- [ ] Implement poll status and wakeups.
- [ ] Implement descriptor update and teardown semantics.
- [ ] Validate masks and flags.
- [ ] Add signal delivery, polling, and close-race tests.

Evidence:

- [`kernel/modules/userland/signalfd.v`](kernel/modules/userland/signalfd.v#L44)
  contains a queue but has no producer and an empty read path.

Completion criteria:

- Signals directed to signalfd are delivered exactly once.
- Normal handlers and signalfd obey the configured signal mask.

### Entropy and random-number generation

- [ ] Introduce a kernel entropy pool and cryptographic DRBG.
- [ ] Accept bootloader-provided entropy when available.
- [ ] Mix hardware RNG output, interrupt timing, and device events.
- [ ] Track initialization and refuse premature cryptographic reads where
  required.
- [ ] Back both `/dev/urandom` and `getrandom()` with the same subsystem.
- [ ] Add deterministic DRBG tests and boot-time entropy-state tests.

Evidence:

- [x86-64 `/dev/urandom`](kernel/modules/dev/random/random.v#L165) can fall
  back to timestamp-derived state.
- [ARM64 `getrandom()`](kernel/modules/syscall/table/syscall_table_arm64.v#L672)
  uses timer-seeded xorshift.

Completion criteria:

- Random output is not predictable from boot time or public kernel state.
- Both architectures use one reviewed cryptographic design.

## Priority 3: VFS and terminal semantics

### VFS syscall completeness

- [ ] Apply and validate supported `mount()` flags and filesystem data.
- [ ] Implement `umount()` and busy-mount lifetime rules.
- [ ] Honor the `openat()` creation mode and process umask.
- [ ] Enforce `O_EXCL`.
- [ ] Implement `O_TRUNC` atomically during open.
- [ ] Implement `linkat(AT_EMPTY_PATH)` or reject it consistently.
- [ ] Make devtmpfs mounting instance-safe or explicitly single-mount.
- [ ] Add syscall tests for permissions, truncation, exclusion, and mount
  lifetime.

Evidence:

- [`mount()` and `umount()`](kernel/modules/fs/vfs.v#L277) ignore mount
  options and leave unmount unimplemented.
- [`openat()`](kernel/modules/fs/vfs.v#L874) receives `mode` but creates files
  as `0644`.
- [devtmpfs mounting](kernel/modules/fs/devtmpfs.v#L193) relies on a single
  global root.

Completion criteria:

- File creation and mount behavior follow the documented Vinix/POSIX ABI.
- No supported flag is silently ignored.

### Terminal attribute actions

- [ ] Make `TCSETS` apply immediately.
- [ ] Make `TCSETSW` wait for pending output to drain.
- [ ] Make `TCSETSF` drain output and discard unread input.
- [ ] Apply the same behavior to PTYs and virtual terminals.
- [ ] Add terminal drain/flush tests.

Evidence:

- [x86-64 console handling](kernel/modules/dev/console/console.v#L736) treats
  all three operations identically.
- ARM64 contains the corresponding TODO.

### ARM64 console and signal behavior

- [ ] Track controlling terminals and foreground process groups on ARM64.
- [ ] Route terminal-generated signals to the foreground process group.
- [ ] Implement default signal actions instead of dropping them.
- [ ] Remove the `latest_thread` Ctrl-C fallback.
- [ ] Add foreground/background job-control tests.

Evidence:

- The ARM64 console calls its current approach a
  [massive hack](kernel/modules/dev/console/console_arm64.v#L36).
- [Default ARM64 signal actions](kernel/modules/userland/userland_arm64.v#L269)
  are ignored.

## Priority 4: architecture and device bring-up

### ARM64 platform gaps

- [ ] Discover and map PCI ECAM from the device tree or ACPI.
- [ ] Implement GIC ITS and Apple AIC MSI routing without placeholder
  addresses.
- [ ] Stop other CPUs during panic using architecture-appropriate IPIs.
- [ ] Route ARM64 kernel-print requests through a validated syscall path.
- [ ] Complete SMP wake/intercept behavior.
- [ ] Replace the minimal ARM64 recovery shell when the normal userland ABI is
  ready.

Evidence:

- [ARM64 boot](kernel/main_arm64.v#L347) skips PCI initialization.
- [ARM64 panic](kernel/modules/lib/panic_arm64.v#L12) does not halt the other
  CPUs.
- [ARM64 kprint](kernel/modules/kprint/kprint_arm64.v#L7) bypasses the full
  syscall path.

### Kernel-only C runtime support

- [ ] Determine which kernel dependencies require stdio or ctype entry points.
- [ ] Replace reachable hard-panic functions with bounded kernel-safe
  implementations.
- [ ] Remove unused compatibility symbols rather than retaining latent traps.
- [ ] Implement meaningful `isatty()`, `fflush()`, and `pthread_detach()`
  behavior where they remain required.

Evidence:

- [`kernel/modules/lib/stubs/file.v`](kernel/modules/lib/stubs/file.v#L18)
  contains hard-panic stdio functions and accepts only writes to descriptors 1
  and 2.
- [`kernel/modules/lib/stubs/misc.v`](kernel/modules/lib/stubs/misc.v#L5)
  contains hard-panic ctype functions.

## Priority 5: package and utility limitations

### V

- [ ] Add a userspace stack-unwinding facility.
- [ ] Enable V backtraces on Vinix after the kernel/userspace ABI exists.

Current behavior: V programs run, but Vinix backtrace requests return false.

### X11 compatibility

- [ ] Implement keyboard LED state.
- [ ] Implement keyboard bell behavior or expose it as unsupported.
- [ ] Implement framebuffer blanking and colormap operations where supported.
- [ ] Ensure optional X11 operations do not report false success.

### `chsh`

- [ ] Ignore blank and comment lines in `/etc/shells`.
- [ ] Validate and update the exact passwd entry rather than relying on broad
  string replacement.
- [ ] Add utility-level tests for shell-list parsing and passwd updates.

Evidence:

- [`util-vinix/chsh/main.v`](util-vinix/chsh/main.v#L66) does not parse
  comments in `/etc/shells`.

## Working rules

- Prefer a complete vertical implementation over another application-specific
  compatibility shim.
- Never return success for an operation that did not occur.
- If an operation is temporarily unsupported, return an accurate error and
  document the limitation.
- Put architecture-independent semantics in shared kernel modules; architecture
  layers should translate ABIs and operate hardware.
- Add a regression test before marking a completed item.
- When an item is completed, check it off and add the implementing commit hash
  beside the checkbox.
