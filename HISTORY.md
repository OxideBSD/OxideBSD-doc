# OxideBSD development: history

Status: **archive** (2026-10-01). Not maintained: describes the code as it was.

This file collects OxideBSD's development history in one place. Its material comes from two
sources:

- the full `CLAUDE.md` of the OxideBSD repository as of 2026-09-29 (commit `259b1d6`), before it
  was cut down to invariants and live gotchas, kept here as the record of how each subsystem was
  built and which bugs were found along the way; and
- the text cut from the design documents on 2026-10-01 (`ROADMAP.md`, `CLEANUP.md`,
  `BUSYBOX_APPLETS.md`, `HIER.md`, `INIT_WORKPLAN.md`, `MISSING_POSIX_SYSCALLS.md`,
  `POSIX_COMPLIANCE_CHECKLIST.md`, `DEVFS.md`, `TIMEZONE.md`, `TTY.md`, `UNIX.md`): progress logs,
  superseded status text, and bug narratives.

The material is arranged by subsystem, roughly chronologically within each section. The prose is
kept as written; each block carries a note naming its source. Cross-references inside the text
("see ... below", "CLAUDE.md's ... section", "this doc", "§4") name the places the text was
written for, not the sections of this file. Where the same story was told in two sources, it is
kept once and the other place points to it as "this file's §N.M". Numbers in this file (pass
rates, applet counts, the highest syscall number) are historical; current figures live in
the maintained documents.

## 1. Project overview and planning

### 1.1. Project summary as of 2026-09-29

*(from CLAUDE.md, 2026-09-29)*

OxideBSD is a 100% Rust-based BSD-like OS, x86_64 only (see `OxideBSD-doc/ROADMAP.md` for phase history).
Current state:

- Boots via the Limine protocol (`limine` crate + `scripts/qemu_runner.sh` staging a hybrid
  BIOS+UEFI ISO, `sys/boot.rs`) — not the old `bootloader` crate, retired in the Limine migration
  (see "Boot: Limine" below). GDT/TSS/IDT with a dedicated double-fault stack, PIC-driven
  interrupts (timer + PS/2 keyboard, plus a real xHCI/HID USB keyboard path — see "USB input"),
  a VGA console mirroring serial plus a real framebuffer console, a heap allocator over
  Limine-provided paging info (HHDM offset + memory map).
- Separate per-process address spaces, ELF64 loading, ring-3 execution, and a native BSD-style
  syscall ABI over `SYSCALL`/`SYSRETQ` (`sys/syscall/mod.rs`) with carry-flag error signaling.
- A dynamic kernel module loader (`sys/module.rs`) relocates `#![no_std]` code into the kernel at
  boot and resolves symbol references against a hand-curated kernel API. Syscall handlers are
  registered by modules, not hardcoded: `sys/modules/native_abi/` (core syscalls), `modules/
  posix_compat/` (pipe/dup2/ioctl/setpgid/...), `sys/modules/signal/` (kill/sigaction/...),
  `sys/modules/oxfs/` (the live filesystem).
- `sys/modules/oxfs/` is a real in-memory Unix-shaped inode/block filesystem (real names,
  multi-component paths, per-process cwd, no fixed file-size cap) — replaced an earlier FAT32
  module (8.3 names, one path component per call, fixed file cap), since removed entirely (v0.2.0
  cleanup — no longer built or loaded).
- A real process table + scheduler (`sys/process/`) with `fork`/`execve`/`wait4`/`getpid`, real
  `argv`/`envp` passthrough, blocking pipes, per-process signal delivery, real ring-3 preemption
  (see "Real preemptive scheduling"), and real threading (`clone(2)`/`pthread_create`, see "Real
  threading").
- pid 1 is OxideBSD's own `/bin/sh` (`lib/libsh`, see "Shell"), an interactive login shell;
  BusyBox's `hush` (built against a patched musl fork) is still at `/bin/hush`. 195 BusyBox applets run as standalone static
  binaries, `execve`'d individually (not a multi-call `busybox` binary), placed per HIER.md (see
  "Filesystem layout"). 12 utilities (`echo true false pwd cat ls mkdir rm cp mv ln touch`) are
  native `bin/<name>` PIE binaries over `lib/oxlibc` — see "Real PIE/ASLR loading" below.
- A real networking stack (`sys/drivers/{pci,rtl8139}.rs`, `sys/net/*` interfaces, `sys/netinet/*` protocols,
  `sys/modules/socket/`): PCI + an rtl8139
  driver, Ethernet/ARP/IPv4/ICMP, UDP/TCP/raw-ICMP sockets, `poll(2)`, and real hostname
  resolution over musl's own DNS stub resolver (no DNS protocol code of its own) — see "Real
  networking" below.
- A real, on-target Clang/LLVM C/C++ toolchain (`external/apache2/llvm`, see "Clang/LLVM port"
  below) — a real, statically-linked, self-hosted `clang`+`ld.lld`, cross-compiled by itself, runs
  as ordinary seeded `/bin` binaries and can genuinely compile+link+run a real C file against a
  real, seeded `/usr/include`/`/usr/lib` musl tree. Real `futex(2)`, real threading, and milestone 1
  of real dynamic linking (`PT_INTERP`) exist. An earlier, simpler on-target compiler (TinyCC)
  served as this project's first proof that a real on-target compile+link was even possible, and
  was removed once Clang/LLVM superseded it.
- Real USB input (xHCI + HID boot-protocol keyboard, see "USB input" below) — this kernel's first
  real-hardware boot target.

Known, deliberate gaps: no pointer validation in `sys_read`/`sys_write`, no module unload/reload,
no *kernel-mode* preemption (real ring-3/user-mode preemption exists), no copy-on-write fork
(real per-address-space frame reclaim exists at exit, see "Real threading"/memory-reclaim notes
below), no general
block-device-agnostic VFS/mount-table layer (a real ATA disk driver + oxfs mount/format
persistence + a scoped bind/tmpfs mount table exist now — see "Real disk persistence"/"Mount
table" — but only for oxfs's own fixed backing store), no IPv6, no real routing table (one
default-gateway rule only), no SMP. See "BusyBox gap analysis" below for what's needed to go
further. Architecture decisions for remaining subsystems haven't been made — discuss with the
user before large structural commitments.

### 1.2. Git workflow

*(from CLAUDE.md, 2026-09-29)*

- Work directly on `master`; no feature branches. Release branches stay: `v0.2.x` still gets fixes,
  `v0.1.x` is end-of-life (kept, never updated).
- Before a risky change (a large refactor, anything touching many files, or a history/working-tree
  operation), commit what's there first so it can be recovered. Never `git stash` as a shortcut;
  read old versions with `git show <rev>:<path>`.

### 1.3. Roadmap: the three phases

*(from ROADMAP.md, cut 2026-10-01)*

OxideBSD is a 100% Rust BSD-like operating system. The plan is three phases, each a prerequisite
for the next.

#### Phase 1 — Minimal environment: a running, interactive kernel

**Goal:** a kernel that boots, stays up, and gives you a shell to type into — not just a kernel
that boots and halts.

**Status:** done. GDT/TSS/IDT with a dedicated double-fault stack, PIC-driven interrupts (timer +
keyboard), a heap allocator, a VGA console, and a real interactive shell all exist — see
`CLAUDE.md` for full detail. (`stsh`, the original hand-written shell described below, has since
been superseded as pid 1 by BusyBox's `hush` — see Phase 2.)

Milestones, roughly in dependency order:

- **CPU structures** — GDT, TSS, IDT, with exception handlers and a separate stack for double
  faults (a bug here otherwise triple-faults and silently reboots the VM).
- **Interrupts** — PIC (or APIC) initialization, a timer tick (PIT or APIC timer), and a keyboard
  IRQ handler.
- **Heap allocation** — a global allocator so `alloc` (`Vec`, `String`, `Box`, ...) is usable; a
  lot of later work assumes this exists.
- **Console output** — VGA text-mode buffer as the primary display (serial has been the console so
  far and can remain the logging/debug channel).
- **Keyboard input** — scancode-to-keycode translation (e.g. via the `pc-keyboard` crate) feeding
  a line-editing input buffer.
- **Shell** — a command loop that reads a line, dispatches to a small set of built-ins (`help`,
  `echo`, memory/heap stats, a deliberate panic for testing the panic handler, etc.), and loops
  forever instead of halting.

Phase 1 is "done" when the kernel boots into that shell and stays responsive to input indefinitely
— met.

#### Phase 2 — Getting Rust running on it

**Goal:** run actual Rust programs under OxideBSD — not the kernel binary itself, but separate
programs the kernel loads and executes. The end target of this phase is running `rustc`/`cargo`
themselves as userland programs.

**Status:** far along, but not "done" by this phase's own stated bar. Every milestone below is
built except the last — a C libc (musl), not a Rust `std` port, ended up being the actual
libc/userland story that got this phase moving (see `CLAUDE.md`'s musl-port section), and
`rustc`/`cargo` running as OxideBSD processes hasn't been attempted yet. Current work (v0.2.0
closing the POSIX pilot gap, v0.3.0/v0.4.0 deepening the C-toolchain side of userland with
GCC/Clang and glibc — see "Release sequence" below) is deepening the existing C-based userland
story rather than attacking `rustc`/`std` directly — a deliberate detour, not abandonment of this
phase's actual goal.

Depends on phase 1's interactivity, plus:

- **Paging / address spaces** — real virtual memory, one address space per process, page fault
  handling. Done.
- **User/kernel privilege separation** — ring 3 execution, a context switch between processes.
  Done.
- **ELF loading** — load a separate binary from somewhere and execute it as a process. Done.
- **Syscall ABI** — a defined interface for user programs to ask the kernel for services (I/O,
  memory, process control). Done — OxideBSD's own native ABI, see `CLAUDE.md`'s Syscall ABI
  section.
- **A filesystem** — at minimum something to load programs from; doesn't need to be persistent to
  start (an in-memory/initrd-style filesystem is a reasonable first cut). Done and then some —
  `oxfs`, a real Unix-shaped inode/block filesystem with optional disk persistence, superseded an
  earlier, more limited FAT32 implementation.
- **A libc/std story for userland** — either a `#![no_std]`-only userland to start, or porting
  `std` to a custom `x86_64-unknown-oxidebsd` target (the harder but more useful path, since
  `rustc`/`cargo` assume `std`). Landed differently than either option here: a real port of musl
  (a C libc) to this kernel's native syscall ABI, which in turn let BusyBox and a real C compiler
  (`tcc`) run as userland. A Rust `std` port remains undone and is what this phase's "done" bar
  below still actually requires.

Phase 2 is "done" when `rustc` can run as an OxideBSD process and compile a program — not yet met.

#### Phase 3 — Self-hosting: OxideBSD builds itself

**Goal:** close the loop — an OxideBSD instance can build a new, bootable OxideBSD image using
only tools running under OxideBSD itself, with no host OS involved.

**Status:** not started on the Rust-toolchain side this phase originally describes. The v0.3.0/
v0.4.0 goals below are a first step toward self-hosting from the C side instead — self-hosting
C-side toolchain components, retiring `tcc` for real GCC/Clang, and a real glibc port — ahead of,
not instead of, eventually closing this loop for `rustc`/`cargo` themselves.

- The full build toolchain (`rustc`, `cargo`, a linker, an assembler) running as userland programs.
- Enough of a POSIX/BSD-like surface (process spawning, file I/O, environment variables, pipes)
  for that toolchain to actually function, not just execute trivial programs.
- Build tooling to fetch/vendor the kernel and userland source trees and drive a full rebuild from
  within the running OS.
- A working bootstrap: boot an OxideBSD image, rebuild OxideBSD from source on it, boot the result.

### 1.4. Release sequence

*(from ROADMAP.md, cut 2026-10-01)*

As of 2026-09-04, the old single "v0.2.x goals" bucket below is split into separate, sequential
releases — each ships standalone rather than bundling everything into one v0.2.0. v0.5.0 onward
(added 2026-09-12) reflects the user's own longer-term plan past the original three-release split.

- **v0.2.0 — POSIX pilot compliance.** The current focus. **Concrete target (set 2026-09-08):
  >91% raw pass rate, >95% excluding UNTESTED**, on the full corpus via
  `scripts/run_posix_pilot_supervised.sh`. Close as much of the gap as practical
  between OxideBSD's own Open POSIX Test Suite pilot run and a real Unix baseline, using the full
  ~1687-file corpus (not a curated subset — see `CLAUDE.md`'s "POSIX pilot: full corpus expansion"
  section) as the measuring stick. **The real comparison target is literal UNIX and the BSDs
  (FreeBSD/NetBSD/OpenBSD), not Linux** — Linux/glibc is only used today because it's the one host
  actually available to measure against (`scripts/run_posix_pilot_host.sh`, manual/root-only); a
  real BSD-host run of the same corpus would be a truer number and isn't slotted yet (needs a BSD
  box/VM to run it on). Latest measured OxideBSD baseline (2026-09-07, a fresh `--reset`
  full-corpus run, `scripts/run_posix_pilot_supervised.sh`): **87.4%** raw pass rate / **92.8%**
  excluding UNTESTED (1474 PASS / 1686 total; 22 FAIL / 39 UNRESOLVED / 14 CRASH / 11 TIMEOUT / 29
  UNSUPPORTED / 97 UNTESTED — `shm_open/23-1.c` needed excluding again, a known, real single-core
  scheduling-throughput limit, not a new bug). **Newer baseline (2026-09-15, no exclusions
  needed)**: **90.3%** raw / **94.6%** excluding UNTESTED (1523 PASS / 1687 total) — within a point
  of the target on both axes. A few more fixes have landed since (`mlockall/3-7.c`, the ACPI HPET
  overlay closing `timer_getoverrun/2-2.c`, a `timer_gettime` precision fix) that haven't yet been
  folded into an official re-run. Last real host-side comparison (2026-09-06, not re-run since):
  the user's Artix (glibc/Linux) host at **89.5%** / **94.3%** — OxideBSD has now passed that
  proxy figure on both axes. Closing the remaining gap to the concrete target means triaging the
  full corpus's own remaining FAIL/UNRESOLVED set, not growing the corpus further — it's already
  complete. Several clusters already ruled out as real, accepted (non-kernel) issues rather than
  bugs to fix — see `CLAUDE.md`'s own history for detail: `sigaction/17-{2,10,20,25,26}.c`'s FAILs
  were transient host-load timing flakiness; `aio_suspend`'s/`aio_cancel`'s remaining UNRESOLVEDs
  are a real oxfs file-size-cap gap and an inherent test-timing race respectively; a dozen-plus
  pthread `CRASH`es are a confirmed real, pre-existing musl 1.2.6 UAF design trait (reproduced
  against unmodified host musl, not an OxideBSD bug); the last 3 scheduler-shaped hangs
  (`fork/18-1.c`, `pthread_mutex_init/{1,3}-2.c`) are likewise confirmed real, pre-existing musl
  bugs, not OxideBSD's. **Full POSIX syscall coverage** (every POSIX-mandated syscall, even where
  this ABI's own number/shape — see `CLAUDE.md`'s Syscall ABI section — diverges from Linux's or
  any real BSD's; not a promise to match Linux/BSD numbering or wire format) falls out of this same
  push, not a separate goal.

- **v0.3.0 — GCC and Clang self-hosted ports, plus a real Rust `std` target.** What v0.2.0 used to
  target before the 2026-09-04 re-scope (see `CLAUDE.md`'s TinyCC section for why this is a much
  bigger lift than TinyCC — real subprocess pipelines, likely real dynamic linking and threads
  beyond what exists today): self-hosting C-side toolchain components running on-target (moving
  further into Phase 3's "build itself" goal from the C side first), then retiring `tcc` once both
  GCC and Clang are real, working on-target ports — TinyCC was always the first/easiest target,
  never the intended long-term C compiler. **Deferred into this same "toolchain maturity" release
  (2026-09-09)**: a real Rust `std` target for OxideBSD userland — originally motivated by
  `rustrc`, an AGPLv3, OpenRC-inspired init system the user was evaluating; **that plan changed on
  2026-09-14** — `rustrc` was dropped (AGPLv3 conflicts with this project's permissive-licensing
  direction, and it was "too generic" for OxideBSD's own needs anyway) in favor of a native,
  from-scratch BSD-style init+rc.d system, matching FreeBSD/NetBSD/OpenBSD's own convention, built
  directly against this kernel's native ABI rather than through a hosted `std` target. The `std`
  target work itself is still worth doing here — it unblocks any future real-world Rust crate with
  a crates.io dependency tree, not just the no-longer-relevant `rustrc` case. **Underway as of
  2026-09-17**, and landing faster than expected: the recommended approach below turned out right
  — `std` links against the existing musl fork rather than a from-scratch syscall backend, and
  almost none of `std::sys::pal::unix` needed a new backend at all. A private `rust-lang/rust` fork
  (`OxideBSD/rust-oxidebsd`, `oxidebsd` branch) plus a private `libc` crate fork
  (`OxideBSD/libc-crate-oxidebsd`, `oxidebsd` branch, patched in via `library/Cargo.toml`'s
  `[patch.crates-io]`) add `target_os = "oxidebsd"` throughout std's own existing
  `linux`/musl-shaped cfg gates — a real, genuine target identity (confirmed via
  `std::env::consts::OS`), not borrowed Linux identity. `library/std/build.rs`'s
  supported-platform allowlist now lists `oxidebsd` too, so consumer binaries need no
  `#![feature(restricted_std)]` — a real Tier-3-shaped target, not one std merely tolerates.
  Verified end to end via two real `fork`+`execve`+`wait4`-driven boot tests
  (`tests/std_hello_oxidebsd_syscall_smoke.rs`, `tests/std_process_fs_oxidebsd_syscall_smoke.rs`):
  real `println!`/`process::exit`, and real `std::fs` (write/read_to_string/remove_file) +
  `std::process::Command` (its own internal fork+execve+waitpid, spawning `/bin/true`/`/bin/echo`).
  Two more real std platform-allowlist gaps found and fixed the same way as `restricted_std` along
  the way — `sys/pipe/unix.rs`'s `pipe2` list and `sys/fd/unix.rs`'s `set_cloexec` list both
  defaulted to a fallback (`pipe()`+`ioctl(FIOCLEX)`) that doesn't work here (`ioctl(2)` only
  handles `TCGETS`/`TCSETS*`/`TIOCGWINSZ`/`TIOCSWINSZ` against the real console); fixed by routing
  `oxidebsd` into the same real `pipe2(O_CLOEXEC)`/`fcntl(F_SETFD, FD_CLOEXEC)` paths `linux`
  already uses (both genuinely supported by this kernel's own `pipe2(2)`/`fcntl(2)`). Threads,
  signals and `std::net` socket plumbing have since been exercised through `std` too
  (`std-thread-net-signal-oxidebsd`). Still a hand-maintained pair of private forks, not anything
  upstreamable. Panics unwind (`panic_unwind`, `catch_unwind` tested).

  **v0.3.0 scope, decided 2026-09-23:** (1) **GCC** as a real on-target port (not started);
  (2) **finish `std`** -- the whole surface a `/bin` utility needs, verified by a std coverage
  consumer, **PIE** std binaries -- since 2026-09-30 dynamically linked on `/lib/libc.so` and
  `/lib/libgcc_s.so.1` (LLVM libunwind), pid 1 alone a static PIE -- and the 12 native `bin/`
  utilities **rewritten as std apps**; (3) a native
  **init system** -- `/sbin/init` as a Rust std app, FreeBSD/NetBSD-style `/etc/rc` + `rc.d` +
  `rcorder` + `rc.conf`, replacing `hush` as pid 1. Clang *rebuilding itself* on-target is **not**
  v0.3.0: it needs Python (LLVM's CMake) and CMake, which move later. Landed toward it already: the
  C++ stage (libc++, on-target `clang++`), the whole `*at()` family, `ppoll(2)`, demand-grown user
  stacks, and ninja on-target (see `CLAUDE.md`); and, 2026-09-30, OpenSSL 3.5 LTS with the
  system trust store (`certctl(8)`), the `openssl` crate, dynamic linking with `dlopen`, the
  loopback interface (`UNIX.md` §11.4), and syslog over TCP and TLS (`SYSLOG.md` §8). Placement of every binary: `HIER.md`.

  **Added 2026-09-24:** (4) **a cleanup phase** -- OxideBSD should *act like a regular OS* rather
  than take shortcuts; every known shortcut and its target is inventoried in `CLEANUP.md`;
  (5) **`sudo` via sudo-rs**, with the kernel credentials, `/dev/tty`, pseudo-terminals and
  OpenPAM it needs (`SUDO.md`); sudo-rs's `su` replaces BusyBox's. Since then pid 1 is OxideBSD's
  own interactive `/bin/sh` (`lib/libsh`), not hush -- `/sbin/init` (item 3) replaces it next.

- **v0.4.0 — a real glibc port**, alongside (not replacing) the existing native-ABI musl port.
  **Decided 2026-09-23:** a *full* glibc port (a `sysdeps/` port to OxideBSD's native ABI), for
  **source** compatibility with glibc-only software -- chosen over an Alpine-style compatibility
  layer on musl. Needs v0.3.0's GCC, and Python (glibc's build uses it). Also in v0.4.0: a batch of
  userland work, and **oxlibc pulled forward** from v0.7.0 -- grown from scratch in `lib/oxlibc`
  until `std` on `x86_64-unknown-oxidebsd` can run on it instead of musl, with no change to the
  std-based utilities.
- **v0.5.0 — SMP.** Real multi-core support. A substantial architectural undertaking, not a
  bolt-on: huge parts of this codebase currently lean on "single core" as a real correctness
  argument, not just a performance ceiling — `IA32_SFMASK` clearing `IF` for a syscall's entire
  duration is the *entire* lock-safety reasoning behind most of this kernel's `spin::Mutex` usage
  (see `CLAUDE.md`'s syscall-ABI section), and several already-landed fixes (the scheduler-race
  fix in "Closing a real scheduler race...", `sched_yield/1-1.c`'s own resolution) explicitly
  depend on there being only one core to preempt at all. Real work: per-CPU GDT/TSS/IDT and
  kernel-stack state, genuine SMP-safe locking once two cores can actually execute kernel code
  simultaneously (not just take turns via preemption), ACPI/MADT parsing to discover other cores,
  a real AP (application processor) boot/startup sequence, and IPI-based scheduling/TLB shootdown.
  Not started.
- **v0.6.0 — self-hosting `rustc`/`cargo` on-target.** Distinct from v0.3.0's Rust `std` target
  (which only lets Rust *programs* run on OxideBSD, for `rustrc`'s sake): this is Phase 3's own
  "OxideBSD builds itself" goal, closed from the Rust side specifically — a real `rustc`+`cargo`+
  linker+assembler toolchain running *as OxideBSD userland processes*, capable of rebuilding
  OxideBSD's own kernel and userland from source, on-target, with no host OS involved. v0.3.0's
  `std` target work is the direct prerequisite this builds on (rustc/cargo are themselves real
  `std`-using Rust programs). Not started.
- **v0.7.0 — `oxlibc`.** OxideBSD's own from-scratch native libc (BSD-3-Clause licensed — a
  deliberate licensing choice, not a fork of `relibc` or anything else with different terms),
  standing alongside the existing vendored musl/glibc ports rather than replacing them outright.
  Long-term/deferred until this point in the sequence; not started. **Partly pulled into v0.4.0
  (2026-09-23)** -- see there.
- **v0.8.0 — the graphical update: more advanced graphics.** Builds directly on real
  groundwork already landed ahead of this release: a real `/dev/fb0` character device
  (`process::mm::do_mmap_fb` maps the actual framebuffer's physical MMIO frames into a userland
  process) and a real, general-purpose raw keyboard-event source (`SYS_GET_KEYEVENT`,
  `console::keyevents`) — both deliberately built as general infrastructure, not specific to any
  one program, and proven end-to-end by a real, playable port of Doom (via `doomgeneric`,
  `third_party/doomgeneric`). This future release is where that groundwork grows into something
  closer to a real desktop environment: real mouse support (currently entirely absent — no mouse
  driver exists anywhere in this kernel, PS/2 or USB), a real windowing/compositing model, and
  real display-mode negotiation beyond whatever Limine's boot-time GOP/VBE choice happens to be.
  Not started beyond the v0.2.0-era groundwork above.
- **v0.9.0 — the hardware support update.** Broader real hardware support by porting drivers from
  Linux/BSD sources (**license terms need real, per-driver scrutiny** — not a blanket "copy it
  over," since Linux's GPL and the BSDs' own licenses aren't interchangeable with this project's
  own). This is also the real-hardware readiness gate for actually switching the user's own
  Surface Pro over to OxideBSD as a daily driver (see `CLAUDE.md`'s USB/xHCI section — the Surface
  has no PS/2 controller at all, already closed — real WiFi/networking hardware and real graphics
  acceleration are the remaining pieces this release would need to close). Not started.
- **v0.10.0 — the package manager update.** A real package manager — no such infrastructure exists
  anywhere in this project today (BusyBox/tcc/musl/etc. are all baked into the kernel image itself
  via `build.rs`, not independently installable). Not started, not yet designed.
- **v0.11.0 — v1.0.0 prep.** A stabilization/hardening pass ahead of a real 1.0 release; specific
  scope not yet defined.

### 1.5. Unscheduled ideas

*(from ROADMAP.md, cut 2026-10-01)*

A separate idea — replacing some BusyBox utilities with Rust `uutils` ahead of GCC/Clang — was
raised and set aside: not a real dependency of GCC/Clang bring-up (unrelated subsystems), just a
possible future nice-to-have, not currently sequenced into this list.

**Real text editors: `nano` and real `vim`** — BusyBox's roster today only has the small `vi`
applet (see `BUSYBOX_APPLETS.md`); `nano` and full (non-BusyBox) `vim` are separate ports, for
meaningfully better on-target text editing than the current applet-only story — not yet slotted
into a specific release above.

**`SCHED_SPORADIC` (POSIX Sporadic Server)** — the real-time scheduling policy behind
`sched_setscheduler`/`sched_setparam`'s 13 `UNSUPPORTED` `_POSIX_SPORADIC_SERVER`-gated
conformance files: a thread alternates between a normal and a low priority based on a real
execution-time budget/replenishment-period pair, bounding an aperiodic task's CPU share without
breaking periodic real-time schedulability analysis (an RTOS-space feature — QNX/VxWorks/RTEMS,
not something glibc or upstream musl implement either). Doesn't move the Linux/glibc comparison
number at all (real Linux distros are `UNSUPPORTED` here too) but would be a genuine feature this
kernel doesn't have. Real implementation needs an extended `struct sched_param` (musl header
patch), a per-thread budget/priority state machine, and timer-driven replenishment — a new
scheduling primitive, not a quick fix. Not yet slotted into a specific release.

### 1.6. Cleanup inventory: introduction and rows retired 2026-10-01

*(from CLEANUP.md, cut 2026-10-01)*

OxideBSD grew fast by taking shortcuts: behaviour that is good enough for the next milestone but
not what a regular Unix system does. v0.3.0 is also a cleanup release, whose goal is that OxideBSD
*acts like a regular OS*. This document lists every known shortcut, what a regular system does
instead, and where it is planned. It is sourced from the "known gap" notes in the main repository's
`CLAUDE.md` and from what recent work uncovered; add to it whenever a new shortcut is found.

**Target** is `v0.3.0`, a later release named in `ROADMAP.md`, or `later` (unscheduled). An item is
removed from this list when its fix lands, with the commit noted in the history section.

| Shortcut today | A regular OS | Target |
|---|---|---|
| One uid and one gid per process; no real/effective/saved split; supplementary groups not stored (`getgroups` returns the caller's gid); setuid/setgid bits ignored at `execve`. | POSIX credentials; setuid executables | v0.3.0 (`SUDO.md` §5.1) |
| pid 1 is a shell (`/bin/sh`, before that hush); no init, no `/etc/rc`, no getty/login at boot. | `/sbin/init` | v0.3.0 (`INIT.md`) |
| An orphan reparented to pid 1 is detached immediately (pid 1 has no reaping loop). | init reaps orphans | v0.3.0 (with init) |
| `times()` reports `tms_stime`/`tms_cstime` as zero; `getrusage` system time stale. | Real user/system split | later |
| `unlink`/`rmdir` never free blocks or inodes; tmpfs space is never reclaimed. | Freed on last link and last close | v0.3.0 |
| Only four device nodes do anything (`/dev/random`, `urandom`, `null`, `zero`). No `/dev/tty`, `/dev/console`, ptys. | Real character devices | v0.3.0 (`SUDO.md` §5.2) |
| The whole disk is loaded into RAM at mount; the block pool is a fixed ~1 GiB; `NUM_BLOCKS`/`MAX_INODES` are compile-time constants. | Block cache over the disk; size from the disk | later |
| ATA is PIO and polled, with interrupts masked. | DMA, interrupt-driven | later (v0.9.0, hardware) |
| The console's descriptors are one-way: fd 0 cannot be written, 1 and 2 cannot be read. | A tty opened read-write | v0.3.0 |
| No line discipline: `ICANON` is recorded, not acted on; every program does its own erase and echo; Ctrl+D is a plain byte to a program that didn't implement EOF itself. | Canonical mode in the kernel | v0.3.0 |
| One global termios and one controlling session, because there is one console. | Per-terminal state | v0.3.0 (with ptys) |
| No pseudo-terminals. | ptys | v0.3.0 (`SUDO.md` §5.2.3) |
| Incoming packets are only processed when a process calls into the network stack (the NIC is polled, not interrupt-driven), so `poll`/`select` on a socket must keep running instead of blocking, and can't also see keystrokes in the same call. | Interrupt-driven receive | v0.3.0 |
| BusyBox applets are 195 separate static binaries at fixed load addresses. | A multi-call binary, or native replacements | v0.3.0 (native `bin/` rewrite as `std` apps) |
| `/etc/passwd` and `/etc/group` can't be changed by any tool (`adduser`, `passwd`...). | They can | v0.3.0 |

## 2. Build system, toolchain and tests

### 2.1. Toolchain

*(from CLAUDE.md, 2026-09-29)*

- Nightly Rust, pinned to a dated nightly in `rust-toolchain.toml`. Load-bearing unstable
  features: `-Z build-std` (no prebuilt std for the custom target), `-Z json-target-spec`,
  `-Z panic-abort-tests`. **The `external/mit/rust` fork must sit on that nightly's exact commit**
  (`git_commit_hash` in `static.rust-lang.org/dist/<date>/channel-rust-nightly.toml`): its `std`
  source is compiled by that compiler. Bump both together, plus the libc fork if std's required
  `libc` version moved.
- Requires `qemu-system-x86_64` on `PATH`, plus OVMF firmware for UEFI boot (the default — see
  "Boot: Limine" below); no separate `bootimage` install needed any more.
- `.cargo/config.toml` sets the default target to `x86_64-oxidebsd.json` and
  `runner = "scripts/qemu_runner.sh"` — replaces the retired `bootimage runner`.

### 2.2. Commands

*(from CLAUDE.md, 2026-09-29)*

- `cargo build` — kernel ELF only
- `cargo run` — stages a hybrid BIOS+UEFI ISO (`scripts/qemu_runner.sh`, via `build.rs`'s
  `build_limine_deploy_tool`) and boots it in QEMU, serial to stdio
- `cargo test` / `cargo test --test basic_boot` — each target boots its own QEMU instance (slow;
  no fast check path exists)
- `cargo clippy` / `cargo fmt` — **`cargo fmt` with no package selector reformats the entire
  workspace**, including every separate `regress/*`/`usr.bin/*`/`sys/modules/*` crate — scope it
  with `cargo fmt -p oxidebsd` to touch only the root package, matching how build/test commands are
  already scoped below.

These commands at the repo root only target the `oxidebsd` package. `regress/*`, `usr.bin/*`, and
`sys/modules/*` are separate workspace members that the root `build.rs` cross-builds as a side
effect of building `oxidebsd`. To build one directly: `--manifest-path <dir>/<name>/Cargo.toml --target-dir
target/userland` (or `target/modules`) — a separate target dir avoids a nested-cargo lock deadlock
against the outer build. **Editing `build.rs` or an `include!`'d
sibling (`build_busybox.rs`) invalidates the build-script cache and forces a full rebuild**,
including the ~20-30 min BusyBox roster rebuild and the multi-minute POSIX pilot cross-compile —
expect a single-line comment tweak in either file to cost real wall-clock time on the next build.

### 2.3. Custom target spec (`x86_64-oxidebsd.json`)

*(from CLAUDE.md, 2026-09-29)*

- `target-pointer-width`/`target-c-int-width` must be numbers, not strings.
- Float returns need both `"features": "...,+soft-float"` and `"rustc-abi": "softfloat"`, or
  `core`/`compiler_builtins` fail to build.
- `panic-strategy: "abort"` is the only supported strategy — hence `-Z panic-abort-tests` in
  `.cargo/config.toml` (otherwise Cargo builds an unwind-based test harness and produces a second,
  ABI-incompatible `core`).
- SSE/MMX disabled, `disable-redzone: true` (interrupt handlers can't safely use either).

### 2.4. Dependency notes

*(from CLAUDE.md, 2026-09-29)*

- `x86_64` crate: `default-features = false, features = ["instructions", "abi_x86_interrupt"]` —
  the default feature set pulls in `step_trait`, an unstable-API moving target that has broken
  this crate against newer nightlies before.
- `limine` crate (`"0.6"`) — the request-statics/response-parsing glue for the Limine boot
  protocol; see "Boot: Limine" below. Replaced the old `bootloader` v0.9 crate (BIOS-only,
  unmaintained) in the 2026-09-09/10 migration.
- `linked_list_allocator`: `default-features = false` — its default `LockedHeap` depends on
  `spinning_top`, a second spinlock crate alongside `spin` (used everywhere else here).
- `pc-keyboard` 0.9's type is `PS2Keyboard<L, S>`, not `Keyboard<L, S>` (older tutorials reference
  the pre-0.9 name). Decoding is two calls through the *same* locked guard: `add_byte` →
  `KeyEvent`, then `process_keyevent` → `DecodedKey`.
- `pic8259`/`uart_16550` are deliberately **not** dependencies — both wrap a handful of
  `outb`/`inb` calls against a stable protocol, small enough that owning the code (`sys/cpu/
  pic.rs`, `sys/console/serial.rs`) outweighs the dependency. `pc-keyboard` (hundreds of lines of
  scancode tables) and `linked_list_allocator` (safety-critical free-list logic) stay external.
- `sha2`/`chacha20` (`sys/random.rs`): `default-features = false`, `sha2` additionally needs
  `features = ["force-soft"]` and `chacha20` needs `--cfg chacha20_backend="soft"` via
  `.cargo/config.toml`'s rustflags — both otherwise try to compile a SIMD backend this target's
  disabled SSE/MMX can't lower. Crypto primitives are the one place this codebase deliberately
  prefers a vetted dependency over hand-rolling — the opposite call from `pic8259`/`uart_16550`
  above.

### 2.5. Test architecture

*(from CLAUDE.md, 2026-09-29)*

No libtest — `no_std`, tests boot in QEMU and self-report via `sys/qemu.rs` (writes to the
`isa-debug-exit` port; `test-success-exit-code` in `Cargo.toml` must stay in sync with
`QemuExitCode::Success`) and `sys/console/serial.rs` (hand-rolled 16550 UART, read via `-serial
stdio`).

- **Since nightly-2026-09 cargo writes test binaries and module objects under `build/<crate>/<hash>/
  out/`, not `deps/`**: `scripts/qemu_runner.sh` spots a test by its `-<16 hex>` name suffix (it
  used to match `*/deps/*`, silently running every test as an interactive `cargo run` that
  reported panics as passes), and `build.rs` links a module's newest object from either place
  (a stale same-named `deps/` object once got a kernel panic at boot) and fails the build if
  `core`/`alloc` symbols stay undefined.
- `sys/lib.rs` defines `no_std` test scaffolding (`custom_test_frameworks`, `#[test_case]`) and
  boots itself under `#[cfg(test)]`.
- `tests/*.rs` integration tests use `harness = false` — each defines its own `fn main()` via
  `entry_point!` and calls `exit_qemu()` directly.
- `tests/fork_wait.rs` + `regress/fork-exec-smoke/`: since `scheduler::start`/`process::do_exit`
  never return to a test's own `main`, it registers a syscall number (`9999`) directly via
  `oxidebsd::syscall::oxidebsd_register_syscall` (kept `pub` for this) whose handler calls
  `exit_qemu`.
- **Any test claiming to verify syscall-reachable code should spawn a real ELF and go through an
  actual `SYSCALL` instruction**, not call kernel handlers as plain Rust functions from a test's
  own `main()` — interrupts stay enabled and `ticks()` keeps advancing in the latter, hiding real
  bugs (see "Real networking" gotcha 2 below). Established pattern (`tests/*_syscall_smoke.rs` +
  `regress/*-syscall-smoke/`) for anything syscall-shaped added from here on.
- Anything needing live interactive keyboard input (real Ctrl+C→SIGINT, `su`/`login` prompts,
  `sulogin`/`getty` tty takeover, persistence surviving a real QEMU restart, any `reboot`/halt/
  poweroff success path) used to be flatly manual-QEMU-only — **partially superseded**: plain
  keystroke injection (typing, Ctrl+C/Ctrl+Z/held-key-for-autorepeat) genuinely can be scripted
  headlessly via the QEMU monitor's own `sendkey <combo> [hold-ms]` command (see the USB-input
  section's own `OXIDEBSD_QEMU_MONITOR` doc comment) — this is how a real Ctrl+C/Ctrl+D bug got
  found and confirmed fixed without a human at a display. Still genuinely manual-only: anything
  needing a real human *decision* mid-session (`su`/`login`/`sulogin` credential entry), and
  persistence-across-a-real-restart/`reboot`/halt/poweroff (there's no scripted way to observe the
  VM coming back up cleanly, only to send keys into an already-running one) — hand those to the
  user rather than trying to drive them via a backgrounded `cargo run`.
- **The full ~1687-file Open POSIX Test Suite pilot** (`tests/posix_conformance_smoke.rs`) is the
  primary correctness signal for POSIX conformance work — see "POSIX conformance pilot" below for
  its own history/tooling. `scripts/run_posix_pilot_supervised.sh [--reset]` is the standard way
  to run it unattended (a host-side supervisor that kills and retries around a genuine kernel-level
  wedge, since `t0`'s own userspace `alarm(40)` can't rescue one). A curated, fast-running subset
  (`POSIX_PILOT_CANARY_ONLY=1`, `build.rs`) accumulates every file a real regression was ever found
  through, as a standing smoke suite — currently ~173 files.

### 2.6. Traps and methods (2026-09-30)

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

- **Build caching**: the full story is in this file's §15.10; if in doubt, `objdump -d` the
  executable and look for the syscall numbers. Never `touch build.rs`.
- **Regression set** for socket, network, fd or process changes, one `cargo tv --test` each
  (about 25 minutes in all; run it in the background):
  `socket_syscall_smoke basic_boot rtl8139_smoke udp_smoke tcp_smoke poll_smoke ping_smoke
  icmp_smoke socketpair_smoke readv_smoke udp_syscall_smoke tcp_syscall_smoke poll_syscall_smoke
  ppoll_syscall_smoke ping_syscall_smoke socketpair_syscall_smoke rc_syscall_smoke
  std_hello_oxidebsd_syscall_smoke std_process_fs_oxidebsd_syscall_smoke
  std_thread_net_signal_oxidebsd_syscall_smoke sh_syscall_smoke at_syscall_smoke
  sysctl_syscall_smoke sysctl_tunables_smoke tty_syscall_smoke init_respawn_smoke fork_wait`.
  After a musl change also `POSIX_PILOT_CANARY_ONLY=1 cargo tv --test posix_conformance_smoke`,
  compared per file with `target/canary_run3.log` (127/173 pass, 2026-09-28).
- Build logs contain the POSIX pilot's expected per-file compile errors (53 skipped files);
  filter for `panicked at`, `could not compile`, `^error:` instead.
- A test that uses socket calls must load the `socket` module (`socketpair`/`shutdown` moved
  there from `posix_compat`). A test using the network must call `rtl8139::init` before loading
  modules: the card's DMA addresses are 32-bit, and after oxfs's pools the driver refuses.
- `spin::Mutex` is not re-entrant: a second `STATE.lock()` while a guard is alive spins forever
  (found in TCP's `detach`). A hang: sample it with gdb through the QEMU monitor
  (`OXIDEBSD_QEMU_MONITOR=<port>`, monitor command `gdbserver tcp::<port>`, then `addr2line`
  against the test ELF under `target/x86_64-oxidebsd/debug/build/oxidebsd/*/out/`).
- musl: `__syscall(...)` counts its arguments; a compound literal passed to it must be
  parenthesized (braces don't protect commas). Never write the macro prefix `__NR_` in a
  `syscall.h.in` comment. Check new `__NR_*` names and numbers for collisions.
- New `tests/*.rs` need a `[[test]] harness = false` entry in `Cargo.toml`.
- **A musl change relinks all of BusyBox** (about 40 minutes, since `libc.a` gets newer). Batch
  musl edits into one change. The canary (above) then has to be rerun too.
- **A persistent disk keeps what it was seeded with**: `target/oxfs_disk.img` is mounted, never
  reseeded, so new files in `/etc`, `/sbin`, `/dev` or rebuilt BusyBox applets only appear after
  deleting it (the owner has OK'd that; it reformats in seconds). Tests always use a fresh disk.
  A symptom seen: `wget` failing with "unrecognized syscall number 142" from a stale applet.
- **Driving a live boot headlessly**: `OXIDEBSD_QEMU_MONITOR=45454 OXIDEBSD_QEMU_DISPLAY=none
  cargo rv > run.log 2>&1` in the background, wait for `switching to pid 1` in the log, then
  `scripts/qemu_sendkeys.py 45454 'command' ...`. Note the log's size before sending and read from
  there. Stop QEMU by process name (`ps -eo pid,comm`), not `pgrep -f`/`pkill -f`, whose pattern
  matches the shell running them and kills it.
- **A test kernel that calls `boot::apply_cmdline` replaces the flags the real command line set**:
  include `-D`, or user output stops reaching COM1 and the test looks silent
  (`tests/sysctl_tunables_smoke.rs`).
- To make the kernel print something from user space in a test, call an unregistered syscall
  number: it logs `unrecognized syscall number N`, once per number.
- `poll`/`select`/`ppoll` are registered by the `socket` module: a test that polls anything (a
  pipe, `/dev/klog`) must load it, or `poll` is `ENOSYS`.
- oxfs buffers writes per descriptor; since `2e49de9` a lookup, open or read through another
  descriptor commits them first. A new path into file contents that bypasses those three (a new
  syscall reading an inode directly) must call `force_commit_pending_writes` too.
- **Every syscall-reachable change gets a test first-run before believing it**: this session's own
  test expectations were wrong four times (two gc cases, a control-buffer size, a weekday) and the
  kernel right; and the kernel was wrong once (an overflow in `kern.msgbuf`'s read, a kernel panic
  any user could trigger). Check which it is before changing either.

## 3. Boot

### 3.1. Boot: Limine (`sys/boot/mod.rs`, `x86_64-oxidebsd.ld`, `scripts/qemu_runner.sh`, `external/bsd/limine`)

*(from CLAUDE.md, 2026-09-29)*

Migrated off the `bootloader` v0.9 crate (BIOS-only, unmaintained) to the Limine boot protocol
2026-09-09/10 — real UEFI boot capability, needed for the eventual real-hardware (Surface) target
(see "USB input" below).

- `sys/boot/mod.rs` (renamed from `sys/boot.rs` when the Multiboot2 boot path below was added)
  declares the Limine request statics (`HhdmRequest`/`MemmapRequest`/
  `FramebufferRequest`/`RsdpRequest`/`ExecutableCmdlineRequest`) Limine scans for at load time,
  plus a `BootInfo` shim (`physical_memory_offset`/`memory_map` — same field names as the old
  `bootloader::BootInfo`, so every existing call site across `sys/main.rs`/`sys/lib.rs`/
  `tests/*.rs` keeps working unchanged; Limine's HHDM offset and memory map are direct analogs of
  the old crate's two fields) and a `limine_entry_point!` macro replacing `entry_point!`.
- **Higher-half kernel placement**: `x86_64-oxidebsd.ld` links the kernel into the top of the
  address space now, not identity-mapped low memory — this is *why* `module::MODULE_VA_BASE`
  moved into the top 2 GiB (see "Dynamic kernel modules" below) and needed a matching
  `-C code-model=kernel` rustflag.
- **No more direct `0xb8000` VGA text-mode access** — Limine doesn't guarantee that mapping.
  `sys/console/framebuffer.rs` is a from-scratch real framebuffer console (dynamic grid sizing off
  Limine's own reported resolution, a hand-rolled 16x8 glyph font) replacing it; `sys/console/
  vga.rs`'s VT100/ANSI layer now writes through the framebuffer console instead.
- **PIC/LAPIC interrupt routing needed real fixes** — Limine's own interrupt setup differs from
  `bootloader` v0.9's: LAPIC disable + IMCR + explicit IRQ unmask, done explicitly at boot rather
  than relying on firmware/bootloader state left over from `bootloader` v0.9.
- **`scripts/qemu_runner.sh`** replaces `bootimage runner` as `.cargo/config.toml`'s `runner`:
  stages a hybrid BIOS+UEFI ISO from `target/limine-stage/` (populated by `build.rs`'s
  `build_limine_deploy_tool`) plus the just-built kernel/test ELF, boots it under QEMU (UEFI/OVMF
  by default, `OXIDEBSD_FIRMWARE=bios` for the legacy path), and for a test binary translates the
  real `isa-debug-exit` code into this script's own pass/fail exit status. See "Real disk
  persistence" below for how the real ATA disk and the boot ISO share IDE channels without
  colliding.
- **Real-hardware safety gate**: a `no-ata` kernel cmdline token (`oxidebsd::boot::ata_disabled()`)
  skips the real ATA disk probe entirely — oxfs's mount-or-format logic will genuinely *format*
  whatever disk it finds on the legacy IDE ports, so this is off by default (QEMU dev/test workflow
  relies on the real ATA-backed disk) and on whenever `OXIDEBSD_REAL_HARDWARE=1 cargo run` is used.
- **Two real regressions found the same migration session, both from one root gap** in `build.rs`:
  cargo silently inherits a build script's own `CARGO_ENCODED_RUSTFLAGS` (higher-priority than a
  plain `.env("RUSTFLAGS", ...)` override) into any `Command` it spawns — the kernel's own new
  `-T x86_64-oxidebsd.ld` linker flag was leaking into every nested userland/module `cargo`
  invocation, silently overriding their own linker scripts. Broke every userland crate's entry
  point (`ENTRY(_start)`, produced ELFs with entry `0x0`/zero program headers) until fixed with
  `.env_remove("CARGO_ENCODED_RUSTFLAGS")` in both `build_userland_crate` and
  `build_module_crate` — which in turn let `-C relocation-model=static` start genuinely applying
  to module builds for the first time, surfacing the `code-model=kernel` gap noted under "Dynamic
  kernel modules" below. **Any future rustflags addition to the top-level target should be
  checked against this same leak path** before assuming a nested `cargo` invocation's own
  `.env("RUSTFLAGS", ...)` override actually took effect.
- Verified via all 51 `tests/*.rs` files migrated and passing, confirmed on both `OXIDEBSD_FIRMWARE`
  values.
- **Kernel command line** (`boot::parse_cmdline`, fed by Limine's cmdline response or the Multiboot2
  cmdline tag): `no-ata`, `console.underline=color` (SGR 4 as cyan, Linux-console style, instead of
  a stroke under the glyph), and FreeBSD's boot flags: `-s` (single-user), `-D` (dual console: `ttyv0`
  output also to COM1), `-h` (serial console, output only). Without `-D` the serial log shows only
  kernel messages; `qemu_runner.sh` adds `-D` for tests and headless runs. `boot::init_argv()` is
  pid 1's argv as FreeBSD/OpenBSD build it (`/sbin/init` [`-s`], empty environment); unused until
  `/sbin/init` replaces `/bin/sh` as pid 1. `OXIDEBSD_KERNEL_CMDLINE=-s cargo run` or `cargo run -- -s` sets it.

### 3.2. Boot: Multiboot2 (`sys/boot/multiboot2.rs`, `x86_64-oxidebsd-multiboot2.ld`, `regress/multiboot2-boot-smoke/`, `regress/multiboot2-kernel/`, `scripts/qemu_common.sh`, `scripts/run_multiboot2_smoke.sh`, `scripts/run_multiboot2_kernel.sh`)

*(from CLAUDE.md, 2026-09-29)*

A second, independent boot path alongside Limine — real GRUB or Limine's own `protocol:
multiboot2` can load this kernel directly. Gated behind a `multiboot2` Cargo feature; one
dedicated smoke test (`tests/multiboot2_boot_smoke.rs`, structurally identical to `basic_boot.rs`
via a `multiboot2_entry_point!` macro mirroring `limine_entry_point!`) lives in its own workspace
member (`regress/multiboot2-boot-smoke/`) purely so it can get its own linker script under an
otherwise-shared-rustflags workspace.

- A real, hand-written 32-bit-protected-mode → 64-bit-long-mode trampoline (`global_asm!`, Intel
  syntax): builds temporary page tables (a fixed 64 MiB low-identity window + a kernel-higher-half
  window sized *dynamically* from linker-provided `_kernel_phys_start`/`_kernel_phys_end` — this
  kernel's own embedded content already makes `.rodata` alone >100 MiB, so a hardcoded page count
  would go stale exactly like the userland-load-base floor already has), enables PAE/LME/paging,
  hands off to Rust (`init_from_mbi`: parses the real Multiboot2 memory map into the same
  `limine::memmap::Entry` shape the frame allocator consumes, builds final page tables including a
  fresh 8 GiB HHDM window at `MULTIBOOT2_HHDM_OFFSET`, returns a `&'static BootInfo`).
- **Real bug**: the smoke crate depends on the `oxidebsd` lib itself (unlike every other
  `build_*_crate` helper in `build.rs`), so an unconditional call to build it from `oxidebsd`'s own
  build script recurses forever. `CARGO_PRIMARY_PACKAGE` looks like the fix but isn't — Cargo sets
  it only while *compiling* a package, not while running its already-built build-script binary.
  Fixed with an explicit `OXIDEBSD_BUILDING_MULTIBOOT2_SMOKE` reentrancy-guard env var instead.
- **Two real bugs found on the first real boot, both silent triple faults** (no IDT exists this
  early in boot): (1) the final page tables dropped Stage A's own low-identity window, exactly
  where the still-active call stack (`boot32_stack`) lives — `Cr3::write` unmapped the stack out
  from under itself; fixed by keeping that window mapped permanently instead. (2) entering Rust via
  `jmp` instead of `call` left `RSP` at the wrong System V ABI parity (`%16==0`, not `8`) —
  harmless until the first alignment-sensitive instruction, `cpu::fpu::init`'s `fxsave`; fixed with
  a `sub rsp, 8`.
- `scripts/qemu_common.sh`: the loader-agnostic parts of driving QEMU (firmware/OVMF selection, the
  fixed IDE topology, isa-debug-exit wedge-guard/exit-code translation), shared by `qemu_runner.sh`
  and `scripts/run_multiboot2_smoke.sh` (`OXIDEBSD_MULTIBOOT2_LOADER=limine|grub`, default limine).
- Verified booting clean via both Limine's own multiboot2 protocol and real GRUB (BIOS). **GRUB
  under UEFI/OVMF crashes inside GRUB/firmware itself, before ever reaching this kernel's own
  code** — root-caused by disassembling GRUB's own compiled `multiboot2.mod`/`relocator.mod`
  (real evidence, not a guess): GRUB's classic-entry boot dispatch always uses its own
  `grub_relocator32_boot`, which has a genuine internal bug downgrading itself from UEFI's 64-bit
  long mode back to 32-bit protected mode (confirmed via a fully isolated repro — a trivial,
  unrelated hand-assembled kernel crashes identically through the same GRUB+OVMF+QEMU pipeline).
  Two more header tags fixed the *dispatch*, confirmed by the crash address changing: a bare
  `MULTIBOOT_HEADER_TAG_EFI_BS` (type 7, optional) tells GRUB not to call `ExitBootServices()`
  first, which is what its dispatch checks (`grub_efi_is_finished`) to choose the native
  `grub_relocator64_efi_boot` over the buggy downgrade. Past that, a **third, deeper issue
  remains, outside this kernel's reach**: `grub_relocator64_efi_boot` itself page-faults writing
  to one of its own global variables (confirmed via QEMU's gdbstub — a correctly-relocated
  address, but the page is mapped read-only). **Confirmed via web search to be a known, already-
  diagnosed upstream GRUB 2.14 regression** (our exact installed version, released 2026-01-14),
  not an OVMF quirk: commit `d72208423dca` ("kern/dl: Use correct segment in
  `grub_dl_set_mem_attrs()`") made GRUB correctly mark loaded modules' `.text` read-only per real
  ELF section flags, but the x86 relocator's own stubs are patched *in place at runtime* and GNU
  `as` always emits plain `.text` as `"ax"` (no write flag) — so the runtime patch now faults. A
  fix (moves those stubs into a new `.text.relocator` section flagged `"awx"`) was submitted
  upstream 2026-05-13 ("relocator/x86: fix multiboot2 Xen boot failure on GRUB 2.14"); merge
  status into a release build unconfirmed as of this writing. `OXIDEBSD_FIRMWARE=bios` with the
  grub loader remains the reliable path until a fixed GRUB lands.
- **`regress/multiboot2-kernel/`**: a second, separate entry crate booting the *real* kernel (module
  loading, `hush` spawn, scheduler handoff — `oxidebsd::kernel_main::run_real_system`, shared
  verbatim with `sys/main.rs`'s own Limine path) via Multiboot2, not just the trampoline-only smoke
  test above. Needs its own crate rather than reusing `sys/main.rs` directly (the smoke test's own
  trick): every embedded module/`hush` ELF's `include_bytes!(env!("..._PATH"))` needs a
  `rustc-env` var only visible while compiling the package that set it, never a downstream
  dependent — confirmed directly, not assumed. `scripts/run_multiboot2_kernel.sh` builds and boots
  it interactively; needs `RUSTFLAGS` to fully override (not merely append to) the plain kernel's
  own config-resolved `-Tx86_64-oxidebsd.ld`, same reasoning as `build_multiboot2_boot_smoke_crate`.
- **A real, previously-latent frame-allocator bug, only surfaced by a kernel this large**: a
  Multiboot2 memory map (unlike Limine's own) has no concept of "where the loader put the kernel" —
  left unfixed, `BootInfoFrameAllocator` treated this kernel's own ~266 MiB debug image as free
  memory and started handing out frames that alias its own live code/page-tables, hanging silently
  right after the heap-mapping log line (no panic — consistent with corrupting currently-executing
  state, not a caught fault). The tiny `multiboot2-boot-smoke` test never allocates enough to hit
  it. Fixed: `exclude_kernel_range` carves `[0x100000, _kernel_phys_end)` out of any `MEMMAP_USABLE`
  entry before it reaches the frame allocator, splitting an entry if the exclusion falls strictly
  inside it.
- **Real UEFI can't load this real kernel via Multiboot2 at all, separately from the GRUB/UEFI bug
  above**: Multiboot2's fixed-physical-address placement (no relocation, unlike Limine's native
  protocol) needs one contiguous free hole the image's full size — confirmed live, Limine's own
  multiboot2 loader panics `"Could not find viable load address for executable"` under OVMF for
  this real ~266 MiB image (the small smoke-test image never hit this either). Real BIOS/SeaBIOS's
  much simpler, unfragmented memory map has no such hole shortage. `scripts/run_multiboot2_kernel.sh`
  therefore defaults to `OXIDEBSD_FIRMWARE=bios` itself (unlike every other script here, which
  defaults to `uefi`) — this is now the *only* known-working firmware choice for either loader with
  the real, full-size kernel.
- **`exclude_kernel_range`'s own alignment bug, found chasing a real, reproducible page fault**:
  `_kernel_phys_end` isn't page-aligned, but the exclusion used it as-is — `BootInfoFrameAllocator`'s
  `region.base / 4096` truncates *down*, so the first frame handed out after exclusion still
  overlapped the kernel's own `.bss` (specifically `MMAP_PTRS` itself, right at the tail of the
  image) by however many bytes `_kernel_phys_end` overshot its own page boundary. The first
  consumer to receive that frame corrupted a `&'static Entry` pointer read back later, producing a
  fault at a garbage address inside `BootInfoFrameAllocator::allocate_frame` — root-caused via
  `addr2line` against the real faulting `RIP`, not guessed. Fixed: round the exclusion's own end up
  to the next page boundary.
- **`boot32_stack` (the Stage A trampoline's own stack, never replaced by a real per-process kernel
  stack this early in boot) was only 64 KiB, sized for `multiboot2-boot-smoke`'s tiny workload,
  never revisited once `multiboot2-kernel` (module loading + oxfs's real mount-or-format pass)
  started using the same trampoline**. Silently overflowed (no guard page) into the corrupted-frame
  bug above with no evidence beyond a shifted stack pointer. Bumped to 1 MiB.
- **Real Multiboot2 framebuffer support**: added the header's own framebuffer *request* tag (type
  5) plus parsing of the loader's *info* tag (type 8) it produces in response — without either,
  `console::framebuffer` has nothing to find and the screen stays black, confirmed live (a real
  boot reached a working `hush` prompt, serial-log-confirmed, with a genuinely blank display).
  `boot::FbInfo` is a new boot-path-agnostic descriptor `console::framebuffer`/`drivers::fbdev` now
  consume instead of `limine::framebuffer::Framebuffer` directly, so the same rasterizer/`/dev/fb0`
  code serves either boot path. **A real off-by-one-byte bug in the info tag's own layout**: its
  `reserved` field (right after `framebuffer_type`) is a `u16`, not a `u8` — every color-info field
  read one byte too early, producing plausible-looking but wrong red/green/blue mask values (e.g.
  `red_size=16`, an impossible width for one channel) that rendered the whole text console in the
  wrong color (blue instead of white) while doom's own direct pixel writes — a separate path,
  bypassing this tag entirely — stayed correct throughout, which is what made it look
  doom-specific at first. Root-caused by printing the parsed values and back-solving what a
  one-byte shift would produce (a clean, standard XRGB8888 layout), not by guessing at the fix.
  Also required exposing a `boot::set_hhdm_offset` setter: `boot::hhdm_offset()` (used by
  `drivers::fbdev` to recover the framebuffer's real physical address) was populated only by
  Limine's own `read_boot_info`, panicking the instant anything called it under multiboot2.
  Confirmed end to end: a real, playable doom frame captured via QEMU's own `screendump`.

## 4. Memory and program loading

### 4.1. Memory management (`sys/memory/mod.rs`, `sys/memory/allocator.rs`)

*(from CLAUDE.md, 2026-09-29)*

- `memory::init` walks `CR3` and adds `BootInfo::physical_memory_offset` to get a virtual pointer
  to the level-4 table. Call at most once — hands out a `&'static mut`.
- `memory::BootInfoFrameAllocator` bump-allocates from `BootInfo::memory_map`'s `Usable` regions.
  Holds plain `(region_index, frame_number)` cursor state, not a rebuilt-each-call iterator (the
  old approach was O(n²)). **A boxed-iterator "fix" is wrong, not just suboptimal**: this
  allocator is constructed *before* `allocator::init_heap` (which needs it to map the heap's own
  pages), so any heap allocation inside its own constructor panics with no heap yet to satisfy it.
  Gained a real `FrameDeallocator` impl later (an intrusive, singly-linked free list stored *in*
  the freed frames themselves — safe pre-heap-init by construction, unlike a `Vec`) — see "Real
  threading"'s memory-reclaim notes below.
- `allocator::init_heap` and `module::map_region` map freshly allocated pages with `.ignore()`,
  not `.flush()` — a never-before-mapped page has no stale TLB entry, and `invlpg` is individually
  trapped under QEMU's software TCG.
- The heap lives at a fixed VA (`allocator::HEAP_START`); size scales with detected RAM
  (`memory::usable_ram_bytes()`), clamped floor/ceiling (currently `1024` MiB ceiling, QEMU RAM
  `8192` MiB). Same RAM-scaling pattern for `process::kernel_stack_size()`/`user_stack_pages()`.
  NOT scaled: `module::MODULE_VA_BASE`/`MODULE_REGION_CEILING` (a VA-range limit from the
  relocation model, not RAM).
- Global allocator is `linked_list_allocator`'s `Heap` wrapped in a local `Locked<T>`
  (`spin::Mutex`), not the crate's own `LockedHeap` — avoids a second spinlock crate in the graph.

### 4.2. User-mode execution (`sys/memory/address_space.rs`, `sys/process/elf.rs`, `sys/process/usermode.rs`)

*(from CLAUDE.md, 2026-09-29)*

`process::spawn` builds the first process this way at boot; `process::do_execve` builds every
later one the same way, mid-syscall.

- Regression-test crates (`regress/*`) are separate workspace members; `build.rs`'s
  `build_userland_crate` (kept its name -- see that function's own doc comment) cross-builds each
  into `target/userland/` and exposes `<NAME>_ELF_PATH`
  via `cargo:rustc-env` for `include_bytes!`. Each crate's `linker.ld` forces a distinct load base
  clear of the kernel image, heap, phys-mem-offset window, and identity-mapped low-memory region.
  **This floor moves as the kernel image grows** — surfaces as `Elf(MappingFailed)`/
  `PageAlreadyMapped` at `execve`/spawn time, not build time. **Before adding a new binary or
  trusting the current floor**, re-derive it: `readelf -l target/x86_64-oxidebsd/debug/oxidebsd |
  grep -A1 LOAD`, take highest `VirtAddr + MemSiz`, round up with real headroom — this exact class
  of bug ("embedded corpus/kernel image grew past the fixed load-base floor") has hit multiple
  times as the kernel and the POSIX test corpus grew. `regress/musl-smoke/` isn't a Rust crate —
  built with `musl-gcc`, load base via `-Wl,-Ttext-segment=`.
- `AddressSpace::new` shallow-copies all 512 L4 entries from the currently active table — safe
  only when the active table's user-space content is empty (true only for boot spawn).
  `AddressSpace::fork`/`new_excluding_user` (live process) instead recursively walk the table
  using `USER_ACCESSIBLE` as the sole kernel-vs-user signal at any level. `AddressSpace` is now
  `Arc`-refcounted (`teardown` gated on `strong_count == 1`) — see "Real threading" below.
- **`gdt.rs`'s ring-0 stacks must be `static mut`, not `static`.** A plain `static`, never written
  via a Rust `&mut`, gets interned into `.rodata` by the optimizer — causes a double/triple fault
  the instant an exception uses it. Any future stack added the same way needs the same treatment.
- **Every IDT gate a software interrupt (`int n`, `int3`, ...) can trigger from ring 3 needs
  `DPL = Ring3` explicitly** — gates default to `Ring0`. Wrong DPL manifests as a `#GP` on the IDT
  entry itself.
- **`elf::load` tracks already-mapped pages in a `BTreeMap<Page, PhysFrame>` for one call** —
  `PT_LOAD` segments align to `p_align`, not to each other, so small binaries routinely share a
  page across segments. Flags aren't unioned across segments sharing a page — found live via a
  small RW segment sharing a page with an RX segment, keeping only the RX flags (first static
  write page-faulted). Worked around at the linker-script level for that one crate, not fixed in
  `elf.rs` generally — a real flag-union fix would help every future small binary with writable
  globals.
- Known simplification: no `NO_EXECUTE` on any ELF segment (would also need `EFER.NXE`).

### 4.3. Real ring-3 fault-to-signal delivery, and real mmap fixes (`sys/cpu/interrupts.rs`, `sys/process/fault_trampoline.rs`, `sys/process/mm.rs`, `sys/modules/oxfs/`, `sys/syscall/ffi.rs`)

*(from CLAUDE.md, 2026-09-29)*

**`interrupts::page_fault_handler` used to reboot the whole kernel on any page fault, ring-3 or
not** — a wild pointer deref in any userland program took the entire VM down. Fixed: on ring-3
(checked via the interrupted frame's CS RPL; ring-0 stays a hard reboot), resolves a real signal
(`SIGBUS` for a reference into a live mapping's own reserved-but-unbacked tail, `SIGSEGV`
otherwise) via `do_kill`'s self-signal path, then redirects to a real, kernel-authored,
user-executable trampoline page (`process::fault_trampoline`, fixed VA `0x_1FFF_FFFF_F000`).
`general_protection_fault_handler` and `invalid_opcode_handler` (`#UD`, real `SIGILL`) needed and
got the identical ring-3 treatment, each found missing it independently later.

- **Why not invoke the handler directly from the fault handler**: `extern "x86-interrupt"`'s
  compiler-generated entry/exit exposes no Rust-visible GPR fields. Fix: the trampoline is
  `mov eax, SYS_FAULT_PUMP (554); syscall; ud2` — redirecting `instruction_pointer` there forces a
  real `SYSCALL` through `syscall_entry`'s already-correct GPR capture; `syscall_dispatch`
  special-cases `SYS_FAULT_PUMP` like `SYS_SIGRETURN`. **Redirecting execution this way
  permanently clobbered the interrupted process's real `RAX` before it could be captured** until
  fixed by stashing it to a scratch slot on the trampoline's own page first — and separately, see
  the syscall-ABI section's `SYSRETQ`/`RCX` note for the deeper version of this same class of bug.
- **Real MPR-correct partial mapping**: `mm::do_mmap_file_backed` only backs/maps pages covered by
  a file's real (page-rounded) extent — the tail past it gets no page-table entry at all, so a
  reference there raises `SIGBUS` rather than silently succeeding against a zero page.
- **A real, separate bug found chasing this, not about mmap at all**: `open(O_CREAT)` on a
  brand-new path defers the real inode/dir-entry until first commit; `unlink()`ing before that
  commit found nothing to remove and silently no-op'd, then the deferred commit resurrected the
  name. Fixed: `OpenFile::Write` gained `unlinked: bool`.
- **Real `MAP_FIXED`/`MAP_PRIVATE` flags** riding the wire (packed into `prot`'s unused high bits,
  musl patched accordingly) with real `EBADF`/`EINVAL` validation — previously the kernel guessed
  anonymous-vs-file-backed purely from `fd == -1` and ignored `MAP_FIXED` entirely. Real
  `mtime`/`ctime` tracking (`oxidebsd_unix_time`). Real `mlockall(MCL_FUTURE)`/`RLIMIT_MEMLOCK`
  enforcement via `ThreadGroupShared`'s `mlockall_future`/`locked_bytes` — no longer a no-op.
  Real `ENXIO` for an out-of-bounds nonzero-offset mmap; real `EOVERFLOW` when `off + len` exceeds
  `i64::MAX` (musl's own client-side guard against this was removed on the `oxidebsd` branch —
  deliberately fixed even though real glibc+Linux fails this same test too, since this project
  targets literal POSIX-spec conformance).
- **Real anonymous `PROT_NONE` + scoped real `mprotect(2)`**: `SYS_MPROTECT` had been a total
  no-op; real musl's `pthread_create()` builds a guard page via `mmap(PROT_NONE)` then
  `mprotect()`s the usable tail — with both stubbed, no pthread stack ever had a real guard.
  `PROT_NONE` anonymous mmap now leaves the region genuinely unmapped (load-bearing:
  `AddressSpace::teardown` treats a clear `USER_ACCESSIBLE` bit as an absolute "nothing here"
  signal and would otherwise leak a frame per guard page). `mprotect(2)` enforcement is
  deliberately scoped to only the mmap-managed VA window (`MMAP_REGION_BASE..CEILING`) — outside
  it (a `PT_LOAD` segment, the heap, `ld.so`'s own RELRO target) stays the original permissive
  no-op, since the module/kernel region's page tables are shared physical frames across every
  process. A not-yet-backed page inside the window demand-allocates on `mprotect` instead of
  `ENOMEM`ing, matching musl's guard-then-widen sequence — uses
  `map_to_with_table_flags` with intermediate P2/P3/P4 flags always pinned fully open (the
  convenience `map_to` derives parent flags from the leaf, which would leave a widened region's
  own intermediate tables permanently inaccessible).
- **A real `sys_pwritev2` gap**: missing the negative-offset check `sys_pwrite` already had —
  real musl's `pwrite()` issues `SYS_pwritev2`, not `SYS_pwrite`, so that check never ran. A test
  calling `pwrite(fd, buf, len, -1)` (musl maps to `-2` internally) drained oxfs's entire
  free-block pool in one `resize_inode_data` call before failing `EIO` instead of the `EINVAL`
  POSIX requires, starving every later test in the same boot that needed to write a file. Fixed:
  reject any `ofs` other than exactly `u64::MAX` (the real "current position" sentinel) that's
  negative.
- `pthread_create/1-5.c`/`3-2.c` (real pthread guard-page/stack-size-immutability checks) still
  `FAIL` even with a real, verified-working guard mechanism — confirmed not the same bug: this
  musl port's own TLS/TSD carve-out leaves more slack before the guard boundary than
  `_SC_THREAD_STACK_MIN` accounts for, so the tests' bounded recursion never actually touches the
  guard on this build. `pthread_create/1-6.c` is a real, permanent, accepted `TIMEOUT` — the test
  hardcodes `NCPU=4` real-parallel busy-loop threads, which serialize on this single-core kernel;
  a real-SMP prerequisite (ROADMAP.md v0.5.0), not a bug.
- `mlockall/3-7.c` — not a kernel bug: the only file in the whole corpus that `open()`s its own
  source by a relative path; fixed by seeding that literal fixture path (`POSIX_TEST_EXTRA_FILES`
  in `build.rs`, same convention `sigaltstack/9-1.c`'s fixture already established).
- Verified via `tests/mmap_syscall_smoke.rs` (14 parts, several run in isolated forked children
  since a fault kills whichever process it hits) and `tests/dynlink_syscall_smoke.rs` (RELRO's
  `mprotect` call untouched by the new enforcement scope).

### 4.4. File-backed `mmap`: status record

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

- [x] **File-backed `mmap`**: done — corrected from an earlier draft of this doc, which said
      `do_mmap` took no fd/offset argument at all; that was true when this row was first written
      but real `MAP_SHARED` fd-backed mapping landed since (see CLAUDE.md's "Real /tmp, /dev/shm,
      and real fd-backed MAP_SHARED mmap" section), and real MPR (`SIGBUS` past a mapped object's
      own real extent) plus real ring-3 fault-to-signal delivery landed after that (see CLAUDE.md's
      "Real ring-3 fault-to-signal delivery, and two mmap fixes" section) — closes
      `mmap/11-2.c`/`11-3.c`/`12-1.c` in the pilot below. **`MAP_PRIVATE` no longer always behaves
      as `MAP_SHARED`** — real `MAP_FIXED`/`MAP_PRIVATE` flags now ride the wire (previously guessed
      purely from `fd == -1`), with real `EBADF`/`EINVAL` validation, real `MAP_FIXED` replace-at-
      address semantics, and a real fresh never-cached, never-written-back frame copy for
      `MAP_PRIVATE` against a file-backed fd; real `EOVERFLOW`/`ENXIO` for out-of-range nonzero
      `off` also landed (see CLAUDE.md's "SIGCHLD delivery, real `sched_setparam(2)`, and four more
      mmap conformance fixes" section for the four commits closing `mmap/{3,9,14,18,19,21,28,31}-1.c`/
      `munmap/{3,4}-1.c` — landed after this doc's last recorded pilot baseline below, not yet
      re-verified with a fresh full pilot run). Real `mtime`/`ctime` tracking and real
      `mlockall(MCL_FUTURE)`/`RLIMIT_MEMLOCK` enforcement landed alongside. **Genuine remaining
      gaps**: no copy-on-write page-fault tracking for `MAP_PRIVATE` against anonymous memory (only
      the file-backed case is real), and real `msync(2)` itself still doesn't exist as its own
      syscall (writeback only happens at `munmap`/exit).

### 4.5. Dynamic linking: milestone 1, real `PT_INTERP` (`sys/process/elf.rs`, `sys/process/lifecycle.rs`, `build.rs`, `sys/modules/oxfs`)

*(from CLAUDE.md, 2026-09-29)*

A real, working `fork`+`execve` of a genuinely dynamically-linked ELF, resolved/relocated by
musl's own real `ld.so` running as the interpreter — not this kernel doing the linking itself.

- **A second, fully separate `-fPIC`/shared musl build** produces a real `libc.so`
  (`/lib/ld-musl-x86_64.so.1` is a symlink to it, matching musl's own real convention).
- **`elf.rs` accepts `ET_DYN` alongside `ET_EXEC`** — solely for a `PT_INTERP` interpreter image.
  `elf::load` gained a real, kernel-chosen additive `bias` parameter applied to every segment's
  `p_vaddr`.
- **Found the hard way, why a fixed link-time base doesn't work**: musl's own self-relocation
  bootstrap always computes `real_addr = AT_BASE + stored_value`, expecting `stored_value` already
  zero-based — a fixed-base link double-counts the base. Fixed by linking `libc.so` at its own
  natural near-zero base and applying the real bias in `elf::load` instead.
  `INTERP_LOAD_BASE = 0xc000000` — one fixed VA, nothing here needs more than one interpreter
  resident at once.
- `do_execve` loads the interpreter alongside the main binary when a `PT_INTERP` segment is
  present, both sharing the same fresh address space; the real jump target becomes the
  interpreter's entry point.
- **`SYS_MPROTECT=492`** — `ld.so`'s RELRO step calls real `mprotect`, now gained real, scoped
  enforcement (see "Real anonymous `PROT_NONE` + scoped real `mprotect(2)`" below) — RELRO's own
  call target (a `PT_LOAD` ELF segment) falls outside that scope and stays the original permissive
  no-op, confirmed unaffected.
- Verified end-to-end via `tests/dynlink_syscall_smoke.rs`.
- **Milestone 2, not started**: `dlopen`/`dlsym`/`dlclose`/`dlerror` — blocked on `mmap`/`mprotect`
  actually enforcing real placement/protection outside the narrow anonymous-mmap-window scope that
  now exists (real file-backed segment protection and `MAP_FIXED` placement guarantees a real
  dynamic loader would need are still permissive no-ops/bump-allocators).

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

- [x] **Milestone 1 done, milestone 2 open** — corrected from an earlier draft of this doc, which
      wrongly said no `PT_INTERP` support existed at all; CLAUDE.md itself was stale on this same
      point until this pass. **Milestone 1 (done, `e72fc7d`)**: a real `fork`+`execve` of a
      genuinely dynamically-linked ELF works end to end — `elf.rs` accepts `ET_DYN`, loads a real
      `PT_INTERP` interpreter (musl's own `ld.so`, i.e. `libc.so` itself) alongside the main binary,
      and that interpreter performs real self-relocation and symbol resolution, verified by a real
      libc call round-tripping (`tests/dynlink_syscall_smoke.rs`). See CLAUDE.md's "Dynamic
      linking" section for the full design. **Milestone 2 (not started)**: `dlopen`/`dlsym`/
      `dlclose`/`dlerror` — loading a *second*, independently-chosen shared object at runtime.
      musl's own implementation of that is pure userspace logic over `mmap`/`mprotect`/relocation
      processing once a `.so` is mapped, not a new syscall gap — but genuinely blocked on real
      `mprotect` enforcement below (`SYS_MPROTECT` exists but is still a permissive no-op stub —
      unaffected by the mmap-flags work above). **`mmap` itself is less of a blocker than when this
      row was first written**: real `MAP_FIXED` now exists (needed to place a `.so` at a
      loader-chosen address) — see the `mmap` row above — so the remaining gap is narrower than
      "mmap/mprotect enforcement" as a pair; `mprotect` alone is what's left.

### 4.6. Real PIE/ASLR loading + native `/bin` utilities (`sys/process/aslr.rs`, `lib/oxlibc`, `bin/*`, `build.rs`)

*(from CLAUDE.md, 2026-09-29)*

- A no-`PT_INTERP` `ET_DYN` main binary is a real PIE: `do_execve` loads it at a fresh random,
  page-aligned bias from `aslr::pick_bias()` (~32 bits, window starts at `0x3000_0000_0000`, an
  empty gap above the mmap region). `fork` never re-picks (it never calls `elf::load`). Every
  fixed-`ET_EXEC` (`regress/*`, BusyBox) is unchanged. `user_stack::build` adds `main_bias` to
  `AT_PHDR`/`AT_ENTRY` (silently correct before only because that bias was always 0).
- **No in-kernel relocation processor**: a PIE-model binary must have *zero* relocations, enforced
  at build time by `build_pie_crate_at`'s `assert_zero_relocations` (fails the build). Traps found
  live: (1) ordinary disciplined Rust still gets relocations, because `#[track_caller]` bounds-check
  `Location` metadata embeds a real address — a fixed-address link hides this entirely (same source:
  0 relocs as `ET_EXEC`, 4 as `ET_DYN`); `build_pie_crate_at` bakes in `-C panic=immediate-abort -Z
  location-detail=none` to fix it (so `#[panic_handler]` is mostly dead code). (2) `_start as usize
  as u64` compiles to a stored, GOT-style address — take symbol addresses with `asm!("lea …",
  sym _start)`. (3) no `core::fmt`, no tables of slices (use `if` chains).
- PIE crates use **no `-T<linker.ld>`**: rust-lld's default script is what maps the ELF header/phdrs
  into the first `PT_LOAD` (so `AT_PHDR` is dereferenceable; note the first phdr is `PT_PHDR`, not
  `PT_LOAD`). Their `build.rs` is just `-pie` + `--no-dynamic-linker`.
- `lib/oxlibc` (`#![no_std]`, deliberately the seed of the eventual libc): syscall stubs,
  `entry_point!` (`global_asm!` `_start` capturing `RSP`), `exit`, the crate graph's one
  `#[panic_handler]`, `fs`/`io`/`path`/`args`. `bin/{echo,true,false,pwd,cat,ls,mkdir,rm,cp,mv,ln,
  touch}` bind to the same `OXFS_<NAME>_ELF_PATH` names their BusyBox predecessors used, so
  `sys/modules/oxfs`'s `seed_file` calls are unchanged. `NATIVE_BIN_UTILITIES` in `build.rs` filters
  them out of the roster — deliberately *not* by deleting their tuples from `build_busybox.rs`,
  which would force a ~1h full BusyBox rebuild (the inert tuples can go with the next unrelated
  edit there). `sbin/lsoxmod` is PIE too.
- Behavior notes: flags are `-n` echo, `-a -l -1 -C --color=…` ls (sorted; on a tty a plain `ls`
  is column-major and colored — dirs bold blue, symlinks cyan, executables green; off a tty, i.e.
  redirected/piped, it's one-per-line and plain, since `tty_size()`/`TIOCGWINSZ` only succeeds on
  the console; `-l` has aligned columns, a `total` line, owner/group names from `/etc/passwd`+
  `/etc/group`, UTC mtime, ` -> target`), `-p` mkdir, `-r -f` rm, `-r` cp, `-s` ln, `-c` touch
  (really updates mtime); short-flag clusters (`-rf`) work. `lib/oxlibc` has `time`
  (`clock_gettime` + epoch→UTC civil date) and `io::BufWriter`.
- **A console `write` costs ~1 ms** (framebuffer render + serial mirror): `ls /bin` took 770 ms to
  the console but 30 ms to `/dev/null`, `ls -l /bin` 3.25 s vs 70 ms. Any utility that prints many
  small pieces must batch through `BufWriter`, not `print`. `TIOCGWINSZ` reports the console's
  real grid (`console::vga::width()/height()`, framebuffer ÷ 8x16, e.g. 160x50 at 1280x800) — it
  used to be a fixed 24x80, which left `ls` columns and `hush` wrapping on half the screen. `cat`
  with no file args reads fd 0 (fine from a pipe). **Corrected 2026-09-22** (this entry previously
  claimed the console's stdin was non-blocking, so bare interactive `cat` "just exits" — stale,
  see the ncurses/nano/nvi section's own real input-hang writeup for why): stdin is a real,
  genuine blocking read, so a bare interactive `cat` now genuinely **blocks** waiting for input,
  confirmed live — double-echoing each typed character (the kernel's own auto-echo plus `cat`'s
  own read-then-write-to-stdout loop, both independently echoing the same bytes, a real and
  expected effect against a program with no line-editing of its own). **Real, disclosed gap found
  the same way**: this kernel has no canonical-mode (`ICANON`) EOF-character handling at all (see
  the syscall-ABI section's own `ICANON` doc comment) — Ctrl+D lands as a plain byte `0x04`, not a
  real end-of-file, so a bare interactive `cat` with no controlling-tty session established (the
  common case; nothing here has called `setsid`/`TIOCSCTTY`) currently has no keyboard-reachable
  way to end it at all. `rm -r` re-opens the directory after each batch: oxfs's `getdents` cursor
  counts *used* records, so deleting under a live cursor skips entries.
- Seeded file modes (`oxfs`'s `seed_mode`): `0755` only for what the kernel could execute — a
  `#!` script or an `ET_EXEC`/`ET_DYN` ELF (static binaries, PIEs, `libc.so`) — else `0644` (data,
  headers, `.a`, relocatable `.o`); `/etc/shadow` stays `0600`. It used to be `0755` for everything.
- **Gotcha**: a persistent `target/oxfs_disk.img` keeps its old seeded binaries — the native
  utilities only appear after a fresh format (delete the image; formatting takes a few seconds with DMA/virtio).
- Verified by `tests/pie_aslr_smoke.rs` (real per-exec randomization, fork inherits),
  `tests/native_bin_syscall_smoke.rs` (all 12, flags + error paths), and `sh /test_busybox.sh`
  through real hush (104/104), driven headlessly via `OXIDEBSD_QEMU_MONITOR` `sendkey`.

## 5. System call ABI and coverage

### 5.1. Syscall ABI (`sys/syscall/`)

*(from CLAUDE.md, 2026-09-29)*

OxideBSD's own native, BSD-flavored ABI over `SYSCALL`/`SYSRETQ` — not Linux-compatible. Syscall
number in `RAX`, up to 4 args in `RDI`/`RSI`/`RDX`/`R10` (not `RCX`/`R11`, clobbered by `SYSCALL`
itself). Success/failure via the **carry flag** (`CF=0` success, value in `RAX`; `CF=1` failure,
positive errno in `RAX` — traditional BSD/x86 Unix convention). Pre-musl-port syscalls
(`SYS_EXIT=1`, `SYS_FORK=2`, `SYS_READ=3`, `SYS_WRITE=4`, `SYS_OPEN=5`, `SYS_CLOSE=6`,
`SYS_WAIT4=7`, `SYS_LSEEK=8`, `SYS_GETPID=20`, `SYS_EXECVE=59`) match real FreeBSD numbers as an
authenticity nod. Everything since is OxideBSD's own invention, picked for what porting
musl/BusyBox actually needed: `SYS_MMAP=100`...`SYS_UTIMENSAT=167`/`SYS_SETSID=112`/
`SYS_GETSID=177`/`SYS_SETGROUPS=178`/`SYS_MOUNT_BIND=174`/`SYS_MOUNT_TMPFS=175`/`SYS_UMOUNT2=176`
(the `100-178` batch: mmap/munmap/brk/fs_base/writev/pipe/dup2/getppid/getcwd/unlink/rmdir/
rename/kill/sigaction/sigprocmask/sigreturn/setpgid/getpgid/ioctl/dup/fstat/stat/lstat/getdents/
uname/clock_gettime/nanosleep/socket family/poll/socketpair/set_tid_address/fcntl/shutdown/readv/
readlink/symlink/setitimer/getitimer/uid-gid family/chmod/chown), then `SYS_FSYNC=471` through
`SYS_FSTATFS=477`, `SYS_PRLIMIT64=478` through `SYS_REBOOT=486`, `SYS_UMASK=487`, `SYS_LINK=488`,
`SYS_MKNOD=489`, `SYS_CHROOT=490`, `SYS_GETRUSAGE=491`, `SYS_MPROTECT=492`, `SYS_SIGTIMEDWAIT=495`,
`SYS_SIGQUEUE=496`, `SYS_SCHED_SETPARAM=507`, the pre-reserved `526`-`553` POSIX/SysV batch (see
that section), `SYS_FAULT_PUMP=554`, `SYS_CLONE=555`, `SYS_EXIT_GROUP=556`,
`SYS_FUTEX_REQUEUE=557`, the socket calls `SYS_SENDMSG=577`...`SYS_ACCEPT4=582` (OxideBSD-doc
`UNIX.md` §4; 142-144 retired, `ENOSYS`); plus real Linux numbers reused directly where confirmed dead in this musl
fork (`fchmod=91`, `sched_getaffinity=204`, `futex=202`). **Check `sys/syscall/` and module
sources for the current highest number before assigning a new one.**

**Before picking a new syscall number**: grep every still-inert real-Linux value in
`external/mit/musl/arch/x86_64/bits/syscall.h.in` for a live musl caller before reusing it — bit
twice already: `SYS_KILL`'s invented number collided with real Linux's inert `setgroups` (which
*did* have a live musl caller via `initgroups()`), silently misrouting `setgroups()` into
`kill(2)`; and a later batch continuing `100-178` collided with real, still-referenced numbers
(`__NR_gettid`, live in `src/thread/synccall.c`). Since this musl fork is frozen at tag `v1.2.6`,
`471`+ (past the highest real-Linux number `bits/syscall.h.in` ever inspects) is *permanently*
collision-free — continue new invented numbers from there, or from this ABI's own highest already-
assigned number, whichever is higher.

**A collision-free *number* doesn't mean a collision-free *name*.** `__NR_futex_requeue=557`
(correctly past 471) reused a macro *name* this same vendored header already defines elsewhere for
real Linux's own unrelated futex2-family syscall `456` — plain C `#define` redefinition let the
textually-later `456` silently win, so `unlock_requeue()`'s musl-side call issued syscall `456`
(never registered here) instead of `557`, permanently and silently breaking every private-condvar
chain-wake beyond the first directly-woken waiter (found live via `pthread_cond_broadcast/1-1.c`).
Check the macro *name* for a collision too, not just the number, when adding a new `__NR_*`.

errno values must match musl's compiled-in `bits/errno.h`, not FreeBSD: whatever a handler
returns via the carry-flag ABI becomes musl's raw `errno` (`syscall_arch.h`'s `jnc`/`neg`). Every
`const E*` in the tree was audited against it 2026-09-24 (the net stack and oxfs's `ENOTEMPTY` still
had FreeBSD's) — re-check any new one.

The number→handler mapping is a runtime registry (`SYSCALL_TABLE`, `Mutex<BTreeMap>`) populated by
`oxidebsd_register_syscall` from each module's `module_init` — not a hardcoded `match`. An
unregistered number logs `[boot] unrecognized syscall number N` and returns `ENOSYS`, the main
tool for discovering what a ported program's startup still needs.

- **`SYSRETQ`'s selector scheme forces GDT order.** `SYSRETQ` derives `SS`/`CS` from
  `IA32_STAR[63:48]` as `+8`/`+16` — user data must sit immediately before user code. `sys/cpu/
  gdt.rs` order: kernel code, kernel data, unused placeholder, user data, user code, TSS. Don't
  reorder without redoing the `STAR` arithmetic; `Star::write` panics loudly if the GDT regresses.
- **No automatic stack switch on `SYSCALL` entry.** Control arrives at `syscall_entry` still on
  the user's own stack. `gdt::CURRENT_RSP0` (`static mut`, kept in sync by
  `gdt::set_kernel_stack` on every context switch) always names the current process's own kernel
  stack — required since two processes can be mid-syscall at once. No per-CPU `swapgs` —
  single-core only.
- `SyscallFrame`: the stub's pushed GPRs plus `user_rsp`. `rcx`/`r11` double as saved `RIP`/
  `RFLAGS`; `syscall_dispatch` flips bit 0 of `r11` to signal `CF`. **`SYSRETQ` couples `RIP` to
  the value in `RCX` at the instant it executes** — any code path that redirects execution
  asynchronously (the fault/timer trampoline redirect, see "Real ring-3 fault-to-signal delivery"
  below) must restore real `RCX`/`R11` through a dedicated two-stage restore-stub trampoline, not
  a plain register clobber, or it silently corrupts the interrupted process's own live computation
  on resume.
- `dispatch()` is a small, pure, directly unit-tested function separate from
  `syscall_dispatch`'s raw-pointer/frame handling.
- A registered handler's own wire format (`SyscallHandler`) is a plain `i64` (negative = `-errno`)
  — distinct from the public carry-flag ABI, just the module↔kernel boundary's shape.
- `sys_write`/`sys_read` don't validate `[ptr, ptr+len)` before dereferencing — a bad pointer
  page-faults (handled safely: log + reboot for ring-0, real signal delivery for ring-3 — see
  "Real ring-3 fault-to-signal delivery" below), not a soundness hole.
- `sys_read` delegates every fd, including 0/stdin, to `crate::fd`'s per-process `(Pid, fd)`
  registry — stdin's own registered callback is a **real, genuine blocking read** (`console::
  stdin::read`, see "Interactive shell" below), not a return-`0`-immediately one; corrected here
  2026-09-22 after a real, previously-undiscovered input-hang investigation (see the ncurses/nano/
  nvi section) found this file's own earlier claim to the contrary was stale.
- `sys_write`'s `fd == 2` (stderr) is an alias for `fd == 1` — no real second sink exists.

### 5.2. Numbering discipline and the scope of the POSIX syscall survey

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

Tracks OxideBSD's syscall surface against POSIX.1-2017 (Issue 7)'s System Interfaces volume,
not just against musl's live call graph (a narrower, earlier pass — still cited here where
relevant, since a POSIX-mandated interface with no live caller in our current userland is a much
lower priority than one BusyBox/TinyCC/hush already calls). Source list: the Open Group's own
function index, filtered down to the subset that's genuinely syscall-backed on a real Unix kernel
(process control, file I/O, directories, signals, IPC, sockets, time/clocks, threads, memory
mapping, users/groups/permissions, resource limits) — pure libc/userspace interfaces (`string.h`,
`math.h`, `ctype.h`, most of buffered stdio above `open`/`read`/`write`/`close`, locale, `regex.h`,
`wordexp`, POSIX tracing) are excluded; they never reach a syscall on any real Unix and don't
belong in this doc.

**Numbering discipline** (restated because it's real bug history, not boilerplate — see below):
before assigning any new number, grep `third_party/musl/arch/x86_64/bits/syscall.h.in` for a live
`__NR_*` caller in `third_party/musl/src/`. If musl already calls a real, unremapped Linux number
directly, use that number — don't invent one. Otherwise continue OxideBSD's own invented sequence
from the current highest, **555** (`SYS_CLONE` — now with a real handler,
`process::lifecycle::do_clone`, real threading having landed since this number was first reserved;
see "Real threading: `clone(2)`, `pthread_create`/`join`" below; see the full sweep below, then the
planned-implementation-order pre-reservation batch further down — this range moved four times
across three sessions). This
project has been bitten by number collisions twice before (`SYS_KILL`/real `setgroups`,
`__NR_getdents64` sibling) — and a great many more times, found and **fixed** by a full sweep of
the header, documented below.

**Deliberate exception to the discipline above, as of the batch in "Pre-reserved ahead of
implementation" further down**: this project has since decided it doesn't want its own planned
future syscalls sitting at borrowed real Linux numbers even when they're safely unclaimed today —
OxideBSD is its own ABI, not obligated to reuse real Linux's numbering just because a slot happens
to be free. So for syscalls with a **planned** implementation (not just a theoretical future one),
claim a permanent OxideBSD-invented number now, ahead of writing the handler, rather than waiting
until implementation time. This is a one-time cost (one musl-submodule bump, one full BusyBox
relink) paid once for a whole batch, instead of once per syscall spread across future sessions —
see that section for the full reasoning.

### 5.3. The full sweep of real/invented numeric collisions in the musl header

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

Not inferred — confirmed directly, then fixed. C allows two `__NR_*` macros with different names
but identical values with no warning, so nothing catches this at compile time: a program calling
the still-real side silently invoked OxideBSD's handler for the numerically-colliding invented
side, misinterpreting its arguments. A full pass over every `#define __NR_*` line in
`bits/syscall.h.in`, cross-referenced against every one of OxideBSD's own invented `SYS_*` values
(`src/`, `modules/*/src/`), found **33 real collisions** beyond the original four (`SYS_KILL`/
`setgroups`, `__NR_getdents64` sibling). All 33 have been redirected to fresh, verified-unclaimed
numbers starting at 493; **no kernel-side handler existed for any of the real-side names before
this fix**, so every one of these was a pure safety fix (silent misroute → clean `ENOSYS`), not a
functional regression — nothing that worked before still needs to work the same way.

| Real, formerly-unremapped macro | Old value → new | Collided with (OxideBSD's own) | Live caller | Effect if hit (now fixed) |
|---|---|---|---|---|
| `times` | 100 → 493 | `SYS_MMAP = 100` | `src/time/times.c:6` | Reachable via hush's `times` builtin — would have created a bogus anonymous mapping and returned garbage as a `clock_t`. |
| `ptrace` | 101 → 497 | `SYS_MUNMAP = 101` | none confirmed live | Dormant, fixed anyway. |
| `getpgrp` | 111 → 498 | `SYS_RENAME = 111` | none — musl's `getpgrp()` is emulated via `getpgid(0)`, never issues this syscall | Genuinely dead macro, fixed for hygiene. |
| `setresuid`/`seteuid` | 117 → 499 | `SYS_SIGACTION = 117` | `src/unistd/setresuid.c`, `seteuid.c` | Would have invoked `sigaction` with `(ruid,euid,suid)` misread as a signal-handler installation — high severity if ever hit. |
| `getresuid` | 118 → 500 | `SYS_SIGPROCMASK = 118` | `src/misc/getresuid.c` | Would have invoked `sigprocmask` instead. |
| `setresgid`/`setegid` | 119 → 501 | `SYS_SIGRETURN = 119` | `src/unistd/setresgid.c`, `setegid.c` | Highest-severity of the batch: `sigreturn` restores raw CPU state from a signal frame — a stray call here could have corrupted execution state, not just misrouted arguments. |
| `getresgid` | 120 → 502 | `SYS_SETPGID = 120` | `src/misc/getresgid.c` | Would have invoked `setpgid` instead. |
| `capget` | 125 → 503 | `SYS_DUP = 125` | `src/linux/cap.c` | Would have invoked `dup` instead. |
| `capset` | 126 → 504 | `SYS_FSTAT = 126` | `src/linux/cap.c` | Would have invoked `fstat` instead. |
| `ustat` | 136 → 505 | `SYS_MKDIR = 136` | none confirmed live (obsolete real syscall) | Dead, fixed for hygiene. |
| `sysfs` | 139 → 506 | `SYS_NANOSLEEP = 139` | none confirmed live (obsolete real syscall) | Dead, fixed for hygiene. |
| `sched_setparam` | 142 → 507 | `SYS_SENDTO = 142` | `src/thread/pthread_setschedprio.c`, `src/sched/sched_setparam.c` | Real handler now exists (`process::do_sched_setparam`, `SYS_SCHED_SETPARAM` in `modules/posix_compat`) — the number remap alone wasn't enough, since `sched_setparam(2)`'s own musl wrapper was separately, permanently stubbed to `ENOSYS` (unlike its `sched_getparam`/`sched_setscheduler` siblings) until the Open POSIX Test Suite pilot's `sched_setparam/*.c` FAILs surfaced it live — see CLAUDE.md's sched-related fixes. |
| `sched_rr_get_interval` | 148 → 508 | `SYS_POLL = 148` | `src/sched/sched_rr_get_interval.c` | `SYS_POLL` is heavily live (musl's DNS resolver) — this was the highest-traffic collision partner in the batch even though `sched_rr_get_interval` itself has no confirmed caller in the current roster. |
| `mlock` | 149 → 509 | `SYS_SOCKETPAIR = 149` | `src/mman/mlock.c` | `SYS_SOCKETPAIR` is live (wget HTTPS path). |
| `munlock` | 150 → 510 | `SYS_SET_TID_ADDRESS = 150` | `src/mman/munlock.c` | `SYS_SET_TID_ADDRESS` fires on *every* musl program's startup — highest-frequency collision partner in the batch. |
| `mlockall` | 151 → 511 | `SYS_FCNTL = 151` | `src/mman/mlockall.c` | `SYS_FCNTL` is live (`O_NONBLOCK` path). |
| `munlockall` | 152 → 512 | `SYS_SHUTDOWN = 152` | `src/mman/munlockall.c` | `SYS_SHUTDOWN` is live (wget HTTPS path). |
| `vhangup` | 153 → 513 | `SYS_READV = 153` | `src/linux/vhangup.c` | `SYS_READV` is live (buffered `fread`/`fgets` path). |
| `modify_ldt` | 154 → 514 | `SYS_READLINK = 154` | none confirmed live | `SYS_READLINK` is live (symlink work); fixed anyway. |
| `pivot_root` | 155 → 525 | `SYS_SYMLINK = 155` | `src/linux/pivot_root.c` | `SYS_SYMLINK` is live; `pivot_root`'s own BusyBox applet was already cut from the roster before v0.1, but the macro itself was still live in musl. |
| `_sysctl` | 156 → 515 | `SYS_SETITIMER = 156` | none confirmed live (obsolete real syscall) | `SYS_SETITIMER` is live (`ping`'s receive-loop timeout); fixed anyway. |
| `prctl` | 157 → 516 | `SYS_GETITIMER = 157` | `src/linux/prctl.c` (no BusyBox-roster caller — grepped, only comment references in `pgrep.c`/`pidof.c`) | `SYS_GETITIMER` is live; fixed anyway since musl's own `prctl()` wrapper does contain a real call site even if unreferenced today. |
| `arch_prctl` | 158 → 517 | `SYS_GETUID = 158` | `src/linux/arch_prctl.c` only — confirmed **not** used by this port's real TLS setup, which goes through the patched `__set_thread_area.s` asm stub instead | `SYS_GETUID` is extremely live; `arch_prctl.c` itself is genuinely dead code but fixed for hygiene given how frequently 158 would otherwise dispatch to `getuid`. |
| `adjtimex` | 159 → 518 | `SYS_GETEUID = 159` | `src/linux/clock_adjtime.c` (only under `CLOCK_REALTIME`, no confirmed applet path) | `SYS_GETEUID` is live; fixed anyway. |
| `setrlimit` | 160 → 519 | `SYS_GETGID = 160` | none reachable — musl's own `setrlimit()` wrapper always tries `prlimit64` first and never falls through | **Reverses a previously-*accepted* risk** (see CLAUDE.md's own Syscall ABI section, which flagged this exact collision as "avoided only because `prlimit64` always succeeds first"). Now genuinely impossible instead of merely masked. |
| `acct` | 163 → 520 | `SYS_SETGID = 163` | `src/unistd/acct.c` (no process-accounting applet in roster) | `SYS_SETGID` is live; fixed anyway. |
| `settimeofday` | 164 → 521 | `SYS_GETGROUPS = 164` | `src/internal/syscall.h`'s `time32` alias (no confirmed applet calls it directly) | `SYS_GETGROUPS` is live (the `su`/`setgroups` work); fixed anyway. |
| `swapon` | 167 → 522 | `SYS_UTIMENSAT = 167` | `src/linux/swap.c` — no `swapon`/`swapoff` applet is currently seeded (`grep` of `build.rs`/oxfs seeding confirms neither is built) | `SYS_UTIMENSAT` is live (`touch`'s `ENOENT`→`O_CREAT` fallback); fixed anyway since a future roster change could reintroduce `swapon`. |
| `get_kernel_syms` | 177 → 523 | `SYS_GETSID = 177` | none confirmed live (obsolete real syscall) | `SYS_GETSID` is live (`getty`'s real fallback path); fixed anyway. |
| `query_module` | 178 → 524 | `SYS_SETGROUPS = 178` | none confirmed live (obsolete real syscall) | Ironic: 178 was the landing number chosen to *fix* the original `SYS_KILL`/`setgroups` collision, without checking it against this file's own still-inert `query_module` value at the time. Not currently dangerous (no live caller) but fixed for consistency now that a full sweep was done anyway. |

**Deliberately left alone** (confirmed intentional, not oversights):
- `__NR_exit` / `__NR_exit_group` (both 1), `__NR_fork` / `__NR_vfork` (both 2), `__NR_getdents` /
  `__NR_getdents64` (both 129) — documented in-file as real aliases: exit/exit_group have no
  "just this thread" distinction to preserve on a kernel with no threads; vfork aliases to real
  `fork()` per POSIX's own explicitly-allowed implementation; getdents/getdents64 are the
  already-fixed 64-bit-sibling case from CLAUDE.md's musl-port section.
- `__NR_mount` (165, collides with `SYS_CHMOD`) / `__NR_umount2` (166, collides with `SYS_CHOWN`) —
  `third_party/musl/src/linux/mount.c`'s own comment already states both macros are "unreferenced
  from here on": `mount()`/`umount()`/`umount2()` are patched at the call-site level to issue
  `SYS_create_module`/`SYS_init_module`/`SYS_delete_module` directly (see "Mount table" below),
  bypassing these macros entirely. Left untouched to match that file's own explicit, already-made
  decision rather than second-guessing it.

None of the 33 fixed collisions had been hit by the test suite or `test_busybox.sh` (no seeded
applet calls most of the real-side names directly), which is exactly why they were still latent —
same invisibility class as the `SYS_KILL`/`setgroups` bug before `su` was tested interactively.
`times`, `setresuid`/`seteuid`, `setresgid`/`setegid`, and `getresuid`/`getresgid` are the ones with
a real, if narrow, live path today. No kernel-side handler exists yet for any of the real-side
names (`times`, `sigpending`, `sigtimedwait`, `sigqueue`, `setresuid`, etc.) — this sweep only
guarantees each now lands on a clean, unclaimed number and `ENOSYS`s honestly instead of
misrouting; implementing any of them is separate future work, tracked in the tables below.

### 5.4. Filesystem/process misc syscalls: fsync, ftruncate, fallocate, flock, statfs, prlimit64, nice, chrt, reboot (`sys/modules/oxfs`, `sys/modules/posix_compat`, `sys/reboot.rs`)

*(from CLAUDE.md, 2026-09-29)*

`link`/`mknod`/SysV IPC/`chroot`/namespaces/`inotify`/ext2 `ioctl`s/`xattr` were a distinct,
deliberately-out-of-scope gap at the time this landed (`link`/`mknod`/`chroot` since done);
namespaces don't fit this single-address-space kernel at all.

- **All sixteen numbers land at `471`-`486`** — see the syscall-ABI collision rule above.
  `oxfs`'s `SYS_FSYNC=471`...`SYS_FSTATFS=477`, `posix_compat`'s `SYS_PRLIMIT64=478`...
  `SYS_REBOOT=486`.
- **`SYS_FSYNC`/`SYS_SYNC`** are real, not stubs — a shared `commit_write_buffer` (from
  `oxfs_close`) is callable for one fd or swept across every open write fd.
- **`SYS_FTRUNCATE`/`SYS_FALLOCATE`** resize directly at the block level, not via a whole-content
  buffer (the 128 KiB kernel-stack floor can't hold a large file). Growing zero-fills only the
  new region.
- **`SYS_FLOCK`** is a real per-inode `LOCK_SH`/`LOCK_EX`/`LOCK_UN` advisory table (16 entries),
  released on close. A conflicting request fails `EAGAIN` immediately even without `LOCK_NB` — no
  scheduler-yield primitive is reachable from a module syscall handler.
- **`SYS_STATFS`/`SYS_FSTATFS`** report a real musl-layout `struct statfs` (120 bytes) from live
  block/inode-usage counts.
- **`SYS_PRLIMIT64`** backs `getrlimit`/`setrlimit`. `Process::rlimits: [(u64,u64); 16]` — stored,
  never enforced.
- **`SYS_SETPRIORITY`/`SYS_GETPRIORITY`** (`nice`) — `Process::nice: i32`, no real scheduling
  effect. **`SYS_SCHED_SETSCHEDULER`/`_GETSCHEDULER`/`_GETPARAM`/`_GET_PRIORITY_MAX`/`_MIN`/
  `SYS_SCHED_SETPARAM=507`** (`chrt`) — **real `SCHED_FIFO`/`SCHED_RR` priority semantics are
  genuinely enforced**, including a real `EPERM` on a non-root priority raise; `sched_setscheduler`
  returns `0` on success (not the former policy — a real bug where an earlier draft returned the
  former policy broke `pthread_setschedparam()` whenever the caller's policy wasn't already
  `SCHED_OTHER`, since fixed).
- **`SYS_REBOOT`** (+ `sys/reboot.rs`) matches real Linux's `RB_AUTOBOOT`/`RB_HALT_SYSTEM`/
  `RB_POWER_OFF` magic values. Root only (`EPERM`). Every success path halts/resets/powers off the
  VM — manual-QEMU-only.
- **`SYS_UMASK=487`**. `Process::umask: u32` (default `0o022`), applied by oxfs's `open(O_CREAT)`,
  `mkdir` and `mknod`.
- **`sched_getaffinity`** (real `__NR_sched_getaffinity=204`, found via `nproc`): single-core, mask
  always bit 0.
- Verified via `tests/needs_syscall_smoke.rs`/`needs_syscall2_smoke.rs` (except `reboot`/`umask`,
  manual-only).

### 5.5. The 28-syscall batch pre-reserved ahead of implementation (`526`-`553`)

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

Distinct from the collision sweep above (that batch fixed real bugs — a still-real macro silently
misrouting into an OxideBSD handler with mismatched arguments). **Nothing in this batch was
colliding with anything** — every one of these 28 syscalls was already confirmed sitting at a
safe, unclaimed real Linux value, and would have `ENOSYS`'d cleanly forever if left alone. This
batch exists purely because of a deliberate architectural choice (see the numbering-discipline
note at the top of this doc): OxideBSD is its own ABI, and syscalls it actually plans to implement
shouldn't sit at borrowed real-Linux numbers just because the slot happened to be free — they get
a permanent OxideBSD-invented number instead, claimed now, so the eventual implementation pass is
a pure kernel-side change (register a handler at the already-claimed number) with **zero further
musl-submodule edits**. Landed in one commit
(`third_party/musl`'s `oxidebsd` branch, `bd7f66d3`) covering the whole batch at once — one
submodule bump, one full BusyBox relink, instead of paying that cost once per syscall spread
across future sessions.

**Implementation order** (update the checkbox when a syscall in this batch gets a real kernel-side
handler — this is the tracking list for the batch, not just historical numbering rationale):

- [x] 1. `getrandom` (`526`) — `modules/posix_compat`'s `handle_getrandom` -> `src/syscall/ffi.rs`'s
      `sys_getrandom`, delegating to `src/random.rs`'s existing generator. Verified via
      `tests/getrandom_syscall_smoke.rs` + `userland/getrandom-syscall-smoke/`.
- [x] 2. `sysinfo` (`527`) — `modules/posix_compat`'s `handle_sysinfo` -> `src/syscall/ffi.rs`'s
      `sys_sysinfo`/`RawSysinfo` (368 bytes, verified via a direct C `offsetof`/`sizeof` probe
      against musl's real `struct sysinfo`). Real `uptime`/`totalram`/`procs`; `freeram ==
      totalram` (same "no deallocation tracking" tier `/proc/meminfo`'s `MemFree` already uses);
      `loads`/`sharedram`/`bufferram`/`totalswap`/`freeswap`/`totalhigh`/`freehigh` honestly zero
      (no load-average/page-cache/swap tracking exists). Verified via
      `tests/sysinfo_syscall_smoke.rs` + `userland/sysinfo-syscall-smoke/`.
- [x] 3. `sigaltstack` (`528`) — `modules/signal`'s `handle_sigaltstack` -> `src/syscall/ffi.rs`'s
      `sys_sigaltstack` -> `src/process/signals.rs`'s `do_sigaltstack`/`AltStack`. Real
      `(ss_ptr, old_ptr)` wire format; bookkeeping only (`SA_ONSTACK` still isn't honored by
      signal delivery -- a handler's frame is always built off the interrupted context's own live
      `user_rsp`, not this stack's address) -- `SS_ONSTACK` is always reported unset on read-back.
      Copied by `fork`, reset to disabled by `execve`.
      Verified via `tests/sigaltstack_syscall_smoke.rs` + `userland/sigaltstack-syscall-smoke/`.
- [x] 4. `pause` (`529`) — `modules/signal`'s `handle_pause` -> `src/syscall/ffi.rs`'s `sys_pause`
      -> `src/process/signals.rs`'s `do_pause`. A genuine new block/wake-on-signal primitive
      (`ProcState::Blocked(BlockReason::WaitingForSignal)`), not just a state field — woken by
      `do_kill`/`signal_foreground_group`'s own `Action::SetPending` arm via a new shared
      `wake_if_paused` helper. Always returns `EINTR`; real POSIX ordering (a caught handler runs
      before the caller ever observes `pause()` "returning") falls out for free from this
      codebase's existing "deliver pending signals at the tail of every completed syscall" design.
      Verified via `tests/pause_syscall_smoke.rs` + `userland/pause-syscall-smoke/`.
- [x] 5. `sigsuspend` (`530`)
- [x] 6. `timer_create` (`531`)
- [x] 7. `timer_settime` (`532`)
- [x] 8. `timer_gettime` (`533`)
- [x] 9. `timer_getoverrun` (`534`)
- [x] 10. `timer_delete` (`535`)
- [x] 11. `mq_open` (`536`)
- [x] 12. `mq_unlink` (`537`)
- [x] 13. `mq_timedsend` (`538`)
- [x] 14. `mq_timedreceive` (`539`)
- [x] 15. `mq_notify` (`540`)
- [x] 16. `mq_getsetattr` (`541`)
- [x] 17. `shmget` (`542`)
- [x] 18. `shmat` (`543`)
- [x] 19. `shmctl` (`544`)
- [x] 20. `shmdt` (`545`)
- [x] 21. `semget` (`546`)
- [x] 22. `semop` (`547`)
- [x] 23. `semctl` (`548`)
- [x] 24. `semtimedop` (`549`)
- [x] 25. `msgget` (`550`)
- [x] 26. `msgsnd` (`551`)
- [x] 27. `msgrcv` (`552`)
- [x] 28. `msgctl` (`553`)

Numbers assigned in the batch's own planned implementation order (cheapest / most build on
existing primitives first, most architecturally novel last):

| Order | Number | Syscall | Old (real, unclaimed) value | Why this position |
|---|---|---|---|---|
| 1 | `526` | `getrandom` | `318` | Near-direct backing already exists (`src/random.rs`'s real ChaCha20 generator, already serving `/dev/urandom`). |
| 2 | `527` | `sysinfo` | `99` | Non-POSIX footnote (see below) but same tier — honest all-zero-except-real-fields struct, same pattern as `getrusage`/`times`. |
| 3 | `528` | `sigaltstack` | `131` | One small `Process` state addition. |
| 4 | `529` | `pause` | `34` | Thin wrapper, reuses whatever primitive `sigsuspend` ends up needing. |
| 5 | `530` | `sigsuspend` | `130` (`rt_sigsuspend`) | Needs a genuinely new block/wake-on-signal primitive, not just a state field. |
| 6-10 | `531-535` | `timer_create`/`timer_settime`/`timer_gettime`/`timer_getoverrun`/`timer_delete` | `222-226` | Natural extension of the already-implemented `setitimer`/`getitimer` infrastructure once per-timer-id tracking exists. |
| 11-16 | `536-541` | `mq_open`/`mq_unlink`/`mq_timedsend`/`mq_timedreceive`/`mq_notify`/`mq_getsetattr` | `240-245` | Needs a new blocking primitive, but `src/fs/pipe.rs`'s existing blocking-buffer machinery (already reused for `socketpair`) is the natural backing. |
| 17-28 | `542-553` | SysV IPC: `shmget`/`shmat`/`shmctl`/`shmdt`, `semget`/`semop`/`semctl`/`semtimedop`, `msgget`/`msgsnd`/`msgrcv`/`msgctl` | `29-31`/`64-71`/`220` | Biggest, most novel subsystem, no live caller today, and `ipcrm`/`ipcs` are already cut from the BusyBox roster — lowest priority of the batch. |

This table reflects the batch's state *at reservation time* — purely the number reservation,
matching the collision-sweep's own "safety fix, not a functional regression" framing above, with
implementation left as separate future work. That future work is now done: see "Pre-reserved
batch: first/second/third/fourth/fifth/sixth implementation" above for all 28 items' real
handlers, landed across six sessions in real POSIX/SysV order rather than this table's own
original priority order (items 17-28, the SysV IPC sub-batches, were originally expected to land
last given their novelty — msg (25-28) and sem (21-24) each turned out simpler than shm (17-20),
so shm ended up genuinely last, matching this table's own prediction after all).

### 5.6. Pre-reserved batch, first implementation: `getrandom`, `sysinfo`, `sigaltstack`, `pause`, `sigsuspend`

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

Items 1-5 of the 28-syscall "pre-reserved ahead of implementation" batch further below now have
real handlers:

| POSIX interface(s) | Number | Handler | Notes |
|---|---|---|---|
| `getrandom` (only reachable via `getentropy()`) | `SYS_GETRANDOM = 526` | `modules/posix_compat` → `sys_getrandom` → `src/random.rs`'s existing generator | Real `(buf_ptr, buflen, flags)` wire format, no musl call-site patch needed. Delegates straight to the generator already backing `/dev/random`/`/dev/urandom` — inherits its persistent entropy pool and `RDRAND`/`RDSEED` hypervisor-distrust gate for free. `flags` outside real `GRND_NONBLOCK`/`GRND_RANDOM` is `EINVAL`; both accepted bits make no behavioral difference since this generator has no blocking-on-low-entropy distinction to honor them against. |
| `sysinfo` (non-POSIX, see footnote below) | `SYS_SYSINFO = 527` | `modules/posix_compat` → `sys_sysinfo`/`RawSysinfo` | Real `(info_ptr)` wire format, no musl call-site patch needed. `RawSysinfo` is 368 bytes, verified via a direct C `offsetof`/`sizeof` probe against musl's real `struct sysinfo` rather than assumed from Rust `repr(C)` layout rules alone. Real `uptime`/`totalram`/`procs`; `freeram == totalram` (same tier `/proc/meminfo`'s own `MemFree` placeholder already uses — no deallocation tracking exists anywhere in this kernel); `loads`/`sharedram`/`bufferram`/`totalswap`/`freeswap`/`totalhigh`/`freehigh` honestly zero (no load-average/page-cache/swap tracking exists). |
| `sigaltstack` | `SYS_SIGALTSTACK = 528` | `modules/signal` → `sys_sigaltstack` → `process::do_sigaltstack`/`AltStack` | Real `(ss_ptr, old_ptr)` wire format, no musl call-site patch needed (musl's own wrapper filters `SS_ONSTACK`/an undersized `ss_size` client-side). Bookkeeping only — no signal is ever actually delivered at the alt stack's own address, `SA_ONSTACK` still isn't honored by `deliver_pending_signal` (a handler's frame is always built off the interrupted context's own live `user_rsp` instead). `SS_ONSTACK` is always reported unset on read-back, an honest reflection of that. Copied by `fork` (the duplicated address space keeps the alt stack's address valid); reset to disabled by `execve` (the old address is meaningless in the new image). |
| `pause` | `SYS_PAUSE = 529` | `modules/signal` → `sys_pause` → `process::do_pause` | Real zero-argument wire format, no musl call-site patch needed. The first item in the batch to need a genuine new block/wake primitive (`BlockReason::WaitingForSignal`), not just a state field — see `do_pause`'s own doc comment for the full real-POSIX-ordering reasoning (a caught handler runs before the caller ever observes `pause()` "returning"). Woken by `do_kill`/`signal_foreground_group`'s own `Action::SetPending` arm via a new `wake_if_paused` helper; an ignored or blocked signal correctly leaves it parked. |
| `sigsuspend` | `SYS_SIGSUSPEND = 530` | `modules/signal` → `sys_sigsuspend` → `process::do_sigsuspend` | Real `(mask_ptr, sigsetsize)` wire format, no musl call-site patch needed. Reuses `do_pause`'s own `BlockReason::WaitingForSignal`/`wake_if_paused` primitive unchanged, adding a temporary, atomic swap of `blocked_signals` around the same wait (atomicity falls out for free from this kernel's single-core, no-preemption design). The one real new wrinkle: the temporary mask must **not** be restored as soon as a deliverable signal is found (the woken signal is very often blocked under the *original* mask — the canonical `sigsuspend` use case — so restoring early would hide it from `take_deliverable_signal`), but real POSIX semantics also require the *original* mask back once the wait is over, not the temporary one. Solved with a new `Process::sigsuspend_restore_mask` handoff: `do_sigsuspend` records the mask to restore instead of applying it, and `deliver_pending_signal` (`src/syscall.rs`) consumes it once it knows how the woken signal actually resolved — immediately, if no handler runs (`Terminate`/`Stop`/nothing left deliverable); deferred until `sigreturn`, if one does (via a new `set_signal_saved_blocked_override`, so the *original* mask is what `sigreturn` restores, not the temporary one `stash_signal_context` would otherwise have captured). |

**Verified end-to-end**: `tests/getrandom_syscall_smoke.rs` + `userland/getrandom-syscall-smoke/` —
a real spawned ELF through genuine `SYSCALL`/`SYSRETQ` (not a plain Rust function call --
`tests/random_smoke.rs` already covers the generator's own cryptographic logic directly, this test's
job is proving the syscall plumbing itself). Four parts: a real 32-byte request succeeds and isn't
degenerate, two consecutive requests differ, `len == 0` is a harmless no-op, and flag handling
(`GRND_NONBLOCK`/`GRND_RANDOM` accepted, any other bit `EINVAL`) is correct. **Passes.**

**Verified end-to-end**: `tests/sysinfo_syscall_smoke.rs` + `userland/sysinfo-syscall-smoke/` — same
real-`SYSCALL` pattern. Three parts: a real call's fields (`mem_unit == 1`, `totalram > 0`,
`freeram == totalram`, `procs >= 1`, every untracked field honestly zero), `uptime` non-decreasing
across two calls, and `totalram` stable across two calls. **Passes.**

**Verified end-to-end**: `tests/sigaltstack_syscall_smoke.rs` + `userland/sigaltstack-syscall-smoke/`
— same real-`SYSCALL` pattern, deliberately bypassing musl's own `sigaltstack()` wrapper (a raw
`syscall()` call) to exercise the kernel's own `EINVAL` path directly. Five parts: the real POSIX
startup state is disabled, installing a real alt stack succeeds, reading it back matches
(`flags == 0`, not `SS_DISABLE`/`SS_ONSTACK`), a combined set+read-old call reports the state from
just before, and an invalid flag bit is `EINVAL` while disabling correctly zeroes `sp`/`size`.
**Passes.**

**Verified end-to-end**: `tests/pause_syscall_smoke.rs` + `userland/pause-syscall-smoke/` — same
real-`SYSCALL` pattern. Forks; the parent immediately calls `pause()` (genuinely blocks, forcing
the scheduler to run the freshly forked child); the child sends the parent a caught-disposition
`SIGUSR1` (the wake hook fires against a process actually sitting in
`Blocked(WaitingForSignal)`), then exits; the parent's `pause()` returns `EINTR` only after the
handler has already run, and it reaps the child's clean `exit(0)` via `wait4`. **Passes.** (Found
and fixed live along the way: this crate's own real writable static — `HANDLER_RAN: AtomicBool`,
set from inside the signal handler — hit the exact same `elf.rs` PT_LOAD-segment-sharing-a-page
issue `sa-siginfo-syscall-smoke` first found; same linker-script `ALIGN(0x1000)` workaround
applied, see this crate's own `linker.ld`.)

**Verified end-to-end**: `tests/sigsuspend_syscall_smoke.rs` + `userland/sigsuspend-syscall-smoke/`
— same real-`SYSCALL` pattern (same `ALIGN(0x1000)` writable-global workaround, this time a real
`AtomicU32` handler counter). Blocks `SIGUSR1` via `sigprocmask`, forks; the parent immediately
calls `sigsuspend(&empty_mask)` (genuinely blocks, forcing the scheduler to run the freshly forked
child); the child sends the parent `SIGUSR1` — blocked under the parent's *original* mask, but not
under `sigsuspend`'s temporary empty one — then exits; the parent's `sigsuspend()` returns `EINTR`
only after the caught handler has already run once. Then, the specific correctness property
`do_sigsuspend`'s own doc comment exists for: a `sigprocmask` readback confirms `SIGUSR1` is
blocked *again* (the original mask, not left at the temporary empty one); a self-`kill(pid,
SIGUSR1)` while blocked again is held pending (`sigpending()`) without invoking the handler a
second time; unblocking it and issuing one more ordinary syscall then delivers it for real (handler
count reaches `2`) via the normal `deliver_pending_signal` tail. Finally reaps the child's clean
`exit(0)` via `wait4`. **Passes.**

### 5.7. Pre-reserved batch, second implementation: POSIX timers

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

Items 6-10 of the 28-syscall "pre-reserved ahead of implementation" batch above -- the real POSIX
per-process timer sub-batch -- now have real handlers too:

| POSIX interface(s) | Number | Handler | Notes |
|---|---|---|---|
| `timer_create` | `SYS_TIMER_CREATE = 531` | `modules/clock` -> `src/syscall/ffi.rs`'s `oxidebsd_sys_timer_create` -> `process::do_timer_create`/`process::PosixTimer` | Real `(clockid, evp_ptr, timerid_ptr)` wire format. `evp_ptr == 0` matches real POSIX's own default (`SIGEV_SIGNAL`/`SIGALRM`); an explicit `evp` supports `SIGEV_SIGNAL`/`SIGEV_NONE` only -- `SIGEV_THREAD`/`SIGEV_THREAD_ID` are real `EINVAL` (this kernel has no `clone(2)`, so musl's own `SIGEV_THREAD` path never reaches the syscall in the first place). A caller's own opaque `timer_t` is just an index into a new fixed `Process::posix_timers: [Option<PosixTimer>; MAX_POSIX_TIMERS]` array (`MAX_POSIX_TIMERS = 8`, no live caller to size this against) -- `EAGAIN` once every slot is in use, matching real Linux. |
| `timer_settime` | `SYS_TIMER_SETTIME = 532` | `process::do_timer_settime` | Real `(timerid, flags, new_ptr, old_ptr)` wire format (a bare 4-argument syscall on this LP64 target -- no `*64`-suffixed sibling exists, see `bits/syscall.h.in`'s own comment on the batch). Supports both relative (`flags == 0`) and `TIMER_ABSTIME` arming; `TIMER_ABSTIME` resolves the absolute target against whichever `clockid` the timer was created with (`CLOCK_MONOTONIC` converts directly since `ticks()` already *is* that domain; `CLOCK_REALTIME` anchors off `src/cpu/rtc.rs`'s live CMOS read). An all-zero `it_value` disarms regardless of `TIMER_ABSTIME`, matching real semantics. |
| `timer_gettime` | `SYS_TIMER_GETTIME = 533` | `process::do_timer_gettime` | Real `(timerid, val_ptr)` wire format, same remaining-time/floored-readback shape `getitimer`'s own `RawItimerval` handling already established, just nanosecond- (`RawItimerspec`) instead of microsecond-precision. |
| `timer_getoverrun` | `SYS_TIMER_GETOVERRUN = 534` | `process::do_timer_getoverrun` | Real single-argument `(timerid)` wire format -- unlike the other three, the overrun count itself *is* the syscall's return value, no output pointer. A real, if simplified, count: an expiry whose signal is still pending (undelivered) from a previous expiry increments it instead of being silently lost; resets to `0` on a fresh (non-overlapping) expiry or on rearming. **Known, accepted gap**: two timers sharing one `signo` can't be told apart by this bookkeeping (both observe the same process-wide `pending_signals` bit) -- no live caller to exercise this. |
| `timer_delete` | `SYS_TIMER_DELETE = 535` | `process::do_timer_delete` | Real single-argument `(timerid)` wire format. Just frees the slot -- no dealloc beyond that, consistent with this kernel's "no deallocation anywhere" stance. |

Delivery is a new scan inside `interrupts::timer_interrupt_handler`, alongside the existing
`ITIMER_REAL`/`real_timer_deadline` check: same simple "just set the pending bit" design (no
forced cross-process wake), now also computing the overrun count above. **Real, not just planned,
`fork`/`execve` semantics**: `Process::posix_timers` is *not* inherited by `fork` (matching real
`timer_create(2)`'s own NOTES section) and, unlike `real_timer_deadline`/`ITIMER_REAL`, *is* reset
(disarmed and deleted) by `execve` too -- a POSIX timer's whole purpose (notifying the program that
created it) means nothing to a new program image, the same reasoning `AltStack`'s own `execve`
reset already established.

**Verified end-to-end**: `tests/posix_timer_syscall_smoke.rs` + `userland/posix-timer-syscall-
smoke/` -- same real-`SYSCALL` pattern (same `ALIGN(0x1000)` writable-global workaround as
`pause-syscall-smoke`, this time two `AtomicU32` handler-run counters). Eight parts: an invalid
`clockid` is `EINVAL`; a default-`evp` (`SIGALRM`) relative one-shot timer fires exactly once and
reads back disarmed; an explicit `SIGEV_SIGNAL`/`SIGUSR1` periodic timer fires repeatedly and
`timer_delete` genuinely stops it; `TIMER_ABSTIME` against both `CLOCK_MONOTONIC` and
`CLOCK_REALTIME` (the latter specifically exercising the CMOS-RTC-anchored branch); overrun
accounting (block the signal, let a periodic timer expire several times undelivered, confirm a
nonzero overrun, unblock and confirm exactly one delivery); `EAGAIN` once all `MAX_POSIX_TIMERS`
slots are in use plus slot reuse after `timer_delete`; and `EINVAL` for an out-of-range or
already-deleted `timerid` across all four of `timer_settime`/`timer_gettime`/`timer_getoverrun`/
`timer_delete`. **Passes.**

### 5.8. Pre-reserved batch, third implementation: POSIX message queues

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

Items 11-16 of the 28-syscall "pre-reserved ahead of implementation" batch above -- the real POSIX
message-queue sub-batch -- now have real handlers too, closing out the whole batch's first three
sub-batches (SysV IPC, items 17-28, remains unimplemented).

| POSIX interface(s) | Number | Handler | Notes |
|---|---|---|---|
| `mq_open` (also backs `mq_send`/`mq_receive`/`mq_getattr`'s own `mqd_t`) | `SYS_MQ_OPEN = 536` | `modules/posix_compat` -> `src/syscall/ffi.rs`'s `sys_mq_open` -> `src/fs/mqueue.rs`'s `do_mq_open` | Real `(name, flags, mode, attr)` wire format, no musl call-site patch needed -- `name` is a raw NUL-terminated pointer (not this codebase's usual length-prefixed convention: real `mq_open(2)` already fills all 4 register slots, leaving no room for a `path_len`, and real Linux doesn't length-prefix it either). A real, separate name -> queue namespace (`NAMES`/`QUEUES`), not backed by `oxfs`. Returns a real fd from `crate::fs::fd` -- an mqd rides the ordinary fd registry exactly like a pipe/socketpair end, since real `mq_close(3)` is a bare `syscall(SYS_close, mqd)` (no distinct `mq_close` number exists in this batch). |
| `mq_unlink` | `SYS_MQ_UNLINK = 537` | `do_mq_unlink` | Real `(name)` wire format, no patch needed. Removes the name immediately; the queue itself survives until every open descriptor closes, matching real POSIX. |
| `mq_timedsend` (also backs `mq_send`) | `SYS_MQ_TIMEDSEND = 538` | `do_mq_timedsend` | Real Linux needs 5 syscall args (`mqd, msg, len, prio, at`); this ABI only carries 4. `third_party/musl/src/mq/mq_timedsend.c` is patched (`oxidebsd` branch) to pack `mqd`/`len` into one register (high 32 = len, low 32 = mqd) rather than dropping an argument the way `utimensat` drops its always-`AT_FDCWD` `fd` -- nothing here is redundant to drop. Real priority-ordered insertion (highest priority first, FIFO among ties), a real bounded block (`BlockReason::WaitingForMqSpace`) once `mq_maxmsg` is reached, real `EMSGSIZE` past `mq_msgsize`, and real `mq_notify` delivery on an empty-to-non-empty transition with no receiver already waiting. |
| `mq_timedreceive` (also backs `mq_receive`) | `SYS_MQ_TIMEDRECEIVE = 539` | `do_mq_timedreceive` | Same 4-register packing as `mq_timedsend`. Real blocking (`BlockReason::WaitingForMqData`) on an empty queue, real `EMSGSIZE` if the caller's buffer is smaller than the queue's own `mq_msgsize`, real priority readback via the (optional) `prio_ptr` out-argument. |
| `mq_notify` | `SYS_MQ_NOTIFY = 540` | `do_mq_notify` | Real `(mqd, sev_ptr)` wire format, no patch needed (`third_party/musl/src/mq/mq_notify.c` issues this raw syscall directly for every notify kind except `SIGEV_THREAD`, which never reaches the syscall boundary at all -- handled entirely in userspace over a real `AF_NETLINK` socket this port doesn't have). `SIGEV_SIGNAL` delivery reuses `process::do_kill` directly (no permission check to bypass, real disposition-respecting delivery) rather than a bespoke path. `SIGEV_THREAD`/`SIGEV_THREAD_ID` are real `EINVAL`. `si_value` is read but was never delivered at
the time this was first written -- `pending_signals` had nowhere to carry a payload; `mq_notify`
still doesn't attach it (`process::do_kill`'s own signature has no room for one), but the
underlying gap this row used to point at is now closed for `sigqueue` specifically -- see
"Implemented: `sigtimedwait`/`sigwaitinfo`/`sigqueue`" below. |
| `mq_getsetattr` (also backs `mq_getattr`/`mq_setattr`) | `SYS_MQ_GETSETATTR = 541` | `do_mq_getsetattr` | Real `(mqd, new, old)` wire format, no patch needed. Only `mq_flags`'s `O_NONBLOCK` bit is actually settable (`mq_maxmsg`/`mq_msgsize` are fixed at creation and silently ignored if passed in `new`, matching real Linux); `old` is always filled with the queue's real current state (`mq_curmsgs` included). |

Real timeout support falls out of a genuine new dual-wake shape: `BlockReason::WaitingForMqData`/
`WaitingForMqSpace` carry a deadline (`u64::MAX` for the plain, non-timed `mq_send`/`mq_receive`
wrapper's null-`at` case -- never realistically reached within this kernel's lifetime, so no
`Option` wrapper is needed), woken either by the matching send/receive draining the condition or by
`interrupts::timer_interrupt_handler`'s own deadline scan (extended alongside its existing
`Sleeping`/`real_timer_deadline`/`posix_timers` checks). `resolve_deadline` converts the `at`
`timespec` via `process::abstime_to_ticks` (now `pub(crate)`, reused from the per-process-timer
batch above), always against `CLOCK_REALTIME` -- real POSIX `mq_timedsend`/`mq_timedreceive`'s own
timeout is never configurable the way `timer_settime`'s `clockid` is.

Two hard caps this port enforces that real Linux doesn't (no privileged-override/`rlimit`-driven
ceiling exists here): `mq_maxmsg <= 256`, `mq_msgsize <= 65536` -- `EINVAL` past either. Each queue
is a plain heap-backed `Vec`, not block-allocator-bounded the way `oxfs` is; an unbounded
`maxmsg * msgsize` would be the same "unbounded heap growth reachable from userspace" bug
`fs/pipe.rs`'s own `PIPE_CAPACITY` was already added to close for pipes.

**Verified end-to-end**: `tests/mq_syscall_smoke.rs` + `userland/mq-syscall-smoke/` -- same real-
`SYSCALL` pattern. Eight parts: `O_CREAT | O_EXCL` open then a real `EEXIST`/`ENOENT`; priority-
ordered delivery (three sends at priorities `1, 5, 1` come back `5, 1, 1`); `EMSGSIZE` both
directions; filling to `mq_maxmsg` then a real `O_NONBLOCK` `EAGAIN`, confirmed by an
`mq_getsetattr` readback of `mq_curmsgs`/`mq_maxmsg`/`mq_msgsize`/`mq_flags`; a real
`TIMER_ABSTIME`-shaped deadline actually expiring `ETIMEDOUT`; a real block/wake pair across
`fork()` (the parent genuinely blocks in `mq_timedreceive` on an empty queue, forcing the freshly
forked child to run, which sends the message that wakes it); `mq_notify`/`SIGEV_SIGNAL` firing
exactly once on an empty-to-non-empty transition with nothing already blocked, then *not* firing
again on a second send (one-shot, nothing re-registered); and `mq_unlink` removing the name while
the already-open descriptor keeps working, torn down via a real `close()`. **Passes.**

### 5.9. Pre-reserved batch, fourth implementation: SysV message queues

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

Items 25-28 of the 28-syscall "pre-reserved ahead of implementation" batch above -- the real SysV
message-queue sub-batch -- now have real handlers too. Implemented out of the batch's own planned
order (ahead of items 17-24, the shm/sem sub-batches) since it's the more directly useful half of
SysV IPC and shares no code with the shm/sem work.

| POSIX interface(s) | Number | Handler | Notes |
|---|---|---|---|
| `msgget` | `SYS_MSGGET = 550` | `modules/posix_compat` -> `src/syscall/ffi.rs`'s `sys_msgget` -> `src/fs/sysv_msg.rs`'s `do_msgget` | Real `(key, flag)` wire format, no musl call-site patch needed. A fundamentally different lifecycle from `crate::fs::mqueue`'s POSIX message queues (see that module's own doc comment for the contrast): identified by an integer `key_t` via a separate `KEYS`/`QUEUES` namespace, `IPC_PRIVATE` always allocates a fresh unfindable-by-key queue, real `IPC_CREAT`/`IPC_EXCL` semantics. Returns a bare integer id, not a real fd -- no `crate::fs::fd` involvement at all (a SysV queue has no "open"/"close" step; it lives from `msgget` until an explicit `msgctl(IPC_RMID)`). |
| `msgsnd` | `SYS_MSGSND = 551` | `do_msgsnd` | Real `(q, m, len, flag)` wire format, already fits this ABI's 4 real register args, no patch needed. `m` points at a real `{long mtype; char mtext[len];}` buffer; `mtype < 1` is `EINVAL`. Real bounded blocking (`BlockReason::WaitingForSysvMsgSend`) once the queue's own `qbytes` cap is reached, `IPC_NOWAIT` `EAGAIN` otherwise; `len` alone exceeding `qbytes` is `EINVAL` (can never fit regardless of occupancy). Real `ipc_perm` rwx-style permission check (`check_access`), same shape a file's own mode bits use. |
| `msgrcv` | `SYS_MSGRCV = 552` | `do_msgrcv` | Real Linux needs 5 syscall args (`q, m, len, type, flag`); this ABI only carries 4. `third_party/musl/src/ipc/msgrcv.c` is patched (`oxidebsd` branch) to pack `q`/`flag` into one register (high 32 = flag, low 32 = q), same shape `mq_timedsend`/`mq_timedreceive`'s own patches already established. Real `msgtyp` selection matching `msgrcv(2)`'s exact documented semantics -- `0` = oldest message any type, `> 0` = oldest message of that exact type (or, with `MSG_EXCEPT`, oldest message of any *other* type), `< 0` = among messages with `mtype <= |msgtyp|`, the oldest message of the *smallest* such type (`find_matching_index`). Real `E2BIG`/`MSG_NOERROR`: a message peeked (not yet removed) that's too big for the caller's buffer without `MSG_NOERROR` returns `E2BIG` **without consuming the message** -- found live during this session's own testing, not preemptively: an earlier draft removed the message before checking size, silently destroying it on a failed receive. Real bounded blocking (`BlockReason::WaitingForSysvMsgRecv`), `IPC_NOWAIT` `ENOMSG` otherwise. |
| `msgctl` | `SYS_MSGCTL = 553`, last of the batch | `do_msgctl` | Real `(q, cmd, buf)` wire format, no patch needed. `cmd` always arrives with real glibc/musl's `IPC_64` bit (`0x100`) OR'd in (`third_party/musl/src/ipc/msgctl.c`'s own `IPC_CMD()` macro) -- masked off before matching. `IPC_STAT` (real permission-checked readback, including live `cbytes`/`qnum` computed fresh), `IPC_SET` (owner/creator/root only -- a stricter check than plain write permission, real SysV distinction from `msgsnd`/`msgrcv`'s rwx check), `IPC_RMID` (owner/creator/root only; removes the queue and wakes every blocked sender/receiver, which each re-check `QUEUES` from scratch and find the id gone -- real `EIDRM`, no distinct wake signal needed). `MSG_STAT`/`MSG_STAT_ANY`/`IPC_INFO`/`MSG_INFO` (real `/proc`-introspection-shaped commands) are honest `EINVAL` -- no live caller, not silently no-op'd. |

**Real, not honest-zero, timestamps**: `stime`/`rtime`/`ctime` are real `crate::cpu::rtc::
unix_epoch_seconds()` reads at creation and every successful `msgsnd`/`msgrcv`/`msgctl(IPC_SET)` --
cheap (the same CMOS read `CLOCK_REALTIME` already uses) and meaningfully more useful than a
placeholder for a struct whose whole job is reporting these three timestamps, a deliberate
departure from the "honest zero" tier `RawRusage`/`RawTms`/`RawSysinfo` use for concepts this
kernel genuinely doesn't track at all.

**No timeout concept, unlike the POSIX `mq_*` batch**: real `msgsnd`/`msgrcv` only ever block
indefinitely or (`IPC_NOWAIT`) fail immediately -- no `semtimedop`-style deadline argument exists
to plumb through, so no timer-IRQ deadline scan was needed here the way the POSIX-timer/`mq_*`
batches needed one.

`RawIpcPerm`/`RawMsqidDs` (48/120 bytes) were verified via a direct `musl-gcc`/`sizeof`/`offsetof`
probe against musl's real `struct ipc_perm`/`struct msqid_ds` on this arch, same rigor
`RawSysinfo` already established, rather than assumed from Rust `repr(C)` layout rules alone.

**Verified end-to-end**: `tests/sysv_msg_syscall_smoke.rs` + `userland/sysv-msg-syscall-smoke/` --
same real-`SYSCALL` pattern. Seven parts: `IPC_CREAT | IPC_EXCL` then a real `EEXIST`/`ENOENT`; a
plain send/receive round trip preserving `mtype`; real `msgtyp` selection (positive exact match out
of FIFO order, negative smallest-type-within-bound, zero FIFO-any, plus `MSG_EXCEPT`); real
`E2BIG` that doesn't consume the message, then a `MSG_NOERROR` receive that does (truncated);
`msgctl(IPC_SET)` shrinking `qbytes` then a real `EINVAL`/`IPC_NOWAIT` `EAGAIN`/`IPC_NOWAIT`
`ENOMSG`; a real block/wake pair across `fork()` (the parent genuinely blocks in `msgrcv` on an
empty queue, forcing the freshly forked child to run, which sends the message that wakes it); and
`msgctl(IPC_STAT)` reporting real state followed by `IPC_RMID` and confirmation that
`msgsnd`/`msgrcv`/`msgctl` against the removed `msqid` are all real `EIDRM`. **Passes.**

This brings the batch to 20 of 28 items done (1-16, 25-28) -- only the shm/sem sub-batches (items
17-24, `542-549`) remain, the biggest and most novel remaining subsystem with no live caller today.

### 5.10. Pre-reserved batch, fifth implementation: SysV semaphores

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

Items 21-24 of the 28-syscall "pre-reserved ahead of implementation" batch above -- the real SysV
semaphore sub-batch -- now have real handlers too, closing every sub-batch except SysV shared
memory (items 17-20, `542-545` -- see "Pre-reserved batch: sixth implementation" below, which
closes that one too).

| POSIX interface(s) | Number | Handler | Notes |
|---|---|---|---|
| `semget` | `SYS_SEMGET = 546` | `modules/posix_compat` -> `src/syscall/ffi.rs`'s `sys_semget` -> `src/fs/sysv_sem.rs`'s `do_semget` | Real `(key, nsems, flag)` wire format, no musl call-site patch needed -- confirmed directly against every one of `third_party/musl/src/ipc/sem{get,op,ctl,timedop}.c`'s own call sites that no `SYS_ipc` multiplexer is ever defined on this arch, so this whole sub-batch needed **zero** musl-side patches (a first, compared to `msgrcv`/`mq_timedsend`/`mq_timedreceive` each needing one). Same "`key_t` -> id via a separate `KEYS`/`SETS` namespace, `IPC_PRIVATE` always fresh, real `IPC_CREAT`/`IPC_EXCL` semantics, bare integer id with no `crate::fs::fd` involvement" shape `msgget` already established -- real `nsems == 0` matches any existing set's size on a lookup, a nonzero mismatch is `EINVAL`. `src/fs/sysv_ipc.rs` is a new shared module factoring out `RawIpcPerm`/the rwx permission-check helpers `sysv_msg`'s own `check_access`/`is_owner_or_creator` used to duplicate, now that a second SysV IPC subsystem exists. |
| `semop` | `SYS_SEMOP = 547` | `do_semop` -> shared `do_semop_impl` | Real `(id, sops, nsops)` wire format. **A whole `sembuf` array applies atomically**: simulated against a scratch copy of every touched semaphore value first -- if every op can proceed, all commit at once; if any op would block, nothing is applied and the caller either fails (`IPC_NOWAIT` on that specific op) or blocks on it, retrying the *entire* array from scratch once woken (same "block, `schedule()`, loop and re-check the real condition" pattern every blocking primitive here already follows). A negative `sem_op` decrements (blocking below zero); positive always succeeds immediately; zero blocks until the value is exactly zero. `sem_num` outside the set's real `nsems` is `EFBIG` (real SysV's own, not `EINVAL`). |
| `semctl` | `SYS_SEMCTL = 548` | `do_semctl` | Real `(id, num, cmd, arg)` wire format. `cmd` always arrives with real glibc/musl's `IPC_64` bit OR'd in, masked off before matching, same `IPC_CMD()` convention `msgctl` already established. `arg`'s own interpretation is polymorphic by `cmd` (matching real Linux): the raw value itself for `SETVAL`, a real pointer for everything else. Implements `IPC_STAT`/`IPC_SET`/`IPC_RMID` (owner/creator/root-gated, same distinction from `semop`'s plain rwx check `msgctl` already established) plus `GETVAL`/`SETVAL`/`GETALL`/`SETALL` (range-checked into `[0, SEMVMX] = [0, 32767]`, real `ERANGE` past it) and `GETPID`/`GETNCNT`/`GETZCNT`. `SEM_STAT`/`SEM_STAT_ANY`/`IPC_INFO`/`SEM_INFO` are honest `EINVAL`, no live caller, matching `msgctl`'s own tier for its analogous commands. |
| `semtimedop` | `SYS_SEMTIMEDOP = 549`, last of the batch | `do_semtimedop` -> shared `do_semop_impl` | Real `(id, sops, nsops, timeout)` wire format. **The one real wire-format wrinkle in this sub-batch, though not one needing a musl patch**: unlike `mq_timedsend`/`mq_timedreceive`'s own `at` (always absolute `CLOCK_REALTIME`), real `semtimedop(2)`'s `timeout` is a plain *relative* `struct timespec` -- `resolve_relative_deadline` deliberately mirrors `do_nanosleep`'s own whole-second/sub-second tick-rounding conversion, not `crate::process::abstime_to_ticks` (`crate::fs::mqueue`'s absolute-clock helper). |

**Real `GETNCNT`/`GETZCNT`, not fabricated**: a new `BlockReason::WaitingForSemOp(semid, semnum,
waiting_for_zero, deadline)` variant carries exactly the `(semnum, waiting_for_zero)` pair for
whichever single op in a blocked multi-op array actually couldn't proceed (real POSIX allows
picking any representative op for a wait queue when a multi-op array blocks -- this always picks
the first one in program order, both for retry ordering and as this counting payload).
`semctl(GETNCNT)`/`semctl(GETZCNT)` scan `process::table()` for an exact match, the same "IRQ/
syscall handler reaches directly into `process::table()`" shape every other `BlockReason` here
already uses for its own wake/introspection -- not an honest-zero placeholder the way `RawRusage`/
`RawSysinfo`'s untracked fields are, since the real data already exists on the block state itself.

**Real `SEM_UNDO` support** (`Process::sysv_sem_undo`, a new per-process field): every `sembuf`
with `SEM_UNDO` set accumulates a signed adjustment, applied (added back, clamped into
`[0, SEMVMX]`) automatically on process termination via a new `crate::fs::sysv_sem::
apply_undo_for_exit`, called from `process::lifecycle::terminate_process` *before* that function's
own `PROCESS_TABLE` lock is taken (avoids a real deadlock -- `apply_undo_for_exit` takes that same
lock itself, then a second, separate lock to wake blocked waiters). Real POSIX semantics: not
inherited by `fork` (a child starts with its own empty undo list, matching real Linux's `semadj`
being fork-local), preserved across `execve` (untouched, since `do_execve` mutates the live
`Process` in place and never assigns this field). **Known, accepted simplification**: real Linux
also adjusts *other* processes' outstanding undo entries when a value-changing call on the same
semaphore invalidates them -- not tracked here (would need a global scan of every process's own
undo list on every value-changing call); no live caller to exercise the difference, and the one
case that matters most (`IPC_RMID`) is already handled correctly since a removed `semid` just
makes `apply_undo_for_exit` silently skip it.

**Real timer-IRQ deadline support for `semtimedop`**: `interrupts::timer_interrupt_handler` gained
a `WaitingForSemOp` scan alongside its existing `WaitingForMqData`/`WaitingForMqSpace` one -- same
dual-wake shape (woken either by a matching `semop`/`semctl`/`IPC_RMID`, or by the deadline
passing), same `u64::MAX` "no timeout" sentinel convention for the plain `semop` wrapper's case.

`RawSembuf`/`RawSemidDs` (6/88 bytes) were verified via a direct `musl-gcc`/`sizeof`/`offsetof`
probe against musl's real `struct sembuf`/`struct semid_ds` on this arch, same rigor
`RawIpcPerm`/`RawMsqidDs` already established.

**Two real bugs found live by this sub-batch's own smoke test, both fixed, neither theoretical**:
1. **A precision bug in the wake mechanism itself**, found by the `GETZCNT` part of the fork
   scenario below: an earlier draft's `wake_blocked_semop(semid)` woke *every* process blocked on
   `semid`, regardless of which specific `semnum` it was actually waiting on. Harmless for
   `semop`'s own correctness (a spuriously woken process just re-checks its whole op array from
   scratch and re-blocks on its next turn -- the same discipline every blocking primitive here
   already follows), but it broke `semctl(GETNCNT)`/`semctl(GETZCNT)`'s own "real, not fabricated"
   count: a process genuinely still blocked on an *untouched* semaphore would transiently read back
   as `Ready` (merely not yet rescheduled to re-block) the instant some *other* semaphore in the
   same set changed -- reproduced deterministically by the smoke test's own two-semaphore fork
   scenario (waking a parent blocked on `sem0` also spuriously flipped a child genuinely blocked on
   `sem1` to `Ready`, undercounting `GETZCNT(sem1)`). Fixed: `wake_blocked_semop` now takes a
   `touched: &[u16]` slice (the specific semnums the just-committed operation actually changed) and
   only wakes a match on both `semid` *and* `semnum` -- real semantics, not just a precision nicety
   (a process waiting on one semaphore's value has no reason to wake when a different semaphore in
   the same set changes). `semctl(IPC_RMID)` is the one caller that still wants the old broad
   behavior (the semid itself is gone, so every blocked process needs to wake and discover a real
   `EIDRM` regardless of which semnum it cared about) -- kept as a separate `wake_blocked_semop_all`.
2. **`do_semop_impl`'s own commit path wrote every semaphore's `sempid` unconditionally**, not just
   the ones the just-applied op array actually named -- harmless for `val` (an untouched entry's
   scratch copy is identical to its live value) but a real misattribution of `semctl(GETPID)`'s own
   backing store: any semaphore in the set, however unrelated, would report the last caller of *any*
   `semop` against the set, not the last caller that actually touched *that* semaphore. Fixed:
   the commit loop now only writes the semaphores named in `ops`.

**Verified end-to-end**: `tests/sysv_sem_syscall_smoke.rs` + `userland/sysv-sem-syscall-smoke/` --
same real-`SYSCALL` pattern. Seven parts: `semget`'s `IPC_CREAT`/`IPC_EXCL`/`ENOENT`/nsems-mismatch
`EINVAL`; `SETVAL`/`GETVAL`/`SETALL`/`GETALL` round trips plus `EFBIG` past the real `nsems`; a
real atomic two-op `semop` (confirmed both ops landed together) plus a real `GETPID` readback;
`IPC_NOWAIT` `EAGAIN`; a real `semtimedop` timeout that genuinely expires with `ETIMEDOUT`; a single
orchestrated `fork()` round exercising a real block/wake pair (`GETNCNT` observed against a
genuinely blocked parent), a second real block/wake pair on a *different* semaphore in the same set
(`GETZCNT` observed against a genuinely blocked child -- the scenario that caught bug 1 above), and
real `SEM_UNDO` (a child's own decrement, auto-reversed the instant it exits without ever explicitly
undoing it); and `semctl(IPC_STAT)`/`IPC_SET` reporting/changing real state, followed by `IPC_RMID`
and confirmation that `semop`/`semctl`/`semtimedop` against the removed `semid` are all real
`EIDRM`. **Passes.**

This brought the batch to 24 of 28 items done (1-16, 21-28) at the time -- only the shm sub-batch
(items 17-20, `542-545`) remained; see immediately below for its own implementation.

### 5.11. Pre-reserved batch, sixth implementation: SysV shared memory

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

Items 17-20 of the 28-syscall "pre-reserved ahead of implementation" batch above -- the real SysV
shared-memory sub-batch -- now have real handlers too, closing the whole 28-syscall batch out (all
28 of 28 items done).

| POSIX interface(s) | Number | Handler | Notes |
|---|---|---|---|
| `shmget` | `SYS_SHMGET = 542` | `modules/posix_compat` -> `src/syscall/ffi.rs`'s `sys_shmget` -> `src/fs/sysv_shm.rs`'s `do_shmget` | Real `(key, size, shmflg)` wire format, no musl call-site patch needed -- same "no `SYS_ipc` multiplexer on this arch" finding `semget`'s own doc comment already made, confirmed again directly against `third_party/musl/src/ipc/shmget.c`. Same `key_t` -> id via `KEYS`/`SEGMENTS`, `IPC_PRIVATE` always fresh, real `IPC_CREAT`/`IPC_EXCL` semantics shape `msgget`/`semget` already established. **The one sub-batch that needs real memory-management plumbing, not just a `BTreeMap` namespace**: eagerly allocates a fixed `Vec<PhysFrame>` up front (same "hand out forward, never reclaim" policy `crate::process::mm::do_mmap` already establishes), zero-filled once (matching anonymous `mmap`'s own guarantee). An existing-key lookup accepts any `size` up to the real segment's own size (`EINVAL` past it) -- real `shmget(2)`'s own documented behavior, distinct from `semget`'s "must match exactly" rule since a segment's size can never change after creation either way. |
| `shmat` | `SYS_SHMAT = 543` | `do_shmat` | Real `(id, shmaddr, shmflg)` wire format. `shmaddr` is always ignored (same simplification `do_mmap`'s own `addr_hint` already gets) -- real callers pass `NULL` for exactly this case anyway. **The actual proof of real shared memory**: every `shmat` against the same `id`, by any process, maps that segment's own already-allocated frames (not fresh ones) into the caller's page table at a freshly bump-allocated VA (`SHM_REGION_BASE = 0x_4000_0000_0000`, a window distinct from `crate::process::mm::MMAP_REGION_BASE`) -- a write through one process's mapping is genuinely visible through another's. Returns the real mapped address directly (this ABI's carry-flag success path already puts a handler's return value in `RAX`, matching real `void *shmat(...)`'s own calling convention with no special-casing needed). `SHM_RDONLY` omits `PageTableFlags::WRITABLE` on the caller's own mapping; `SHM_RND`/`SHM_REMAP`/`SHM_EXEC` are accepted but meaningless here (no caller-chosen address to round/replace; every user page is already executable, no `NO_EXECUTE`/`EFER.NXE` anywhere yet). An invalid `id` is `EINVAL` (real `shmat(2)`'s own documented errno for this case). |
| `shmctl` | `SYS_SHMCTL = 544` | `do_shmctl` | Real `(id, cmd, buf)` wire format. `cmd` always arrives with real glibc/musl's `IPC_64` bit OR'd in, masked off before matching, same `IPC_CMD()` convention `semctl`/`msgctl` already established. Implements `IPC_STAT`/`IPC_SET`/`IPC_RMID` (owner/creator/root-gated); `SHM_LOCK`/`SHM_UNLOCK`/`SHM_STAT`/`SHM_STAT_ANY`/`SHM_INFO` are honest `EINVAL`, no live caller, matching `semctl`/`msgctl`'s own tier for their analogous unimplemented commands. **`IPC_RMID` on a still-attached segment defers real removal**: the key is unlinked from `KEYS` immediately (a fresh `shmget` on that key can never find this segment again) but `SEGMENTS` itself, and the segment's real backing frames, survive until the last attached process detaches -- real SysV lifecycle, same shape `semctl`/`msgctl`'s own `IPC_RMID` already established for their respective namespaces. **A lookup miss is `EIDRM`, not `EINVAL`** -- deliberately different from `shmat`'s own choice for the identical underlying situation, since real `shmat(2)`'s man page documents only `EINVAL` while real `shmctl(2)`'s documents both; this port doesn't distinguish "never valid" from "since removed" (a plain `BTreeMap` miss either way), so `shmctl` follows `semctl`/`msgctl`'s own established convention instead. |
| `shmdt` | `SYS_SHMDT = 545`, last of the batch | `do_shmdt` | Real single-argument `(shmaddr)` wire format. Finds the calling process's own matching `(addr, shmid)` entry in a new `Process::sysv_shm_attach` list (an unmatched `shmaddr` is a real `EINVAL`), unmaps the real page-table range via `Mapper::unmap` (the one SysV IPC syscall in this whole batch that actually touches page tables on the way out, not just kernel-resident bookkeeping), then decrements the segment's `nattch` and finalizes a deferred `IPC_RMID` removal if this was the last attachment. |

**Known, accepted simplification: not inherited across `fork`.** This kernel's own `fork` is a full
eager address-space copy, not real copy-on-write (see CLAUDE.md's process section) --
`AddressSpace::fork` duplicates the *content* of every user-accessible page into a brand-new
physical frame, including whatever's mapped at a parent's own shm attachment addresses at fork
time. A forked child therefore ends up with its own private snapshot at the same VA regardless of
what this module does -- no amount of attachment-list inheritance would make the child's copy
actually alias the segment's real frames, since the underlying page-table entries it inherits
already point at freshly-copied ones, not the segment's own. Given that pre-existing architectural
fact, `Process::sysv_shm_attach` simply starts empty in a forked child (same "starts fresh across
fork" precedent `Process::sysv_sem_undo` already established) rather than pretending to support
real Linux's "child inherits attached segments" behavior. The cross-process sharing case this
module *does* support fully, proven end-to-end by this section's own smoke test below, is the far
more common real-world one anyway: unrelated (or related) processes independently `shmget`ing the
same `key` and `shmat`ing it themselves.

**Real implicit detach on both process exit and `execve`**: `crate::fs::sysv_shm::
detach_all_for_exit(pid)` is called from two places -- `process::lifecycle::terminate_process`
(same "before `PROCESS_TABLE` is locked" placement `crate::fs::sysv_sem::apply_undo_for_exit`
already established, and for the identical reason), and `do_execve`, right after the new
`AddressSpace` is committed (the old one, and every prior `shmat`'s own mapping into it, is what
just became unreachable -- a real implicit detach of everything, matching real Linux's own
`execve(2)` destroying the old address space). Neither call site unmaps any page-table entries
itself (unlike `do_shmdt`) -- a terminating or `execve`'d process's *old* address space is never
freed anywhere in this kernel regardless, so there's nothing that needs unmapping before it's gone
either way; only the `nattch`/possible-removal bookkeeping needs to run.

`RawShmidDs` (112 bytes) was verified via a direct `musl-gcc`/`sizeof`/`offsetof` probe against
this port's own patched sysroot (`toolchain/x86_64-unknown-oxidebsd`), same rigor `RawIpcPerm`/`RawMsqidDs`/
`RawSemidDs` already established.

**Verified end-to-end**: `tests/sysv_shm_syscall_smoke.rs` + `userland/sysv-shm-syscall-smoke/` --
same real-`SYSCALL` pattern. Six parts: `shmget`'s `IPC_CREAT`/`IPC_EXCL`/`ENOENT`/oversized-`size`
`EINVAL`; a real `shmat` mapping with a real pattern written through it plus `shmctl(IPC_STAT)`
reporting real `key`/`mode`/`segsz`/`nattch`/`cpid` (and a safe, read-only exercise of the
`SHM_RDONLY` flag path); **the core proof of real physical sharing** -- a `fork()`, then the child
performs its own *independent* `shmat` against the same `id` (not an inherited mapping, per the
simplification above) and reads back the parent's exact pattern, then writes its own pattern back
and `shmdt`s before exiting, after which the parent confirms *it* now sees the child's pattern
through its own original mapping (real bidirectional sharing, not just shared initial content);
`nattch` correctly back to `1` after the child's own `shmdt` and real exit (proving neither path
double-decrements); a real `IPC_RMID`-while-still-attached lifecycle on a second key (a fresh
`shmget` on the same key immediately gets a genuinely different id even though the old segment
survives, followed by real `EIDRM` once the last attachment actually detaches); and a final
`shmdt` to `nattch == 0` triggering an *immediate* `IPC_RMID` removal, followed by real `ENOENT`/
`EINVAL`/`EIDRM` against the fully-removed segment and an already-detached address. **Passes.**

This brings the batch to 28 of 28 items done -- the whole 28-syscall pre-reserved batch is
complete.

### 5.12. The pre-reserved batch in summary: Real getrandom/sysinfo/sigaltstack/pause/sigsuspend/POSIX timers/POSIX message queues/SysV IPC (`sys/modules/posix_compat`, `sys/modules/signal`, `sys/modules/clock`, `sys/fs/{mqueue,sysv_msg,sysv_sem,sysv_shm,sysv_ipc}.rs`)

*(from CLAUDE.md, 2026-09-29)*

A 28-syscall batch (`526`-`553`) pre-reserved with permanent invented numbers ahead of having real
handlers (see `OxideBSD-doc/MISSING_POSIX_SYSCALLS.md`'s "Pre-reserved" section for why). All 28 now have
real handlers, landed roughly in POSIX/SysV order except SysV IPC landed message queues before
semaphores before shared memory (each needed progressively more novel machinery).

- **`getrandom`** (`526`): thin plumbing to `sys/random.rs`'s existing generator. Only reachable
  via `getentropy()` in this port's roster, which caps `len` at 256 and loops — this handler
  always fills the whole request in one shot so that loop exits after one iteration.
- **`sysinfo`** (`527`): `RawSysinfo` (368 bytes, confirmed via a direct C `offsetof`/`sizeof`
  probe). Real `uptime`/`totalram`/`procs`; `freeram == totalram` (no dealloc tracking); rest
  honest zero.
- **`sigaltstack`** (`528`): bookkeeping via `Process::altstack`, real `SA_ONSTACK` delivery (see
  Signal handling module above).
- **`pause`** (`529`): first item needing a genuine new primitive — `BlockReason::
  WaitingForSignal` + `wake_if_paused`, checked-before-block/looped-after-wake (avoids lost
  wakeup/stale-block, the discipline every blocking primitive here follows).
- **`sigsuspend`** (`530`): reuses `pause`'s primitive plus a temporary `blocked_signals` swap.
- **POSIX timers** `timer_create`/`_settime`/`_gettime`/`_getoverrun`/`_delete` (`531`-`535`,
  `sys/process/timers.rs`): `Process::posix_timers`, up to 8, relative/`TIMER_ABSTIME` arming
  against `CLOCK_MONOTONIC`/`CLOCK_REALTIME`, real overrun accounting (HPET-precision when
  present, see "Real-time clock" above), delivered from the timer IRQ handler. Not inherited by
  fork; disarmed by execve. Also accepts `CLOCK_PROCESS_CPUTIME_ID`/`CLOCK_THREAD_CPUTIME_ID`
  (real musl unconditionally claims `_SC_CPUTIME` support; rejecting these was a real bug, fixed).
- **POSIX message queues** `mq_open`/`_unlink`/`_timedsend`/`_timedreceive`/`_notify`/`_getsetattr`
  (`536`-`541`, `sys/fs/mqueue.rs`): a separate name→queue namespace, real priority-ordered
  delivery, real bounded blocking send/receive with real signal-interrupt support, real
  `mq_notify`/`SIGEV_SIGNAL` via `do_kill` directly. `mq_close` isn't its own syscall — an mqd
  rides the ordinary fd registry. `mq_timedsend`/`_timedreceive` needed a musl call-site patch (5
  real args packed into one register: high 32 bits = len, low 32 = mqd).
- **SysV message queues** `msgget`/`msgsnd`/`msgrcv`/`msgctl` (`550`-`553`,
  `sys/fs/sysv_msg.rs`): integer-`key_t`-addressed, fd-less namespace (a queue lives from `msgget`
  until explicit `IPC_RMID`). Real `ipc_perm` checks, real `msgtyp` selection semantics, real
  timestamps. A real bug found in testing: an early draft removed a matched message *before*
  checking buffer size, destroying it on `E2BIG` — fixed to peek length first (real Linux
  "too-big message stays queued" semantics).
- **SysV semaphores** `semget`/`semop`/`semctl`/`semtimedop` (`546`-`549`,
  `sys/fs/sysv_sem.rs`): same `key_t`→id namespace, factored through a shared `sysv_ipc.rs`.
  `semop`/`semtimedop` apply a whole `sembuf` array atomically (simulate-then-commit-or-nothing).
  Real `SEM_UNDO` via `Process::sysv_sem_undo`, applied on process termination. A new
  `BlockReason::WaitingForSemOp` backs real `GETNCNT`/`GETZCNT`.
- **SysV shared memory** `shmget`/`shmat`/`shmctl`/`shmdt` (`542`-`545`,
  `sys/fs/sysv_shm.rs`), the one sub-batch needing real memory-management plumbing: `shmget`
  eagerly allocates a fixed `Vec<PhysFrame>`, zero-filled once. **`shmat` is the real proof of
  shared memory** — every attach against the same id maps those exact same frames into the
  caller's own page table (`SHM_REGION_BASE = 0x_4000_0000_0000`). `shmdt` is the one syscall in
  this batch that actually unmaps on the way out. Real `IPC_RMID`-while-attached lifecycle. **Not
  inherited across `fork`** (fork here is eager-copy, never COW) — starts empty in a child, same
  precedent `sysv_sem_undo` established.

Closes the whole 28-item batch — see `OxideBSD-doc/MISSING_POSIX_SYSCALLS.md`'s own per-item write-up for
detail this section only summarizes.

### 5.13. POSIX syscall coverage tables, as last revised

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

#### Missing, live caller confirmed

Interfaces musl's own C source calls directly (grepped, not inferred) that have no registered
OxideBSD handler.

| POSIX interface(s) | Backing syscall | Live caller | Suggested number | Notes |
|---|---|---|---|---|
| `sigtimedwait`, `sigwaitinfo` | `rt_sigtimedwait(2)` | `src/signal/sigtimedwait.c:19,22` | `495`, now implemented | See "Implemented: `sigtimedwait`/`sigwaitinfo`/`sigqueue`" below. |
| `sigqueue` | `rt_sigqueueinfo(2)` | `src/signal/sigqueue.c:19` | `496`, now implemented | See "Implemented: `sigtimedwait`/`sigwaitinfo`/`sigqueue`" below. |

#### Missing, POSIX-mandated, no live caller yet in ported userland

Real POSIX interfaces with no confirmed call site anywhere in `third_party/musl/src` reachable from
the current roster (BusyBox, TinyCC, hush). Worth tracking, not worth building ahead of a real
need — same "don't build for a hypothetical caller" discipline this codebase already applies
elsewhere.

| POSIX interface(s) | Backing concept | Notes |
|---|---|---|
| `mq_open`, `mq_close`, `mq_unlink`, `mq_send`, `mq_receive`, `mq_timedsend`, `mq_timedreceive`, `mq_notify`, `mq_getattr`, `mq_setattr` | POSIX message queues | `536-541`, all now implemented — see "Pre-reserved batch: third implementation" above. No seeded applet uses these yet (no live caller in the current roster), but a real handler exists for any future one. |
| `sem_init`, `sem_destroy`, `sem_wait`, `sem_trywait`, `sem_timedwait`, `sem_post`, `sem_getvalue` (unnamed semaphores) | futex-backed | **No longer blocked — real `futex(2)` `FUTEX_WAIT`/`FUTEX_WAKE` now exist** (`process::do_futex`, `src/process/limits.rs`, real threading phase 3 — see "Real threading" below), so these already work today for the single-process case every unnamed semaphore in this port's roster actually exercises (`sem_init`, not `sem_open`). Real thread creation itself (`clone(2)`/`pthread_create`) has also landed since (see "Real threading" below), so a `sem_init(&s, 0, ...)` (`pshared == 0`) shared *between threads* of one process should also already work — not separately verified by a dedicated test yet. No distinct syscall of its own to reserve a number for — not part of the pre-reservation batch below. |
| `sem_open`, `sem_close`, `sem_unlink` (named semaphores) | `/dev/shm`-backed `open`+`mmap` | No live caller; would also want the `shm_open` path below first, plus real cross-*process* `FUTEX_WAKE` (today's `do_futex` is deliberately scoped to the waker's own `tgid` — real threads sharing a `tgid` now wake each other correctly, but two unrelated processes still wouldn't). Not a distinct syscall either — not part of the pre-reservation batch below. |
| `shm_open`, `shm_unlink` | POSIX shared memory | No live caller in roster. Implemented via plain `open`/`mkdir` on real Linux, not a distinct syscall — not part of the pre-reservation batch below. |
| `shmget`, `shmat`, `shmctl`, `shmdt`, `msgget`, `msgctl`, `msgrcv`, `msgsnd`, `semget`, `semctl`, `semop`, `semtimedop` | SysV IPC | `542-553`, all now implemented — see "Pre-reserved batch: fourth/fifth/sixth implementation" above. `ipcrm`/`ipcs` were already cut from the BusyBox roster before v0.1 (this didn't exist yet at the time) and haven't been added back — see CLAUDE.md's own gap-analysis table; a real handler now exists for any future BusyBox roster change that wants them back. |
| `aio_read`, `aio_write`, `aio_fsync`, `aio_error`, `aio_return`, `aio_cancel`, `aio_suspend`, `lio_listio` | POSIX async I/O | Not a missing syscall — musl implements these via a userspace thread pool (`src/aio/aio.c`) over real `clone(2)`/futexes. **Now confirmed working**: real threading landed (see "Real threading" below), and a dedicated pass fixed 14/18 of the corpus's AIO conformance FAILs; the remainder are a real oxfs file-size-cap gap (`aio_suspend`) and an inherent test-timing race (`aio_cancel`), not kernel gaps. Not part of the pre-reservation batch below. |
| `timer_create`, `timer_settime`, `timer_gettime`, `timer_getoverrun`, `timer_delete` | POSIX per-process timers | `531-535`, all now implemented — see "Pre-reserved batch: second implementation" above. Distinct from `setitimer`/`getitimer` (`ITIMER_REAL` only), which were already implemented separately. Still no live caller in the current BusyBox/TinyCC/hush roster, but a real handler exists for any future one and the Open POSIX Test Suite pilot exercises them directly. |
| `select`, `pselect` | fd readiness | `poll(2)` already exists and covers every confirmed live caller (musl's DNS resolver). `src/select/poll.c` doesn't route through `pselect6` on this build (confirmed: `SYS_poll` is used directly). The only BusyBox callers of raw `select` (`inetd`, `telnetd`, `dhcprelay`, `fdisk`, ...) are already cut from the roster. Not part of the pre-reservation batch below — genuinely not needed. |
| `posix_spawn`, `posix_spawnp` + the `posix_spawnattr_*`/`posix_spawn_file_actions_*` family | process creation | musl implements `posix_spawn` entirely in userspace on top of `vfork`/`execve` (`src/process/posix_spawn.c`) — both of those already exist here (see CLAUDE.md's `vfork.s` note). Not a missing syscall at all, just unexercised library code. |
| `fexecve` | `execveat`-style exec by fd | musl's `fexecve` falls back to `/proc/self/fd/<n>` + `execve` when `execveat` is unavailable — would work today given real per-fd `/proc` entries exist, modulo the "not a real symlink" limitation already documented in `BUSYBOX_APPLETS.md`'s `NEEDS_PROC` section. |

#### Structurally inapplicable to this kernel's current architecture

Not "not yet built" — genuinely doesn't fit until a prerequisite this codebase has explicitly
deferred exists.

| POSIX interface(s) | Why inapplicable today |
|---|---|
| `sched_yield`, `sched_rr_get_interval` | Covered — `sched_setscheduler`/`sched_setparam`/`sched_getscheduler`/`sched_getparam`/`sched_get_priority_max`/`_min` all exist (`modules/posix_compat`), stored/echoed honestly with no real scheduling effect, matching `nice`'s own honesty tier. `sched_yield` itself is a genuine yield now that real preemption exists (see CLAUDE.md's "Real preemptive scheduling"), not just a no-op. |
| `munlock`, `posix_madvise` | This kernel never pages anything out (no swap, no reclaim of any kind anywhere — a documented, deliberate gap per CLAUDE.md's memory-management section) — "lock this page so it can't be swapped" is a no-op by construction, not a missing capability. |
| `mlockall`, `mlock`, `munlockall` | **No longer a pure no-op** — real `mlockall(MCL_FUTURE)`/`RLIMIT_MEMLOCK` enforcement exists (`ThreadGroupShared`'s `mlockall_future`/`locked_bytes`, see CLAUDE.md's mmap-fixes section), closing several `mlockall` conformance files. Kept a table row of its own since it's no longer accurate to describe alongside the genuine no-ops above. |
| `msync` | **No longer inapplicable — real `mmap` here is not always anonymous/private any more** (see CLAUDE.md's "Real /tmp, /dev/shm, and real fd-backed MAP_SHARED mmap" and "Real ring-3 fault-to-signal delivery, and two mmap fixes" sections), so `msync`'s real job (flushing a live `MAP_SHARED` mapping back to its file on demand) is now a genuine, narrow gap, not a structural non-issue: writeback today only happens implicitly, at `munmap`/process exit (`src/process/mm.rs`'s `writeback_region`), never on explicit request. A real caller wanting `msync(2)` itself hasn't shown up yet in this port's roster. |
| `fattach`, `fdetach`, `isastream`, `putmsg`, `getmsg`, `putpmsg`, `getpmsg` | STREAMS — an XSI option almost no modern Unix (including real Linux) implements at all; not a gap specific to this kernel. |
| `posix_trace_*` (the whole family) | POSIX tracing — an optional XSI extension real Linux/glibc/musl don't implement either; nothing to port against. |
| `dlopen`, `dlsym`, `dlclose`, `dlerror` | musl's real implementation is pure userspace logic over `mmap`/`mprotect`/relocation processing once a `.so` is already mapped — not a syscall gap itself, but blocked on `mmap`/`mprotect` actually enforcing real placement/protection (currently both are permissive no-ops/bump-allocators, per CLAUDE.md's PT_INTERP milestone notes) before a second real shared object could be loaded correctly. Tracked as the actual blocker under "milestone 2" in this conversation's prior research, not re-litigated here. |
| `getlogin`, `getlogin_r`, `ttyname`, `ttyname_r`, `tcgetsid` | Real Linux backs these via `/proc/self/fd/N` symlink resolution + `ioctl(TIOCGSID)`-adjacent lookups against `utmp`, not a single dedicated syscall — `tcgetsid` specifically has no distinct number on this ABI at all (would fold into the existing `TIOCGPGRP`-style `SYS_IOCTL` gate, not a new registration). No live caller in the current roster. |
| `pathconf`, `fpathconf`, `sysconf` (the syscall-shaped subset) | On real Linux these are pure libc constant tables, not syscalls at all — musl's own implementation never issues one. Not a gap; correctly out of scope for this doc. |

#### Non-POSIX interfaces worth a footnote

`sysinfo(2)` isn't a POSIX interface at all (Linux-specific), but it's the confirmed live blocker
for `free`/`uptime`'s primary numbers (`procps/{free,uptime}.c`) per prior research and
`BUSYBOX_APPLETS.md`'s own `NEEDS_PROC` section. Pre-reserved at `527` (see "Pre-reserved
ahead of implementation" above) — previously sat at its real, unclaimed Linux number `99`. Tracked
here for completeness since it'll come up in the same implementation pass as several POSIX entries
above, not because it belongs in a POSIX-conformance doc on its own merits.

## 6. Kernel modules

### 6.1. Dynamic kernel modules (`sys/module.rs`, `sys/modules/*`)

*(from CLAUDE.md, 2026-09-29)*

Loads independently-compiled, relocatable (`ET_REL`) `#![no_std]` objects into the kernel's
currently-active address space at boot: relocates them, resolves referenced symbols against a
hand-curated kernel API table, calls `module_init`. Distinct from `elf.rs` (loads a
non-relocatable `ET_EXEC` binary with zero relocations) — this is the largest subsystem.

- `build.rs`'s `build_module_crate` runs `cargo rustc --release --lib -- --emit=obj` then a
  mandatory relocatable partial relink (`rust-lld -flavor gnu -r`) against the exact
  `core`/`alloc`/`compiler_builtins` `.rlib`s.
- `--gc-sections -u module_init` on that relink is **required, not optional** — coarse
  archive-member selection during `-r` linking otherwise pulls in entire bundled `core`/`alloc`
  object files (once ballooned a module to 3+ MB/2900 sections, exhausting the boot-time heap).
- `RUSTFLAGS="-C relocation-model=static -C code-model=kernel"` keeps relocations to absolute
  32-bit forms — every module maps inside the top-2GiB kernel region (`MODULE_VA_BASE=
  0xffff_ffff_a000_0000`, `MODULE_REGION_CEILING=0xffff_ffff_ff00_0000` — moved here from the low
  2 GiB during the Limine migration's higher-half kernel placement, see "Boot: Limine" below).
  **The kernel image must end below `MODULE_VA_BASE`** (512 MiB from `0xffff_ffff_8000_0000`) —
  the debug image crossing the old `0x9000_0000` base surfaced as `MappingFailed` on the first
  module load; check `readelf -lW` when embedding more. `oxidebsd_module_alloc_zeroed` pools
  (oxfs's ~1.25 GiB) live in a separate window, `MODULE_DATA_BASE=0xffff_c000_0000_0000` (64 GiB,
  L4 slot 384) — pointer-reached, so no `±2 GiB` constraint.
  `code-model=kernel` is required alongside `relocation-model=static` at this placement — LLVM's
  default `small` code model emits unsigned `R_X86_64_32` for function-pointer references,
  unrepresentable this high up; `kernel` emits sign-extending `R_X86_64_32S` instead. (Found
  through the `CARGO_ENCODED_RUSTFLAGS` leak; the full story is in this file's §3.1.)
  A few GOT-indirected references survive anyway — handled via a minimal, eagerly-populated
  per-relocation-site GOT.
- **No `core::fmt::Write`/`write!` in module code** — that trait object's vtable emits a GOTPCREL
  reference, the single largest bloat source before `--gc-sections`. Hand-rolled byte formatting
  instead.
- **Modules can't use `alloc`/`Vec`/`BTreeMap`** — avoids depending on `#[global_allocator]`'s
  unstable-ABI internals from relocated code. State lives in fixed-size `static mut` arrays, or,
  for a genuinely large pool (see oxfs's own `BLOCKS`/`WRITE_BUFFERS`), real kernel-allocated
  memory via `oxidebsd_module_alloc_zeroed` — a module calling this from *inside* its own
  `module_init` reaches the exact `allocate_region`/`map_region` machinery `module::load` already
  used for that module's own code, rather than baking the pool into its own object file's `.bss`.
- **A `static mut` gotcha distinct from `gdt.rs`'s**: a private `static mut` buffer written but
  never observably read back through an externally-reachable function can have the write deleted
  as an unobservable dead store. Module state needs a syscall-reachable read to survive
  optimization.
- Modules are mapped kernel-only (no `USER_ACCESSIBLE`), every page `WRITABLE` (relocation must
  patch code bytes; no W^X anywhere in this kernel yet).
- A module panic is fatal to that call (no unwinding). `module::CURRENT_MODULE_FATAL` (`static
  mut`) gates a per-module `fatal_on_panic: bool` — `false` for every module except `oxfs`
  (`hlt_loop()`); `oxfs` reboots the whole system (a real disk attached makes a torn
  superblock/inode-table write worse to resume past than an in-memory panic).
- `serial_println!` can't take implicit `{name}`-style captures (its `concat!`-based expansion
  blocks it) — use explicit positional args; `serial_print!` has no such restriction.
- Known limits: no module unload/reload, no versioning, no inter-module direct calls (only
  module→kernel via each module's own resolved symbol table — why `sys/fs/fd.rs`'s registry
  exists at all).

## 7. Processes, scheduling and threads

### 7.1. Process abstraction, scheduler, and fork/exec/wait (`sys/process/`)

*(from CLAUDE.md, 2026-09-29)*

Dynamically allocated process table, scheduler (cooperative round-robin + real ring-3 preemption,
see "Real preemptive scheduling"), kernel-thread-style context switch between per-process kernel
stacks. No copy-on-write fork (full eager copy), no SMP. **`Process` is no longer strictly one
schedulable entity per real process** — real `clone(2)`/`pthread_create` threads sharing one
address space also exist (`Process::tgid`, `ThreadGroupShared`, a per-thread-group `Arc<Mutex<>>`
bundle covering `cwd`/`root_inode`/`umask`/`uid`/`gid`/`brk`/`mmap_file_regions`/`sigactions`) —
see "Real threading" for the full design.

- **Process table is `Mutex<BTreeMap<Pid, Box<Process>>>`, `Box` is load-bearing** — a
  `BTreeMap`'s internal nodes can move on insert/remove, but a `Box`'s heap allocation never does;
  holding the table lock across a context switch would deadlock. Every function touching both the
  table and `scheduler::schedule()` drops the lock first.
- `context_switch::switch_context` only saves System V callee-saved registers + `RSP`. Two
  first-run trampolines: `spawn_trampoline_asm` and `fork_trampoline_asm` (jumps into
  `syscall_entry`'s GPR-pop/`sysretq` tail).
- `fork` resumes the child via a copy of the parent's live `SyscallFrame` with `rax=0` and CF
  explicitly cleared.
- `do_execve` builds everything (new `AddressSpace`, `elf::load`, user stack) *before* mutating
  the live frame/`CR3`/stored `AddressSpace` — a failure at any point must leave the caller
  untouched, matching real `execve(2)`.
- **Real `#!interpreter [arg]` shebang support**: `do_execve` peeks the target's first two bytes;
  if `#!`, parses interpreter + one optional trailing argument, re-targets the load at the
  interpreter, looping up to `MAX_SHEBANG_DEPTH=4` (past which `ELOOP`).
- Per-process state across `fork` (copied)/`execve` (mostly preserved): `cwd` preserved; `brk`
  copied, not reset; `fs_base` copied, reset to 0; `pgid` inherited, untouched; signal state
  (`sigactions` reset to `SIG_DFL` for caught handlers only; `pending`/`blocked` untouched);
  `uid`/`gid` copied, preserved; `sid` inherited, untouched; `rlimits`/`nice`/`sched_policy`/
  `sched_priority`/`umask` copied, preserved; `root_inode` copied, untouched. Itimer state resets
  on `fork`, preserved by `execve` (the one exception).
- Kernel stack size floor is `128` KiB — found empirically. Stacks live in `memory::kstack`'s
  VA window (L4 slot 385, 1 MiB slots, frame-backed) with unmapped guard space below; an overflow
  double-faults and logs `KERNEL STACK OVERFLOW`. The window's L3 table is allocated in `init`,
  before any `AddressSpace` copies the kernel's L4 entries.
- **`do_wait4`'s reported status is real `wait(2)`-encoded — normal exit shifts into bits 8-15**
  (`WEXITSTATUS`). Signal-based termination passes a pre-encoded `128 + sig` directly, must
  **not** be shifted. Real `WUNTRACED`/`WCONTINUED`/`WNOHANG`; `WIFSTOPPED` writes
  `0x7f | (stopsig << 8)`, `WIFCONTINUED` writes `0xffff`.
- **`kill(pid, 0)`** does a real existence-only check (self or cross-process; a zombie still
  counts until reaped), bypassing the pending-signal bitmask.
- **Real orphan reparenting**: a process's still-living children are reparented to pid 1
  (`Process::adopted`, `process::lifecycle::reparent_orphans`/`INIT_PID`) on exit, matching real
  Unix; an adopted orphan's own later exit is treated like `SA_NOCLDWAIT` (immediate detach, since
  pid 1 here has no generic "reap anything adopted" loop).
- **Real per-process `times(2)`** (`Process::cpu_ticks`/`child_cpu_ticks`, folded in transitively
  by `do_wait4` at reap time) — `tms_utime`/`tms_cutime` real, `tms_stime`/`tms_cstime` honest
  zero (no user/kernel CPU-time split tracked). `getrusage(2)`'s `ru_utime`/`ru_stime` have the
  same latent staleness, not yet fixed.
- `tests/fork_wait.rs` + `regress/fork-exec-smoke/` covers fork/wait4/exit.
  `sys/modules/oxfs/src/test_busybox.sh` is real, broader, hand-run coverage.

### 7.2. Real preemptive scheduling (`sys/process/scheduler.rs`, `sys/cpu/interrupts.rs`, `sys/cpu/fpu.rs`)

*(from CLAUDE.md, 2026-09-29)*

The scheduler is no longer purely cooperative. A process still leaves `Running` voluntarily
(`scheduler::schedule()`, unchanged) — but can now also be preempted:
`interrupts::timer_interrupt_handler` calls `schedule()` directly whenever it catches a process
executing ring-3 code and a quantum has elapsed. **`Process::quantum_ticks_left`** is set to a
fresh `PREEMPT_QUANTUM_TICKS=4` (40ms) every time a process is (re)activated to `Running`, and
decremented once per tick it's found running — a real per-process round-robin quantum, not a
purely global tick-phase check (an early version used `now.is_multiple_of(PREEMPT_QUANTUM_TICKS)`,
which gave a freshly-created thread anywhere from 1 to 4 ticks of guaranteed runtime purely by
luck of the global counter's phase — real, reproducible races under this kernel's single-core
QEMU/TCG timing, since a real multi-core machine's own fast instruction window almost never loses
the same race. `do_clone` resets the *caller's* own remaining quantum on creating a new thread,
giving it a guaranteed window to finish any immediate follow-up work before the new child could
preempt it).

- **Deliberately scoped to ring-3 only, not full kernel preemption.** Checked via the interrupted
  frame's CS RPL bits, not a software flag. Kernel/syscall/module code is never preempted
  (`IA32_SFMASK` already clears `IF` for a syscall's entire duration). This is the load-bearing
  scoping decision: user-mode code never holds a kernel `spin::Mutex`, so no existing critical
  section anywhere needed auditing for preemption-safety.
- **EOI is sent before the possible `schedule()` call, not after** — load-bearing: until EOI, the
  PIC won't deliver *any* further timer interrupt to *anyone*, freezing every `ticks()`-gated
  wakeup in the kernel permanently.
- **Real per-process `FXSAVE`/`FXRSTOR` across every context switch** (`Process::fpu_state`) —
  became load-bearing once preemption could interrupt at literally any instruction, not just a
  syscall boundary. A freshly spawned/forked process starts from `cpu::fpu::clean_state()` (a real
  CPU-reset image captured once via `fninit`+`fxsave` at boot).
- **A real scheduler bug found chasing a flaky hang**: `schedule()`'s re-enqueue branch used to
  push the outgoing pid back onto `READY_QUEUE` without updating its own `state` to `Ready` —
  harmless before real preemption, but a cross-process `SIGSTOP` targeting a merely-interrupted
  (not genuinely re-blocked) process failed its own `state == Ready` dequeue check, leaving it
  queued *and* marked `Stopped` — the scheduler later resumed it anyway, silently un-stopping it.
  Fixed at the source: `schedule()` now sets `prev.state = Ready` before enqueueing.

### 7.3. Real threading: `clone(2)`, `pthread_create`/`join`, shared address spaces (`sys/process/`, `sys/memory/address_space.rs`, `sys/fs/fd.rs`)

*(from CLAUDE.md, 2026-09-29)*

Closes the single biggest foundational architecture blocker this project tracked — motivated by
real POSIX AIO, which both musl and glibc implement as pure userspace logic over a
`pthread_create` worker pool (no distinct kernel AIO syscall family exists on real Unix either).

- **Phase 1**: `clone.s`/`__unmapself.s` hardcoded raw Linux syscall numbers directly (same bug
  class as `vfork.s`). Fixed: `clone.s` targets a real reserved `SYS_CLONE=555`;
  `__unmapself.s` calls this ABI's real `SYS_MUNMAP`/`SYS_EXIT` directly.
- **Phase 2**: `Process::tgid: Pid` splits real `getpid()`/`gettid()` apart — set at both
  spawn/fork (never inherited by a forked child, a real process), untouched by execve.
- **Phase 3**: real `FUTEX_WAIT`/`FUTEX_WAKE` (`process::do_futex`, `BlockReason::
  WaitingForFutex(tgid, addr, deadline)`), scoped by `tgid` not raw pid (correct today since no
  ASLR means unrelated processes can share addresses like `USER_STACK_TOP`, and happens to be
  exactly right for `CLONE_THREAD` sharing).
- **Phases 4+5, the actual thread-creation prerequisite** — five changes to a kernel with no prior
  notion of two live threads sharing an address space: (1) `AddressSpace` → `Arc<PhysFrame>`-
  refcounted, `teardown` gated on `strong_count == 1`; (2) `ThreadGroupShared`
  (`cwd`/`root_inode`/`umask`/`uid`/`gid`/`brk`/`mmap_file_regions`/`sigactions`) `Arc<Mutex<>>`-
  wrapped, shared by every `CLONE_THREAD` sibling; (3) `sys/fs/fd.rs` keyed by `tgid`, not raw pid
  — real `CLONE_FILES` sharing falls out for free (`do_clone` must *not* also call
  `fs::fd::fork_inherit`, or it orphans duplicate entries); (4) real `do_clone`/`SYS_CLONE=555`;
  (5) per-thread `SYS_EXIT` — a non-leader thread's table entry is marked `Zombie` and deferred
  via `scheduler::queue_thread_reap`, drained at the top of every `schedule()`.
- **Real `CLONE_CHILD_CLEARTID`** (`Process::clear_child_tid`) — needed for a genuinely unmodified
  `pthread_create()`/`pthread_join()` round trip: real musl's `__pthread_exit` routes
  `__thread_list_lock`'s release through a real kernel clear-and-wake at task-exit time.
- **Real per-address-space frame reclaim**: `memory::BootInfoFrameAllocator` gained a real
  `FrameDeallocator`; `AddressSpace::teardown` walks and frees every `USER_ACCESSIBLE` frame
  beneath a discarded address space (safe since every page-table structure frame is always
  freshly allocated per address space, fork is eager-copy never COW). `SHARED_LEAF` (a repurposed
  PTE bit) marks the two real exceptions that *do* alias a leaf across address spaces — SysV
  `shmat` and fd-backed `MAP_SHARED` mmap — `teardown` skips those. `Process::address_space` is
  `Option<AddressSpace>` (`None` only for a `Zombie` whose frames are already reclaimed) —
  `terminate_process` tears down frames **immediately at exit**, not deferred to a future
  `wait4`, closing a real physical-frame-exhaustion cascade the full POSIX corpus otherwise hit
  (many `pthread_*`/`fork` tests fork-and-exit without ever `wait4`ing). Every OOM path along this
  chain (`KernelStack::new`, `AddressSpace::new`/`copy_table_level`, `map_user_stack`,
  `fault_trampoline::map`) returns a real `Result` instead of hard-panicking, since a single
  userspace process exhausting a shared pool must not take the whole kernel down —
  `do_fork_from_current`/`do_clone` propagate a real `ENOMEM`; boot-time call sites still panic
  (no syscall caller to report to that early).
- **A real, separate `do_munmap` frame leak**, found chasing renewed physical-frame exhaustion
  after the fix above: the unmap loop discarded the frame `Mapper::unmap` handed back instead of
  ever returning it to the frame allocator — every real `munmap()` (including `pthread_join()`'s
  own stack unmap on every join) leaked one physical frame per page, permanently. Fixed: capture
  the frame and return it via `FrameDeallocator::deallocate_frame` unless it carries `SHARED_LEAF`
  (owned by `MMAP_FILE_CACHE` instead, released via `release_mmap_file_ref`). `sysv_shm.rs`'s
  near-identical-looking `shmdt` unmap loop was checked and is correctly unaffected (every page
  there is unconditionally shared, owned by `SEGMENTS`).
- **Named POSIX semaphores** (`process::limits::futex_key`): a *shared* (non-`FUTEX_PRIVATE`)
  futex now resolves `addr` through the caller's address space to the real physical address
  backing it, rather than keying purely on `(tgid, addr)` — real `sem_open()` semaphores are
  `pshared`, and two independently `fork()`ed processes generally map the same `/dev/shm`-backed
  region at *different* virtual addresses (this kernel's `NEXT_MMAP_PAGE` bump allocator is
  global, not reset per caller), so a waiter's `FUTEX_WAIT` and a waker's `FUTEX_WAKE` almost
  never agreed on the same key before this fix. A private futex is unaffected, still keyed by
  `(tgid, addr)` (still required on this no-ASLR kernel). Named POSIX shared memory (`shm_open`)
  still needs its own separate cross-process coordination work beyond this.

**Verified**: `tests/clone_syscall_smoke.rs` (raw `clone(2)`), `tests/pthread_syscall_smoke.rs` (a
genuinely unmodified `pthread_create()`/`pthread_join()` C fixture),
`tests/sem_open_syscall_smoke.rs` (unmodified `sem_open()`+`fork()`+`sem_post()`/`sem_wait()`).
**Unlocks**: POSIX AIO with zero further kernel work; `pthread_mutex_*`/`_cond_*`/`_rwlock_*`/
`_barrier_*`/`_spin_*` all expected to already work (userspace logic over the same real
`futex(2)`). Real `dlopen` stays not done (blocked on `mprotect` enforcement, unrelated to
threading).

**Two real bugs found writing the raw-`clone(2)` smoke test itself**: a child's own new stack must
be `static mut`, not plain `static` (an all-zero immutable static gets placed read-only by
rustc); a hand-written `asm!` block must `setc` immediately after `syscall`, before any
flag-clobbering instruction.

### 7.4. Real threading, as recorded in the syscall survey

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

`SYS_CLONE = 555` (reserved ahead of implementation, see the numbering-discipline note at the top
of this doc) now has a real handler — closes what used to be this doc's "Structurally inapplicable"
`pthread_create` row entirely, landed across five phases plus a finish-line pass. Full detail lives
in CLAUDE.md's own "Real threading" section and the `[[project_real_threading_for_aio]]` memory;
summarized here since it's this doc's own reserved number finally getting a handler.

- **Phase 1**: `third_party/musl/src/thread/x86_64/clone.s`/`__unmapself.s` no longer hardcode raw
  Linux syscall numbers (the same asm-bypass-the-remap-table bug class already fixed once for
  `vfork.s`) — `clone.s` now targets `SYS_CLONE = 555` directly; `__unmapself.s` calls this ABI's
  real `SYS_MUNMAP=101`/`SYS_EXIT=1`.
- **Phase 2**: `Process::tgid` splits real `getpid()`/`gettid()` — `do_getpid()` returns `tgid`;
  `gettid()` needed no kernel change (musl caches it client-side from `SYS_SET_TID_ADDRESS`'s
  existing return value).
- **Phase 3**: real `FUTEX_WAIT`/`FUTEX_WAKE` (`process::do_futex`, `src/process/limits.rs`,
  `BlockReason::WaitingForFutex(tgid, addr, deadline)`), scoped by `tgid` not raw `pid` (load-
  bearing today, since there's no ASLR and unrelated processes can share addresses like the fixed
  `USER_STACK_TOP`) — happens to be exactly the right scope for real `CLONE_THREAD` sharing later
  too. Unblocked unnamed POSIX semaphores for real (3 pilot FAILs flipped to PASS).
- **Phases 4+5**: the actual thread-creation prerequisite — `AddressSpace` became
  `Arc`-refcounted (`src/memory/address_space.rs`, `teardown` gates its free-walk on
  `Arc::strong_count == 1`); a new `ThreadGroupShared` (`cwd`/`root_inode`/`umask`/`uid`/`gid`/
  `brk`/`mmap_file_regions`) is `Arc<Mutex<>>`-wrapped on `Process`; `src/fs/fd.rs` is keyed by
  `tgid` not raw `pid` (real `CLONE_FILES` sharing falls out for free — calling the existing
  `fs::fd::fork_inherit` on top would double-bump refcounts, a real bug found and fixed while
  landing this); `process::lifecycle::do_clone` is the real `SYS_CLONE` handler (`tls` read via
  `crate::syscall::frame_tls`, the same raw-frame-access route `fork`/`execve` already use); a
  non-leader thread's own exit uses a new deferred-reap mechanism
  (`scheduler::queue_thread_reap`/`reap_pending_threads`) since its own `Process` table entry can't
  be removed while the CPU is still executing on its `KernelStack`.
- **Finish line**: real `CLONE_CHILD_CLEARTID` support (`Process::clear_child_tid`) — found
  necessary getting a genuinely unmodified `pthread_create()`/`pthread_join()` round trip working:
  musl's own `__pthread_exit` routes `__thread_list_lock`'s release through a real kernel
  clear-and-wake at true task-exit time, not a plain userspace unlock, and without it `pthread_join`
  hung forever in musl's own `__tl_sync` after its primary `detach_state` futex wait/wake already
  succeeded.

**Verified end-to-end**: `tests/clone_syscall_smoke.rs` + `userland/clone-syscall-smoke/` — a raw
`syscall(SYS_CLONE, ...)` (no musl) proving real `CLONE_VM` (cross-"thread" write visibility),
`CLONE_THREAD` (shared `getpid()`), `CLONE_PARENT_SETTID`, and a real futex-based join. Separately,
`tests/pthread_syscall_smoke.rs` + `userland/pthread-syscall-smoke/` drives a genuinely unmodified
`pthread_create()`/`pthread_join()` C fixture (`userland/pthread-smoke/main.c`, built via
`musl-gcc`, seeded as `/pthread-smoke.elf`) — proving real musl threading works, not just the raw
syscall. Full regression sweep (`fork_wait`, every IPC/signal/mount/mmap smoke test) re-run clean
after each phase.

**What this unlocks, and what it doesn't**: POSIX AIO (`aio_*`/`lio_listio`) is unblocked with zero
further kernel-side work — musl implements it as pure userspace logic over a `pthread_create`
worker pool. `pthread_mutex_*`/`_cond_*`/`_rwlock_*`/`_barrier_*`/`_spin_*` are all userspace logic
over the same real `futex(2)` primitive, so they're expected to already work, though not yet
covered by a dedicated smoke test of their own. **Still not done**: named POSIX semaphores/POSIX
shared memory (need a `/dev/shm` path plus real cross-*process* `FUTEX_WAKE` — today's scoping is
deliberately `tgid`-only, safe but not cross-process) and real `dlopen` (blocked on `mprotect`
enforcement, unrelated to threading).

## 8. Signals

### 8.1. Signal handling module (`sys/modules/signal/`, `sys/process/signals.rs`, `sys/syscall/mod.rs`)

*(from CLAUDE.md, 2026-09-29)*

Real `kill(2)`/`sigaction(2)`/`sigprocmask(2)` + delivery, plus
`sigtimedwait(2)`/`sigwaitinfo(2)`/`sigwait(3)`/`sigqueue(2)`. `SYS_KILL=116`/`SYS_SIGACTION=117`/
`SYS_SIGPROCMASK=118`/`SYS_SIGRETURN=119` match real Linux/BSD wire formats (pure number remap).
`SYS_SIGTIMEDWAIT=495`/`SYS_SIGQUEUE=496` are real, unclaimed
`__NR_rt_sigtimedwait`/`__NR_rt_sigqueueinfo` values. Real signal numbers (`SIGHUP=1`...
`SIGSYS=31`), extended to real-time signals `SIGRTMIN..=SIGRTMAX` (`35..=64`, matching musl's own
`sigrtmin.c`/`sigrtmax.c`). Signals `32..=34` (`SIGTIMER`/`SIGCANCEL`/`SIGSYNCCALL`) are valid,
kernel-side, real signal numbers too — real musl uses `SIGCANCEL=33` for `pthread_cancel(3)` over
the same raw `kill`/`sigaction` path as any other signal; the "permanently unclaimed" framing is a
libc-level convention only, not a kernel restriction.

- `Process::sigactions` moved from `Process` into the `Arc<Mutex<>>`-shared `ThreadGroupShared` —
  real POSIX requires signal disposition to be process-wide, not per-thread (found live: a
  per-thread copy meant `pthread_cancel()`'s installed `SIGCANCEL` handler was invisible to the
  actual target thread). `[SigAction; 65]` (real `SIG_DFL=0`/`SIG_IGN=1`); `Process` itself still
  holds `pending_signals`/`blocked_signals` bitmasks, `pending_siginfo: [QueuedSigInfo; 65]` (real
  per-signal sender `pid`/`uid`/`si_code`/`sigqueue` value — **sized to cover the full `0..=64`
  range**, found live: accepting the `32..=34` range without widening this array first would have
  turned a userspace `EINVAL` into a real kernel out-of-bounds panic), and a real
  `signal_stack: Vec<SignalStackFrame>`.
- **Real RT signal queuing**: `Process::rt_queue: [Vec<QueuedSigInfo>; RT_SIGNAL_COUNT]` gives
  each RT signal its own small fixed-capacity (`RT_QUEUE_CAP=16`) FIFO — a second
  `sigqueue`/`raise` against an already-pending RT signal genuinely queues (standard signals stay
  bitmask-collapsed, which POSIX permits). `record_pending` is RT-aware and fallible: returns
  `Err(EAGAIN)` once a queue is full.
- Delivery happens once, at the tail of `syscall_dispatch` (and from `sigreturn` itself — see
  chaining below). `sigreturn` bypasses the normal `Ok`/`Err` carry-flag rewrite entirely.
- `do_kill` cross-process: immediate for the common case (no handler → terminate right there, even
  against a blocked target); deferred until next-scheduled only if the target has a custom
  handler. **Real permission checking** (`has_signal_permission`): sender must be root or share
  the target's uid, else `EPERM` — single-target paths only, not `signal_foreground_group`'s
  broadcast. **Real process-group targeting** (`target_pid == 0`/`< 0`) — see "Real job control".
  **A signal that must terminate the whole thread group** (default-disposition delivery via
  `deliver_pending_signal`, and every `do_kill` `Action::Terminate` site) routes through
  `terminate_thread_group`, not a single-thread `terminate_process` — killing every non-leader
  member first, the leader always last (found live: a signal hitting the leader while a sibling
  was still alive used to wrongly treat the leader as disposable and skip parent notification,
  permanently hanging `wait4`).
- **Real `SA_SIGINFO` handler invocation**: `RawSiginfo`/`RawUcontext`/`RawMcontext` built on the
  handler's own stack frame with real GP registers and `uc_sigmask`. **`RawSiginfo`'s
  `si_code`/`si_errno` field order was a real bug** (swapped relative to real musl x86_64, silent
  because `SI_USER == 0` too) — fixed by reordering. **Three userland smoke crates hand-duplicate
  this struct** and needed the identical fix — any future wire struct duplicated this way needs
  the same audit whenever the kernel-side original changes.
- **`sigtimedwait`/`sigwaitinfo`/`sigwait`** and **`sigqueue`**: see this file's §8.3.
- **Real signal-stack chaining**: see this file's §8.4.
- **Real `SA_ONSTACK`**/**`SA_NOCLDWAIT`**/**`SA_NOCLDSTOP`**: `Process::on_altstack` +
  `begin_altstack_if_requested`; `terminate_process` detaches an exiting child immediately when
  the parent's `SIGCHLD` flags request it; `notify_parent_sigchld` skips generation for the *stop*
  transition when requested.
- **Real `SIGCHLD` delivery** on child exit/stop/continue (`signals::notify_parent_sigchld`, real
  `CLD_EXITED`/`CLD_KILLED`/`CLD_STOPPED`/`CLD_CONTINUED`) — this kernel never delivered a real
  `SIGCHLD` before a dedicated pass added it, also fixing `hush`'s own `CONFIG_HUSH_FAST`
  short-circuit (previously dead since its `SIGCHLD` counter could never move).
- **A real fault-to-signal-delivery bug: blocking a synchronously-generated signal.** Real musl's
  `pthread_kill()`/`pthread_cancel()` call `__block_all_sigs()` internally — a real page fault
  occurring inside that critical section used to respect the target's blocked-signal mask (correct
  for an async `kill()`-delivered signal, wrong for one synchronously generated by the faulting
  instruction itself), leaving nothing for the fault trampoline to deliver and falling through to
  its `ud2` safety net — an unbounded, whole-VM-halting crash instead of a normal per-process
  `SIGSEGV`. Fixed: `process::signals::force_fault_signal(pid, sig)` force-clears just the one bit
  being delivered before recording it pending, matching real Linux's `force_sig()` semantics
  (every other blocked signal stays blocked). Both fault handlers' self-signal call sites use it.
- **`SYS_FUTEX_REQUEUE=557`**: real `pthread_cond_timedwait`'s `unlock_requeue` needs to move a
  waiter from a condvar's futex word to a mutex's — doesn't fit this ABI's plain 4-register
  `SYS_FUTEX` wire format (real `futex(2)` needs 6 args for this op), so it's a dedicated syscall
  taking exactly `(uaddr, uaddr2, nr_wake, nr_requeue)`. This kernel has no literal wait-queue
  structure to requeue between — "moving" a waiter is just overwriting its own `(scope, key)`
  fields in place.

### 8.2. `tkill`, `times`, `sigpending`, `fchdir`, and `SA_SIGINFO` handler invocation

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

Four of the cheap, no-new-primitive entries from the table below now have real handlers:

| POSIX interface(s) | Number | Handler | Notes |
|---|---|---|---|
| `raise`, `abort`, `pthread_kill`, `pthread_cancel`, `timer_delete` | `SYS_TKILL = 200` (real, unclaimed) | `modules/signal` → `src/syscall/ffi.rs`'s `sys_tkill` → `process::do_kill` | Thin wrapper — `tkill(tid,sig)` is exactly `kill(tid,sig)` since `SYS_SET_TID_ADDRESS` already returns the real pid as `tid`. `abort()`/`assert()` now deliver real `SIGABRT` instead of trapping. |
| `times` | `SYS_TIMES = 493` | `modules/posix_compat` → `sys_times`/`RawTms` | Honest all-zero `struct tms` (same tier as `getrusage`'s `RawRusage`); return value is the real `ticks()` counter, not fabricated. |
| `sigpending` | `SYS_SIGPENDING = 494` | `modules/signal` → `sys_sigpending` → `process::do_sigpending` | Direct readback of the existing `pending_signals` bitmask. |
| `fchdir` | `SYS_FCHDIR = 81` (real, unclaimed) | `modules/oxfs`'s `oxfs_fchdir` | Resolves the fd via the existing `resolve_write_fd_inode`, rejects non-directories with `ENOTDIR`, reuses `oxfs_chdir`'s own `set_current_cwd_real` tail. |

`SYS_TKILL`/`SYS_TIMES`/`SYS_SIGPENDING`/`SYS_FCHDIR` were verified with a fast, scoped `cargo check`
on the individual module crates plus a full `cargo build` (0 warnings, 0 errors, 27m01s — the musl
header sweep's own rebuild cascade). `SYS_TKILL`/`SYS_SIGPENDING` additionally now have a real
end-to-end `SYSCALL` smoke test (`tests/sa_siginfo_syscall_smoke.rs` +
`userland/sa-siginfo-syscall-smoke/`, see immediately below — it exercises both directly). `SYS_TIMES`/
`SYS_FCHDIR` still don't have a dedicated test of their own.

**`SA_SIGINFO` handler invocation** (`src/syscall/mod.rs`'s `deliver_pending_signal`,
`RawSiginfo`/`RawUcontext`/`RawMcontext`) is also now real, closing the "No `SA_SIGINFO` support"
gap that function's own doc comment used to list. A handler installed with `SA_SIGINFO` is invoked
as a genuine 3-argument `void (*)(int, siginfo_t *, void *)` — `rsi`/`rdx` point at a correctly
sized/shaped `siginfo_t`/`ucontext_t` built on the handler's own stack frame, not `NULL`.
Faithfully populated: `si_signo`, `si_code`, the real general-purpose registers in
`uc_mcontext.gregs` (from the interrupted syscall's own saved frame), and `uc_sigmask` (the real
pre-handler `blocked_signals`). Honestly zeroed, not fabricated: FPU state (never saved anywhere on
this kernel), `uc_stack` (`sigaltstack` is bookkeeping-only, never actually switched to). This
needed **zero module-side changes** — `sigaction` already threaded `flags` through to `Process::
sigactions`; only the kernel-resident delivery path needed to consult it. **`si_pid`/`si_uid`/
`si_value`/`si_code` were honest zeros at the time this was first written** (`SI_USER` was the only
possible value, and no sender identity was tracked anywhere) — now real, see "Implemented:
`sigtimedwait`/`sigwaitinfo`/`sigqueue`" below, which added the shared `Process::pending_siginfo`
store this delivery path now reads from too.

**Verified end-to-end**: `tests/sa_siginfo_syscall_smoke.rs` + `userland/sa-siginfo-syscall-smoke/`
installs a real `SA_SIGINFO` handler for `SIGUSR1`, `tkill`s itself, and confirms — from inside the
handler, into global statics — that `signum`/`si_signo`/`si_code`/a non-`NULL` `ucontext`/
`uc_sigmask` all arrived correctly, then confirms (after the `tkill` syscall itself returns, proving
a real `sigreturn` round trip actually resumed the interrupted instruction stream) that
`sigpending()` no longer reports the signal. **Passes.** This also incidentally found a real,
previously-only-theoretical bug: `elf.rs`'s "flags aren't unioned across `PT_LOAD` segments sharing
a page" gap (already documented in CLAUDE.md) page-faulted this crate's very first static write,
since it's the first userland crate with real writable globals — worked around at the linker-script
level for this one crate, not fixed in `elf.rs` itself; see CLAUDE.md's own updated note on that gap.

### 8.3. `sigtimedwait`/`sigwaitinfo`/`sigqueue`

*(from MISSING_POSIX_SYSCALLS.md, cut 2026-10-01)*

The two real, confirmed-live-caller gaps this doc's own "Missing, live caller confirmed" table
tracked now have real handlers, landed in a later session than the batch below (this doc's own
sections aren't in strict chronological order past this point — this one slots in here because it
closes out the gap the table above first identified, ahead of the unrelated 28-syscall
pre-reservation batch that follows).

| POSIX interface(s) | Number | Handler | Notes |
|---|---|---|---|
| `sigtimedwait`, `sigwaitinfo`, `sigwait` | `SYS_SIGTIMEDWAIT = 495` (real, unclaimed `__NR_rt_sigtimedwait`) | `modules/signal` → `src/syscall/ffi.rs`'s `sys_sigtimedwait` → `src/process/signals.rs`'s `do_sigtimedwait` | Real `(mask_ptr, info_ptr, ts_ptr, sigsetsize)` wire format — confirmed directly against `third_party/musl/src/signal/sigtimedwait.c`'s own call site that no `SYS_rt_sigtimedwait_time64` sibling is ever defined for this arch, so the real syscall's own 4-argument shape already fits this ABI exactly, no musl call-site patch needed. `sigwaitinfo`/`sigwait` are thin musl-side wrappers around this same function (a null `ts`, and discarding everything but `si_signo`, respectively) — one kernel handler covers all three library entry points, the same "one syscall backs several libc names" shape `SYS_TKILL` already established for `raise`/`abort`/`pthread_kill`. **A genuinely new primitive, not just a state field**: `BlockReason::WaitingForSpecificSignal(wait_set, deadline)` — real semantics directly *consume* a pending signal matching `wait_set` and return its number, **bypassing the normal handler-invocation machinery entirely** (`take_deliverable_signal`/`deliver_pending_signal` are never involved), matching real POSIX's documented behavior that `sigwaitinfo` never runs an installed handler even when one exists. `info_ptr`, if non-null, is filled with a real (not fabricated) `siginfo_t`. Real `EAGAIN` on timeout (`semtimedop`'s own `ETIMEDOUT` is the wrong errno for this syscall specifically); the timeout is real-relative, same `resolve_relative_deadline` shape `crate::fs::sysv_sem`'s own semtimedop conversion already established (duplicated locally, not shared, same precedent). |
| `sigqueue` | `SYS_SIGQUEUE = 496` (real, unclaimed `__NR_rt_sigqueueinfo`) | `do_sigqueue` | Real `(pid, sig, siginfo_ptr)` wire format, no musl call-site patch needed. Unlike `kill(2)`, only ever targets a single specific pid (`target_pid <= 0` is `EINVAL` — no process-group broadcast shape exists for it in real POSIX either). Reuses `do_kill`'s own single-target Discard/Terminate/Stop/SetPending disposition resolution, duplicated rather than factored out (same "small per-caller copy over cross-function abstraction" precedent `signal_foreground_group` already set for this exact enum/match shape). |

**A real, shared per-pending-signal sender-identity/payload store, not just a bespoke sigqueue
landing spot**: `Process::pending_siginfo: [QueuedSigInfo; 32]` (indexed like `sigactions`) — every
`do_kill`/`signal_foreground_group`/`do_sigqueue` call site that used to just do `pending_signals |=
1 << (sig - 1)` now goes through a new shared `record_pending` helper that also records real `si_code`
(`SI_USER` for `kill`-shaped, `SI_QUEUE` for `sigqueue`-shaped), real sender `pid`/`uid` (`0` only
for `signal_foreground_group`'s own two callers — a keyboard-generated Ctrl+C/Ctrl+Z or a
`kill(-pgrp, sig)` broadcast — neither of which has one specific real sender process to attribute),
and the real `sigqueue`-supplied value. **This closed a second, previously-separate gap for free**:
the `SA_SIGINFO` handler-invocation path (`src/syscall/mod.rs`'s `deliver_pending_signal`,
implemented in an earlier session — see "Implemented this session" above) used to report honest-zero
`si_pid`/`si_uid`/`si_value` and a hardcoded `SI_USER` for every delivery; `take_deliverable_signal`
now threads the real `QueuedSigInfo` it finds through `SignalDelivery::Handler`'s own new `siginfo`
field, so a caught handler now sees real sender identity/payload too, not just `sigtimedwait`.
`RawSiginfo` itself (the real 128-byte musl `siginfo_t` layout) moved from `src/syscall/mod.rs` to
`crate::process` so both consumers (`deliver_pending_signal` and `process::signals`'s own
`do_sigtimedwait`/`do_sigqueue`) share one verified-layout definition instead of risking two
independently-drifting copies of a wire-format struct.

**A real regression found live, not by review, while writing this feature's own smoke test**: an
early test draft self-`sigqueue`d a signal with no installed handler (default disposition
`Terminate`) expecting it to simply sit pending for a later `sigtimedwait` to consume — instead, the
*same* `sigqueue` syscall's own normal delivery tail (`deliver_pending_signal`, run at the end of
every completed syscall) found it immediately deliverable and terminated the process right there,
before `sigtimedwait` was ever reached. This is real, correct POSIX behavior, not a kernel bug — the
POSIX standard explicitly documents `sigwait`-family behavior as unspecified for a signal that isn't
already blocked, precisely because it otherwise races the normal delivery path exactly like this.
Separately, this kernel's own `do_kill`/`do_sigqueue` cross-process disposition resolution doesn't
consult `blocked_signals` at all when deciding whether a *different* target's signal resolves
immediately (an already-documented, accepted simplification — see `do_kill`'s own doc comment) — so
a cross-process signal also needs a real handler installed (not just blocking) to defer as
`SetPending` rather than terminating the target immediately. Fixed by correcting the *test* (install
handlers for every signal used with `sigtimedwait`, block them first) rather than the kernel — both
requirements are real, intentional POSIX/this-ABI's-own-documented behavior, not gaps.

**Verified end-to-end**: `tests/sig_syscall_smoke.rs` + `userland/sig-syscall-smoke/` — same
real-`SYSCALL` pattern. Seven parts: installs handlers for and blocks both `SIGUSR1`/`SIGUSR2`; a
real self `sigqueue`/`sigtimedwait` round trip (`SI_QUEUE`, real `si_pid`/`si_value`, handler never
ran); a real relative-timeout `EAGAIN`; a `fork()`-driven cross-process wake via plain `kill()`
(`SI_USER`, real sender `si_pid`, `si_value == 0`); the same shape via `sigqueue` with a real
nonzero value (`SI_QUEUE`); confirmation that `sigtimedwait` genuinely bypasses handler invocation
one more time, followed by unblocking and a plain self-`kill()` that *does* still invoke it
immediately (real POSIX ordering, same "handler already ran before the interrupted call returns"
property `pause-syscall-smoke`/`sigsuspend-syscall-smoke` already proved); and real `EINVAL`
validation (`sigqueue` against pid `0`/negative, signal `0`/`32`). **Passes.** Also re-verified
clean: `sa_siginfo_syscall_smoke`, `pause_syscall_smoke`, `sigsuspend_syscall_smoke`,
`sysv_sem_syscall_smoke` (the existing tests most likely to regress from the shared `record_pending`/
`RawSiginfo`-relocation refactor) all still pass.

### 8.4. Real-time signal queuing and the signal stack

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

- [x] **Real-time signal queuing**: done. `SIGRTMIN..=SIGRTMAX` (`35..=64`, matching musl's own
      `sigrtmin.c`/`sigrtmax.c`; `32..=34` stay permanently unclaimed, matching real glibc/musl
      convention) now validate through `do_kill`/`do_sigqueue`/`sys_sigaction`, and
      `Process::rt_queue` (`src/process/mod.rs`) gives each RT signal number its own small
      fixed-capacity (`RT_QUEUE_CAP = 16`) FIFO — a second `sigqueue`/`raise` against an
      already-pending RT signal number genuinely queues rather than merging into
      `pending_signals`' single bit, matching real POSIX. Standard signals (`1..=31`) are
      unchanged (still bitmask-collapsed, which POSIX permits for non-RT). Verified via
      `tests/rt_signal_syscall_smoke.rs` + `userland/rt-signal-syscall-smoke/` (queuing count,
      real per-signal `EAGAIN` past `RT_QUEUE_CAP`, lowest-signal-number-first delivery order,
      partial-drain pending-bit semantics) and by re-running the Open POSIX Test Suite pilot: flips
      `sigqueue/1-1,5-1,6-1,7-1.c` and `sigwait/2-1.c` from UNRESOLVED to real PASS.
      **A real, separate, pre-existing gap this surfaced for the first time, since fixed** (not a
      bug in the queuing work above — confirmed by `tests/rt_signal_syscall_smoke.rs`'s own part 1,
      which originally passed the identical scenario only via an explicit multi-syscall "pump"
      workaround, since removed): `deliver_pending_signal` (`src/syscall/mod.rs`) used to deliver
      only **one** signal per completed syscall, by design (redirecting the live frame into a
      handler once; no real signal stack existed to chain further redirects within the same return
      path). Real POSIX code that unblocks several already-queued RT instances in one call
      (`sigqueue/4-1.c`/`8-1.c`: `sigrelse()` once, then immediately expects all 5 queued instances
      already delivered) only saw one delivered before it checked — genuinely failed/went
      UNRESOLVED (that pilot run: `sigqueue/4-1.c` FAIL, `sigqueue/8-1.c` UNRESOLVED, both for this
      exact reason). **Fixed with a real signal stack**: `Process::signal_saved_frame: Option<
      SyscallFrame>` (a single snapshot) became `Process::signal_stack: Vec<SignalStackFrame>` (a
      real stack, `src/process/mod.rs`); `stash_signal_context` pushes an entry per delivery instead
      of overwriting one; `do_sigreturn` (`src/syscall/mod.rs`) now re-checks for a further
      deliverable signal immediately after popping and restoring an entry, and if one exists,
      chains straight into another handler invocation (pushing a fresh entry) instead of ever
      letting the popped state resume as real userspace execution. This closes the gap generally,
      not just for RT signals: any sequence of deliverable signals now plays out as N real handler
      invocations, each one's own `sigreturn` triggering the next, before the originally-interrupted
      code resumes. Flips `sigqueue/4-1.c` FAIL and `sigqueue/8-1.c` UNRESOLVED to real PASS with no
      other pilot regressions. Verified via the full automated pilot
      (`tests/posix_conformance_smoke.rs` + `userland/posix-conformance-driver/`, not manual) and
      `tests/rt_signal_syscall_smoke.rs`'s part 1/3 (now pump-free, proving the chain happens within
      the unblocking `sigprocmask` call's own tail) plus every other signal-touching smoke test
      (`sig`/`sa_siginfo`/`sigsuspend`/`sigaltstack`/`pause`/`mmap`/`fork_wait`).
      **A follow-up pass fixed a second real gap the pilot's remaining `sigqueue`/`kill` FAILs
      converged on**: real `kill(2)`/`sigqueue(2)` permission checking, plus `sigqueue`'s own real
      `sig == 0` null-signal existence(+permission)-only convention (previously always `EINVAL`,
      unlike `kill(pid, 0)`, which already had this). `has_signal_permission` (`src/process/
      signals.rs`) is the real POSIX rule — sender is root, or sender's uid matches the target's —
      checked by both `do_kill`/`do_sigqueue`'s single-target cross-process paths (not
      `signal_foreground_group`'s own process-group broadcast; no pilot test needs it, and real
      POSIX's own per-member partial-success rule there is meaningfully more complex). Flips
      `kill/2-2,3-1.c` and `sigqueue/2-1,2-2,3-1,11-1,12-1.c` from FAIL to real PASS — pilot moved
      45P/16F/3U/4UT → 52P/9F/3U/4UT, and (combined with several later, separately-landed fixes —
      see CLAUDE.md's own "Real ring-3 fault-to-signal delivery"/"Three more pilot fixes" sections —
      plus this signal-stack fix) now stands at **64P/0F/0U/4UT/0TIMEOUT/0CRASH, 68 total**: every
      pilot interface passes; the remaining 4 (`mq_open/10-1,14-1.c`, `shm_open/10-1,12-1.c`) are
      the suite's own self-declared UNTESTED — each one's own `main()` prints why and returns
      `PTS_UNTESTED` unconditionally, before ever calling anything this kernel implements (real
      multi-user/multi-group permission testing `mq_open/10-1.c` says it can't do in this
      environment; unspecified file-offset behavior `shm_open/10-1.c` declines to check at all) —
      not a kernel gap this pilot subset can close by implementing anything further. Verified via
      `sig-syscall-smoke`'s new part 8 (real `ESRCH`/`EPERM` enforcement, including a forked,
      uid-dropped child).

### 8.5. Real job control: Ctrl+C/Ctrl+Z, colored tty, `kill(-pgrp)` (`sys/process/`, `sys/cpu/interrupts.rs`, `build.rs`)

*(from CLAUDE.md, 2026-09-29)*

**Root cause, no BusyBox patch needed**: `hush.c` has always shipped a complete job-control
startup sequence that activates itself *if* it discovers a controlling tty — it never did, since
pid 1's stdin/stdout were wired directly to the console, never through a real `open()`. **Fix**:
`process::spawn` calls `console::stdin::set_controlling_session(pid)` directly right after
inserting pid 1 — mirrors what a real kernel does. That's what makes `FOREGROUND_PGID` get
claimed (via `hush`'s own `TIOCSPGRP`), unlocking the pre-existing Ctrl+C interception.

- **Colors**: `TERM=linux` + a colored `PS1` added to pid 1's `envp`. Real `ls --color` needed its
  own Kconfig flip in `build.rs`. This BusyBox fork's `grep` has no color feature at all.
- **Real `kill(-pgrp, sig)` process-group broadcast** (`do_kill`'s `target_pid <= 0` branch) —
  `hush`'s own `fg`/`bg` and job-cleanup paths depend on it. Reuses `signal_foreground_group`'s
  exact per-process action resolution.
- **Real `SIGSTOP`/`SIGTSTP`/`SIGCONT`** (genuine Ctrl+Z suspend/`bg`/`fg` resume):
  `ProcState::Stopped(u64)` (payload = stopping signal). `DefaultDisposition::Stop` split from the
  old blanket `Ignore` bucket. `SIGCONT` gets a pre-dispatch step at every cross-process-capable
  call site: an actually-`Stopped` target always resumes regardless of its own disposition.
  - **A real regression found live**: `process::timers::do_nanosleep` was the one blocking call
    that didn't loop and re-check its wake condition after `scheduler::schedule()` returns. Real
    `SIGCONT` unconditionally wakes a `Stopped` process, so `bg`-ing a Ctrl+Z-stopped `sleep 100`
    woke it almost immediately instead of at its real ~100s deadline. Fixed by looping and
    re-checking the deadline — **any future mechanism that can force an arbitrary process back to
    `Ready` cross-process needs the same audit** of every non-looping `scheduler::schedule()` call
    site.
  - Not covered: real `SIGTTIN`/`SIGTTOU`-driven job control (still `Ignore`).

## 9. Terminals, sessions and login

### 9.1. Session, controlling-tty, and login authentication (`sys/process/`, `sys/console/stdin.rs`, `sys/cpu/interrupts.rs`, `sys/modules/posix_compat/`, `sys/modules/oxfs/`)

*(from CLAUDE.md, 2026-09-29)*

Closes `su`/`login`/`sulogin`/`getty`.

- **A real second user**: `/etc/passwd` gains `user:x:1000:1000:User:/home/user:/bin/sh` (real
  `/home/user`, owned `1000:1000`, mode `0700`). **A real `/etc/shadow`** (mode `0600`, root-owned)
  holds real SHA-512 (`$6$`) `crypt(3)` hashes (password equals username) — musl's stock
  `crypt` code needed zero changes.
- **A real session model**: `Process` gains `sid: Pid`. Two new **single, not per-session**
  globals in `sys/console/stdin.rs`: `CONTROLLING_SESSION: Option<Pid>`, `FOREGROUND_PGID:
  Option<Pid>` — this kernel has exactly one real console.
  - **`SYS_SETSID=112`**: `EPERM` if the caller is already a process-group leader; else becomes
    leader of a fresh session+pgroup.
  - **`SYS_GETSID=177`** (invented — real Linux's `124` means `SYS_IOCTL` here).
  - **`SYS_IOCTL` gains `TIOCSCTTY`/`TIOCNOTTY`/`TIOCGPGRP`/`TIOCSPGRP`**, gated to the real
    console fd. `TIOCGPGRP` falls back to the session id when nothing's called `TIOCSPGRP` yet.
  - **Real Ctrl+C → `SIGINT` to the foreground process group**: keyboard IRQ intercepts ASCII ETX
    (`0x03`) before the stdin ring buffer, only when `ISIG` is set **and** `FOREGROUND_PGID` is
    claimed — see "Real job control" below for how pid 1 gets a controlling tty automatically.
  - Verified via `tests/session_syscall_smoke.rs`, run as a forked child of pid 1.

**Two real bugs found live-testing `su`**: a real syscall-number collision (this ABI's invented
`SYS_KILL` equaled real Linux's inert `setgroups`, which *did* have a live musl caller via
`initgroups()`, silently misrouting `setgroups()` into `kill(2)` — fixed with a dedicated
`SYS_SETGROUPS=178`); and a real `ENOSYS` mismatch (this kernel's `ENOSYS` was FreeBSD's `78`
instead of musl's compiled-in `38`, so BusyBox's `initgroups()`-failure-is-harmless fallback never
fired — fixed by correcting the constant). Both confirm the syscall-ABI collision rule above.

### 9.2. Terminals (`sys/tty/`; spec + status: OxideBSD-doc `TTY.md` §10)

*(from CLAUDE.md, 2026-09-29)*

`sys/console/stdin.rs` is gone. Each terminal is a `sys/tty::Tty` with its own queues, termios
(4.4BSD `TTYDEF`), winsize, session and foreground pgrp, and a real line discipline (canonical
mode, VMIN/VTIME, echo flags, ISIG from `c_cc`, OPOST/ONLCR). `ttyv0` (`sys/tty/console.rs`) is
the console: keyboard in, ANSI engine/framebuffer out, a pre-OPOST copy to COM1 so serial logs and
tests read as before. fds 0-2 of the first process are one RW description of it (`fs::fd::init`).
- Job control: SIGTTIN/SIGTTOU (default Stop), hang-up on session-leader exit, SIGWINCH;
  `TIOCSCTTY` can't steal, `TIOCNOTTY` refuses a leader (BSD rules). `ERESTART` +
  `SA_RESTART` restart syscalls (`syscall_dispatch`).
- **An interrupt handler must only call `schedule()` when it interrupted ring 3** — a nested
  `schedule()` from the idle loop (`wait_for_ready`) hung the system (found live after ^D).
- `vga`'s `ESC[6n` reply is queued and fed to input after its lock drops (echo would deadlock).
- Device nodes: oxfs's `Device` arm hands majors 4-6 to `tty::oxidebsd_tty_open` (`/dev/tty` =
  the caller's controlling terminal, `/dev/console` = `ttyv0` for now). Kernel-owned descriptions
  carry an `fs::fd::FdKind` (pipe/socket/FIFO/mqueue) so oxfs can `fstat` them and build the
  `/proc/<pid>/fd/<n>` symlinks musl's `ttyname(3)` reads; `/proc/self` exists.
  `tests/tty_syscall_smoke.rs`.
- Not done yet (TTY.md §10.3): COM2 `tty01`, `TIOCCONS` + msgbuf//dev/klog. Test console input
  headlessly with the monitor's `sendkey`.

*(from TTY.md, cut 2026-10-01)*

Today's terminal state is one
set of console-wide globals (`sys/console/stdin.rs`); this design replaces it.

A live boot driven through QEMU's `sendkey`
confirmed line editing, `^D` end-of-file, `^C` (status 130), and `^Z` with
`jobs` and `kill %1`.

The same slice fixed a scheduler re-entrancy bug: an interrupt that landed in
the scheduler's idle loop called `schedule()` again, which halted the system
with a process marked Running. Interrupt handlers now reschedule only when they
interrupted user code.

### 9.3. Terminal and job-control gaps, as recorded in the conformance checklist

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

- [ ] **Real pty layer** (`posix_openpt`/`grantpt`/`unlockpt`/`ptsname`, `/dev/pts`): this kernel
      has exactly one physical console tty — real job control (`setsid`/`TIOCSCTTY`/Ctrl+C/Ctrl+Z,
      see CLAUDE.md's "Real job control" section) already works *for that one console*, but
      anything needing a second, program-allocated terminal (a real terminal emulator, `script`,
      `ssh`/`telnet` servers, `expect`-style automation) has nothing to allocate.
- [ ] **`SIGTTIN`/`SIGTTOU` delivery**: still `Ignore` disposition unconditionally — confirmed in
      CLAUDE.md's job-control section as an explicit known gap (only `SIGINT`/`SIGTSTP` are ever
      delivered to a foreground group). Real background-process-writing-to-the-controlling-tty
      semantics depend on this.
- [ ] **`getlogin`/`getlogin_r`/`ttyname`/`ttyname_r`/`tcgetsid`**: real Linux backs these via
      `/proc/self/fd/N` symlink resolution plus `ioctl(TIOCGSID)`-adjacent `utmp` lookups, not one
      dedicated syscall each — `tcgetsid` specifically would fold into the existing
      `TIOCGPGRP`-style `SYS_IOCTL` gate rather than a new registration. No live caller in the
      current roster; low priority relative to the pty gap above, but a real conformance suite
      will still probe them.

## 10. Filesystems, disks and devices

### 10.1. Filesystem: oxfs

*(from CLAUDE.md, 2026-09-29)*

**`sys/modules/oxfs/`** is the live filesystem — a real Unix-shaped inode/block filesystem. In-memory
by default, with real optional persistence to an attached ATA disk (see "Real disk persistence").
Fixed-size `static mut` pools: `NUM_BLOCKS=65536` × `BLOCK_SIZE=4096`, `MAX_INODES=8192`,
`NAME_MAX=40`, `OXFS_PATH_MAX=4096` (real, whole-path `ENAMETOOLONG` enforcement, matching musl's
`PATH_MAX` — doesn't cover a name with embedded `/` characters, since real POSIX leaves
interpretation of those implementation-defined and musl's own `shm_open` client code already
rejects them before the kernel ever sees them). Each inode has 12 direct blocks + one
single-indirect + one **double-indirect** block (~4.1 GiB addressable per file; real ceiling is
pool free space, ~1 GiB pool). `OpenFile::Write` streams to real blocks once its buffer
(`MAX_WRITE_BUFFER=16` MiB) fills, rather than buffering a whole file and replacing it at `close`.
The buffer itself lives in a separate, lazily-claimed pool (`WRITE_BUFFERS`/`WRITE_BUFFER_USED`,
`MAX_WRITE_BUFFERS=256`) rather than embedded in every `OpenFile::Write` — a read-only or
never-written fd never claims a slot, which is what let `MAX_OPEN_FILES` scale `256 → 2048`
cheaply (found necessary chasing a real POSIX stress test that opened up to 1000 fds
simultaneously with no `close()`). `NO_BLOCK = u32::MAX` is the "unallocated" sentinel.
Directories are ordinary inodes holding fixed 32-byte records that grow additional blocks on
demand. `unlink`/`rmdir` only clear a record's `used` byte (no dealloc). Root is fixed inode `0`,
self-referencing `.`/`..`.

- Real multi-component path resolution (`resolve_path`/`resolve_parent`, handling `.`/`..`).
- Real **per-process** cwd: `Process::cwd` (opaque inode number), falls back to `BOOT_CWD` for pid
  `0` (module_init's own self-check).
- Syscalls: `SYS_OPEN=5`, `SYS_CLOSE=6`, `SYS_CHDIR=12`, `SYS_MKDIR=136`, `SYS_GETCWD=108`,
  `SYS_UNLINK=109`, `SYS_RMDIR=110`, `SYS_RENAME=111`, `SYS_FSTAT=126`/`SYS_STAT=127`/
  `SYS_LSTAT=128` (byte-exact 144-byte musl `struct stat`), `SYS_GETDENTS=129`. `st_uid`/`st_gid`/
  `mode`/timestamps are real (see "Permission model") — `oxfs_lstat` doesn't follow a final
  symlink, `oxfs_stat` does.
- Seed files (BusyBox applet ELFs, the musl runtime tree, fixtures) are embedded via
  `include_bytes!` in `module_init`, no build-time disk image needed.
- **The on-disk bitmap was once hardcoded to one block** (broken past `NUM_BLOCKS=32768`) and the
  block allocator was once an O(n²) rescan — both fixed as part of the max-file-size redesign.
  `SUPERBLOCK_VERSION` bumped alongside.
- **`BLOCKS`/`WRITE_BUFFERS` are real, kernel-allocated memory (`oxidebsd_module_alloc_zeroed`,
  `sys/module.rs`), not `static mut` arrays baked into this module's own object file** — found live
  investigating a boot-path memory failure: those two pools alone made this module's own mapped
  region ~1.5 GiB (the block pool's real ~1 GiB capacity plus the write-buffer pool, versus ~230 MiB
  of actual code/embedded seed content). `init_pools()` (top of `module_init`) requests both from
  the kernel via a new symbol modules can call *from inside* `module_init`, reusing the exact
  `allocate_region`/`map_region` machinery `module::load` already uses for a module's own code —
  bridged via raw pointers `load` stashes for the duration of one `module_init` call
  (`CURRENT_LOAD_MAPPER`/`_FRAME_ALLOCATOR`, `sys/module.rs`), since `module_init`'s own fixed,
  parameterless calling convention can't carry them directly.

An earlier FAT32 module (8.3 names only, one path component per call, a directory that could never
grow past its first cluster, one kernel-wide cwd, whole-file-buffered reads, no `unlink`/`rmdir`/
`rename`) has since been removed entirely (v0.2.0 cleanup) — oxfs replaced it as the live
filesystem well before that, this was just retiring dead weight.

**`sys/fs/fd.rs`** (now `tgid`-keyed — see "Real threading"): a per-process
`(Pid, fd)` scoped registry — the only coordination channel between independently-loaded modules.
Two tables: `(tgid, fd) -> real_fd` and `real_fd -> Description` (callbacks + refcount). fd
numbers are per process, lowest free (POSIX); `real_fd` is a never-reused global id that modules
key their state by. **`oxidebsd_alloc_fd` returns a `real_fd`; `oxidebsd_register_fd_ops*` returns
the user fd** — return *that* to userspace, and pass `real_fd` to the `oxidebsd_set_fd_*` setters.
**Real per-`(pid, fd)` `FD_CLOEXEC`**: scoped per
descriptor not per open-file description (`dup`/`dup2` don't copy it, `fork_inherit` does);
`do_execve` calls `fs::fd::close_cloexec`. **FIFOs**: `InodeKind::Fifo` (`mknod(S_IFIFO)`); `open`
calls the kernel's `oxidebsd_fifo_open` (`sys/fs/pipe.rs`, keyed by inode), which can block — oxfs
clears its `AT_BASE_OVERRIDE` around the call. **Real per-fd access-mode enforcement**
(`OpenFile::Write::readonly`) on write/`ftruncate`/`fallocate` — `open(path, O_CREAT)` with no
explicit `O_WRONLY`/`O_RDWR` now genuinely produces a read-only fd rather than silently writable.

### 10.2. Real disk persistence (`sys/drivers/{disk,ata,virtio,virtio_blk,dma}.rs`, `sys/modules/oxfs`)

*(from CLAUDE.md, 2026-09-29)*

Scoped deliberately: real disk I/O and oxfs mount/format persistence, not a general VFS/mount-table
layer.

- **`drivers::disk`** owns oxfs's `oxidebsd_block_*` exports and picks one data disk at boot:
  virtio-blk (modern virtio 1.x only), else the IDE secondary master — by bus-master DMA when the
  PIIX controller allows it, else PIO. `cargo run` attaches virtio-blk (`disable-legacy=on`);
  tests attach IDE; `OXIDEBSD_QEMU_DISK=ide|virtio` overrides either, `OXIDEBSD_DISK_IMAGE` swaps
  the image. `no-ata`/`no-disk` skips the whole probe.
- **Why**: IDE PIO traps to QEMU per 16-bit word — a fresh format (66254 blocks, ~259 MiB) took
  ~1035 s, IP-sampled inside `outsw` nearly every time. DMA or virtio: ~1.5 s.
- **Completion is interrupt-driven with a polling fallback** (`dma::wait_until`): the IRQ handler
  (IRQ 15 for IDE, the PCI line for virtio — shared lines are fine, the IRQ registry holds several
  handlers per line) only acks and wakes; the waiter re-checks device state, `hlt`s when IF=1
  (boot, `module_init`) and spins when masked (syscalls). All waits are `tsc`-bounded.
- DMA goes through physically contiguous bounce buffers (`dma::DmaBuffer`; below 4 GiB for IDE's
  32-bit PRDs). One request in flight at a time. Writes end with `CACHE FLUSH`/`VIRTIO_BLK_T_FLUSH`.
- Real hardware would need `SET FEATURES` (UDMA mode) before IDE DMA; QEMU doesn't.
- **Format commits via the superblock**: `flush_all_to_disk` blanks block 0 first and writes the
  superblock last, so an interrupted format reformats on the next boot instead of mounting a
  gutted filesystem (found live: a disk with ~3% of its blocks, `ls` missing, doom faulting).
- **QEMU topology** (`scripts/qemu_common.sh`): the IDE data disk is the secondary master
  (`ide.1`, unit 0); the boot ISO is on virtio-scsi (`OXIDEBSD_QEMU_CDROM=ide` puts it back on
  `ide.0`) — firmware reads an IDE CD by PIO, which made Limine's load of the ~257 MiB kernel take
  ~34 s; virtio-scsi takes ~2 s, BIOS and UEFI alike. Images: `target/oxfs_disk.img` (`cargo run`)
  is created if missing and grown in place, never rewritten; `target/oxfs_test_disk.img` is fresh
  (sparse) every test boot. `qemu_common.sh` makes both, sized by `build.rs`'s
  `target/oxfs_disk.bytes`.
- **Build-script rerun traps, found costing ~2 min per no-op build**: never `rerun-if-changed` a
  path that may not exist (cargo treats missing as changed — watch the containing directory) or a
  file something else writes every run (the old `oxfs_disk.img` watch). `cargo build -v` names
  the dirty path.
- **On-disk layout**: physical block `0` is the superblock (magic `b"OXFS"` + version + layout);
  packed inode table follows; then the block-used bitmap; real data after that. **Never a raw
  transmute/memcpy of `Inode`** — `pack_inode`/`unpack_inode` serialize by hand.
- **Mount-or-format, decided once in `module_init`**: no disk → in-memory only. Disk attached,
  superblock magic **and** stored layout match this build → **mount** (eager-load only used data
  blocks). Magic mismatch, or layout mismatch → **format** (reset the in-memory pool to all-free
  first — a stale bitmap/inode-table load must never leak into a fresh format), reseed, then
  `flush_all_to_disk`. **A real, three-layered bug found when `MAX_INODES` changed the on-disk
  table size**: a stale bitmap could leak into a fallback-to-format path, `build.rs`'s own
  hand-duplicated metadata-block-count constant went stale, `mount_from_disk`'s superblock check
  was magic-only (not layout-aware), and the persistent dev disk was never grown if undersized —
  all four fixed (always reset-then-format; compute the constant; check
  `SUPERBLOCK_VERSION`/`NUM_BLOCKS`/`MAX_INODES` too; grow the disk in place).
- **Write-through persistence, centralized at three functions**: `write_block`, `write_inode`,
  `set_block_used` are the *only* functions that ever touch `BLOCKS`/`INODES`/`BLOCK_USED`.
- **`PERSISTENCE_READY`** (`static mut` gate) stays `false` for the entire format/mount duration,
  set `true` right after, before any real syscall becomes reachable.
- **Known, accepted limitation: mount-time load is bitmap-filtered, not true lazy fault-in.**
  Sector transfers themselves are NOT the bottleneck this once implied — `insw`/`outsw` (hand-rolled
  `rep insw`/`outsw` via inline `asm!`, not the pinned `x86_64` crate's own `Port` abstraction,
  which has no such wrapper) already move a whole 512-byte sector in one trapped instruction under
  QEMU's TCG. The real per-command cost is fixed overhead (drive select, `BSY`/`DRQ` polling)
  independent of transfer size — `oxidebsd_block_{read,write}_batch` (`sys/drivers/ata.rs`) cut
  this by issuing one real command (and, for writes, one `CACHE FLUSH`) per *contiguous* run of
  oxfs blocks instead of one per individual 4 KiB block; `mount_from_disk`/`flush_all_to_disk` use
  these instead of the single-block API for their own data-block loops. That batching barely
  mattered in the end: the real cost was PIO's per-word trap, gone with DMA/virtio (see above).
- **The same batching extended to live per-syscall writes, not just the bulk mount/format pass**
  (`write_inode_at`'s own `persist_data_run_if_ready`, `sys/modules/oxfs`) — found live chasing
  real disk-I/O slowness while self-hosting bmake (see the bmake section above): every real
  `write()`/`close()` on a growing file used to persist (and real-`CACHE-FLUSH`) one block at a
  time even when the underlying physical blocks were genuinely contiguous, which a forward-only
  bump allocator (`NEXT_FREE_BLOCK`) makes the common case for a freshly-written file. Now tracks
  a pending contiguous run across the write loop and flushes it in one real batched command,
  falling back correctly (one run of length 1) whenever blocks genuinely aren't contiguous.
  Verified via `tests/mmap_syscall_smoke.rs` (all 15 parts, including real mtime/ctime and
  `MAP_SHARED` writeback) and `tests/oxfs_persistence_syscall_smoke.rs`.
- **Every internal mtime/ctime/atime stamp used to do a fresh raw CMOS hardware read** (real
  `sys/cpu/rtc.rs` `cmos_read`, 7+ separate trapped `out`/`in` port pairs) via
  `oxidebsd_unix_time()`, called on *every* oxfs write/touch — found the same session, real,
  avoidable overhead on a call this hot under QEMU's TCG. Fixed: uses `unix_epoch_now_precise()`
  (the same calibrated-once, `ticks()`-derived clock `sys_clock_gettime`'s own `CLOCK_REALTIME`
  already reads) instead — a real correctness fix too, not just speed, since a file's `st_mtime`
  and `time(NULL)` could previously disagree by however much the two independently-read clocks
  drifted apart. SysV IPC's own `stime`/`rtime`/`ctime`/`otime`/`dtime`/`atime` fields (`sys/fs/
  sysv_{msg,sem,shm}.rs`, called directly, not through `oxidebsd_unix_time()`) had the identical
  bug and got the identical fix, for the same reason `process::timers::abstime_to_ticks` already
  needed it (see that function's own doc comment — same bug class, found once before).
- **No raw block device is exposed to userland** — the disk is purely internal to oxfs's own
  persistence.
- Verified via `tests/ata_smoke.rs`, `tests/oxfs_persistence_syscall_smoke.rs`. **Not covered**:
  persistence surviving a real QEMU restart — manual only.
- **Operational gotcha**: mounting never re-syncs seeded content against the kernel's current
  embedded bytes — only a fresh *format* does. A fix to seeded content needs
  `target/oxfs_disk.img` deleted (destructive to anything created at the hush prompt — ask the
  user first) and reformatted on the next `cargo run`.

### 10.3. Mount table (`sys/modules/oxfs/`)

*(from CLAUDE.md, 2026-09-29)*

A real, but deliberately scoped, mount table — `mount --bind`/`mount -t tmpfs` only, not a general
pluggable-filesystem-type VFS.

- **A second, purely in-memory inode/block pool for tmpfs**: `BLOCKS`/`BLOCK_USED`/`INODES`
  extended with a tail region (`TMPFS_NUM_BLOCKS=1024`/`TMPFS_MAX_INODES=128`, 4 MiB). Block
  allocation picks the real vs. tmpfs pool via `inode_ensure_block_at`'s `inode_num >= MAX_INODES`
  test; new-inode allocation uses a shared `alloc_inode_in(parent)` chokepoint (found live: three
  call sites used to call plain `alloc_inode()` unconditionally, wrongly persisting tmpfs-created
  files to the real pool). Never reclaimed on unmount.
- **The mount table itself** (`MountEntry`/`MOUNTS`, `MAX_MOUNTS=8`): each entry records the real
  inode a mountpoint shadowed and where lookups redirect instead. `resolve_path_impl` checks
  `active_mount_for` right after each component's `dir_lookup`. Scanned LIFO.
  - Tmpfs mount root's `..` points at the mountpoint's real parent.
  - Bind mount reuses the source directory's own real inode directly — known limitation: `cd ..`
    from inside it follows the source's real parent, not the mountpoint's.
  - `st_dev` is `1` (real fs) or `2` (tmpfs pool) — a bind mount deliberately keeps `st_dev == 1`.
  - **The redirect only fires where `resolve_path_impl`'s per-component loop actually runs** —
    doesn't cover a handler using `resolve_parent` + its own bare `dir_lookup` (correct for
    `mkdir`/`symlink`'s EEXIST check, wrong for `open`'s "existing path" branch — found live,
    fixed for `oxfs_open` specifically).
- **`SYS_MOUNT_BIND=174`/`SYS_MOUNT_TMPFS=175`/`SYS_UMOUNT2=176`** — landed on real Linux's
  long-obsolete `create_module`/`init_module`/`delete_module` slots rather than continuing past
  `SYS_UTIMENSAT=167` (168-170 are real, live `swapoff`/`reboot`/`sethostname` numbers).
  `external/mit/musl/src/linux/mount.c` dispatches to one of these two based on `fstype`/`flags`.
- **`/proc/mounts`**: a local formatter produces mtab-shaped lines directly from mount-table state.
- Verified via `tests/mount_syscall_smoke.rs`. **Not covered**: a real block-device-agnostic mount
  table (`pivot_root`/`switch_root`), anything needing a real partition table.

### 10.4. Permission model (`sys/process/`, `sys/modules/oxfs/`, `sys/modules/posix_compat/`)

*(from CLAUDE.md, 2026-09-29)*

Real uid/gid, real per-inode `mode`/`uid`/`gid`, real `chmod`/`chown`, real `open()` permission
enforcement.

- `Process` gains `uid`/`gid` — no separate saved/effective pair. `0` at spawn; copied by fork;
  preserved by execve.
- Syscalls: `SYS_GETUID=158`/`SYS_GETEUID=159`/`SYS_GETGID=160`/`SYS_GETEGID=161`/
  `SYS_SETUID=162`/`SYS_SETGID=163`/`SYS_GETGROUPS=164` (`posix_compat`) and `SYS_CHMOD=165`/
  `SYS_CHOWN=166` (`oxfs`), plus real `fchmod` (`__NR_fchmod=91`, found via `uudecode`).
- **`do_setuid`/`do_setgid`**: real POSIX rule — root may become any uid/gid; anyone else may only
  "become" the uid/gid they already are (no-op success); any other target is `EPERM`.
- **`do_getgroups`** reports a single-element list (caller's own `gid`) — no supplementary-group
  concept.
- **`Inode` gains real `mode`/`uid`/`gid`** (default `FIXED_PERM=0o755`/`0`/`0`). A freshly
  **created** file is owned by its real creator (`OpenFile::Write` gained `owner_uid`).
- **`check_access(inode, uid, gid, want_write)`**: `uid==0` bypasses rwx bits entirely; otherwise
  picks owner/group/other by comparing against the inode's own `uid`/`gid`. Wired into
  `oxfs_open`; `do_execve`'s ELF-loading read goes through this same path (approximate execute
  check).
- **Real write-to-an-existing-file support**: `OpenFile::Write` gained `existing_inode: Option<u32>`
  — `None` is create-new (fresh inode + dir entry at close); `Some(inode)` overwrites in place.
  `O_APPEND` preloads the write buffer with existing content. This filesystem's write primitive
  always replaces a file's complete contents in one shot. Opening a directory with
  `O_WRONLY`/`O_RDWR` is a real `EISDIR`.
- **`oxfs_chmod`**: owner or root only; follows a final symlink. **`oxfs_chown`**: root-only
  unconditionally; supports real POSIX `(uid_t)-1`/`(gid_t)-1` "leave unchanged"; follows a final
  symlink (`lchown` unimplemented).
- **`oxidebsd_current_uid`/`_gid`** (exported to modules) — how oxfs learns the caller's identity.
  `pid == 0` reports root.
- **`/etc/passwd`/`/etc/group`** seeded with `root:x:0:0:root:/:/bin/sh` and (see "Session..."
  below) a real second user. musl's own `getpwuid`/`getpwnam`/`getgrgid`/`getgrnam` parse these
  directly.
- **Real hard links**: `Inode::nlink`. `oxfs_link` follows symlinks, rejects directories (`EPERM`)
  and cross-pool links (`EXDEV`). `oxfs_unlink` decrements `nlink` (still never actually freed).
- **Real device nodes**: `InodeKind::Device`, `Inode::rdev`/`device_char`. `mknod` creates a real,
  listable inode; `oxfs_open`'s `Device` dispatch only services major:minor pairs matching the
  four `/dev/{random,urandom,null,zero}` devices — any other is `ENXIO`. Root-only.
- **Real per-process `chroot`**: `Process::root_inode: u64` mirrors `cwd`'s design (`0` = never
  chrooted). `resolve_path_impl` gains a `root_inode` parameter for containment. Root-only.
- Verified via `tests/uid_syscall_smoke.rs`, `tests/needs_syscall2_smoke.rs`. **Not covered**:
  mutating `/etc/passwd`/`/etc/group` (applet-level gap), `lchown`/setuid/setgid/sticky bits.

### 10.5. The `*at()` family (`sys/modules/oxfs`, `sys/process/lifecycle.rs`, `external/mit/musl`)

*(from CLAUDE.md, 2026-09-29)*

Every `*at()` call musl can issue: `openat`/`mkdirat`/`mknodat`/`fchownat`/`newfstatat`/`unlinkat`/
`renameat`/`linkat`/`symlinkat`/`readlinkat`/`fchmodat`/`faccessat`/`utimensat`/`renameat2` =
`560`-`573` (oxfs), `execveat` = `574` (`native_abi`). Not done: `statx` (musl falls back to
`fstatat`), `name_to_handle_at`/`open_by_handle_at`, `RENAME_EXCHANGE`/`RENAME_WHITEOUT` (`EINVAL`).

- **Wire format**: each `(dirfd, path)` is a pointer to `{dirfd: i64, ptr, len}` in caller memory
  (`RawAtPath` / musl `src/internal/oxidebsd_at.h`) -- `linkat`/`renameat2` can't fit 2 dirfds + 2
  length-prefixed paths + flags in 4 registers. `ptr == 0` is a real NULL path (`futimens`).
- **Kernel design**: single-base calls set `AtBaseGuard` (a static override of `current_cwd()`) and
  delegate to the plain handler, so `/proc`, mounts and chroot behave identically; relies on
  syscalls being uninterruptible on one core (SMP breaks it, like the stdin ring lock). `link`/
  `rename` take both bases explicitly (`link_impl`/`rename_impl`).
- `execveat` pre-reads the image via `SYS_OPENAT`, or `pread` on the fd (`fexecve`). A `#!` script
  reached through a dirfd/fd is `ENOENT` -- no `/dev/fd/N` to hand the interpreter.
- `SYS_UTIMENSAT=167` (path-only) stays for `lib/oxlibc`'s `touch`; musl's `utimensat` name now
  maps to `572`.
- **Real bugs found/fixed alongside**: `open()` ignored `O_DIRECTORY`/`O_NOFOLLOW`; `rename(a, a)`
  lost the entry (`EIO`); musl's `fstatat`/`remove`/`tmpfile`/`tmpnam`/`tempnam` passed upstream
  arg shapes to this ABI's length-prefixed handlers; `lchown`/`fchown`/`futimens`/`utimensat(dirfd)`
  were always `ENOSYS`; `execve` with a garbage argv length **panicked the kernel** (unbounded
  allocation) -- now a 2 MiB total `E2BIG` cap (`MAX_EXEC_ARG_BYTES`); `sys/boot/multiboot2.rs`'s
  `global_asm!` never restored its section, so a CGU reshuffle put the syscall entry stub in
  `.boot32.text` (`multiboot2-boot-smoke` link failure) -- now `.pushsection`/`.popsection`.
- `rename` follows POSIX since 2026-09-24: permission checks, `..` rewritten on reparent, `EINVAL`
  into own subtree, a directory may replace only an empty directory.
- Verified: `tests/at_syscall_smoke.rs` (`regress/at-smoke/main.c`, real musl API, PASS/FAIL per
  check) and `std::filesystem::remove_all` in `tests/clangxx_syscall_smoke.rs`.

### 10.6. Filesystem and IPC gaps, as recorded in the conformance checklist

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

- [ ] **`fcntl` POSIX record locking**: `F_SETLK`/`F_SETLKW`/`F_GETLK` — confirmed absent
      (`SYS_FCNTL`'s current handler only covers `F_GETFL`/`F_SETFL`(`O_NONBLOCK`)/`F_SETFD`(no-op)/
      `F_DUPFD`/`F_DUPFD_CLOEXEC`). **This is distinct from the `flock(2)` support that already
      exists** (`SYS_FLOCK`, a real per-inode `LOCK_SH`/`LOCK_EX`/`LOCK_UN` advisory table) — flock
      is a BSD extension, not POSIX; POSIX itself mandates the `fcntl`-based locking API. A real
      conformance suite tests `fcntl` locking specifically, and `flock`'s existing "conflicting
      request fails `EAGAIN` immediately even without the non-blocking flag, no scheduler-yield
      primitive reachable from a module syscall handler" limitation (see CLAUDE.md) would need
      solving here too for `F_SETLKW`'s real blocking semantics.
- [ ] **FIFOs** (`mkfifo(3)`, `S_IFIFO` nodes): confirmed still `EINVAL` in `mknod` (`modules/
      oxfs`). A real base POSIX interface, and the one BusyBox subsystem this doc's own gap-table
      already flagged as blocked on it (the `runit` family — `runsv`/`runsvdir`/`svlogd`/`svok` —
      was cut from the roster specifically for lacking this). Backing is plausible reuse of
      `src/fs/pipe.rs`'s existing blocking-buffer machinery, opened via a real path instead of
      `pipe(2)`'s anonymous fd pair.
- [ ] **Named POSIX semaphores** (`sem_open`/`sem_close`/`sem_unlink`) and **POSIX shared memory**
      (`shm_open`/`shm_unlink`) — **unnamed semaphores are no longer blocked** (real
      `sem_init`/`sem_wait`/`sem_post`/... work today, see "Real threading" above, now fully done —
      not just phases 1-3). Named ones remain blocked on two things, not one, and **real thread
      creation landing doesn't change either**: a `/dev/shm`-style `open`+`mmap` path (plausible
      reuse of the already-real fd-backed `MAP_SHARED` mmap, see CLAUDE.md), *and* real
      cross-process `FUTEX_WAKE` — `process::do_futex`'s own wake scan is deliberately scoped to
      the waker's own `tgid` (see that function's own doc comment for why address-only keying would
      be unsafe with no ASLR), so a named semaphore shared between two genuinely different
      *processes* (as opposed to threads sharing one `tgid`, which now works) wouldn't actually
      wake across them yet even with the mmap path solved. SysV shared memory/semaphores already
      exist and are *not* a substitute — POSIX treats the two IPC families as genuinely separate
      optional interfaces.
- [x] **POSIX AIO** (`aio_read`/`_write`/`_fsync`/`_error`/`_return`/`_cancel`/`_suspend`,
      `lio_listio`) — real threading (the actual blocker) is now done, see above. On real
      Linux/musl these `aio_*` functions are pure userspace logic over a `pthread_create` worker
      thread pool, not a true syscall gap, so **no further kernel-side work is needed for AIO
      itself** — this row is closed as "unblocked," not yet separately verified with a dedicated
      AIO-specific smoke test (a natural next real step, not a kernel gap).

### 10.7. devfs: why `/dev` was rebuilt

*(from DEVFS.md, cut 2026-10-01)*

…document records the design. It follows FreeBSD, whose `devfs` it is modelled on; NetBSD and
OpenBSD still create static nodes with `MAKEDEV`, which is what OxideBSD had and what failed
(below).

**Rationale.** Until now every node in `/dev` but four was an ordinary oxfs inode created once,
when the disk was formatted. A mount never created them again, so `rm /dev/fb0` removed the
framebuffer for good, surviving every reboot (issue #1). The four exceptions (`null`, `zero`,
`random`, `urandom`) were intercepted by name before path lookup. Device handling was split
between oxfs (those four and `fb0`) and the kernel (terminals, `klog`), by device number.

…registered. oxfs's own table of known devices, and the interception of the four names, are
removed; oxfs registers the devices it implements (`null`, `zero`, `random`, `urandom`, `fb0`)
like any other driver.

### 10.8. Filesystem layout (OxideBSD-doc `HIER.md`)

*(from CLAUDE.md, 2026-09-29)*

oxfs seeds the BSD hierarchy HIER.md defines, not a flat `/bin`: `/bin` (44, single-user
essentials) / `/sbin` / `/usr/bin` (clang, ld.lld, bmake, nano, ninja, most applets) / `/usr/sbin`
/ `/usr/libexec/getty` / `/usr/games/doom` / `/usr/tests` (regress fixtures: `musl`, `smoke`,
`std-*`). Clang's resource dir follows the binary: `/usr/lib/clang/23`. Root PATH (pid 1, POSIX
driver) is `/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/games` (the POSIX driver omits `/usr/games`). 48 BusyBox applets were
cut outright (2026-09-23); `build_busybox.rs` no longer carries the native-utility/`vi` tuples, so
there's no roster filter any more. Older sections below still say `/bin/clang` etc.

*(from HIER.md, cut 2026-10-01)*

Where each program in the base system is installed, and the BusyBox applets taken out of it. A
working list, not a specification: the rules for where things go, and every directory, are in
`hier(7)` (`share/man/man7/hier.7` in the OxideBSD tree, and on the website's manual pages).

This is the seeded layout (2026-09-23). The source tree mirrors it, except for the BusyBox
applets, which all build from `external/gpl2/busybox`. Added since, among others: `/usr/bin/openssl`
and `/usr/sbin/certctl` (2026-09-30).

`sh` is OxideBSD's own shell (`lib/libsh`); `hush` is BusyBox's, still pid 1 and the interactive
shell until `sh` has an interactive mode. `touch` is here (not `/usr/bin` as on FreeBSD) because
it's one of the native `bin/` utilities.

Missing and needed here: `reboot`, `init`, `rcorder`, `shutdown`, `ifconfig`/`route` (OxideBSD's
own, once the kernel has interface-configuration ioctls), `fsck` (when oxfs gets one).

#### Removed 2026-09-23

48 BusyBox applets that don't belong in a BSD base system or can't work on this kernel:

- Foreign or decorative: `dpkg`, `dpkg-deb`, `rpm`, `rpm2cpio`, `bash`/`bash_ash` (aliases for
  hush/ash), `bbconfig`, `nuke`, `unit-test`, `bootchartd`.
- Mail, print and network daemons, never verified here: `sendmail`, `popmaildir`, `makemime`,
  `reformime`, `lpd`, `lpq`, `lpr`, `fakeidentd`, `ftpd`, `telnetd`, `httpd`, `inetd`, `tcpsvd`,
  `udpsvd`, `dnsd`, `dhcprelay`, `udhcpd`, `dumpleases`, `rdate`.
- Linux hardware and `/proc` tools: `lspci`, `lsusb`, `lsscsi`, `powertop`, `smemcap`, `nmeter`,
  `mpstat`, `iostat`, `pmap`, `taskset`, `adjtimex`, `hwclock`, `rtcwake`, `vconfig`.
- Linux network configuration (Linux `SIOC*` ioctls): `ifconfig`, `ifdown`, `route`, `arp`,
  `arping`.

The naming bugs listed here before (`run`, `start`, `remove`, `unit`, `dpkg_deb`) are fixed or
gone: the build now names applets `run-parts`, `start-stop-daemon` and `remove-shell`.

#### Removed 2026-09-30

45 more BusyBox applets, listed with the reasons in `BUSYBOX_APPLETS.md` ("Third cut"),
including `/bin/hush`, `/usr/sbin/crond` and BusyBox's `/usr/bin/crontab` (now native).
`/sbin` gained `init`, `nologin`, `reboot` (+ `halt`, `poweroff`), `rcorder`, `shutdown` and
`emergency` since the list below was made; `/usr/sbin` gained `cron`, `periodic` and `syslogd`.

## 11. Time and clocks

### 11.1. Real-time clock (`sys/modules/clock/`, `sys/cpu/pit.rs`, `sys/cpu/rtc.rs`, `sys/cpu/hpet.rs`)

*(from CLAUDE.md, 2026-09-29)*

`SYS_CLOCK_GETTIME=138` — real `clock_gettime(2)` wire format; `time()`/`gettimeofday()` are
wrappers around it.

- **`sys/cpu/pit.rs`** reprograms PIT channel 0 to a fixed `TIMER_HZ=100` at boot — the
  scheduler's own tick, untouched by anything below.
- **`sys/cpu/rtc.rs`** reads the CMOS RTC. `CLOCK_MONOTONIC` converts `ticks()` against
  `TIMER_HZ`. **Real sub-second `CLOCK_REALTIME`** (`unix_epoch_now_precise`) calibrates a fixed
  `ticks() -> real seconds` offset against the RTC once, then derives every later reading from
  `ticks()`.
- **`SYS_NANOSLEEP=139`** — converts to an absolute wake-up tick deadline, blocks, woken by the
  timer IRQ. **Real signal-interrupts-sleep**: checks `pending_signals & !blocked_signals` before
  each re-block, returns `EINTR` with real remaining time. **Only counts a signal that will
  actually invoke a handler or terminate** (`process::signals::has_interrupting_signal`) — a
  default-`Ignore` signal like `SIGCONT`/`SIGCHLD` must not spuriously interrupt a blocking call;
  the same bug shape (claiming to filter by disposition but not actually doing it) existed at 9
  call sites total (`do_pause`, `do_sigsuspend`, `do_clock_nanosleep`, `do_mq_timedsend`/
  `_timedreceive`, two `FUTEX_WAIT` check sites, `oxidebsd_sys_select`, this one) — fixed
  uniformly. Deliberately doesn't apply to `sigwait`/`sigtimedwait` (bypass disposition by design)
  or the preemption-redirect-to-trampoline check (not a userspace `EINTR` decision).
- **`sys/cpu/hpet.rs` — a real ACPI HPET, but a counter-only sub-tick *overlay*, never an interrupt
  source and never a PIT replacement.** This kernel has no IOAPIC/MSI support, so a real
  interrupt-driven comparator would mean stealing IRQ0 from the PIT — rejected. Instead, a POSIX
  timer's overrun count is computed as exact `elapsed_ns / interval_ns` "catch-up" arithmetic
  (same technique real Linux's `hrtimer_forward()` uses), read at whatever cadence already polls
  (the 100Hz tick) — needed since `TIMER_HZ=100`'s 10ms tick can't represent a 5ms interval.
  Discovered via Limine's real RSDP → XSDT/RSDT → `"HPET"` table walk (`boot::rsdp_address`,
  checksummed, `NO_CACHE`-mapped). Absence at any step is logged, never fatal — every caller has
  an honest tick-based fallback. `sys_clock_getres` reports HPET resolution for
  `CLOCK_REALTIME`/`CLOCK_MONOTONIC` when present; cputime clocks always stay tick-quantized.
  `do_nanosleep` gained a real HPET top-off after the tick deadline passes (bounded, capped at 50
  ticks/500ms) since PIT `ticks()` can measurably lag a directly-read HPET counter by a few ms
  under KVM. **Known, accepted drift**: PIT and HPET are independently clocked with no
  cross-calibration, and their relative *rates* measurably diverge over several minutes of
  sustained guest uptime — a real-time overrun test that passes in isolation can fail deep into a
  long continuous boot; not chased further (would need periodic recalibration).

### 11.2. Time zones (init work plan step 8)

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

As planned. Settled in the code: zic/zdump are static at fixed bases (`0x11000000`,
`0x12000000`), since musl's `libc.a` isn't PIC and static PIE for C would need a musl rebuild;
zdump links tzcode's own `localtime.c` (musl has no `tzalloc`/`localtime_rz`). tzsetup's menus
show each zone as `City (Country: comment)`. Since the musl batch after it (below), zic, zdump
and the C fixtures are static PIE, and running programs follow a changed `/etc/localtime` by
themselves (§5.4 rewritten), so no program reloads the zone on `SIGHUP`.

The original plan:

- Vendor IANA tzdata + tzcode at `external/public-domain/tz`; build `zic` for the host, compile
  the zones, seed `/usr/share/zoneinfo`; build `zic`/`zdump` for the target; `usr.sbin/tzsetup`
  (Rust).
- oxfs's inode count is no longer fixed (`475e995`, `13113f8`), so the zones' ~600 files need
  no layout change.
- Running programs follow a changed zone (TIMEZONE.md §5.4, the musl batch).
- Test: `tz_syscall_smoke`.

*(from TIMEZONE.md, cut 2026-10-01)*

…(This
replaces an earlier requirement that `syslogd` and `cron` re-read the zone on `SIGHUP`.)

## 12. Networking

### 12.1. Real networking (`sys/drivers/{pci,rtl8139}.rs`, `sys/net/*`, `sys/netinet/*`, `sys/modules/socket/`)

*(from CLAUDE.md, 2026-09-29)*

BSD layout: interfaces/Ethernet in `sys/net`, IPv4/ARP/ICMP/UDP/TCP in `sys/netinet`, the NIC
driver in `sys/drivers`, the socket layer in `sys/kern/uipc_socket.rs` (OxideBSD-doc `UNIX.md`).
**Socket layer**: `SOCKETS` maps a socket's `real_fd` to its `&'static dyn Protocol` (UDP, TCP,
raw ICMP; BSD `protosw`); each protocol keeps its own state keyed by the same `real_fd`. Every
socket syscall (incl. `socketpair`/`shutdown`, now in `sys/modules/socket`, not `posix_compat` --
a test using them must load the socket module) resolves and dispatches there; addresses cross as
`sockaddr` bytes. **Local sockets** (`AF_UNIX` stream/dgram/seqpacket, `sys/kern/uipc_usrreq.rs`):
path names are oxfs `InodeKind::Socket` inodes made/looked up through callbacks oxfs registers
(`oxidebsd_register_socket_nodes`), mapped inode -> socket kernel-side; abstract names and autobind
too; `socketpair` is built on them (the pipe-backed pair is gone). Descriptor passing: a message holds
its `SCM_RIGHTS` descriptions (`fs::fd::hold`/`release`/`install_held`), a mark-and-sweep `gc` runs
when an in-flight description loses a descriptor; credentials via `LOCAL_PEERCRED`/`SO_PEERCRED`/
`getpeereid`/`SCM_CREDS`/`LOCAL_CREDS[_PERSISTENT]`/`SO_PASSCRED` (`SOL_LOCAL` = 0x200, not FreeBSD's 0).
All data goes through `sendmsg`/`recvmsg` (577/578, a real `struct msghdr`); musl's `sendto`/
`recvfrom` are built on them, and `get/setsockopt` (579/580) take `{level, name, val, len}` by
pointer (`musl src/internal/oxidebsd_sockopt.h`). A protocol never blocks: it returns `EAGAIN`
and the layer waits (`O_NONBLOCK`/`MSG_DONTWAIT`/`SO_RCVTIMEO`, `ERESTART` for `SA_RESTART`) via
`net::wait_for_change`, which *blocks* (interrupts on) -- network waiters wake on an rtl8139
IRQ (`wake_pollers`) or every 50 ms to drive the NIC. `regress/socket-smoke` +
`tests/socket_syscall_smoke.rs` cover the layer. **rtl8139's DMA addresses are 32-bit**:
`rtl8139::init` must run before big allocations (oxfs's pools), else it refuses (logged) --
found when a test brought it up after the modules and it silently received nothing.

Real, phased stack: PCI enumeration, IRQ-driven rtl8139 driver, Ethernet/ARP/IPv4/ICMP, UDP/TCP
sockets, raw ICMP sockets, `poll(2)`, and real hostname resolution via musl's own stub resolver.

- **`sys/drivers/rtl8139.rs`**: brought up unconditionally at boot, absence logged not fatal.
- **`ipv4::next_hop`** is the *only* routing rule (anything outside `GUEST_IP`'s `/24` → gateway).
- **`sys/netinet/udp.rs`/`tcp.rs`**: UDP (with `connect`) and TCP (non-blocking `connect`,
  `shutdown`, `TcpState::errors` for `SO_ERROR`) as socket-layer protocols. TCP is
  stop-and-wait (one segment in flight, fixed 536-byte MSS, no window/congestion control).
- **`sys/netinet/icmp.rs`** raw sockets: not port-addressed, every inbound ICMP fans out to every open
  raw socket.
- **`SYS_POLL=148`**/`SYS_SELECT`: real `POLLIN`/`POLLOUT`/`POLLHUP`/`POLLERR` per fd
  (`fs::Readiness`: pipes, console, TCP; files always ready) and `EINTR`. Waits on pipes/console
  block as `BlockReason::Polling`; waits involving a socket yield instead (the NIC is pull-based).
- **Real DNS resolution**: `/etc/resolv.conf` seeded with SLIRP's DNS relay.
  `recvmsg`/`sendmsg` delegate to `recvfrom`/`sendto` for the single-iovec shape musl's resolver
  actually uses.

**Architectural gotchas, apply to any future syscall-reachable busy-wait**:
1. **QEMU needs `-accel kvm -accel tcg`** (two repeated flags) in both `run-args`/`test-args`, or
   every boot runs pure-software TCG (can stretch boot past a minute under host load).
2. **`hlt()` inside a syscall handler can freeze the CPU permanently.** `SFMASK` clears `IF` for a
   syscall's entire duration — no timer tick can fire to advance `ticks()` either. Any
   syscall-reachable retry loop must use `core::hint::spin_loop()`, never `hlt()`, gated on
   **`sys/cpu/tsc.rs`** (`RDTSC`-based, immune to `IF`) — **never `crate::interrupts::ticks()`**,
   frozen for a syscall's whole duration. Current spin-loop-with-tsc-deadline sites:
   `ipv4::resolve_with_retry`, `tcp::oxidebsd_sys_connect`, `net::oxidebsd_sys_poll`. **Invisible
   to any test calling kernel handlers as plain Rust functions instead of through a real
   `SYSCALL`.**
3. **Superseded (2026-09-28)**: socket waits used to spin (so no timer or `alarm` fired during
   them); they now block with periodic/IRQ wakeups (the socket-layer note above). Real EOF (`0`)
   only once the peer has actually FIN'd.

Real-`SYSCALL` smoke tests exist for every scenario (`tests/{udp,poll,ping,socketpair,
tcp}_syscall_smoke.rs`), using test-only syscalls (`SYS_TEST_EXIT=9999`,
`SYS_TEST_INJECT_UDP_FRAME=9998`, `SYS_TEST_TCP_STEP=9997`).

**Other real pieces landed for this stack**: `alarm()`/`setitimer()` (`SYS_SETITIMER=156`/
`SYS_GETITIMER=157`, `sys/modules/clock/`, only `ITIMER_REAL`, expiry only sets `pending_signals`, not
inherited by fork); `socketpair` (`SYS_SOCKETPAIR=149`, now on local sockets); getting `wget` HTTPS working needed five further fixes in sequence:
`SYS_SET_TID_ADDRESS=150`, `SYS_FCNTL=151` (`F_GETFL`/`F_SETFL(O_NONBLOCK)`/`F_SETFD`/`F_DUPFD*`),
`SYS_SHUTDOWN=152` (real half-close for a pipe-backed socketpair only), a synthetic
`/dev/{u}random,null,zero` path backed by **`sys/random.rs`** (a real
SHA-256-seeded ChaCha20 generator gathering `RDTSC`/PIT/RTC/`RDRAND`/`RDSEED` when available, plus
a persistent `ENTROPY_POOL` folding real IRQ-timing jitter from keyboard/rtl8139 handlers —
`RDRAND`/`RDSEED` are distrusted whenever `running_under_hypervisor()` is true, since a hypervisor
can trap and fake either instruction undetectably; both crates need soft-float-equivalent backend
flags for this SSE-disabled target), and `SYS_READV=153`; plus a real `tcp_read` EOF-vs-empty fix.
No real routing table, no IPv6 anywhere. BusyBox's vendored TLS client doesn't validate certificate
chains (a limitation of that vendored code, not fixable kernel-side).

### 12.2. The socket-layer rework: what it replaced

*(from UNIX.md, cut 2026-10-01)*

1.4. A socket system-call interface that carries every argument POSIX defines, replacing the
reduced forms in use today (§4).

| Path | Role |
|---|---|
| `sys/drivers/rtl8139.rs` | The network interface driver (moved from `sys/net/`) |
| `sys/modules/socket` | Registers the socket system calls, for every family (renamed from `sys/modules/net`) |

**Rationale.** Today each socket call walks a fixed chain (UDP, then TCP, then ICMP) and the C
library drops arguments the system calls cannot carry. A protocol switch is how every BSD kernel
structures sockets; it makes a new family a table entry instead of another link in the chain.

…connected to each other. It replaces the pipe-based pair in `sys/fs/pipe.rs`, which is removed.

### 12.3. Sockets stages 3-5: local sockets, descriptor and credential passing, manual pages

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

#### Stage 3: local sockets (`38bbcb4`)

As planned, with these details settled in the code: oxfs registers one pair of callbacks
(`oxidebsd_register_socket_nodes(create, lookup)`), each `(path_ptr, path_len) -> inode | -errno`;
the kernel keys sockets by inode number alone (inode numbers are unique across oxfs's pools). No
`SUPERBLOCK_VERSION` bump: the socket kind is a new code in the existing kind byte. `mknod(2)` with
`S_IFSOCK` stays `EINVAL`, as in FreeBSD. Stream control-data attachment (§6.4) waits for stage 4:
the receive queue is already a list of messages, so a message carrying control data will simply
not be merged into.

A disk image formatted before stage 2's musl change still holds BusyBox binaries that call the
retired syscall 142; delete `target/oxfs_disk.img` to reseed.

#### Stage 4: descriptors and credentials

As planned. Settled in the code: `SOL_LOCAL` is 0x200 and `LOCAL_PEERCRED`/`LOCAL_CREDS`/
`LOCAL_CREDS_PERSISTENT` are 0x1001-0x1003 (FreeBSD's 0 and 1-3 collide with `SOL_IP` and `SO_*`
in musl); `SCM_CREDS`/`SCM_CREDS2` keep FreeBSD's 3 and 8. A peek shows credentials but leaves
descriptors in the message. `gc` also runs when a descriptor of an in-flight description is
closed (a socket sent over itself is never destroyed otherwise). Once a socket's own descriptors
are gone nobody can read its queue, so it's garbage even while its peer is open.

#### Stage 5: manual pages (`60d0b7f`)

mdoc pages in `share/man` (lint clean with `oxdoc -T lint`): `unix.4`, `socket.2`, `sendmsg.2`
(and `send`/`sendto` links), `recvmsg.2`, `getsockopt.2`, `getpeereid.3`, `accept.2`, `bind.2`,
`connect.2`, `listen.2`, `shutdown.2`, `socketpair.2`. Seed them in oxfs (`man_man2`/`man4` need
`ensure_dir`s, as `man3` got for `sysctl.3`); `build_man_index` picks them up. Mark `UNIX.md`
implemented (its status line, `Status: **...**`), which the website's spec index shows.

Document what the code settled that the spec doesn't say: `SOL_LOCAL` 0x200 and `LOCAL_*`
0x1001-0x1003; `SCM_CREDS` 3 / `SCM_CREDS2` 8; a peek shows credentials but not descriptors;
`read(2)` on a socket closes descriptors it can't return; `CMSG_SPACE` padding counts as room
(a `CMSG_SPACE(sizeof(int))` buffer takes two descriptors, as on Linux); autobind names are five
hex digits. `oxdoc` lints on the host: `cd lib/liboxdoc && cargo build --release --bin
oxdoc-host`, then `target/x86_64-unknown-linux-gnu/release/oxdoc-host -T lint PAGE` (the
`usr.bin/oxdoc` crate builds for OxideBSD only).

### 12.4. OpenSSL 3, the trust store, dynamic Rust programs, loopback, syslog over TCP and TLS (init work plan step 6)

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

- Vendor OpenSSL 3.5 LTS (`openssl-3.5.9`) as a submodule at `external/apache2/openssl`, on an
  upstream release tag with no patches (decided 2026-09-29). The `oxidebsd-x86_64` Configure target
  lives in our tree and is loaded with `Configure --config=`. `build.rs`: static PIE via musl-gcc,
  `no-shared no-dso no-afalgeng no-ktls` (musl-gcc defines `__linux__`, so OpenSSL takes its Linux
  paths), `OPENSSLDIR=/etc/ssl`; install `libssl.a`/`libcrypto.a`/headers into the sysroot, seed
  `/usr/bin/openssl` and `/etc/ssl/openssl.cnf`. Stamp it like the LLVM builds.
- asm on. The kernel saves only FXSAVE state (no XSAVE), so OpenSSL's OSXSAVE check must keep it
  off AVX; the smoke test confirms that.
- **Done (`d2551f6`)**, dynamically linked rather than static: `libcrypto.so.3`/`libssl.so.3`, the
  legacy provider as a `dlopen`ed module, a PIE `/usr/bin/openssl`, static archives too. Needed
  first: biased load of dynamically linked PIEs (`f9fb253`), one musl build for `libc.a` and
  `libc.so` (`e40cc9f`), file `mmap` at a nonzero offset and the oxfs `shm` inode flag (`026e9ba`).
  `tests/openssl_syscall_smoke.rs` covers it.
- `regress/openssl-syscall-smoke`: KATs (SHA-256, AES-GCM, RSA/ECDSA, `RAND_bytes`) and a TLS 1.3
  handshake over an in-process memory BIO pair (no loopback, no Perl on target).
- Trust store: vendor Mozilla NSS `certdata.txt` (MPL-2.0), split at build time into
  `/usr/share/certs/{trusted,untrusted}/*.pem`, honouring its trust/distrust bits (as FreeBSD's
  `secure/caroot`). `usr.sbin/certctl` (Rust std, `certctl(8)` mdoc page): `rehash`, `list`,
  `untrust`, `trust`, writing `<subject-hash>.N` links in `/etc/ssl/certs` and `/etc/ssl/cert.pem`.
  **Done (`31c5c69`, `d33a27d`)**: NSS 3.130, 121 roots; the logic is `lib/libcertstore` (pure
  Rust, OpenSSL's subject hash reimplemented and checked against the host's `openssl`), shared by
  `certctl` and `build.rs`, which seeds `/etc/ssl` at build time. Distrust-after dates aren't
  enforced (as FreeBSD).
- **Before `openssl-sys`: Rust programs become dynamic PIEs** (decided 2026-09-30), so they link
  `libssl.so.3` like `/usr/bin/openssl`. `x86_64-unknown-oxidebsd`: `crt-static-default` off, PIE
  on. The unwinder is `/lib/libgcc_s.so.1` built from LLVM libunwind (+ compiler-rt builtins), as
  on FreeBSD. pid 1 (`/sbin/init_sh`) stays a static PIE (FreeBSD's `NO_SHARED` init), everything
  else dynamic. Shared libraries `/bin` and `/sbin` need move to `/lib`: `/lib/libc.so` (the real
  file, `ld-musl-x86_64.so.1` beside it), `/lib/libgcc_s.so.1`; `/usr/lib/libc.so` a symlink.
  **Done (`a9b8d5b`, `ab98faf`)**. pid 1 is `/bin/sh` (kernel-embedded), so it and
  `/sbin/emergency` are the static ones; `init_sh` is dynamic. Needed `--eh-frame-hdr` in
  musl-gcc (musl `27a3d66f`) for unwinding through shared libraries.
- Rust binding for syslogd: the `openssl` crate against the sysroot. **Done (`d346cb0`)**:
  `openssl-sys` needs no patch, just `OPENSSL_DIR` and `CC_x86_64_unknown_oxidebsd`; it links the
  shared libraries. `regress/std/openssl-rs-smoke` covers it (TLS 1.3 over a `UnixStream` pair).
- syslogd: RFC 6587 framing, `@@host`, `tcp_server`; RFC 5425 with `@[host]:port(...)`, the
  `tls_*` options, verification, queueing and reconnect (§8.5). Decided 2026-09-30: all in the
  existing single `poll(2)` loop, as the BSDs do (non-blocking sockets, OpenSSL's
  `WANT_READ`/`WANT_WRITE`), no threads; and **a loopback interface first** (`lo0`,
  `127.0.0.0/8`), so the on-target test runs two syslogds on one machine.
  **Done (`b07c19d`)**: `usr.sbin/syslogd/src/net.rs`; host tests of two syslogds (TCP, queue and
  reconnect, TLS with a test CA, a pinned fingerprint, rejections), and on target over lo0.
- Loopback plan: a small BSD-style interface layer (`sys/net/if.rs`): `lo0` (127.0.0.1/8) and
  `re0` (the rtl8139, 10.0.2.15/24), a route lookup (loopback for 127/8 and our own addresses,
  the connected subnet, the default gateway) that picks the interface, next hop and source
  address; `sys/net/if_loop.rs` queues looped packets, drained by `net::poll` with the waiters
  woken as the NIC's interrupt does. Sockets gain a real local address: `bind` to a local address
  or `INADDR_ANY` (else `EADDRNOTAVAIL`), TCP demultiplexes on the full 4-tuple, a listener bound
  to 127.0.0.1 only hears loopback, `getsockname` reports the real address. IPv4 drops
  127/8 arriving on re0. `/etc/hosts` with `localhost`. No interface ioctls yet (ifconfig later).
  **Done (`c22d920`)**; the Ethernet interface is `rl0` (FreeBSD's name for the rtl8139). Also
  fixed there: TCP dropped data still buffered at `close()`.
- Open: `SYSLOG.md` §13 (beyond the trust store above).

## 13. USB and drivers

### 13.1. USB input: xHCI + HID boot-protocol keyboard (`sys/drivers/usb/`, `sys/drivers/pci.rs`, `sys/cpu/interrupts.rs`)

*(from CLAUDE.md, 2026-09-29)*

This kernel's first real-hardware (not just QEMU) boot target is a Surface Pro, which has no PS/2
controller at all — this closes that gap. `sys/drivers/usb/xhci.rs` is the xHCI host-controller
driver (register access, command/event rings, device-slot enable/address/configure); `hid_keyboard.rs`
is a HID **Boot Protocol** keyboard on top of it (no general HID Report Descriptor parsing); `mod.rs`
ties both together and exposes `init`/`poll`.

- **Polling, not IRQ-driven, deliberately** — matches `drivers::ata`'s own established
  polling-only precedent. This kernel has no IOAPIC/MSI support, and legacy PCI `INTx` routing on
  a modern UEFI-only chipset is a real, unquantified risk not worth taking for a few ms of
  keystroke latency. `usb::poll()` runs once per timer tick, draining the shared Event Ring.
- **32-byte device contexts only** (`HCCPARAMS1.CSZ == 0`) — what QEMU's `qemu-xhci` and the
  overwhelming majority of real platforms use. `CSZ == 1` is logged and treated as unsupported.
- **A real bug found live, not by spec-reading**: an early version trusted the boot loader's HHDM
  to cover the xHCI BAR's physical range unconditionally. **Wrong for a 64-bit BAR** — a real boot
  under OVMF (UEFI) placed `qemu-xhci`'s BAR0 at physical `0x800000000` (32 GiB) — real firmware
  parks large/64-bit BARs in a high MMIO window the HHDM's own "at least 4 GiB" guarantee doesn't
  reach. Fixed with a real, explicit two-phase mapping (`map_bar_pages`, `NO_CACHE`): map one page
  first (enough to read Capability registers and learn the real needed extent), then map however
  many pages that turns out to be. Confirmed on both BIOS and UEFI boots before landing.
- **Real BIOS/SMM-to-OS ownership handoff** (USB Legacy Support Capability, walked via
  `HCCPARAMS1.xECP`) — real Intel platforms (this project's own hardware target's chipset
  included) can leave the controller SMM-owned by default; QEMU doesn't implement this capability
  at all, so this path is untested by QEMU, only exercised on real hardware.
- **`drivers::pci::PciDevice::mem_bar` gained real 64-bit BAR-pair merging** (bits `2:1 == 0b10`,
  BAR `n+1` holds the high 32 bits) — the old 32-bit-only version silently truncated it.
- **Reuses `cpu::interrupts`'s existing PS/2 decode pipeline wholesale, not a second
  implementation.** `keyboard_interrupt_handler`'s post-decode logic is factored into
  `handle_decoded_key`, called by both the real PS/2 IRQ handler and a new
  `feed_synthetic_scancode` entry point `hid_keyboard` calls per synthesized PS/2 Scan Code Set 1
  byte. Shift state, Caps Lock, signal interception, and echo all come along for free.
  `feed_synthetic_scancode` never touches the PIC — only the real IRQ handler sends EOI.
- One keyboard device for v1, no hot-plug, US 104-key layout only. Mouse/pointer input entirely
  out of scope — no GUI or pointer concept exists anywhere in this kernel yet.
- **Real key auto-repeat** synthesized kernel-side (`KeyboardDevice::repeat_usage`/
  `repeat_next_tick`, driven by `ticks()`) — unlike PS/2, a USB HID boot-keyboard device reports a
  key exactly once per state change and never resends while held. Only the single
  most-recently-pressed still-held key repeats; modifiers never repeat.
- QEMU test devices (`-device qemu-xhci -device usb-kbd`) are opt-in via `OXIDEBSD_QEMU_USB=1` in
  `scripts/qemu_runner.sh`, not default — QEMU's default i440fx machine already wires up its own
  PS/2 keyboard, so an always-on USB one would double-push every keystroke.
- **Real hardware (Surface Pro) itself is genuinely manual-only** — but live interactive-keystroke
  verification turned out **not** to need a human at a real display after all: QEMU's own monitor
  `sendkey <combo> [hold-ms]` genuinely synthesizes guest keystrokes (including held-key duration)
  over a plain TCP socket (`OXIDEBSD_QEMU_MONITOR=<port>`) — this is how a real, pre-existing
  Ctrl+C/Ctrl+D bug (see "Interactive shell" above) was found and confirmed fixed headlessly.
  Revise the "manual-QEMU-only" framing in Test architecture accordingly for anything
  keyboard-shaped specifically (still true for anything needing a real human *decision* mid-session,
  e.g. `sulogin` credential entry).

## 14. System services: shell, sysctl, syslog, cron, init

### 14.1. The init work plan: introduction, status and order

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

A working list, not a specification: what remains of init's step 2 (sockets, sysctl, the
message buffer, syslog, cron, time zones) and step 3 (`/sbin/init` itself), in order, with the
decisions already taken, the traps already found, and how each part is verified. The design is in
`UNIX.md`, `SYSCTL.md`, `SYSLOG.md`, `CRON.md`, `TIMEZONE.md`, `INIT.md`, `INIT_SH.md`, `LOGIN.md`
and `TTY.md`; this file doesn't repeat it. Update it as parts land.

Last updated 2026-09-30, in the session that did cron stage 1 and init's first cut.

#### Where things stood

Sockets (all five stages), step 4 and step 5 are done and committed (OxideBSD `60d0b7f`,
`2e49de9`, `9056be8`). Step 6 is done too (OpenSSL, the trust store, dynamic Rust programs,
loopback, syslog over TCP and TLS, through `b07c19d`). Step 7 (cron) is done (`6dc085d`, `dc01885`,
`c4261e9`, `bb68898`). Step 9 (the BusyBox cut) is done. Step 10, `/sbin/init`, is done (2026-10-01). **Next: "After step 3" below.** The website has `robots.txt`
(search engines and archives welcome, AI crawlers refused), a sitemap and meta descriptions
(`b316818`, deployed); what's left there is the owner's Search Console setup.

#### Done

| Part | Commits | Notes |
|---|---|---|
| Specs (UNIX, SYSLOG, SYSCTL, CRON, TIMEZONE), INIT.md §§11-13 updated | doc `419c264`, `48d6e1c`, `c3179b8` | all accepted |
| Website `/doc/` renders the specs | doc `3edd514` | `website/doc.sh`, lowdown |
| BSD source layout: `sys/netinet`, rtl8139 in `sys/drivers`, `sys/modules/socket` | `3a7c686` | |
| Sockets stage 1: socket layer and protocol switch (`sys/kern/uipc_socket.rs`) | `d6f73cd` | UDP, TCP, raw ICMP are `Protocol`s |
| Sockets stage 2: `sendmsg`/`recvmsg` (577/578), `get/setsockopt` (579/580), `getpeername` (581), `accept4` (582), flags, options, timeouts, blocking socket waits, UDP `connect`, TCP non-blocking `connect`/`shutdown`/`SO_ERROR` | `a73d4a3`, musl `b37feab1` | `regress/socket-smoke`, 64 checks |
| Sockets stage 3: local sockets (`sys/kern/uipc_usrreq.rs`), oxfs socket inodes, `socketpair` on them | `38bbcb4` | `regress/socket-smoke`, 165 checks; `wget` HTTPS checked by hand |
| Sockets stage 4: `SCM_RIGHTS` (hold/release/install, gc, 1024/4096 limits), credentials (`LOCAL_PEERCRED`, `SO_PEERCRED`, `getpeereid`, `SCM_CREDS`, `LOCAL_CREDS[_PERSISTENT]`, `SO_PASSCRED`/`SCM_CREDENTIALS`) | see git log, musl `2af0e5a2` | `regress/socket-smoke`, 213 checks; canary unchanged |
| Step 4: sysctl(2) + tree, message buffer, `/dev/klog` (7,0), load average, exact memory statistics, tunables with enforced `kern.maxproc`/`kern.maxfiles`, `/sbin/sysctl`, `/sbin/dmesg`, `rc.d/sysctl`, `uname -m` = `amd64` | `f021210`, `75c6e7d`, `1005023`, musl `8f9c13ce` | `sysctl_syscall_smoke` (87 checks), `sysctl_tunables_smoke`; POSIX canary unchanged |

| Sockets stage 5: manual pages (`socket.2` ... `unix.4`, `getpeereid.3`); `UNIX.md` implemented | `60d0b7f` | lint clean |
| oxfs: `flock` on write descriptors; buffered writes visible to other descriptors | `2e49de9` | found by syslogd's pid file; `needs-syscall-smoke` |
| Step 5: `lib/libsyslog`, syslogd, logger, newsyslog, `etc/` files, rc.d, six manual pages | `9056be8` | `syslog_syscall_smoke` (36 checks); 37 host tests; regression set passes |
| oxfs: dynamic inode tables (inode file per pool, `SUPERBLOCK_VERSION` 4) | `475e995` | 5821 inodes after seeding; remount checked by hand |
| oxfs: inodes and blocks freed when nothing refers to them (`oxidebsd_inode_in_use`, orphans, mount sweep) | `13113f8` | `needs-syscall-smoke`; POSIX canary identical |
| Step 8: tz 2026d vendored, `/usr/share/zoneinfo`, zic, zdump, tzsetup, syslogd zone reload | `58a2945`, `ad62ef1` | `tz_syscall_smoke` (34 checks) |

Next free syscall number: **584**.

#### Order

| # | Part | Status |
|---|---|---|
| 1 | Sockets stage 3: local sockets | done |
| 2 | Sockets stage 4: descriptor and credential passing | done |
| 3 | Sockets stage 5: manual pages; `UNIX.md` marked implemented | done |
| 4 | sysctl, message buffer, `/dev/klog`, load average, memory statistics, tunables | done |
| 5 | syslogd, logger, newsyslog (without TLS) | done |
| 6 | OpenSSL 3, then syslog over TCP and TLS | done (`b07c19d`) |
| 7 | cron, crontab, periodic | done (`bb68898`) |
| 8 | Time zones | done |
| 9 | BusyBox roster cut (one rebuild for everything replaced) | done: 45 out, 139 left |
| 10 | `/sbin/init` (init's step 3) | done (four parts, 2026-10-01) |
| — | After step 3: netif ioctls, `initconf`, `daemon(8)`, `LOGIN.md` leftovers | later |

Steps 4, 7 and 8 don't depend on the socket work and may move earlier. syslogd (5) needs local
datagram sockets (1). init (10) needs syslog (5) and uses sysctl (4).

### 14.2. Shell: `lib/libsh`, `/bin/sh`, `/sbin/init_sh`

*(from CLAUDE.md, 2026-09-29)*

From-scratch Rust POSIX shell core (spec: OxideBSD-doc `INIT_SH.md`); `bin/sh` and `sbin/init_sh`
are std binaries over it (`init_sh` adds the `init-dialect` feature, still empty). `/bin/sh` is
libsh now — bmake/ninja/`system()`/the POSIX pilot's driver all go through it — and it's pid 1
(`sys/kernel_main.rs`, `spawn_with(..., &[b"-sh"], ...)`: a login shell with `HOME=/`). Interactive
mode (`src/interactive.rs`, `lineedit.rs`, `jobs.rs`, `prompt.rs`): its own raw-mode line editor
(the console has no line discipline), history in `$HISTFILE` (`~/.sh_history`), Tab completion,
Ctrl+R, `PS2` continuation via `ParseError::incomplete`, job control (`set -m`, `jobs`/`fg`/`bg`,
`%n` specs), FreeBSD-sh `PS1` escapes. Shell errors are `Flow::Fatal` (ends a script, not an
interactive shell); only `exit`/`set -e` are `Flow::Exit`. **The console's fds are one-way** (fd 0
read-only, 1/2 write-only), so the editor reads fd 0 and draws on fd 2 — writing to a dup of fd 0
fails silently. `init_sh` refuses interactive mode. BusyBox hush remains at `/bin/hush`.
- The keyboard driver now sends Linux-console sequences for arrows/Home/End/Insert/Delete/PgUp/PgDn
  (`dispatch_key`, `sys/cpu/interrupts.rs`) — they used to be dropped entirely — and DEL (0x7f)
  for Backspace, matching `TERM=linux`.
- Host-testing the interactive shell: drive `target/x86_64-unknown-linux-gnu/debug/libsh` through
  a pty (Python `pty.fork()`); the diff corpus only covers non-interactive behavior.
- `lib/libsh` is its own workspace targeting the host: `cargo test` there runs
  `tests/differential.rs` (`tests/diff/*.sh` vs `dash`: stdout + status exact). Its
  `.cargo/config.toml` adds `std` to `build-std`, since cargo merges that array with the root's.
- `tests/sh_syscall_smoke.rs` runs the same corpus on target (`/sh-smoke/`) against the
  checked-in `*.expected` (dash's host output) — regenerate those with dash when a script changes.
- `build_std_oxidebsd_userland_crate` takes a crate path now (not just `regress/std/<name>`).

### 14.3. sysctl and the message buffer (`sys/kern/{kern_sysctl,subr_msgbuf}.rs`, `sys/modules/sysctl`)

*(from CLAUDE.md, 2026-09-29)*

FreeBSD's MIB (OxideBSD-doc `SYSCTL.md`): `sysctl(2)` = 583, one pointer to its six args; musl has
`<sys/sysctl.h>`/`sysctl(3)`/`sysctlbyname(3)`/`sysctlnametomib(3)`. The tree is one `BTreeMap`
keyed by OID (its order is `{0,2}`'s depth-first walk); leaves are getter/setter fns, FreeBSD
numbers where FreeBSD has one, else auto from 256. `uname -m` is `amd64` (`hw.machine`). Every
kernel print (`console::serial::_print`) also goes to the message buffer (early static buffer until
the heap, then `kern.msgbufsize`); `kern.msgbuf` reads it, `/dev/klog` (7,0) consumes it, exclusive.
A test using `poll` must load the `socket` module. `tests/sysctl_syscall_smoke.rs`.

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

The musl leftovers (`struct loadavg`/`vmtotal`/`CTLFLAG_SKIP`, `getloadavg(3)` via `vm.loadavg`, and
step 5's `LOG_NTP`/`LOG_SECURITY`/`LOG_CONSOLE`) went in with sockets stage 4 (musl `2af0e5a2`). Not done: a kernel API for modules to add variables (`SYSCTL.md`
§3.6 is a MAY; add it when a module has something to export, `vfs.oxfs` first). `/proc/meminfo`
still reports `MemFree == MemTotal`; `vm_meter::stats` could feed it.

### 14.4. syslogd, logger, newsyslog (init work plan step 5, `9056be8`)

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

As planned, with these details settled in the code (and in the manual pages):
- Messages from this host (`/dev/log`, `/dev/klog`) are stamped on receipt; musl's `syslog(3)`
  stamps in UTC. Network messages keep their stamp unless `-T`.
- Local messages are logged exactly as sent: no pid is added from the sender's credentials
  (decided by the owner; `LOCAL_CREDS` isn't used).
- The pid file is `flock`ed (FreeBSD's `pidfile_open`): a second syslogd exits instead of
  rebinding `/dev/log`. Marks bypass repeat suppression. `#-host` isn't a block (a `#----` banner
  would be).
- logger's local path is `syslog(3)` (as FreeBSD's), so the smoke test covers it.
- newsyslog stamps the newest archive's mtime at rotation and reads it back next run; size,
  interval and time conditions are OR'd.
- rcorder now orders `... NETWORKING newsyslog syslogd SERVERS ...`.

Left over: `re_format(7)`, `utmpx(5)` and `syslog(3)` pages, referenced but not written. oxdoc bugs
found while writing pages: `.Op` inside `.Oo`/`.Oc` on an `.It` line swallows the item's body;
`dmesg.8`'s `.Sm off`/`.Ql` idiom renders wrong; lint doesn't flag an unknown `.St`.

The original plan:

- `usr.sbin/syslogd` (Rust std): `syslog.conf` parser (FreeBSD format, `include`, blocks,
  NetBSD-style `name=value` options), inputs `/dev/log` (local datagram), `/dev/klog`, UDP 514;
  outputs file, `-file`, pipe, `@host`, users (utmpx), `*`, terminals; RFC 3164 and 5424 output;
  repetition; `SIGHUP`; `-k` translation; `LOCAL_CREDS` for real sender PIDs. The FreeBSD flag
  set of `SYSLOG.md` §6.2.
- `usr.bin/logger`, `usr.sbin/newsyslog` (Rust; compression through BusyBox `gzip`/`bzip2`).
- musl: `LOG_NTP`, `LOG_SECURITY`, `LOG_CONSOLE` are done (musl `2af0e5a2`).
- `etc/syslog.conf`, `etc/newsyslog.conf`, `etc/rc.d/syslogd`, `etc/rc.d/newsyslog`,
  `etc/defaults/rc.conf` entries.
- Tests: host tests of the parsers and formatting; `syslog_syscall_smoke` (`SYSLOG.md` §12.2).

### 14.5. cron, crontab, periodic (init work plan step 7)

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

Four stages, each committed and pushed as it lands:
1. **Done (`6dc085d`)**: `lib/libcron`, the table parser and Vixie cron 4's clock handling as a
   pure state machine; 13 host tests. `-o` (default, as FreeBSD) counts minutes in UTC, `-s` in
   local time, which makes a daylight-saving change a clock jump (§4.5). A field beginning with
   `*` counts as unrestricted for the day rule (Vixie); `n/step` means `n-max/step`.
2. **Done (`dc01885`)**: the daemon; login's class code moved into `lib/liblogincap` as
   `setusercontext` (FreeBSD's flags; `PATH` and the class environment are returned, not set);
   `rc.d/cron`, `etc/crontab` (newsyslog only until stage 4), `etc/pam.d/cron`. Host tests need
   `OXIDEBSD_LIBPAM_DIR=<repo>/target/openpam` (OpenPAM is static). Found on the way and fixed
   (`0d0fbbb`): oxfs never updated a directory's times when an entry was added or removed, so
   cron never noticed a new `cron.d` table. Found and **not** fixed: a file made by
   `open(O_CREAT)` always gets gid 0 (only the uid is recorded), while mkdir/mknod/symlink use
   the creator's gid.
3. **Done (`c4261e9`)**: `crontab(1)`, which takes BusyBox's `/usr/bin/crontab` slot through
   the same oxfs name; `cron_syscall_smoke` (21 checks). Not covered: refusing a non-root
   caller (needs `su` in the test).
4. **Done (`bb68898`)**: `periodic` and its scripts, `periodic.conf`, the five manual pages,
   `CRON.md` implemented (§11 there records what the code settled). `cron_syscall_smoke` has
   35 checks. Not exercised by a test: `daily/110.clean-tmps` (off by default; it relies on
   BusyBox `find`'s `-mindepth`, `-empty` and `-atime`).

The original plan:

- A shared table parser (a small library crate) used by both programs.
- `usr.sbin/cron` (Rust std): tables, `cron.d`, reload by mtime, jitter, `@reboot` via
  `/var/run/cron.reboot`, clock-change handling, login class and PAM service `cron`
  (`etc/pam.d/cron`), output to syslog, `/var/run/cron.pid`.
- `usr.bin/crontab` (Rust): root-only until set-user-ID exists (as `passwd`).
- `usr.sbin/periodic` (sh), `etc/periodic/{daily,weekly,monthly}`, `etc/defaults/periodic.conf`,
  `etc/crontab`, `etc/rc.d/cron`.
- Tests: host tests with an injected clock; `cron_syscall_smoke` (`CRON.md` §9.2).

### 14.6. `/sbin/init` (init work plan step 10)

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

**First cut (`52656de`)**, asked for ahead of the rest: `sbin/init` runs `/etc/rc`, then a root
shell on the console, restarted when it exits (3 exits within 5 s pause 30 s); reaps orphans;
`-s` and `-R` skip rc; `SIGINT`/`SIGUSR1`/`SIGUSR2` do §10's shutdown (hang up the console
session first, so `rc.shutdown` can take the console). The kernel embeds it (static PIE) and
starts it without a controlling terminal (`InitProgram::console`); falls back to `/bin/sh` if it
can't be started. What follows is what's left; the shell loop becomes the ttys/getty loop.

**Part 1 done (2026-10-01):** the §3 states, `/etc/ttys` sessions (getty on `ttyv0`), FreeBSD's
restart limit, `SIGHUP`/`SIGTERM`/`SIGTSTP`, the single-user password on an insecure console,
recovery keeping the sessions it finds in `/proc`, `init(8)`, `/etc/profile`. `SIGTERM`'s
single-user returns to multi-user without `/etc/rc` (decided: services keep running; INIT.md §3).
Test: `init_syscall_smoke` (about a minute).

**Parts 2-4 done (2026-10-01):** `syslog(3)` with `LOG_CONS` (facility auth); `BOOT_TIME` and
`SHUTDOWN_TIME` (musl gained `SHUTDOWN_TIME`/`DOWN_TIME` = 11) and closing a killed login's
record; recovery reports why and starts the `KEYWORD: shutdown` services that aren't running,
tested through the new `debug.kill_init` sysctl; `init=`/`init_path=` through the embedded
`start_init` (INIT.md §4.1.1), tested by `init_path_smoke`.

Found on the way and fixed (`poweroff` commit after `98cf1fc`): `poweroff` wrote PM1a control at
SeaBIOS's port `0x604`, but OVMF's is `0xb004`; `sys/acpi.rs` now reads the FADT and `\_S5`.

- `sbin/init` (Rust std): the states of `INIT.md` §3, `/etc/ttys` sessions with restart limits
  (FreeBSD's: 3 deaths within 5 s of start → 30 s pause, logged), the signal table (§6), reaping,
  `rc.shutdown` with `rcshutdown_timeout`, the kill/sync/`reboot(2)` sequence, recovery mode
  `-R` (§9.3), single-user with the console's `secure` flag, `syslog(3)` with `LOG_CONS`,
  `utmpx` `BOOT_TIME`/`SHUTDOWN_TIME` (`LOGIN.md` §8.2).
- Kernel: start `/sbin/init` as process 1 from its embedded image (§9.6), with the boot flags;
  `init_path=` (colon list, FreeBSD) and `init=` on the command line, falling back to `/bin/sh`;
  the existing supervision (respawn, `/proc/initdeaths`, emergency) applies to any of them, `-R`
  only to `/sbin/init`.
- Tests: boot to a getty; `SIGTERM` to single-user; `rc` failure to single-user; respawn in
  recovery mode (extend `init_respawn_smoke`); shutdown paths by hand (they end the VM).

#### After step 3

Interface configuration ioctls and `rc.d/netif`; `/sbin/initconf`; `daemon(8)` for
`<name>_restart`; the `LOGIN.md` leftovers (`tty01` serial tests, `who`).

### 14.7. Side work done and problems found, 2026-09-30

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

#### Side work done 2026-09-30

- oxfs: a new entry takes its directory's group (BSD rule) and directories' times move on
  create/remove (`113d7d9`, `0d0fbbb`).
- `/bin` and `/sbin` are statically linked, OpenBSD-style (`33a69e6`); `/sbin/nologin` added.
  Still missing from a BSD `/sbin`: `ifconfig`/`route` (below), `newfs`/`fsck` (oxfs tools),
  module load/unload tools, `swapon`/`savecore`/`dumpon` (need swap and crash dumps first).
- Rewritten in Rust std (`bc401ba`, `8a7d30a`): `sleep sync link unlink rmdir nproc kill test`
  (`[`) `chmod`, and `mount`/`umount` over the new `nmount(2)` (584) with `/etc/fstab` and
  `rc.d/mountcritlocal`. Still BusyBox in `/bin` (17): `ash` (stays for `configure`), `date stty dd
  df expr pgrep pkill`, `grep egrep fgrep sed ed` (regex library first), `tar gzip gunzip zcat`;
  in `/sbin`: `mknod ping`. BusyBox's `mount`/`umount` left the roster with musl's `nmount()`
  (2026-10-01), on which musl's `mount(3)` is now built; syscalls 174/175 are gone.

#### Found 2026-09-30, not yet fixed

- **`execve` reads the executable 512 bytes per `read`** (`lifecycle::read_fd_to_end_and_close`,
  through `exec_image`), so exec of a large program (clang, ld.lld: tens to hundreds of MB) costs
  hundreds of thousands of system calls. bmake's `configure` on target takes ~14 minutes for this
  reason (4 s on the host). Fix first: read in large chunks or map the file.
- `wget` over TCP is slow (stop-and-wait); a 4 MB download takes minutes. BusyBox `tar` has no
  gzip support (`tar xzf` fails; `gunzip -c | tar xf -` works) -- matters for the floppy plan's
  `.tgz` sets, and for the native `tar`.
- `/bin/sh` runs autoconf `configure` (bmake on target; bmake, nano, ncurses on the host identical
  to dash), so `ash` is no longer needed for that.

## 15. Toolchain and ports

### 15.1. musl port (`external/mit/musl`, `regress/musl-smoke/`, `sys/process/user_stack.rs`, `sys/cpu/fpu.rs`)

*(from CLAUDE.md, 2026-09-29)*

musl is patched (not the kernel made Linux-compatible) to speak this native ABI directly.
`external/mit/musl` is a submodule of a personal fork (`ifduyue/musl`), patches on its own
`oxidebsd` branch based on tag `v1.2.6`. Pin/update by committing on that branch, pushing, then
`git add external/mit/musl` here. Patch surface is deliberately small, entirely under
`arch/x86_64/`: `syscall_arch.h` (carry-flag→negative-errno conversion after every `syscall`),
`bits/syscall.h.in` (only the `__NR_*` values musl's static-binary startup path actually reaches
are remapped), `__set_thread_area.s` (TLS base via `SYS_SET_FS_BASE`, a bare base-address write).

Key gotchas, each a real bug already hit and fixed — the same *class* of bug can recur for any
future syscall port, so re-check these when adding one:
- musl's stdio write path goes through `writev`, never plain `write` — `SYS_WRITEV` is
  load-bearing (its absence once silently redirected all `printf` output into `getpid()` via a
  numbering collision — no crash, just zero output).
- **Remapping a `__NR_*` macro isn't enough if a 64-bit-suffixed sibling exists.** `src/internal/
  syscall.h` unconditionally prefers `SYS_getdents64` over `SYS_getdents` whenever both are
  defined — found live for `getdents`, both now remapped and kept in sync. Any future syscall with
  a same-shaped 64-bit sibling (`__NR_stat64`, `__NR_fstatat64`, ...) needs the same audit.
- SSE was never enabled at the hardware level; `sys/cpu/fpu.rs::init()` enables it once at boot.
  Real per-process `FXSAVE`/`FXRSTOR` across every context switch exists (`Process::fpu_state`) —
  became load-bearing once ring-3 preemption landed (see "Real preemptive scheduling").
- `sys/process/user_stack.rs` builds a real System V argc/argv/envp/auxv stack. `AT_PHDR` derived
  from the `PT_LOAD` segment with smallest `p_offset` (linker scripts don't map the ELF header
  into any segment). `AT_RANDOM` is 16 fresh `sys/random.rs` bytes per exec.
- **`open`/`execve` argument-convention mismatches are fixed on the musl side**, not by remapping
  alone: length-prefixed `RawArgvEntry{ptr, len}` arrays instead of NUL-terminated `char**`, real
  4th syscall arg (`R10`) for `envp_ptr`. Same length-prefix pattern for
  `unlink`/`rmdir`/`rename`/`readlink`/`symlink`/`chdir`/`mkdir`. **Any future libc call ported
  here needs the same audit** — matching the syscall *number* isn't sufficient if the argument
  shape differs.
- **A hand-written asm stub can bypass the `__NR_*` remap table entirely.** `vfork.s` hardcoded
  the real Linux syscall number directly; fixed by hardcoding OxideBSD's own `SYS_FORK` instead (a
  real `fork()`, not true vfork semantics — POSIX-legal). **Any syscall with its own hand-written
  arch-specific asm stub needs this same direct-patch treatment, not just a header remap** — bit
  again later for `clone.s`/`__unmapself.s` (see "Real threading").
- `utimensat` drops the always-`AT_FDCWD` `fd` arg, passes `(path_ptr, path_len, times_ptr,
  flags)`. Kernel side gained real mtime/ctime tracking (`oxidebsd_unix_time`) later, and
  `oxfs_utimensat` now genuinely sets atime/mtime (null `times` = now; `UTIME_NOW`/`UTIME_OMIT`;
  `EINVAL` on bad `tv_nsec`; explicit times need owner-or-root, "now" also allows write access).
- `SYS_MMAP=100` is `(addr_hint, len, prot)` originally, later gained real `flags` (packed into
  `prot`'s unused high bits) and real `MAP_FIXED`/`MAP_PRIVATE` handling. `SYS_BRK=102`
  grows/shrinks `Process.brk`, no reclaim on shrink.
- **A real, previously-undiscovered bug in this project's own musl fork**: real, unmodified
  `fork()` takes a `LOCK()` on internal locks (including stdio's `ofl_lock`) in the parent
  whenever the process is genuinely multi-threaded — but `_Fork.c`'s own `reset_stdio_locks_in_child`
  (an earlier fix for a *different* hang, `fork/11-1.c`) unconditionally re-locks `ofl_lock` to
  walk the open-`FILE` list, self-deadlocking since the child inherits it already locked. Only
  reproduces with 2+ real contending forked children *and* a live second thread at fork time.
  Fixed on the `oxidebsd` musl branch: reset the lock to unlocked in the child unconditionally,
  matching how every other atfork lock is already treated (a freshly forked child is always the
  sole surviving thread, so any inherited "locked" state is never real contention).
- **Two more real, independent stock-musl bugs behind `fork/11-1.c`'s original hang**: (1)
  `__post_Fork` never reset any `FILE`'s own `.lock` word in the child, so a `flockfile(stdout)`
  held by the parent left a "ghost" tid the child could never clear (real glibc avoids this via
  `pthread_atfork`; stock musl has none) — fixed by resetting every known `FILE`'s lock in the
  child branch. (2) Once that let the child lock `stdout`, a thread exiting without
  `funlockfile()` (legal per POSIX) hit `__do_orphaned_stdio_locks()`, which marked the lock with
  a poison bit instead of releasing it — fixed to do a real release-and-wake.
- **`sigset(sig, SIG_HOLD)`** had a real stock-musl bug (returned current disposition instead of
  `SIG_HOLD` on first call) — fixed on the `oxidebsd` branch.
- **`PTHREAD_STACK_MIN`** was `2048`, too small for a real page-size multiple — bumped to `65536`
  (plus a `sysconf.c` `short`→`int` table widening it needed to take effect).
- **`pthread_detach()` on an already-`PTHREAD_CREATE_DETACHED` thread** used to unconditionally
  fall back to `__pthread_join()`'s own `a_crash()` instead of returning `EINVAL` — fixed on the
  `oxidebsd` branch (this specific case is memory-safe to detect directly, target is always
  `pthread_self()`).
- **A real, permanent, accepted class of musl 1.2.6 bug, not OxideBSD's**: several real conformance
  files (`pthread_join`/`_detach`/`_cancel`/`_kill`/`_create`/`_key_create`/`_getcpuclockid` on a
  stale tid) crash on a real use-after-free reading a freed TCB — confirmed via direct
  reproduction against the host's own unmodified musl 1.2.6, not an OxideBSD bug, not fixable
  without a much bigger design change. Left as accepted `CRASH` results.

### 15.2. BusyBox port (`external/gpl2/busybox`, `sys/modules/posix_compat/`)

*(from CLAUDE.md, 2026-09-29)*

256 applets run today (24 original + 232 from a second-pass roster), each its own standalone
single-applet static binary. Vendored as a submodule (fork of `mirror/busybox`, tag `1_38_0`,
`oxidebsd` branch, **no patches of its own** — upstream is `git.busybox.net`; the GitHub mirror
stopped at `1_36_1`). `build.rs`'s `build_busybox_applet` runs
`allnoconfig` → flip one applet's Kconfig symbol → `oldconfig` → build, asserting
`NUM_APPLETS == 1`; `sh` additionally forces on `CONFIG_HUSH_INTERACTIVE`/`HUSH_JOB`/
`FEATURE_EDITING` and hush's control-flow symbols directly (`allnoconfig` writes an explicit
"not set" before `oldconfig` ever sees hush's own `default y`). Applets are embedded into oxfs's
inode table by `sys/modules/oxfs`'s `module_init` (data-driven from `build.rs`'s applet lists; each
new applet needs one manual `seed_file` call). Roster grew 24 → 290 (287 from an exhaustive
per-applet build probe — **"builds" is a much weaker bar than "works"**), then curated down to 232
(256 total) before v0.1 by dropping 58 applets structurally incapable of working under this
kernel's architecture (see `OxideBSD-doc/BUSYBOX_APPLETS.md`'s "Removed before v0.1"; a few later
unblocked — `chroot`/`mknod`/`link` — were fixed forward instead). `OxideBSD-doc/BUSYBOX_APPLETS.md` is the
full roster with per-applet needs (`NEEDS_NETWORK`/`NEEDS_PROC`/`NEEDS_CLOCK`/`NEEDS_UID`/`WORKS`).
`sys/modules/oxfs/src/test_busybox.sh` (seeded at `/test_busybox.sh`) is ~95 real applet/control-flow
checks with a `PASS`/`FAIL` tally — the tool that found several bugs below.

- `build_busybox_applet` is staleness-checked against `external/gpl2/busybox`/`build.rs`/
  `musl_sysroot`'s `lib/libc.a` mtimes, builds in parallel. **Two real staleness bugs found**: (1)
  `libc.a`'s mtime wasn't originally compared, so a musl fix left applets linked against stale
  libc. (2) BusyBox's incremental build never tracks musl's *installed sysroot headers* as a
  dependency — a musl header fix left most object files unrecompiled despite fresh binary mtimes.
  **Only a full `rm -rf` of the stale `O=` out-of-tree build dir reliably fixes this** — trust
  neither BusyBox's incremental tracking nor mtime alone. Expensive (~38 min full rebuild), only
  triggers when something genuinely changed. **`ccache` is wired into both this build and the
  POSIX pilot's own per-file compile loop** (~79% hit rate confirmed live) — falls back cleanly
  when not installed.
- `hush` (pid 1) uses real `execvp()`/`$PATH` (`PATH=/bin` in envp). `sys/modules/oxfs` seeds every
  applet under its bare name in `/bin`.
- New kernel-resident pieces `sh` required: real 4th syscall arg (`R10`, envp), real blocking
  `pipe(2)`/`dup2(2)` (`sys/fs/pipe.rs`, `PIPE_CAPACITY=64` KiB, blocks via `BlockReason::
  WaitingForPipeData`/`WaitingForPipeSpace`), and a **per-process** `(Pid, fd)` fd table
  (`sys/fs/fd.rs`) — a flat table broke real pipelines when a parent closed its own copy of a pipe
  fd out from under still-using children.
- **Fixed: a producer whose `write()` never blocks used to OOM the kernel heap.** `yes | head -n
  3` reliably panicked — `sys/fs/pipe.rs`'s buffer used to be an unbounded `VecDeque<u8>`, and
  with no preemption `head` never got scheduled to stop `yes`. Fixed by bounding the buffer
  (`write_into` now blocks the producer once full, `EPIPE` on read-end close) rather than adding
  preemption.
- **`IA32_FS_BASE` (TLS) is a single global MSR never saved/restored per-process by
  `context_switch::switch_context`** — a resuming musl-linked parent would silently inherit a dead
  child's leftover TLS base and fault its own stack-protector check. Fixed via `Process::fs_base`,
  restored on every switch by `scheduler::activate_and_prepare`.
- `getcwd`/`getppid`/`chdir`/`mkdir` needed the same argument-convention fixes as `open` — only
  surfaced once `hush` was driven interactively.
- musl's stdio calls `write(fd, buf, 0)`/`read(fd, buf, 0)` with a null/garbage `buf`
  (POSIX-legal at length 0) — crashed every fd callback's unconditional `slice::from_raw_parts`;
  fixed centrally in `sys/fs/fd.rs`'s `read`/`write` funnel functions.
- New syscalls always go in a dedicated module (`sys/modules/posix_compat/`, `sys/modules/signal/`, ...),
  not `sys/modules/native_abi/` — keeps the core ABI module small.
- **83 more candidate applets didn't even build**: the full breakdown is in this file's §15.3.

### 15.3. BusyBox applet roster: the build probe and its cuts

*(from BUSYBOX_APPLETS.md, cut 2026-10-01)*

Generated by an exhaustive per-applet build probe against every Kconfig applet symbol BusyBox's
own `//applet:` source markers define (393 candidates), using the exact single-applet recipe
`build.rs`'s `build_busybox_applet` uses (`allnoconfig`, flip one symbol + `STATIC`/`SH_IS_NONE`/
`SHOW_USAGE`/`FEATURE_VERBOSE_USAGE`, resolve any newly-revealed sub-options via `oldconfig` fed
blank lines, then a real static `musl-gcc` build, requiring `NUM_APPLETS == 1`).

**"Builds" is a much weaker bar than "works."** musl provides a fairly complete libc surface, so a
lot of applets that make no sense on this kernel (networking, mount, login, `/proc`-reading tools)
still compile and link cleanly -- they just fail at runtime (usually a clean `ENOSYS` from an
unregistered syscall, sometimes silent no-op behavior). Every applet below that builds is tagged
with what it actually needs, so the roster stays honest about what's decorative versus real.
Rebuilding this list requires no new kernel work; making a `NEEDS_*`-tagged applet actually work
does, and is exactly what CLAUDE.md's "BusyBox gap analysis" tracks.

24 applets were already ported before this pass (`true`, `echo`, `cat`, `sh`/hush, `false`, `yes`,
`more`, `mkdir`, `rmdir`, `rm`, `mv`, `cp`, `touch`, `head`, `tail`, `wc`, `basename`, `dirname`,
`printf`, `seq`, `cut`, `sort`, `uniq`, `kill`) and aren't re-listed here.

#### Build succeeded: 287 applets (229 kept in the roster)

**Pre-v0.1 roster cleanup**: 58 of these 287 built cleanly but their core function structurally
cannot work on this kernel at all today (no VT/console/serial/framebuffer/syslog device model, no
SysV IPC, namespaces that don't fit this kernel's single-address-space model, no ext2 ioctl/xattr
support, no FIFO inode kind, no partition-table/swap/hw-profile concept) -- pure decoration that
would waste a user's time discovering an instant `ENOSYS` instead of saving it. These are no
longer built or seeded at all (removed from `build.rs`'s `BUSYBOX_APPLETS_PASS2` and
`modules/oxfs`'s seed list) -- see "Removed before v0.1" below for the full list and reasoning.
Everything else below reflects the current, kept roster; stale `NEEDS_*` tags on applets whose
blocking syscall has since landed (`chroot`, `mknod`, `makedevs`, `link`, `time`, `cttyhack`,
`setsid`) were corrected in the same pass and moved into WORKS.

##### WORKS (119)

Builds and needs only syscalls OxideBSD already implements -- plain file/text/arg-processing tools, or terminal I/O covered by the existing termios/ioctl support.

`ar`, `ascii`, `ash`, `awk`, `base32`, `base64`, `bash_is_ash`, `bash_is_hush`, `bbconfig`, `bb_arch`, `bc`, `bunzip2`, `bzcat`, `bzip2`, `cal`, `chat`, `chroot`, `cksum`, `clear`, `cmp`, `comm`, `cpio`, `crc32`, `cttyhack`, `dc`, `dd`, `diff`, `dos2unix`, `dpkg`, `dpkg_deb`, `du`, `ed`, `egrep`, `env`, `expand`, `expr`, `factor`, `fgrep`, `find`, `fold`, `getopt`, `grep`, `gunzip`, `gzip`, `hexdump`, `hexedit`, `hostid`, `install`, `ipcalc`, `less`, `link`, `ls`, `lzcat`, `lzop`, `makedevs`, `makemime`, `man`, `md5sum`, `mknod`, `mktemp`, `nl`, `nohup`, `nuke`, `od`, `paste`, `patch`, `pipe_progress`, `printenv`, `pwd`, `pwdx`, `realpath`, `reformime`, `reset`, `resize`, `rev`, `rpm`, `rpm2cpio`, `run_parts`, `sed`, `setsid`, `sha1sum`, `sha256sum`, `sha3sum`, `sha512sum`, `shred`, `shuf`, `split`, `stat`, `strings`, `stty`, `sum`, `tac`, `tar`, `tee`, `test`, `time`, `tr`, `tree`, `ts`, `tsort`, `tty`, `ttysize`, `uncompress`, `unexpand`, `unit_test`, `unix2dos`, `unlink`, `unlzma`, `unxz`, `unzip`, `uudecode`, `uuencode`, `vi`, `volname`, `which`, `xargs`, `xxd`, `xzcat`, `zcat`

- `chroot`/`mknod`/`makedevs`/`link`/`time` moved here from `NEEDS_SYSCALL` -- `SYS_CHROOT=490`/
  `SYS_MKNOD=489`/`SYS_LINK=488`/real `wait4` rusage all landed (see CLAUDE.md's "Real hard links,
  device nodes, per-process chroot, and getrusage/wait4 rusage" section); `makedevs` shares
  `mknod`'s same underlying syscall and wasn't individually re-probed but has no other blocker.
- `cttyhack`/`setsid` moved here from `NEEDS_HARDWARE` -- both were tagged as needing "a real
  controlling-tty/session model beyond what termios covers", which now exists (`SYS_SETSID=112`,
  `TIOCSCTTY`/`TIOCNOTTY`/`TIOCGPGRP`/`TIOCSPGRP`; see CLAUDE.md's "Session, controlling-tty, and
  login authentication" section). Neither individually re-run end-to-end yet.

##### NEEDS_NETWORK (38)

Builds, but needs socket syscalls -- originally none existed in OxideBSD at all. **Stale as of
real socket/DNS support landing (see CLAUDE.md's own "Real networking" section) -- socket syscalls
now exist, so this whole category needs re-probing against the current kernel, not just the three
below that have actually been re-verified live.** The rest of this list hasn't been individually
retested and may still be blocked for other reasons (raw sockets, broadcast/multicast, netlink-
shaped ioctls, etc.) even though "no socket syscalls at all" is no longer the reason.

- **confirmed working live**: `ping` (real `SOCK_RAW`/`IPPROTO_ICMP` socket, real routing via a
  default-gateway rule, real DNS resolution for a hostname target), `nslookup` (real DNS
  resolution via musl's own stub resolver), `wget` (**both plain HTTP and HTTPS now confirmed
  live** -- `wget https://raw.githubusercontent.com/torvalds/linux/master/README` completed a
  full download, real content verified afterward via `cat`. HTTPS previously failed at
  `socketpair(AF_UNIX, SOCK_STREAM, ...)` with `ENOSYS`; getting it working end to end took five
  rounds of live retesting, each surfacing the next gap once the previous fix landed: `fcntl`/
  `shutdown`/`set_tid_address` were *also* entirely unregistered (`SYS_SET_TID_ADDRESS=150`/
  `SYS_FCNTL=151`/`SYS_SHUTDOWN=152` now exist); then the TLS handshake itself turned out to need
  real `/dev/urandom` (BusyBox's own vendored `tls_get_random`), which this kernel had no `/dev`
  for at all -- `modules/oxfs` now has a synthetic `/dev/{u}random`/`null`/`zero`, backed by a real
  SHA-256/ChaCha20 generator (`src/random.rs`); then a real bug surfaced in `src/net/tcp.rs`'s own
  `tcp_read`, which used to return false EOF the instant its buffer was momentarily empty
  (indistinguishable from a real peer close) -- the first real remote TCP exchange this stack had
  ever actually driven, previously only exercised against a synthetic in-test peer; then, once
  real response bytes were flowing, `readv` (real Linux syscall `19`) turned out to be missing too
  -- musl's own buffered-`fread()` read path (`third_party/musl/src/stdio/__stdio_read.c`), the
  read-side mirror of the `writev` gap already fixed for `printf`. `SYS_READV=153` now exists. All
  verified via `tests/socketpair_smoke.rs`/`tests/random_smoke.rs`/`tests/tcp_smoke.rs`/
  `tests/readv_smoke.rs`; see CLAUDE.md's own gap entry for the full trace)

- POP3 client -- connects to a mail server: `popmaildir`

- SMTP client -- connects to a mail server: `sendmail`

- not yet re-verified against current socket/DNS support (originally: "no socket syscalls
  implemented at all"): `arp`, `arping`, `dhcprelay`, `dnsd`, `dnsdomainname`, `dumpleases`,
  `fakeidentd`, `ftpd`, `ftpget`, `ftpput`, `httpd`, `ifconfig`, `ifdown`, `inetd`, `lpd`, `lpq`,
  `lpr`, `nc`, `netcat`, `netstat`, `ntpd`, `pscan`, `rdate`, `route`, `ssl_client`, `tcpsvd`,
  `telnet`, `telnetd`, `traceroute`, `udhcpd`, `udpsvd`, `vconfig`, `whois`

##### NEEDS_PROC (26)

Builds, but reads /proc -- **`/proc` is now essentially complete for what this roster needs** (see
CLAUDE.md's own "BusyBox gap analysis" table and "Filesystem: oxfs" section): per-pid `stat`/
`cmdline`/`status`, dir listing, `stat(2)`/`lstat(2)`, a `task/<tid>/` redirect, **plus, added this
pass**: system-wide `/proc/{meminfo,uptime,stat}`, per-fd `/proc/<pid>/fd/` enumeration, and real
`chdir(2)` into `/proc` (with a relative-path-aware `open`/`stat`/`getdents` to match). Not
wholesale re-probed against the live roster; the entries below split into what's actually unlocked
vs. what a documented, deliberate gap still blocks.

- unlocked by the per-process /proc (per-pid `stat`/`cmdline`/`status` + dir listing); `pstree`
  confirmed live (including the `task/<tid>/` redirect fix needed for its own uid/gid `stat()`
  calls), the rest share the same underlying mechanism but haven't been individually re-run:
  `pidof`, `pgrep`, `pkill`, `pstree`, `minips`

- likely unlocked by system-wide `/proc/{meminfo,uptime,stat}` + real chdir-into-`/proc`: `top`
  (confirmed via BusyBox's own source, `procps/top.c`: it `chdir("/proc")` once at startup, then
  does relative `open("stat")`/`open("meminfo")` against that cwd -- both now real). Its own CPU%/
  mem% columns will read as permanently ~0% used, an honest reflection of "no real per-process CPU
  or free-memory accounting exists" (see `oxidebsd_proc_stat_global`'s/`oxidebsd_proc_meminfo`'s own
  doc comments in `src/process.rs`), not a bug -- not yet confirmed live end to end.

- still blocked -- `free`/`uptime` turn out to call the Linux-only `sysinfo(2)` syscall for their
  *primary* numbers (confirmed via BusyBox's own source, `procps/{free,uptime}.c`); `/proc/meminfo`/
  `/proc/uptime` (both now real) only back `free`'s own optional `Cached`/`MemAvailable` fields and
  aren't consulted by `uptime` at all. `sysinfo(2)` itself remains unimplemented -- a distinct,
  still-open gap, not fixed by this pass: `free`, `uptime`

- partially unlocked -- `/proc/<pid>/fd/` enumeration now works (real directory listing, real fd
  numbers), but each entry is a plain placeholder, not a real symlink to its target (real Linux
  `lsof`/`fuser` also `readlink()` each entry to show what it points at -- this kernel now has real
  `readlink(2)`/`symlink(2)` in general, but no mechanism yet for oxfs to describe what a pipe/
  socket/other-module's fd actually is). A real per-fd target needs a separate, cross-module
  "describe this fd" mechanism -- a known, deliberate limitation of this pass, not solved by
  guessing: `lsof`, `fuser`

- not yet re-probed against the current /proc support -- may need more than plain per-pid /proc
  (`/proc/bus/pci`-style paths, sysctl-shaped interfaces, procps-specific parsing not checked
  against this kernel's fixed-placeholder fields): `bb_sysctl`, `dmesg`, `iostat`, `killall5`,
  `lspci`, `lsscsi`, `lsusb`, `mpstat`, `nmeter`, `nproc`, `pmap`, `powertop`, `renice`,
  `smemcap`, `taskset`, `watch`

##### NEEDS_UID (16, 4 now done -- `getty`/`login`/`su`/`sulogin`)

Builds, but needs a real uid/passwd-db model -- see CLAUDE.md's "uid/passwd-db model" gap, **done**
for the process-attribute half (`getuid`/`geteuid`/`getgid`/`getegid`/`setuid`/`setgid`/
`getgroups`, real `/etc/passwd`+`/etc/group`) -- `whoami`/`groups`/`logname` should now work
end-to-end (not yet re-probed against the live roster to confirm). **`su`/`login`/`sulogin`/
`getty` are also done now** -- see CLAUDE.md's "Session, controlling-tty, and login
authentication" section: a real second user + `/etc/shadow` (crypt-hash password auth) for
`su`/`login`, plus a real session/controlling-tty/foreground-process-group model and real
Ctrl+C-to-`SIGINT` delivery for `sulogin`/`getty`. `adduser`/`chpasswd`/`passwd`/`mkpasswd`/
`addgroup`/`delgroup`/`remove_shell`/`envuidgid`/`setuidgid` still need real *mutation* of
`/etc/passwd`/`/etc/group` (parsing them for lookups is a solved, musl-userspace problem now;
rewriting them isn't a kernel gap at all, just unimplemented applet-level work against files that
already exist and are already writable via ordinary `open`/`write`).

- no uid/passwd-db model (CLAUDE.md's "uid/passwd-db model" gap): `addgroup`, `adduser`, `chpasswd`, `delgroup`, `envuidgid`, `groups`, `logname`, `mkpasswd`, `passwd`, `remove_shell`, `setuidgid`, `whoami`
- real login/session authentication -- **done**, see CLAUDE.md's "Session, controlling-tty, and login authentication" section: `getty`, `login`, `su`, `sulogin`

##### NEEDS_SYSCALL (0 remaining in the kept roster -- see "Removed before v0.1" below for what was cut instead of fixed)

Builds, but its core function needs a specific syscall OxideBSD hasn't registered (link, mknod, SysV IPC, chroot, namespaces, ext2 ioctls/xattr, ...).

- `chmod`/`chown`/`chgrp` -- **done**: `SYS_CHMOD=165`/`SYS_CHOWN=166` (`modules/oxfs`),
  real per-inode `mode`/`uid`/`gid` plus `oxfs_open` permission enforcement. BusyBox's own
  `coreutils/chown.c` implements `chgrp` as the same `chown()` call restricted to the group field,
  so all three are unblocked by the same two syscalls. `chattr`/`fatattr`/`lsattr`/`setfattr`
  were **not** unblocked by this despite the original probe bucketing them together with
  chmod/chown under one loose "no permission model" reason -- real `chattr`/`fatattr` use
  Linux-specific `EXT2_IOC_GETFLAGS`/`SETFLAGS` ioctls on a regular file (`e2fsprogs/chattr.c`) and
  `setfattr` uses `setxattr`/`lsetxattr` (`miscutils/setfattr.c`), neither of which this kernel's
  `SYS_IOCTL` (tty-only) or syscall table implement at all -- **removed from the roster before
  v0.1** (see "Removed before v0.1" below), not left mis-attributed

- `flock`/`fsync`/`fallocate`/`truncate` -- **done** this pass: `SYS_FLOCK=475`/`SYS_FSYNC=471`/
  `SYS_FALLOCATE=474`/`SYS_FTRUNCATE=473` (`modules/oxfs`) -- see CLAUDE.md's own "Filesystem/
  process misc syscalls" section for the full design (real per-inode advisory locks, a real
  force-commit for `fsync`, real block-level resize for `ftruncate`/`fallocate`, and why a
  conflicting `flock` request fails `EAGAIN` immediately rather than genuinely blocking)

- `makedevs`/`mknod` -- **done**: `SYS_MKNOD=489` (`modules/oxfs`), moved to WORKS

- `ipcrm`/`ipcs` (SysV IPC) -- **removed from the roster before v0.1**, no SysV IPC syscalls exist

- `chroot` -- **done**: `SYS_CHROOT=490` (`modules/oxfs`), moved to WORKS. `linux32`/`linux64`/
  `nsenter`/`setarch`/`setpriv`/`unshare` (namespaces/personality) -- **removed from the roster
  before v0.1**; namespaces don't fit this kernel's single-address-space model at all, faking them
  would be theater, not a real syscall

- `time` -- **done**: real `wait4` rusage reporting (`SYS_GETRUSAGE=491`), moved to WORKS

- `chrt`/`halt`/`nice`/`poweroff`/`sync` -- **done** this pass: `SYS_SCHED_SETSCHEDULER=481`/
  `SYS_SCHED_GETSCHEDULER=482`/`SYS_SCHED_GETPARAM=483`/`SYS_SCHED_GET_PRIORITY_MAX=484`/
  `SYS_SCHED_GET_PRIORITY_MIN=485`/`SYS_SETPRIORITY=479`/`SYS_GETPRIORITY=480` (`chrt`/`nice`,
  stored, no real scheduling effect), `SYS_REBOOT=486` (`halt`/`poweroff` -- a real QEMU ACPI
  shutdown / plain halt, `src/reboot.rs`), `SYS_SYNC=472` (`modules/oxfs`, all in
  `modules/posix_compat` unless noted) -- see CLAUDE.md's own "Filesystem/process misc syscalls"
  section. `inotifyd`/`mesg` -- **removed from the roster before v0.1** (inotify/hardware, a
  distinct gap that was never going to close on its own)

- `softlimit` -- **done** this pass: `SYS_PRLIMIT64=478` (`modules/posix_compat`) backs real
  `setrlimit(2)`/`getrlimit(2)` (musl's own wrapper for both tries `prlimit64` first
  unconditionally) -- stored per-process, not actually enforced, an honest documented gap, but
  enough for `chpst.c`'s own `setrlimit()` call itself to succeed rather than `ENOSYS`

- no statfs/fstatfs (df's own core syscall) -- **done** this pass: `SYS_STATFS=476`/
  `SYS_FSTATFS=477` (`modules/oxfs`), a real `struct statfs` built from this filesystem's own live
  usage counts: `df`

- `mkfifo` -- **removed from the roster before v0.1**; oxfs has no FIFO/special-file inode kind

- `link` -- **done**: real hard links (`SYS_LINK=488`), moved to WORKS. `ln -s`/`readlink` were
  already done (real `InodeKind::Symlink`, `SYS_SYMLINK`/`SYS_READLINK`, `stat`/`lstat` divergence,
  confirmed live via `modules/oxfs`'s own boot self-check -- symlinks and hard links are different
  mechanisms, both exist now)

##### NEEDS_HARDWARE (0 remaining in the kept roster)

Builds, but needs a real console/VT, serial device, framebuffer, pty pair, or syslog facility -- none of these are modeled. Every entry that was here is now resolved one way or the other:

- `cttyhack`/`setsid` -- **done**, moved to WORKS (see that section's own note)
- everything else in this category (hibernation resume, syslog, framebuffer/pty, serial/tape/IPC
  device, VT/console ioctls) -- **removed from the roster before v0.1**, see "Removed before
  v0.1" below

##### NEEDS_BLOCKDEV (0 remaining in the kept roster -- mount/mountpoint/umount were already done, everything else removed before v0.1)

Builds, but needs a real block device driver or mount table. A real ATA PIO driver + oxfs
mount/format persistence closed the driver half (see CLAUDE.md's own "Real disk persistence"
section), and a real, deliberately scoped mount table (`mount --bind`/`mount -t tmpfs`,
`SYS_MOUNT_BIND`/`SYS_MOUNT_TMPFS`/`SYS_UMOUNT2` in `modules/oxfs`, see that file's own "Mount
table" section) closed enough of the mount-table half to unblock `mount`/`mountpoint`/`umount`
specifically. Everything else in this category needed either a real block-device-agnostic mount
table (this design only ever redirects within oxfs's own single, already-mounted filesystem -- no
second real device or on-disk format is ever attached) or a real partition-table/multiple-on-disk-
format concept, neither of which is planned -- **all removed from the roster before v0.1**: see
"Removed before v0.1" below for the full list (`pivot_root`, `switch_root`, the partition-table/
fsck/mkswap family, `swapoff`, and the device-memory/hardware-profile family).

##### NEEDS_CLOCK (9)

Builds, but needs a real wall clock/RTC/nanosleep -- **stale as of `clock_gettime`/`nanosleep`
landing (see CLAUDE.md's own "Real-time clock" section) -- not wholesale re-probed.**

- need only `nanosleep` (already implemented) -- likely unlocked, not individually re-run:
  `sleep`, `usleep`, `timeout`

- need the clock read more than a real sleep; not re-probed against the current roster to
  confirm they fully work end to end: `date`, `hwclock`, `rtcwake`, `adjtimex`, `crond`, `crontab`

##### NEEDS_INIT (2, down from 6 -- runsv/runsvdir/svlogd/svok removed before v0.1)

Builds, but is specific to an init-system/service-supervisor framework this kernel doesn't have.

- init-system/service-supervisor specific, no init framework here, but kept in the roster: their
  actual mechanics (fork/exec, `setsid`, pidfile via plain file I/O, `kill`) are all things this
  kernel now supports even without a real init framework driving them, so cutting them would be
  removing something that plausibly still saves a user time, not decoration: `bootchartd`,
  `start_stop_daemon`
- `runsv`/`runsvdir`/`svlogd`/`svok` -- **removed from the roster before v0.1**: the runit family
  communicates via control fifos in a supervise directory, and oxfs has no FIFO inode kind at all
  (same root cause as `mkfifo`'s own removal above) -- genuinely, not just nominally, dead

#### Removed before v0.1: 58 applets

All 58 of these still build cleanly (unchanged in `BUSYBOX_APPLETS.md`'s own build-probe
history above), but were deliberately dropped from `build.rs`'s `BUSYBOX_APPLETS_PASS2` and
`modules/oxfs`'s seed list before v0.1 -- not "not yet working," but structurally incapable of
working under this kernel's current, deliberate architectural choices (no VT/console/serial/
framebuffer/syslog device model, namespaces that don't fit the single-address-space model, no
SysV IPC, no ext2 ioctl/xattr support, no FIFO inode kind, no partition-table/swap/hw-profile
concept). Shipping an applet that can only ever print a clean `ENOSYS` doesn't save a user time --
it costs them the time spent discovering that. Applets whose blocker *has* since closed (`chroot`,
`mknod`, `makedevs`, `link`, `time`, `cttyhack`, `setsid`) were fixed forward into WORKS instead of
cut -- see that section's own note. Two applets that looked similarly blocked on paper
(`bootchartd`, `start_stop_daemon`) were kept rather than cut: their actual mechanics don't
require an init framework to function, just primitives (fork/exec/setsid/kill/pidfile) this kernel
already has.

- **hardware/VT/serial/framebuffer/syslog** (22, all of the old `NEEDS_HARDWARE` bucket except
  `cttyhack`/`setsid`): `resume`, `klogd`, `logger`, `logread`, `syslogd`, `fbset`, `script`,
  `scriptreplay`, `setserial`, `devfsd`, `microcom`, `modinfo`, `mt`, `rx`, `chvt`, `deallocvt`,
  `dumpkmap`, `fgconsole`, `loadkmap`, `setconsole`, `setkeycodes`, `setlogcons`
- **namespaces** (6): `linux32`, `linux64`, `nsenter`, `setarch`, `setpriv`, `unshare`
- **SysV IPC** (2): `ipcrm`, `ipcs`
- **ext2 ioctl/xattr** (4): `chattr`, `fatattr`, `lsattr`, `setfattr`
- **FIFO-dependent** (5, oxfs has no FIFO inode kind -- also takes down the runit family):
  `mkfifo`, `runsv`, `runsvdir`, `svlogd`, `svok`
- **misc** (2): `inotifyd` (no inotify syscall), `mesg` (needs a multi-session/other-user's-tty
  concept that doesn't exist with one real console)
- **partition-table/swap/hw-profile family** (17, all of the old `NEEDS_BLOCKDEV` bucket left
  after mount/mountpoint/umount were already done): `pivot_root`, `switch_root`, `blkid`,
  `fdformat`, `fdisk`, `findfs`, `fsck`, `fsck_minix`, `mkfs` (`MKFS_MINIX`'s applet name), `mkswap`, `rdev`, `swapoff`,
  `devmem`, `eject`, `freeramdisk`, `hd`, `readprofile`

**Note for anyone re-running the exhaustive build probe**: these 58 will still show up as "build
succeeded" if the probe is re-run against `third_party/busybox`, since the probe just checks
`musl-gcc` build success, not roster membership. They're absent from `build.rs`/`modules/oxfs`
deliberately, not because they stopped building.

#### Build failed: 83 applets

##### missing-header (54)

Real Linux kernel uapi headers (`linux/*.h`, `mtd/*.h`, `asm/unistd.h`) that musl deliberately doesn't vendor -- hardware/device-ioctl tools (framebuffer, VT/keyboard, MTD flash, I2C, block-device ioctls, netlink) with no portable equivalent.

- missing Linux uapi header (asm/unistd.h) -- musl doesn't vendor real Linux kernel headers: `ionice`

- missing Linux uapi header (linux/fb.h) -- musl doesn't vendor real Linux kernel headers: `fbsplash`

- missing Linux uapi header (linux/filter.h) -- musl doesn't vendor real Linux kernel headers: `udhcpc`

- missing Linux uapi header (linux/fs.h) -- musl doesn't vendor real Linux kernel headers: `blkdiscard`, `blockdev`, `fsfreeze`, `fstrim`, `mkfs_ext2`, `mkfs_reiser`, `nbdclient`, `partprobe`, `tune2fs`

- missing Linux uapi header (linux/hdreg.h) -- musl doesn't vendor real Linux kernel headers: `hdparm`, `mkfs_vfat`

- missing Linux uapi header (linux/i2c.h) -- musl doesn't vendor real Linux kernel headers: `i2cdetect`, `i2cdump`, `i2cget`, `i2cset`, `i2ctransfer`

- missing Linux uapi header (linux/if.h) -- musl doesn't vendor real Linux kernel headers: `ether_wake`, `ifenslave`

- missing Linux uapi header (linux/if_tun.h) -- musl doesn't vendor real Linux kernel headers: `tunctl`

- missing Linux uapi header (linux/input.h) -- musl doesn't vendor real Linux kernel headers: `acpid`

- missing Linux uapi header (linux/kd.h) -- musl doesn't vendor real Linux kernel headers: `beep`, `conspy`, `kbd_mode`, `loadfont`, `setfont`, `showkey`

- missing Linux uapi header (linux/major.h) -- musl doesn't vendor real Linux kernel headers: `raidautorun`

- missing Linux uapi header (linux/netlink.h) -- musl doesn't vendor real Linux kernel headers: `ifplugd`, `mdev`, `uevent`

- missing Linux uapi header (linux/random.h) -- musl doesn't vendor real Linux kernel headers: `seedrng`

- missing Linux uapi header (linux/rfkill.h) -- musl doesn't vendor real Linux kernel headers: `rfkill`

- missing Linux uapi header (linux/sockios.h) -- musl doesn't vendor real Linux kernel headers: `brctl`, `nameif`, `zcip`

- missing Linux uapi header (linux/types.h) -- musl doesn't vendor real Linux kernel headers: `iptunnel`, `slattach`, `tc`, `watchdog`

- missing Linux uapi header (linux/version.h) -- musl doesn't vendor real Linux kernel headers: `losetup`

- missing Linux uapi header (linux/vt.h) -- musl doesn't vendor real Linux kernel headers: `init`, `linuxrc`, `openvt`, `vlock`

- missing Linux uapi header (mtd/mtd-user.h) -- musl doesn't vendor real Linux kernel headers: `flashcp`, `flash_eraseall`, `flash_unlock`, `nanddump`, `nandwrite`, `ubirename`

- missing Linux uapi header (mtd/ubi-user.h) -- musl doesn't vendor real Linux kernel headers: `ubiupdatevol`

##### link-error (1)

Compiles, but fails at final link -- a real undefined-symbol gap, not a missing header.

- collect2: error: ld returned 1 exit status: `lzopcat`

##### kconfig-dependency (25)

The single-symbol-flip recipe isn't enough -- the applet needs a companion Kconfig option (a `select`/`depends on` chain, an alias needing its parent applet, or infrastructure like utmp/SELinux) that a blank-line `oldconfig` pass didn't resolve on its own.

- IPv6 variant selected via a PING feature flag, not its own standalone symbol: `ping6`

- IPv6 variant selected via a TRACEROUTE feature flag, not its own standalone symbol: `traceroute6`

- IPv6 variant selected via a UDHCPC feature flag, not its own standalone symbol: `udhcpc6`

- Kconfig dependency chain not satisfied by a single-symbol flip: `mim`

- Kconfig dependency chain not satisfied by a single-symbol flip (not individually chased down): `nologin`, `readahead`

- alias of tune2fs -- Kconfig requires TUNE2FS enabled too, not a single-symbol flip: `e2label`

- requires CONFIG_SELINUX infrastructure, not a single-symbol flip: `chcon`, `getenforce`, `getsebool`, `load_policy`, `matchpathcon`, `restorecon`, `runcon`, `selinuxenabled`, `sestatus`, `setenforce`, `setfiles`, `setsebool`

- requires utmp/wtmp support infrastructure, not a single-symbol flip: `last`, `runlevel`, `users`, `wall`

- selected via FEATURE_TFTP_GET/PUT on a shared tftp applet, not its own standalone symbol: `tftp`, `tftpd`

##### not-a-real-applet (3)

The `//applet:` marker my candidate-extraction grep matched isn't live source -- a docs example or intentionally-disabled reference file, never reachable from a real Kconfig symbol.

- docs/embedded-scripts.txt example only -- no real CONFIG_MU Kconfig symbol exists: `mu`

- klibc-utils/ipconfig.c.txt -- a .txt reference file, never wired into Config.in/the real build at all: `ipconfig`

- libbb/parse_config.c's applet marker is commented out (////applet:, not //applet:) -- example code, not a real applet: `parse`

##### missing-from-this-list entirely (known, at least 1)

The mirror-image problem from `not-a-real-applet` above: a real, live applet with a real
`//applet:` marker that this list's own candidate extraction simply never caught, rather than
correctly excluding. `287 + 83 = 370` against a claimed 393 candidates means there's a real gap
here beyond the one instance actually chased down -- nothing else has been individually
identified.

- `lsmod` (`modutils/lsmod.c`) -- real marker
  (`//applet:IF_LSMOD(IF_NOT_MODPROBE_SMALL(APPLET_NOEXEC(lsmod, lsmod, BB_DIR_SBIN,
  BB_SUID_DROP, lsmod)))`), never probed at all; the nested `IF_LSMOD(IF_NOT_MODPROBE_SMALL(...))`
  wrapping likely slipped past whatever grep built the original candidate list. Would build cleanly
  today (`allnoconfig` + `LSMOD`, no exotic dependencies) and, now that `/proc/modules` exists (see
  CLAUDE.md's oxfs section), would even find a real file to read -- but it parses real Linux kernel
  modules' own format (dependency lists, reference counts, `insmod`/`rmmod` semantics), a concept
  that doesn't actually exist on this kernel. Deliberately left unbuilt in favor of a real
  purpose-built native tool instead: `userland/lsoxmod/`, seeded into oxfs at `/bin/lsoxmod` with
  `/bin/lsmod` as a real symlink alias, reads that same `/proc/modules` file and formats it
  honestly for what it actually is -- OxideBSD's own `src/module.rs` loader's state, not Linux
  kernel modules. Same "builds is a much weaker bar than works correctly" reasoning this file's own
  intro already states, just caught before wiring the applet up at all rather than after.

#### Second cut, 2026-09-23: 48 more removed, the rest out of `/bin`

48 applets were removed from the roster (listed in `HIER.md`'s "Removed 2026-09-23"), and the
tuples for the 12 native `bin/` utilities and BusyBox `vi` went with them. 195 BusyBox applets
remain, placed per `HIER.md` across `/bin`, `/sbin`, `/usr/bin` and `/usr/sbin`. BusyBox `sh`
(hush) is `/bin/hush`; `/bin/sh` is OxideBSD's own shell. The categories below predate this cut
and still list the removed names.

#### Third cut, 2026-09-30: 45 more removed (init step 9)

**139 BusyBox applets remain.** Removed in one rebuild:

- **Replaced by native programs** (step 9): `crond`, `crontab` (cron(8), crontab(1)), `sysctl`,
  `dmesg` (`/sbin`'s own), `halt`, `poweroff` (`/sbin/reboot`; these two were already built but
  not installed).
- **Superseded by OxideBSD's own mechanisms**: `hush` (`/bin/sh`; `test_busybox.sh` and
  `/sbin/emergency`'s fallback moved to `ash`), `run-parts` (periodic(8)), `start-stop-daemon`
  (rc.subr), `makedevs` (devfs), `killall5` (init's shutdown), `cttyhack` (init gives each
  session the console).
- **In no BSD base system** (Linux, Debian or daemontools tools): `setuidgid`, `envuidgid`,
  `softlimit`, `chrt`, `remove-shell`, `cryptpw`, `mkpasswd`, `pscan`, `pipe_progress`,
  `ttysize`, `volname`, `ipcalc`, `dnsdomainname`, `mountpoint`, `pwdx`, `free`, `usleep`, `ts`,
  `fallocate`.
- **Useful, but ports material** rather than base on any BSD: `lsof`, `pstree`, `tree`, `watch`,
  `hexedit`, `dos2unix`, `unix2dos`, `shuf`, `shred`, `crc32`, `ascii`, `lzop`, `lzcat`,
  `unlzma`.

Kept although not BSD-base, as the only tool of their kind until a native one exists: `minips`
(the only `ps`), `wget` and `ssl_client` (the only HTTPS client, until a `fetch`), `su` (until
sudo-rs), `nslookup`, `ftpget`, `ftpput`. Still BusyBox and due for native rewrites: 26 in
`/bin` (`ash` stays for `configure`) and 4 in `/sbin`; see `INIT_WORKPLAN.md`.

#### Since the third cut

- 2026-09-30 (`bc401ba`): `sleep`, `sync`, `link`, `unlink`, `rmdir`, `nproc`, `kill`, `test`,
  `chmod` rewritten in Rust and removed.
- 2026-10-01: `mount` and `umount` removed; native ones in `/sbin` (`8a7d30a`) over `nmount(2)`,
  which musl's `mount(3)` now uses too. **128 BusyBox applets remain.**

*(from INIT_WORKPLAN.md, cut 2026-10-01)*

#### Step 9 as planned

BusyBox's `dmesg`, `sysctl`, `crond`, `crontab` stop being installed once their replacements
exist. Editing `build_busybox.rs` costs a ~30-minute BusyBox rebuild: make all four removals in
one edit, together with any other pending roster change.

### 15.4. BusyBox gap analysis: what's needed for more applets

*(from CLAUDE.md, 2026-09-29)*

Almost everything left needs one of a handful of missing kernel capabilities, each unlocking a
cluster of applets at once. New syscall numbers should continue from the highest currently
assigned. `OxideBSD-doc/BUSYBOX_APPLETS.md` is the authoritative per-applet detail behind this summary
table (counts are out of the 287 applets that built at all; a pre-v0.1 pass cut 58 of those 287
entirely — structurally incapable of working here, not "not started yet"). 229 remain seeded.

| Gap | Status | Notes |
|---|---|---|
| `argv[0]` passthrough, real signals, process groups, termios/`ioctl`, `stat`/`fstat`/`lstat`, `getdents`/`getdents64` | done | foundational, all landed early |
| Socket syscalls + real DNS, `socketpair`/`fcntl`/`shutdown`/`set_tid_address`/`readv` + `/dev/{u}random,null,zero` + real `tcp_read` EOF fix | done | `wget` HTTPS confirmed live end to end — see "Real networking" |
| `alarm`/`setitimer` | done | unlocks `ping`'s receive-loop timeout |
| `chmod`/`chown`/`chgrp` | done | ext2 `ioctl`/`xattr` (`chattr`/`fatattr`/`lsattr`/`setfattr`) removed from roster before v0.1 instead |
| `fsync`/`sync`/`ftruncate`/`fallocate`/`flock`/`statfs`/`setrlimit`/sched-priority/`reboot`, `link`/`mknod`/`chroot`/`getrusage` | done | see their own sections above |
| SysV IPC, namespaces, `inotify`, ext2 ioctl/xattr | not started, 0 remaining blocked | the applets that needed these were removed from the roster before v0.1 — namespaces don't fit this kernel's single-address-space model at all |
| `/proc` (per-process, system-wide, per-fd) + real symlinks | done | special-cased path prefix in `sys/modules/oxfs`, no VFS layer to plug into |
| Console/VT ioctls, serial/tape/I2C hardware, syslog, real pty | not started, 0 remaining blocked | `cttyhack`/`setsid` already worked and moved to WORKS; rest removed before v0.1 |
| Real block device driver + oxfs persistence, mount table | done | see "Real disk persistence"/"Mount table" — still a fixed, non-mountable backing store; `pivot_root`/`switch_root`/partition tables remain out of scope |
| uid/passwd-db model, real login/session auth | done | `adduser`/`chpasswd`/`passwd` still need real *mutation* of `/etc/passwd`/`/etc/group` (applet-level gap) |
| `clock_gettime`/`gettimeofday`/`time`/`nanosleep` | done | — |
| Init-system/service-supervisor framework | not started, out of scope | 2 applets kept anyway (don't need a real init framework); 4 removed (runit family needed FIFOs, which exist now) |
| `tcsetpgrp`/real job control | done | see "Real job control" |
| `uname`/`gethostname` | done | `gethostname` is a pure musl wrapper around `uname()`, no new syscall |

### 15.5. TinyCC (removed 2026-09-20)

*(from CLAUDE.md, 2026-09-29)*

An earlier TinyCC port (`third_party/tinycc`) was this project's first real, on-target C compiler
— proved a real `tcc -static -o hello.elf hello.c && ./hello.elf` round trip, contributed
`SYS_LSEEK`/the `ensure_dir`/`seed_tree` directory-seeding infra oxfs still uses, and found two
real GOT/PLT-relocation bugs (one in musl's own PIE-defaulting `configure` probe, one in TinyCC's
own static-link codegen). Removed entirely (2026-09-20 cleanup) once Clang/LLVM (below) superseded
it as this project's real on-target C/C++ toolchain — see git history for TinyCC's own design if
ever needed again.

### 15.6. Clang/LLVM port: Milestone 7 done, real compile+link+run round trip (`external/apache2/llvm`, `sys/modules/oxfs`, `build.rs`)

*(from CLAUDE.md, 2026-09-29)*

A real on-target C/C++ toolchain — genuinely self-hosted (a host-built cross-compiler builds a
target-executable `clang`+`ld.lld`), not vendored binaries. Vendored as a submodule
(`OxideBSD/llvm-project-oxidebsd`, `oxidebsd` branch, sparse checkout trimmed of tests/docs/
unittests, tag `llvmorg-23.1.2`; no shared upstream history — see its `VENDOR_NOTES.md` for how to update). `build.rs`: `build_llvm_host_toolchain` (host cross-compiler) →
`build_llvm_target_runtimes` (libc++/libc++abi/libunwind + compiler-rt, statically self-contained)
→ `build_llvm_target_toolchain` (the real, on-target-executable `clang`+`ld.lld`, built using the
host cross-compiler). A real `Triple::OxideBSD` + `clang::driver::toolchains::OxideBSD`
(`clang/lib/Driver/ToolChains/OxideBSD.{h,cpp}`) picks `gnutools::{Assembler,Linker,StaticLibTool}`
and defaults to LLD by literal name (`ld.lld`), not a triple-prefixed name. `sys/modules/oxfs` seeds
`clang`/`ld.lld` under `/bin`, plus a generated `/lib/clang/23` resource-dir tree
(`write_clang_runtime_manifest`, mirroring `write_musl_runtime_manifest`'s pattern).

**This is the real subprocess-pipeline milestone CLAUDE.md's own intro names as the reason GCC/
Clang were historically unstarted**: `clang`'s driver forks real, separate `cc1`/`ld.lld` child
processes — not something built here, just something that had to start working. Getting from
`ld.lld --version` running at all to a real `clang -static -o out.elf in.c` round trip took three
real, independent bugs, each found live via `tests/clang_syscall_smoke.rs` +
`regress/clang-syscall-smoke/`:

- **A real musl bug, `__init_tls.c`**: its raw `mmap` syscall for large-`PT_TLS` binaries never got
  the packed-args ABI patch the public `mmap()` wrapper already has — `ld.lld` (the first on-target
  binary with a `PT_TLS` big enough to cross musl's `builtin_tls` fast-path threshold) crashed with
  a page fault into `-EFAULT`. Fixed on the musl `oxidebsd` branch.
- **`oxfs_fstat` returned a flat `EBADF` for the console's stdin/stdout/stderr** (`real_fd` `0`/`1`/
  `2` — no backing oxfs inode exists for them). `llvm::sys::Process::FixupStandardFileDescriptors()`
  genuinely `fstat()`s its own fd `0`/`1`/`2` at Clang startup; the `EBADF` made it conclude all
  three were invalid and `dup2` every one onto a freshly opened `/dev/null` — silently discarding
  every one of Clang's own later diagnostic/output writes, no visible error anywhere. Fixed:
  `oxfs_fstat` synthesizes a real character-device `stat` for `real_fd <= 2` instead.
- **`do_clone` flatly rejected `CLONE_VM|CLONE_VFORK|SIGCHLD`** (real vfork-via-`clone()`) — exactly
  what musl's own `posix_spawn()` issues to launch `ld.lld` (`external/mit/musl/src/process/
  posix_spawn.c`). Fixed: `do_clone` accepts this second flag combination too, degrading to a real
  `fork()` (`do_vfork_clone`, sharing `do_fork_from_current`'s body via a common `fork_impl`) — the
  same "vfork degrades to fork" simplification `vfork.s` already uses, POSIX-legal. Uncovered a
  **paired real musl ABI bug**: `clone.s`'s hand-written asm stub bypasses `syscall_arch.h`'s normal
  carry-flag→negative-errno conversion (same bug class as `vfork.s`/`__unmapself.s` before it, the
  ABI-convention half rather than the number-remap half) — on failure it returned this kernel's raw
  *positive* errno as-is, which `posix_spawn` read as a small, valid-looking child pid instead of an
  error, then `waitpid()`'d on a pid that was never created (`ECHILD`, ABI-wire evidence, not the
  real failure). Fixed on the musl `oxidebsd` branch.
- **A real, deferred gap in the `OxideBSD` toolchain's own constructor, closed once a real on-target
  invocation finally exercised it**: `OxideBSD::OxideBSD()` only ever registered `SysRoot + "/lib"`
  as a `crt1.o`/`crti.o`/`crtn.o` search path (correct for the *host-side* cross-compile sysroot
  layout, `target/musl-sysroot`) — but on-target, `D.SysRoot` is empty (nothing to point
  `--sysroot=` at) and the real oxfs seed layout puts those files under `/usr/lib` instead.
  `ToolChain::GetFilePath` silently falls back to an unresolved bare filename on a
  miss, which is exactly what left `ld.lld` invoked with a plain `"crt1.o"` it could never open.
  Fixed: the constructor now registers both directories.
- **The smoke test's own invocation needed fixing too**: `argv[0]` must be the resolvable
  `/bin/clang`, not the bare `"clang"` (Clang's own `InstalledDir` self-location came up empty
  otherwise), and `--target=x86_64-unknown-oxidebsd-musl` must be passed explicitly (the on-target
  binary's own baked-in default triple is still `x86_64-unknown-linux-gnu`).

**Two more real bugs closed the whole milestone, both root-caused by hexdumping the actual
committed object bytes (not more syscall tracing) once a real link kept failing with `ld.lld:
error: <obj>: section header string table index 1 does not exist`:**

- **Real bug 1, in oxfs itself**: `llvm::raw_fd_ostream::pwrite_impl` (LLVM's ELF object writer,
  on every platform — never a real `pwrite64` syscall) backpatches a freshly-written object's
  header (`e_shoff`/`e_shnum`, computed only after every section is already written) via
  `lseek(SEEK_SET)` + `write()` + `lseek(SEEK_SET)` on its own plain `O_WRONLY` output fd. oxfs's
  `Write`-mode fds reported `ESPIPE` for *any* `lseek()`, silently ignored by LLVM's own
  error-handling (no crash) — so both backpatch `write()`s landed at the file's real tail instead
  of overwriting the header in place, leaving `e_shoff`/`e_shnum` at their initial zero
  placeholders (confirmed byte-for-byte: the object's last 10 bytes were exactly the two patch
  values that belonged at offsets 40/60). Fixed: every `Write` fd (`O_WRONLY` included, not just
  `O_RDWR`) now gets a real seekable `position`, and `oxfs_write` compares it against the
  streaming path's own natural next-append offset (`write_pos + len`) to decide whether a
  `write()` call should take the existing fast buffered-append path or instead overwrite at that
  exact seeked position via the same `write_inode_at` primitive `pwrite(2)` already uses
  (`oxfs_lseek`/`oxfs_write` in `sys/modules/oxfs/sys/lib.rs`).
- **Real bug 2, in musl**: `execve.c`'s own `MAX_EXECVE_ENTRIES` (a fixed-size stack array
  converting a real NUL-terminated `argv[]` into this ABI's length-prefixed wire format) was
  hardcoded to `32`, stale against `sys/process/lifecycle.rs`'s own `MAX_PTR_LEN_ENTRIES` (raised
  to `256` earlier in this same port) — silently truncating a real `clang` driver → `cc1`
  subprocess exec's argv mid-flag whenever enough preceding flags (`-dumpdir`/`-static-define`,
  present only on the full compile+link path, never a bare `-c`, which clang runs `cc1` in-process
  and never execs at all) pushed a later flag's own *value* past index 31 — surfaced as a bogus
  `error: argument to '-internal-isystem' is missing`. Fixed on the musl `oxidebsd` branch.
  **A third, real build-caching gap found applying this fix**: `build_llvm_target_toolchain`'s own
  staleness check only ever compared `clang`/`ld.lld`'s mtimes against the *host* build's
  `libc++.a`, never `musl_sysroot`'s — so a musl-only fix left the on-target `clang`/`ld.lld`
  binaries looking "fresh" and silently kept linked against the *old* musl (this build-caching
  bug class already burned the regress/std/`sys/modules/oxfs` build path once, see the std-target
  section below — same shape, different consumer). Fixed: the staleness floor now includes
  `musl_sysroot`'s own `libc.a` mtime, and going stale that way now deletes just the two output
  binaries (not the whole build dir) to force a real `ninja` relink from already-compiled objects,
  since ninja itself has no dependency edge from an external sysroot lib to its own link steps.

Verified end to end via `tests/clang_syscall_smoke.rs`: a real `clang -static -o /hello.elf
/hello.c` (real `cc1` compile, real `ld.lld` link against `crt1.o`/`crti.o`/`crtn.o`/
`libclang_rt.builtins.a`/`libc.a`/`crtn.o`) followed by actually running the produced `/hello.elf`,
which printed its own output and exited `0`. Closes this port's own headline subprocess-pipeline
milestone.

**C++ stage (self-hosting clang, step 2)**: libc++/abi/unwind seeded FreeBSD-style
(`/usr/include/c++/v1`, per-triple `__config_site` under `/usr/include/<triple>/c++/v1`, archives in
`/usr/lib`; `write_libcxx_runtime_manifest`), `/bin/clang++ -> clang`, the LLVM fork's
`OxideBSD::addLibCxxIncludePaths`, and `LLVM_DEFAULT_TARGET_TRIPLE` (no `--target=` needed any
more). `tests/clangxx_syscall_smoke.rs` does a bare `clang++ -static -o /hello-cpp.elf /hello.cpp`
and runs it (`sys/modules/oxfs/src/hello.cpp`: STL, exceptions across frames, RTTI, 4x
`std::thread`+mutex, `std::filesystem`). Real bugs found:
- **`-DCLANG_DEFAULT_SYSROOT` was never a real cmake variable** (it's `DEFAULT_SYSROOT`) -- the
  on-target sysroot was silently empty for the whole port. C hid it (cc1's own `InitHeaderSearch`
  falls back to `/usr/include` for driver-unclaimed triples; `/usr/lib` was registered explicitly).
- `build_llvm_target_toolchain` only configured once and never tracked the patched driver sources
  -- fixed with a configure-args stamp (`oxidebsd-configure-args.stamp`) plus a direct
  `clang/lib/Driver` mtime floor. `build_llvm_target_runtimes` now bumps `libc++.a`'s mtime after a
  no-op ninja run (was permanently "stale" vs. a relinked host clang).
- `std::filesystem::remove_all` needed the whole `*at()` family (libc++ uses `openat`/`unlinkat`/
  `fdopendir`) -- see "The `*at()` family" below.

### 15.7. bmake (`usr.bin/make`, `build.rs`'s `build_bmake`) — self-hosting stage 1: **done**

*(from CLAUDE.md, 2026-09-29)*

Upstream portable bmake 20260912, vendored as a plain committed tree (tarball from crufty.net; no
git mirror exists, no fork). Cross-built by `configure --host=…` (skips run-tests) +
`make-bootstrap.sh` into a static `ET_EXEC` at `0x18000000`; `/bin/bmake` (+ `/bin/make` symlink),
`*.mk` seeded at `/usr/share/mk` (`BMAKE_MK_FILES`). Verified live (headless `sendkey`): bmake
drives on-target `clang -c` + link + run, incremental rebuilds/`touch` dependency tracking correct.
Editing `build.rs` does *not* stale BusyBox (only `build_busybox.rs` does). Known: `gettid` (186)
is unrecognized — clang logs it once per compile, harmless so far. **Genuinely self-hosts on
target now, not just pre-built**: bmake's own `configure` + `make-bootstrap.sh`, run on-target
under `/bin/ash` driving on-target `clang`, both exit `0` and produce a real, working `bmake`
binary built entirely from its own source (see the `NAME_MAX` bug below for what blocked this).
Staged plan for the rest of self-hosting: C → C++ (seed libc++) → ninja/cmake → rebuild clang;
**nano (+ vendored ncurses) is next, planned for a separate session.**

- **`hush` can't parse `>&$var`** (redirect to a variable file descriptor, e.g. `>&$4`) — real
  BusyBox `shell/hush.c` parser limitation (`redirect_opt_num`'s own `//TODO: this is the place to
  catch ">&file" bashism` comment, "ambiguous redirect"), hit immediately by autoconf-generated
  `configure` scripts (`as_fn_error`'s `>&$4`). Not a bug to patch in BusyBox — routed around by
  running `configure`/`make-bootstrap.sh` under `/bin/ash` instead (`CONFIG_SHELL=/bin/ash ... ash
  configure ...`), already in the seeded roster.
- **The real bug: `NAME_MAX=40` was too short, and the over-length check returned the wrong
  errno**, found self-hosting bmake's own build on-target. Symptom chain, each link confirmed
  directly rather than assumed: BusyBox `tar` extracting bmake's own real source tree silently
  dropped exactly 3 files (`util.c`/`var.c`/`wait.h` — the archive's *last* 3 members, out of 985)
  even on a freshly-formatted disk with hundreds of MiB and thousands of free inodes to spare
  (`statfs()` confirmed real headroom on both counts, ruling out `ENOSPC`); a **host-native build
  of the identical vendored BusyBox source** (`make O=... allnoconfig` + flip `CONFIG_TAR`, run
  directly on the host, no OxideBSD involved at all) extracted all 985 members correctly, ruling
  out a BusyBox-source bug; capturing `tar`'s own stderr on-target (every earlier attempt had
  discarded it) surfaced the real error directly: `tar: can't remove old file
  bmake/unit-tests/varname-dot-make-meta-ignore_patterns.exp: Invalid argument` — a 41-byte
  filename, one byte past oxfs's `NAME_MAX = 40`. `dir_insert`'s own length check returned
  `OxfsError::InvalidPath` (`EINVAL`) for an over-length name instead of the semantically-correct,
  already-defined `OxfsError::NameTooLong` (`ENAMETOOLONG`) — `EINVAL` is what BusyBox `tar`
  doesn't tolerate, aborting the whole archive instead of continuing past one bad name.
  **Fixed**: `NAME_MAX` raised `40 → 255` (matching musl's own compiled-in `NAME_MAX`,
  `external/mit/musl/include/limits.h` — closes the mismatch for real, not just this one filename),
  both wrong-errno call sites (`dir_insert`, `resolve_parent`) now return `NameTooLong` correctly,
  `SUPERBLOCK_VERSION` bumped `2 → 3` (`DIR_RECORD_SIZE` changed, `6 + NAME_MAX`: 46 → 261 bytes —
  a real on-disk layout change, needs the same automatic-reformat treatment every prior
  `SUPERBLOCK_VERSION` bump got). Verified end-to-end: a full, genuine self-hosted build —
  `configure` (under `ash`, see above) + `make-bootstrap.sh`, both `rc=0`, real on-target `clang`
  compiling `var.c`/`util.c`/the `wait.h`-dependent code that used to be missing, linking a real,
  working `bmake` binary that reports its own correct version string. **Accepted tradeoff**:
  `RECORDS_PER_BLOCK` drops `89 → 15` (more real directory blocks needed for the same content), a
  real, meaningfully slower format/flush and heavier ongoing directory-write I/O — see the
  freeze-that-wasn't below for why this matters.
- **A real, documented misdiagnosis along the way, corrected rather than left standing**: the
  above investigation's early attempts (before stderr was captured) looked like a genuine
  full-kernel freeze — QEMU pinned near 100% CPU, zero new serial output, and the QEMU monitor's
  own `sendkey` confirmed a keystroke was sent successfully yet the guest never echoed it
  (console-IRQ-level echo happens independent of scheduling, which is why this looked like more
  than "just a busy foreground process"). `gdbserver`-attached (QEMU monitor `gdbserver
  tcp::<port>`, then `gdb -ex "target remote localhost:<port>"`) at freeze time: caught inside
  `cpu::rtc::cmos_read`'s raw `in al, dx`, with **`RSP` reading `0x44444472a1d4`** — read at the
  time as a corrupted/poisoned stack pointer (a suspicious repeating-nibble pattern), which is what
  motivated a `process::KERNEL_STACK_SIZE_CEILING` bump (`512 KiB → 4 MiB`) as a stack-overflow
  mitigation, briefly landed and even backported to `v0.2.x`. **That reading was wrong**:
  `allocator::HEAP_START = 0x_4444_4444_0000` — `0x444444...` is this kernel's own real heap base
  address, not corruption; an ordinary `KernelStack::new` (`alloc_zeroed`) stack legitimately lands
  there. Confirmed directly: re-running the identical repro (stack ceiling still raised) hit the
  identical symptom again — and this time, instead of assuming it was dead, it was left running far
  longer. It completed cleanly on its own (`configure`'s real `exit 0`, then a real bootstrap
  compile+link). Repeated `gdbserver` sampling a few seconds apart during the "freeze" showed `RIP`
  genuinely moving between real functions (`cpu::rtc::cmos_read`, `drivers::ata::outsw`), not
  stuck at one instruction — consistent with real, if slow, ongoing work, not a hang. **What
  actually explains the symptom**: a real, syscall-scoped stretch of heavy disk I/O (many real ATA
  block writes, each preceded by a real RTC read for mtime-stamping — see "Filesystem: oxfs"
  above), run with interrupts masked for that syscall's duration (`SFMASK` clears `IF`, see the
  syscall-ABI section), made meaningfully worse by this same investigation's own `NAME_MAX` fix
  (more, smaller directory records → more real per-block ATA writes for the same directory
  content) — long enough, with interrupts genuinely off, to look indistinguishable from a hang.
  **The stack-ceiling bump has been reverted** (`sys/process/mod.rs`, back to 512 KiB — see its own
  doc comment) on master and via a follow-up revert commit on `v0.2.x`, since there was never real
  evidence it needed to move. Kept in this file specifically so a future investigation hitting the
  same "everything just stopped" symptom on a real slow-I/O stretch doesn't retread the same false
  trail: verify `RIP` is genuinely stuck (not just sampled once) and check whether the address in
  question is a real, named constant (like `HEAP_START`) before concluding "corruption."

### 15.8. ncurses, nano, nvi: a real BSD-shaped curses/editor stack (`lib/ncurses`, `bin/vi`, `usr.bin/nano`, `build.rs`, `sys/console/vga.rs`, `sys/process/lifecycle.rs`)

*(from CLAUDE.md, 2026-09-29)*

The self-hosting plan's next stage after bmake (see that section above) -- a real curses library
plus two real editors, matching how the actual BSDs split the role: `/bin/vi` (OpenVi, a portable
extraction of OpenBSD's own vi/ex, BSD-3-Clause) is the essential, single-user-mode-capable editor;
`/usr/bin/nano` (GNU nano, GPLv3+) is everything-else. ncurses itself mirrors FreeBSD's own choice
to vendor it directly into base (`lib/ncurses`, not `external/`) -- permissively (X11/MIT-style)
licensed despite the "GNU" association, and its portable autotools build is exactly the kind of
`./configure && make` self-hosting story this stage is chasing.

- **Vendoring**: ncurses is a plain committed tree (6.6, no submodule -- same reasoning as bmake,
  no single canonical upstream git to fork, just versioned tarballs). `nano`/`vi` are submodules of
  personal forks (`OxideBSD/nano-oxidebsd` from `ahjragaas/nano`, a fast-syncing unofficial mirror
  of the real `git.sv.gnu.org/nano.git`; `OxideBSD/OpenVi-oxidebsd` from `johnsonjh/OpenVi`), each
  pinned to an `oxidebsd` branch -- same convention as musl/busybox.
- **`build_ncurses`**: cross-builds a real, wide-char (`ncursesw`, genuine UTF-8 support) static
  `libncursesw.a`/`libpanelw.a`/`libmenuw.a`/`libformw.a` + headers against `musl_sysroot`,
  installed to its own `target/ncurses-sysroot`. Library + headers only -- `tic`/`tset`/`tput`/...
  are deliberately out of scope for now (each would need its own fixed load address like every
  other `ET_EXEC` here); the one terminfo-compile step this build needs uses the *host's* own
  `tic` instead (confirmed byte-version-identical to this vendored release), producing a
  deliberately minimal compiled terminfo database (`linux`/`vt100`/`vt100-am`/`dumb` -- the only
  `TERM` values this kernel's own console will ever report) seeded at `/usr/share/terminfo`.
- **Two real musl gaps closed for OpenVi's own `cl/*.c`/`common/*.c`**: `<sys/queue.h>` and
  `<bitstring.h>` (both real BSD-isms, not POSIX, so musl ships neither) -- vendored from real
  FreeBSD (BSD-3-Clause, kept verbatim) into this project's own musl fork. `<sys/queue.h>` needed a
  companion `<sys/cdefs.h>` shim too (`__containerof`/`__predict_false`/...) -- FreeBSD's own real
  version isn't a clean standalone drop-in (cascades into further FreeBSD-internal headers), so
  this one is a small, purpose-built reimplementation of just those macros, still tagged
  BSD-3-Clause (its shape is FreeBSD's, not independently invented, even though the file itself
  is). `<bitstring.h>` needed light patching too (`<stdlib.h>`/`<strings.h>` includes FreeBSD's own
  build environment provides transitively but musl doesn't, `__builtin_popcountl` in place of
  glibc's own internal `__bitcountl` alias). **A real location bug found live**: `bitstring.h`
  belongs directly under `/usr/include`, not `/usr/include/sys/` -- confirmed via OpenVi's own
  `#include <bitstring.h>` (no `sys/` prefix), matching real BSD's own `bitstring(3)` convention.
- **`build_nvi`**: OpenVi's own plain `GNUmakefile` (no autotools) directly -- already portable,
  ships its own BSD-compat shims (`openbsd/strlcpy.c`/`getopt_long.c`/`reallocarray.c`/...) for
  exactly this kind of non-glibc/non-BSD target. **Two real GNU Make variable-precedence gotchas,
  opposite directions, neither a bug in the Makefile itself**: `CURSESLIB`/`OS` are passed as
  `make` command-line args (highest precedence) so the Makefile's own `ifndef CURSESLIB`
  pkg-config-autodetect and `ifeq ($(OS), ...)` platform branches reliably short-circuit;
  `CFLAGS`/`LDFLAGS` are passed as **environment** variables instead, since a command-line-origin
  value would silently block the Makefile's own `CFLAGS += $(CSTD) $(INCLDS)` entirely (GNU Make
  blocks *any* makefile-side assignment to a command-line-overridden variable, `+=` included) --
  found live via every `cl/*.c` file failing `fatal error: bsd_stdlib.h: No such file or
  directory` despite that header genuinely existing in `include/`, simply because `-Iinclude` had
  been silently dropped.
- **`build_nano`**: the bare git checkout deliberately ships no `configure` (upstream's own
  `autogen.sh` clones a separate `gnulib` repo at `--depth=2222` and runs `gnulib-tool`+
  `autoreconf` to produce one fresh) -- rather than replicate that heavy chain, the `oxidebsd`
  branch overlays the exact generated output (`configure`/`config.h.in`/`m4/*`/the gnulib-derived
  `lib/` shim) the official v9.2 release tarball already ships. Real, full-featured wide-char
  build (`ncursesw`, not `--enable-tiny` -- this project's own ncurses has no narrow fallback, and
  a stripped-down editor isn't the point). **A third real Make gotcha, the opposite precedence
  choice from OpenVi's for a genuinely different reason**: automake substitutes `@LDFLAGS@` into
  the generated `src/Makefile` *at configure time* as a hardcoded plain `=` assignment, which
  always overrides an environment-origin value (unlike a command-line-origin one) -- an
  environment `LDFLAGS` at `make` time was silently ignored entirely, producing a `nano` linked at
  the linker's own default base (`0x402554`) squarely inside this kernel's reserved low-memory
  region instead of a real, chosen `-Wl,-Ttext-segment=`. Fixed by passing `LDFLAGS` as a `make`
  command-line argument at the final build step specifically (the one point after `configure` that
  still has a chance to override it).
- **A real BusyBox-applet env-var collision, found live via a real boot, not by inspection**:
  BusyBox already ships its own compact `vi` applet, and `oxfs_env_var_name` derives an env var
  name purely from the seeded filename with no notion of "already taken" -- both BusyBox's own `vi`
  and this real OpenVi replacement produced an env var literally named `OXFS_VI_ELF_PATH`.
  `Command::env`'s last-write-wins semantics meant OpenVi's real build was silently never actually
  reaching the seeded filesystem at all; `ls -la /bin/vi` inside a real boot reported BusyBox's
  much smaller size instead. Fixed the same way `NATIVE_BIN_UTILITIES` handles this class of
  collision for the native `/bin` utilities -- a small, separate `REPLACED_BUSYBOX_APPLETS` list
  (kept separate since `NATIVE_BIN_UTILITIES` also drives building each entry as a `bin/<name>`
  oxlibc crate, which doesn't fit a real cross-compiled C program) filters BusyBox's own `vi` out
  of the roster entirely.
- **A real, previously-unhit gap in this kernel's own VT100/ANSI console parser, found live**:
  `sys/console/vga.rs`'s `execute_csi` had no case for VPA (`ESC[Nd`, vertical position absolute)
  -- nothing in the prior userland roster ever emitted it, so the pre-existing `_ => {}` catch-all
  silently swallowed it instead of moving the cursor. OpenVi's own curses backend uses VPA for
  nearly every row-only cursor move (its status-line/tilde-fill redraw is almost entirely `ESC[Nd`
  sequences), so every subsequent write landed at whatever position the cursor was last left at
  instead of where the program intended -- visually collapsing a full-screen redraw down to just
  its own last line (confirmed via a real screendump showing only the status line, everything else
  black, before the fix; a full, correct redraw -- real file content, tilde fills down the whole
  screen, status line correctly on the last row -- after it). Fixed alongside its sibling gap, CHA
  (`ESC[NG`)/HPA (`` ESC[N` ``), the same class even though not yet confirmed hit.
- **A real `$PATH` gap, found live once something was actually seeded at `/usr/bin`**: pid 1's own
  `envp` only ever set `PATH=/bin` (see "Real job control" above) -- nothing had ever needed
  `/usr/bin` to exist until `nano` did. A bare `nano` invocation failed `ENOENT` via `execvp()`'s
  real `$PATH` search despite the file genuinely existing at `/usr/bin/nano`. Fixed:
  `PATH=/bin:/usr/bin`.
- **A real, severe, three-layered keyboard-input hang, found live *after* the section above's own
  original "verified" claim** (real rendering was genuinely confirmed; real interactive typing
  wasn't tested until a live session tried it and reported "nano freezes the entire machine,
  albeit it's still running") -- root-caused via `gdb`/`gdbserver` (the same live-debugging
  approach used for bmake's own investigations), not guessed:
  1. **`SYS_POLL`/`SYS_SELECT`'s generic "not a socket fd -> always ready" fallback (`sys/net/
     mod.rs`) was wrong for the console specifically.** Correct for a regular oxfs file or a pipe
     (this stack doesn't model real blocking for either), but stdin is genuinely, legitimately
     empty whenever nobody's typing -- and a real curses program's own `nodelay()`-mode "drain any
     further already-buffered keys without blocking" idiom (`nano`'s own `read_keys_from`,
     `usr.bin/nano/src/winio.c`) depends on a zero-timeout `poll`/`select` honestly reporting
     "nothing here yet" to know when to stop and hand a complete keystroke back to its own caller.
     Fixed: a real `console::stdin::has_bytes_available()` check, special-cased for `real_fd == 0`
     (a fixed, global mapping -- see `sys/fs/fd.rs`'s `init`) in both syscalls, instead of the
     blind fallback.
  2. **A real, separate, pre-existing bug that fix #1 newly exposed rather than caused**: `sys/drivers/
     rtl8139.rs`'s `poll_recv` had no genuine iteration bound, unlike every other syscall-reachable
     retry loop in this kernel (this section's own networking "architectural gotchas" already
     establish `spin_loop()` not `hlt()`, always `tsc`-bounded). Before fix #1, `oxidebsd_sys_poll`
     always returned "ready" on its own very first pass (stdin was unconditionally "ready"), so its
     own NIC-drain call (`net::poll()`, already unconditionally reachable every loop pass) never
     got a chance to iterate *internally* more than once either. A real `poll(stdin, timeout=-1)`
     genuinely needing to retry (exactly what fix #1 correctly enables) is what finally exercised a
     real, confirmed hang -- `gdb`'s own `RIP` sampling caught it stuck solid, several seconds
     apart, inside `poll_recv`'s own `CR_BUFFER_EMPTY` port read, cycling through "not empty" +
     "bad frame" forever. Root cause of *why* the ring gets stuck this way is still open; fixed the
     blast radius instead (bounded to 64 frames per call, then gives up and returns `None`,
     matching "ring empty," with a diagnostic log line if it ever fires) rather than claim to have
     found that deeper cause too.
  3. **The real, deepest root cause, found once #1 and #2 together still didn't fix a plain `echo`
     at the `hush` prompt**: both `oxidebsd_sys_poll`/`_select`'s own retry loops used
     `core::hint::spin_loop()` while genuinely waiting -- but this whole syscall runs with
     interrupts masked for its *entire* duration (`SFMASK`, same fact this section's own
     networking gotchas already document). Stdin's own readiness is **interrupt-driven** -- only
     `keyboard_interrupt_handler`'s own `push_byte` call ever adds a byte -- unlike NIC readiness,
     which the same loop's own `poll()` call discovers by directly reading hardware registers, no
     interrupt required. A bare `spin_loop()` while waiting on stdin therefore doesn't just waste
     cycles the way it might for a network fd -- it makes the one event being waited for
     *structurally impossible*, since the interrupt that would ever deliver it can't fire while
     this loop keeps spinning. Confirmed live end to end: real keystrokes genuinely reached the
     kernel's own ring buffer the whole time (`gdb` memory dumps showed `head` correctly advancing
     with every byte sent), so "blocked forever," not "lost," was always the right diagnosis --
     `read_keys_from`/`get_kbinput` never returned because the syscall it was stuck in could
     structurally never see its own wakeup condition become true. Fixed: when stdin is one of the
     awaited fds, block via the exact same `WaitingForStdin` primitive `console::stdin::read`
     itself already uses (a real context switch, which is what actually re-enables interrupts) --
     scoped to "stdin is among the awaited fds" rather than every poll, since a poll that only
     awaits network fds still needs the original spin-and-repoll behavior to keep actively pumping
     a connection nothing else services, and no real caller in this kernel currently mixes stdin
     with a socket fd in one call.
- **This CLAUDE.md's own earlier "sys_read on stdin is non-blocking" claim (see the syscall-ABI
  section above) is stale**, found live investigating this same bug: `console::stdin::read` is a
  real, genuine blocking implementation (`ProcState::Blocked(BlockReason::WaitingForStdin)` +
  `scheduler::schedule()`, woken by `push_byte`'s own `wake_blocked_readers`), not a
  return-`0`-immediately one. Not yet corrected at that section -- flagged here so a future pass
  doesn't trust it without checking the real source first.
- Verified end to end via a real boot, driven headlessly through the QEMU monitor's own
  `sendkey`/`screendump` (`OXIDEBSD_QEMU_DISPLAY=none`, no window needed): a bare `vi /etc/passwd`
  and a bare `nano /etc/passwd` each produce a real, correct, full curses render *and* now
  genuinely accept real keystrokes -- confirmed via `screendump` showing real inserted text
  (`nano`'s own "Modified" indicator lighting up, `vi`'s own insert-mode text landing at the
  cursor), not just rendering. Both exit cleanly back to a plain `hush` prompt through their real
  save-prompt/`:q!` flows, and a plain `echo` at the `hush` prompt itself -- unaffected by any of
  this section's own changes on its face, but genuinely exercising the identical `poll`/`select`
  code path -- was retested and confirmed still correct.
- **Two more real, user-reported bugs, found the same way**: "nano freezes" turned out to be three
  kernel-level input bugs (above); once those were fixed, real interactive use surfaced two more,
  narrower ones -- "can't save documents" and "kinda corrupted due to some unsupported tty
  features."
  1. **The real corruption**: `sys/console/vga.rs`'s `execute_csi` had no case for `X` (ECH,
     "erase character", `ESC[NX]`) -- the same silently-swallowed-by-`_ => {}` shape as the earlier
     VPA/CHA/HPA gaps. `nano`'s own status-bar/shortcut-list redraw (`usr.bin/nano/src/winio.c`)
     uses `ECH` to blank stale menu-item text before writing shorter replacement text over the same
     cells (e.g. switching between the main-menu footer and the write-prompt's own shorter one) --
     without it, old text was never actually cleared, so new text landed *on top of* it. Confirmed
     live via a real screendump showing garbled, overlapping footer fragments exactly where a
     shorter label replaced a longer one; fixed and reconfirmed clean.
  2. **The real save failure, root-caused precisely, not patched around**: pressing Enter to
     confirm `nano`'s "Write to File" prompt did nothing -- the dialog just sat there forever, even
     though the exact same physical Enter keystroke worked fine for inserting a newline in the main
     editor. Traced to `pc-keyboard`'s own `Us104Key` layout (`lib.rs`'s `KeyCode::Return =>
     DecodedKey::Unicode('\u{000A}')`, i.e. LF) -- every real terminal and every curses/readline
     program's own shortcut table is built around a physical Enter key sending **CR** (`\r`,
     `0x0D`) raw (ICRNL-style LF translation is a later, optional *tty-driver*-only step); `nano`'s
     own prompt-confirmation logic (`acquire_an_answer`, `usr.bin/nano/src/prompt.c`) checks only
     its shortcut table (`^M`/`\r` -> `do_enter`, `global.c`), which a raw LF byte never matches --
     while the *main editor's* own newline handling happens to also accept `\n` as a permissive
     fallback (`nano.c`'s own `input == '\r' || input == '\n'` check), which is exactly what masked
     this in every earlier test in this same section. Fixed at the actual translation point
     (`sys/cpu/interrupts.rs`'s new `normalize_enter_key`, called right after `process_keyevent` in
     both the real PS/2 IRQ handler and the USB HID synthetic-scancode path): rewrites LF back to
     CR specifically for the `Return`/`NumpadEnter` key, using the still-available raw `KeyCode`
     rather than the already-collapsed `DecodedKey`. **Deliberately not a blanket `\n` -> `\r`
     rewrite** -- Ctrl+J legitimately decodes to the same Unicode LF via `pc-keyboard`'s own
     `HandleControl` mapping and is a real, distinct keystroke (`nano`'s own `^J` -> `do_justify`)
     that must stay LF; a blanket rewrite would have made the two indistinguishable. Verified live
     end to end: `nano`'s own "[ Wrote 1 line ]" confirmation, the "Modified" indicator correctly
     clearing, and the real saved content confirmed via `cat` afterward.
- **Known, disclosed gaps, not yet chased**: `nano` probes `ioctl(TIOCLINUX)` at startup (`0x5603`,
  a real Linux-console-specific request this kernel doesn't implement) -- logged as unrecognized,
  harmless, nano works fine without it. ncurses' own utility programs (`tic`/`tset`/`tput`/`clear`/
  `infocmp`) aren't built or seeded yet -- a real on-target self-hosting attempt (building ncurses/
  nano from source under `ash`+on-target `clang`+`bmake`, the way bmake's own self-hosting was
  proven, see that section above) is a natural next step, not yet attempted this session. The real
  root cause of `rtl8139::poll_recv`'s own `CR_BUFFER_EMPTY`-never-resolves hang (item 2 above)
  is still open -- the bound prevents a permanent freeze but doesn't explain *why* the ring gets
  into that state, and could still degrade a real poll's latency by up to 64 wasted iterations
  every retry pass until it's actually chased down.

### 15.9. ninja (`usr.bin/ninja`), `ppoll(2)`, and demand-grown user stacks

*(from CLAUDE.md, 2026-09-29)*

- **ninja**: submodule of `OxideBSD/ninja-oxidebsd` (`oxidebsd` branch, v1.13.2). Built with the
  fork's own `Makefile.oxidebsd` -- plain POSIX make, no Python (`configure.py`) or CMake -- by both
  `build.rs`'s `build_ninja` (host cross-build, static `ET_EXEC` at `0x1e000000`, seeded
  `/usr/bin/ninja`) and on-target bmake + `clang++` from the seeded `/usr/src/ninja` -- **self-hosts**:
  `cd /usr/src/ninja && bmake -f Makefile.oxidebsd && ./ninja --version` builds all 32 files and
  prints `1.13.2` (verified headless; needs `src/third_party/` seeded, header-only deps).
  `tests/ninja_syscall_smoke.rs`: on-target `ninja -C /ninja-demo` (2 `clang -c` jobs + link via
  `/bin/sh`), then runs the result.
- **`SYS_PPOLL=575`** (`sys/net/mod.rs`, socket module): `poll` + atomic sigmask swap, reusing
  `do_sigsuspend`'s deferred restore (`begin/end_temporary_sigmask`). Limit inherited from `poll`:
  a signal arriving mid-wait isn't noticed until the wait ends. Fixed alongside: `poll(NULL, 0, t)`
  panicked the kernel (slice from a null pointer). `tests/ppoll_syscall_smoke.rs`.
- **User stacks grow on demand**: `USER_STACK_RESERVE` (8 MiB) below `USER_STACK_TOP`; only the top
  `user_stack_pages()` -- or enough for the argv/envp image -- are mapped at exec.
  `mm::try_grow_user_stack` maps a zeroed page for a not-present fault in the reserve, called first
  in `page_fault_handler` for **both rings** (the kernel writes user stacks too: `read()` into
  on-stack buffers, signal frames); lock-light (mapper from `CR3`, `try_lock` frame allocator).
  Found via ninja (`BuildLog::Load`'s 256 KiB on-stack buffer vs. the old fixed 256 KiB stack).
  Also fixed: an `execve` whose args outgrew the eager stack panicked the kernel
  (`user_stack::write_image`). SysV shm's region now stops at the reserve's bottom.
- Ring-3 page faults and `#GP` now log `[fault] pid N ... ip ...` (Linux's "segfault at" line).

### 15.10. Real Rust `std` target: `x86_64-unknown-oxidebsd` (`external/mit/rust`, `regress/std/`, `build.rs`)

*(from CLAUDE.md, 2026-09-29)*

v0.3.0 work (see `OxideBSD-doc/ROADMAP.md`) — a private `rust-lang/rust` fork (`OxideBSD/
rust-oxidebsd`, `oxidebsd` branch) plus a private `libc` crate fork (`OxideBSD/
libc-crate-oxidebsd`, `oxidebsd` branch, patched in via `library/Cargo.toml`'s
`[patch.crates-io]`) add real `target_os = "oxidebsd"` support throughout `std`'s *existing*
`linux`/musl-shaped cfg gates, reusing `sys::pal::unix` wholesale rather than writing a new
backend — this kernel's own patched musl fork's public C ABI is unchanged from stock musl.
`library/std/build.rs`'s supported-platform allowlist lists `oxidebsd` too, so consumer binaries
need no `#![feature(restricted_std)]` — a real, fully-supported target, not one std merely
tolerates. `build_std_oxidebsd_userland_crate` in `build.rs` does a genuine `-Z
build-std=std,core,alloc,panic_abort,panic_unwind` recompile every build (~20-40s, no prebuilt `std` exists for
a brand-new custom target), linked via a `musl-gcc` `RUSTC_WRAPPER` against the same
`target/musl-sysroot` every other userland ELF uses.

- **Two build-caching layers hid musl changes from `std` programs; both fixed in `build.rs`
  (2026-09-28)**: (1) cargo doesn't track `libc.a` (it's behind `-C linker=musl-gcc`), so
  `build_std_oxidebsd_userland_crate` removes an executable older than `libc.a` *and* its
  `build/<crate>/<hash>/fingerprint` -- the executable is a hard link to
  `build/<crate>/<hash>/out/<crate>`, which cargo re-links when the fingerprint is fresh, so
  deleting it alone does nothing. (2) oxfs didn't reliably re-embed a changed file behind
  `include_bytes!(env!(...))`; `build_module_crate` now passes `OXIDEBSD_EMBED_STAMP` (a hash of
  the embedded files' mtimes) and oxfs reads it with `env!`, which rustc tracks. Check with
  `objdump -d` on the executable if in doubt. Never `touch build.rs` to force rebuilds.
- **Real consumer proofs, each a `#![no_std]` fork+execve+wait4 wrapper spawning a real `std`
  binary embedded at `/bin/<name>`** (same pattern as `clang-syscall-smoke`/`std-hello-syscall-
  smoke`): `std-hello-oxidebsd` (target identity only — `println!`/`process::exit`);
  `std-process-fs-oxidebsd` (real `std::fs` write/read_to_string/remove_file +
  `std::process::Command` spawning `/bin/true`/`/bin/echo`); `std-thread-net-signal-oxidebsd`
  (real `std::thread` spawn/join + `Arc<Mutex<_>>` over real `futex(2)`; real
  SIGPIPE-ignored-at-startup broken-pipe handling + real `SIGKILL`/`ExitStatusExt::signal()`
  `wait(2)`-status decoding; real UDP/TCP `socket()`/`bind()`/`local_addr()`/`listen()`/nonblocking
  `accept()`).
- **Two real `std` platform-allowlist gaps found and fixed the same way as `restricted_std`**
  (`external/mit/rust`, each a hardcoded `target_os` list `std` uses to pick a fallback code path):
  `sys/pipe/unix.rs`'s `pipe2` list (without `oxidebsd`, `pipe()` fell back to plain `pipe()` +
  `ioctl(FIONBIO)`-based `set_cloexec`, both broken here) and `sys/net/connection/socket/
  unix.rs`'s `Socket::set_nonblocking` (same `ioctl(FIONBIO)` default fallback). **OxideBSD's real
  `ioctl(2)` only ever handles `TCGETS`/`TCSETS*`/`TIOCGWINSZ`/`TIOCSWINSZ` against the real
  console fd — any other request or fd returns `ENOTTY`** (see "Interactive shell" above), so any
  future `std` gap surfacing as a mysterious `ENOTTY`/`ENOSYS`-shaped `io::Error` from a
  first-real-consumer program is probably this same allowlist-gap class, not a kernel bug.
- **A real, previously-missing kernel syscall found this way, not just a std/libc gap**:
  `getsockname(2)` had never been implemented at all (`sys/netinet/tcp.rs`'s `getsockname`/
  `sys/netinet/udp.rs`'s `oxidebsd_sys_getsockname`, `SYS_GETSOCKNAME=559`) — real Linux's own stock
  `__NR_getsockname=51` had simply never been remapped, since nothing needed it before a real
  `std::net` consumer called `local_addr()`. `getpeername` remains a deliberately narrower,
  disclosed, still-open gap.
- **No loopback interface exists on this kernel** (single real NIC, see "Real networking" above)
  — the `std::net` consumer proof is real socket/bind/listen/nonblocking-accept plumbing, not a
  full external round trip.
- Not yet exercised through real `std`: anything beyond fs/process/thread/signal-basics/net-
  plumbing above (no real `TcpStream`/`UdpSocket` data transfer, no `std::net` DNS resolution).
  std programs unwind (`panic_unwind` + libunwind, required since nightly-2026-09);
  `std-hello-oxidebsd` proves `catch_unwind` at runtime.

## 16. POSIX conformance

### 16.1. The conformance checklist: scope and what "certifiable" meant

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

Tracks what stands between OxideBSD today and a genuinely POSIX.1-2017 (Issue 7)-conformant
system — broader scope than `MISSING_POSIX_SYSCALLS.md`, which only tracks the syscall
surface. This doc covers everything else certifiable conformance actually depends on: whole
subsystems the syscall doc marks "structurally inapplicable," the Shell & Utilities volume,
locale/timezone data, and the test suite that would actually prove any of it.

Two different things get called "POSIX compliance," and they have very different bars:

1. **Technical conformance to POSIX.1-2017** — the system's interfaces behave the way the
   standard describes. This is the achievable, meaningful target for a project like this, and
   what the rest of this doc tracks.
2. **Official "UNIX" trademark certification** — the Open Group's actual VSX-PCTS (Platform
   Conformance Test Suite) process: a paid, formal submission that licenses the "UNIX" mark itself,
   run against a specific frozen release, re-certified per version. This is a legal/business
   process layered on top of #1, not an engineering task — **out of scope for this project**;
   nothing below tracks toward it, and reaching every item on this list still wouldn't grant the
   trademark without that separate process.

So "certifiable" here means: pass a real, independent POSIX conformance test suite (see
"Verification" at the bottom) against genuine technical conformance — not the trademark.

### 16.2. Already conformant (recap)

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

Process control (`fork`/`execve`/`wait4`/`exit`/signals incl. `sigtimedwait`/`sigqueue`), file I/O
(`open`/`read`/`write`/`lseek`/`stat` family/`access`/hard+symlinks), directories (`getdents`,
real multi-component paths, per-process cwd), permissions (real uid/gid/mode, `chmod`/`chown`),
sockets (UDP/TCP/raw ICMP, `poll`), time/clocks (`clock_gettime`, `nanosleep`, POSIX per-process
timers, `setitimer`), all three IPC families (POSIX message queues, SysV message
queues/semaphores/shared memory — see the memory note this closed out), resource limits
(`prlimit64`, `nice` — stored/echoed, not enforced), real `SCHED_FIFO`/`SCHED_RR` priority
semantics (genuinely enforced, not just stored — real `EPERM` on a non-root priority raise too),
`getrandom`/`sysinfo`. All backed by real end-to-end `SYSCALL` smoke tests.

### 16.3. Foundational architecture blockers (introduction)

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

The big, invasive ones — each blocks a cluster of other items, so they're worth sequencing first
if this becomes real future work rather than just a tracking exercise.

- [x] **Real threading** — the original checklist entry is folded into this file's §7.3 and §7.4; RT
      signal queuing is §8.4, file-backed `mmap` §4.4, dynamic linking §4.5.

### 16.4. Honest-but-unenforced state

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

These already have real, correctly-shaped return values — the open question is whether a
conformance suite merely checks the interface *exists and round-trips*, or actually depends on the
enforced *effect*. Listed separately from the hard blockers above because closing them is smaller,
more mechanical work if a real test run says they matter:

- `rlimits` (`Process::rlimits`) — stored/returned via `prlimit64`, never actually enforced against
  real resource usage.
- `sched_policy`/`sched_priority` — stored/echoed via the `sched_*` family, no real scheduling
  effect (single-core, cooperative round-robin only).
- `sched_yield(2)` — not registered at all; has no real meaning without preemption to yield *to*,
  per `MISSING_POSIX_SYSCALLS.md`'s own note — but a conformance suite may still expect a
  successful no-op rather than `ENOSYS`.
- Real per-process CPU-time accounting — `times(2)`/`getrusage(2)` report honest all-zero `struct
  tms`/`struct rusage` rather than fabricated numbers; a conformance suite checking that CPU time
  actually *increases* under load would fail here regardless of wire-format correctness.
- `clock_settime(2)` — only `clock_gettime` exists; setting the clock isn't implemented.
- `CLOCK_PROCESS_CPUTIME_ID`/`CLOCK_THREAD_CPUTIME_ID` — `clock_gettime`'s `clockid` handling
  covers `CLOCK_REALTIME`/`CLOCK_MONOTONIC` only (any other id is `EINVAL`), per CLAUDE.md's
  real-time-clock section.

### 16.5. Locale, timezone, and the Shell & Utilities volume

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

Out of `MISSING_POSIX_SYSCALLS.md`'s scope entirely (pure userspace/libc, no syscall
involved) but very much in POSIX.1-2017's scope as a whole:

- [ ] **Real locale data beyond `C`/`POSIX`**: musl itself supports locales, but nothing in this
      port seeds real locale definition files or `LC_*` category data — every process effectively
      runs in the `C` locale regardless of environment. A conformance suite that exercises
      `setlocale`/collation/`LC_TIME` formatting will need at least one real non-`C` locale
      available.
- [ ] **Real timezone database** (`/usr/share/zoneinfo`, `TZ` handling beyond a fixed offset) —
      `src/cpu/rtc.rs` reads CMOS directly and assumes the 21st century with no leap-second or
      timezone-conversion logic; `tv_nsec` is always `0`. Fine for this kernel's own internal use,
      not for `tzset(3)`/`localtime(3)` conformance.
- [ ] **A genuinely POSIX-conformant shell**: pid 1 is BusyBox's `hush`, which targets broad
      compatibility, not line-by-line POSIX `sh` conformance (job control, `set -o` options,
      here-documents, etc. — most already work, but this hasn't been checked against the Shell
      volume's own conformance requirements specifically).
- [ ] **The Shell & Utilities (XCU) volume's mandated utility set**: this project's coreutils-shape
      today is BusyBox applets (see CLAUDE.md's BusyBox port section) — broad functional coverage,
      but never audited option-by-option against POSIX's exact mandated behavior/exit-status/option
      set per utility. A real conformance pass would need to run the utility-level test suite (see
      "Verification" below), not just confirm each utility exists.

### 16.6. Remaining syscall-level items

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

Tracked in full in `MISSING_POSIX_SYSCALLS.md` — not duplicated here. As of the 28-syscall
pre-reserved batch landing (see memory: all 28 items done), that doc's own "Missing, live caller
confirmed" table is empty and "Missing, POSIX-mandated, no live caller yet" is down to items
already covered by the architecture blockers above (`mq_*`'s row there already correctly notes
mq_open through mq_getsetattr are implemented) plus `select`/`pselect` (deliberately
skipped, `poll` already covers every live caller) and `fexecve`/`posix_spawn` (already work via
existing primitives, no syscall gap). New syscall numbers should continue from `555` (`SYS_CLONE`,
the current highest — now with a real handler, `process::lifecycle::do_clone`, see "Real threading"
above — per that doc's own numbering-discipline note).

### 16.7. POSIX conformance pilot: growth, tooling, and accumulated fixes (`build.rs`, `sys/process/`, `sys/fs/`, `scripts/run_posix_pilot_{supervised,host}.sh`, `regress/posix-conformance-driver/`)

*(from CLAUDE.md, 2026-09-29)*

The Open POSIX Test Suite pilot (`tests/posix_conformance_smoke.rs`) grew from a hand-picked 68
files to a curated/deduplicated 488, then to the **full ~1687-file corpus** (`pthread_*`/`aio_*`/
`lio_listio*` included once real threading landed — `discover_posix_test_files` walks the
directory dynamically). Each growth pass needed the kernel's low-VA userland-load-base floor
shifted forward (the same "embedded corpus grew past the fixed floor" class of bug hit multiple
times — see "User-mode execution" above) and oxfs's block/inode/name-length pools bumped.

- **`scripts/run_posix_pilot_supervised.sh [--reset]`** is a host-side supervisor: kills a wedged
  QEMU boot (a genuine kernel-level hang can't be rescued by the suite's own in-guest 40s
  `alarm()`), excludes the stuck file, retries — now also excludes+retries on a real crash/panic
  exit, not just a stall, and caches every already-classified file's result across iterations so a
  long run never re-executes a file it already has an answer for. **The naive "exclude whatever
  file was running when a stall was detected" heuristic does not reliably converge** — several
  real investigations found it misattributing a stall to an innocent neighbor file that merely
  happened to be running next; when a supervised run needs many iterations to converge, verify
  each exclusion by testing that exact file in complete isolation before trusting it.
  **`scripts/run_posix_pilot_host.sh`** runs the identical corpus on the host's own real
  glibc/Linux for an apples-to-apples baseline (manual/root-run only, needs a real TTY for `sudo`).
- **A real, severe frame-exhaustion cascade** once the full corpus first ran uncurated (most files
  past ~1/3 through came back instant `UNRESOLVED`, real `ENOMEM` on `fork`/`execve`) — root
  causes and fixes are covered in "Real threading"'s memory-reclaim notes above (zombie
  address-space frames, `do_munmap`'s leak, orphan reparenting). Any full-corpus pass-rate number
  measured before those fixes landed is not comparable to one after.
- **A real global-fd-table exhaustion cascade**, unrelated to memory: `sys/modules/oxfs`'s
  `OPEN_FILES` table is process-*global*, not scoped per process — one real POSIX stress test
  (`shm_open/23-1.c`, 1000 children each opening a new fd with no `close()`) permanently drained
  it, breaking `hush`'s own output redirection for the rest of the boot and misclassifying
  hundreds of unrelated later files as `sigaction`-family FAILs. `MAX_OPEN_FILES` bumped `8 → 256`
  wasn't sufficient alone (the leak is unbounded over wall-clock time); the real fix moved
  `OpenFile::Write`'s buffer out of the enum into a separate, lazily-claimed pool (see "Filesystem:
  oxfs" above), letting `MAX_OPEN_FILES` scale to `2048` while *lowering* total static cost. That
  one file still doesn't `PASS` — a real, accepted single-core scheduling-throughput ceiling for
  1000 concurrent forked processes, not a fd-table symptom (confirmed by raising the rescue
  timeout 4.5x and still timing out).
- **`sched_yield/1-1.c`, once excluded as "needs real SMP," never actually did** — re-reading the
  test's own source (not re-trusting an old, unverified claim) showed it only forks CPU-reserving
  children when `ncpu > 1`; on a genuinely single-core report it correctly exercises two
  equal-priority threads round-robining via `sched_yield()`, a real single-core-achievable
  property. A stale exclusion-list reason needs the same live re-verification as any other claim.
- **A real, distinct `exit_group(2)` bug**: plain `exit()`/`_Exit()` shared a syscall number with
  a bare per-thread exit — a thread-group leader calling `exit()` only tore down itself, silently
  orphaning any live sibling into a deadlocked `pthread_exit()` cleanup. Fixed with a genuinely
  distinct `SYS_EXIT_GROUP=556` (kills every other tgid member first, leader-ordering fixed the
  same way `terminate_thread_group` was — see Signal handling module above) plus a matching musl
  `__NR_exit_group` remap.
- **Real thread-group-wide signal delivery had a routing bug**: the whole-group reroute used to
  fire on every `kill`/`sigqueue`, including a real `pthread_kill(exact_thread, sig)` (this ABI
  has no separate `tkill`/`tgkill`) — fixed via `route_signal_target`, gating the reroute to only
  fire when the literal target names the group's own leader.
- **The last three open scheduler-shaped hangs** (`fork/18-1.c`, `pthread_mutex_init/{1,3}-2.c`)
  were all confirmed **real, pre-existing musl 1.2.6 bugs, not OxideBSD bugs**, via direct
  byte-for-byte reproduction against the host's own unmodified musl: a `PTHREAD_CANCEL_ASYNCHRONOUS`
  cancel landing inside musl's own `canceldisable`-protected mutex-timedlock wait self-deadlocks
  (real musl behavior); a failing `SIGEV_THREAD_ID timer_create()` reports the wrong errno
  (`EAGAIN` instead of `EINVAL`). No kernel code changed for either — left as accepted non-PASS
  results, same bucket as the stale-tid UAF class (see musl-port section above).
- `OxideBSD-doc/BUSYBOX_APPLETS.md`/`MISSING_POSIX_SYSCALLS.md`/`POSIX_COMPLIANCE_CHECKLIST.md` (in
  the separate `OxideBSD-doc` repo) track applet/syscall/conformance detail this section
  summarizes; check there (and `build.rs`'s `POSIX_KNOWN_HANGS` doc comment, currently empty of
  live exclusions) for the current numbers rather than any pass-rate figure in this file, which
  goes stale quickly.

### 16.8. Verification: the Open POSIX Test Suite and the baseline history

*(from POSIX_COMPLIANCE_CHECKLIST.md, cut 2026-10-01)*

Everything above is preparation. The actual "certifiable" gate is running a real, independent
conformance test suite against a built OxideBSD image and looking at the pass/fail counts, not
self-assessing against this checklist:

- [x] **The Open POSIX Test Suite** — running, cross-compiled against this kernel's own musl fork,
      each file a real pre-built ELF run through `t0` (the suite's own real `alarm()`-based timeout
      wrapper) inside a real, single continuous boot (`tests/posix_conformance_smoke.rs` +
      `userland/posix-conformance-driver/`, driven by `modules/oxfs/src/posix_conformance.sh`'s own
      seeded corpus/manifest — see that script's own doc comment for the full design). **No longer a
      curated subset**: the pilot now covers the **full corpus** (~1673 files in
      `conformance/interfaces/`, `pthread_*`/`aio_*`/`lio_listio*` included now that real threading
      exists) — see CLAUDE.md's "POSIX pilot: full corpus expansion..." section for the growth
      history (68 → 488 → full corpus) and every real kernel/musl bug each expansion pass found.
- [x] **A real pass/fail baseline against the full ~1687-file corpus.** History: 82.1%/85.6%
      (2026-09-04) → 87.1%/92.5% (real AIO + oxfs O_RDWR) → 89.8%/94.1% (a real `sys_pwritev2`
      offset-validation fix closed a post-Limine regression) → **90.3% raw / 94.6% excluding
      UNTESTED (2026-09-15, 1523 PASS / 1687 total, zero exclusions needed)** — the latest official
      re-run; see `ROADMAP.md`'s v0.2.0 entry for what's landed since and hasn't yet been folded
      into a fresh number. Last apples-to-apples host comparison (2026-09-06, not re-run since):
      the user's Artix Linux host (glibc, native) at 89.5%/94.3% — OxideBSD now exceeds that proxy
      figure on both axes. Full detail and per-category tables live in CLAUDE.md's own session
      history (search "full-corpus"); `scripts/run_posix_pilot_host.sh`/
      `scripts/run_posix_pilot_supervised.sh` reproduce either side.
      **Next step**: individually triage the full corpus's own remaining FAIL/UNRESOLVED set rather
      than growing the file count further — the corpus is complete, and most of what's left is
      already confirmed to be real, pre-existing musl 1.2.6 bugs (verified against unmodified host
      musl) rather than OxideBSD-side gaps.
