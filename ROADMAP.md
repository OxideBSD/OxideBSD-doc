# OxideBSD releases: roadmap

Status: **v0.3.0 in progress** (2026-10-01, `946dfa0`). Latest release: v0.2.0 (tag `v0.2.0`,
2026-09-16).

Superseded narrative and per-session progress notes from earlier versions of this file are in
`HISTORY.md`. POSIX conformance numbers are recorded only in `POSIX_COMPLIANCE_CHECKLIST.md`.

## 1. Phases

The long-term plan has three phases, each a prerequisite for the next.

| Phase | Goal | Done when | State |
|---|---|---|---|
| 1. Interactive kernel | Boot, stay up, take input in a shell. | The kernel boots into a shell and stays responsive. | Done |
| 2. Rust programs on OxideBSD | Run separate programs the kernel loads; finally `rustc`/`cargo` as userland. | `rustc` runs as an OxideBSD process and compiles a program. | In progress: paging, ring 3, ELF loading, the syscall ABI, oxfs, the musl port and the `x86_64-unknown-oxidebsd` Rust `std` target are done; `rustc` on target is v0.6.0. |
| 3. Self-hosting | An OxideBSD instance builds a bootable OxideBSD image with no host OS. | Boot an image, rebuild OxideBSD from source on it, boot the result. | Not started for the Rust toolchain; C-side toolchain components (Clang/LLVM, C++, bmake, ninja) already run on target. |

Phase 2 took a C libc route first: musl ported to the native syscall ABI, which let BusyBox and
Clang/LLVM run as userland, before the Rust `std` target.

## 2. Release sequence

Decided 2026-09-04: the former single "v0.2.x goals" list is split into sequential releases, each
shipped on its own. v0.5.0 onward added 2026-09-12.

| Release | Theme | State |
|---|---|---|
| v0.2.0 | POSIX pilot conformance | Released 2026-09-16 |
| v0.3.0 | Toolchain maturity, `std`, init, cleanup, sudo | In progress |
| v0.4.0 | glibc port, oxlibc backing `std` | Not started |
| v0.5.0 | SMP | Not started |
| v0.6.0 | `rustc`/`cargo` self-hosted on target | Not started |
| v0.7.0 | oxlibc | Partly pulled into v0.4.0 |
| v0.8.0 | Graphics | Groundwork only |
| v0.9.0 | Hardware support | Not started |
| v0.10.0 | Package manager | Not started, not designed |
| v0.11.0 | v1.0.0 preparation | Scope not defined |
| v1.0.0 | First stable release | — |

## 3. Releases

### 3.1. v0.2.0: POSIX pilot conformance

Released 2026-09-16.

- Scope: close the gap between OxideBSD's Open POSIX Test Suite pilot run (the full corpus, via
  `scripts/run_posix_pilot_supervised.sh`) and a real Unix baseline.
- Target (set 2026-09-08): >91% raw pass rate and >95% excluding UNTESTED. Measured results:
  `POSIX_COMPLIANCE_CHECKLIST.md`.
- The comparison target is UNIX and the BSDs (FreeBSD, NetBSD, OpenBSD). Linux/glibc
  (`scripts/run_posix_pilot_host.sh`) is used only because it is the host available; a BSD-host
  run of the same corpus is not yet scheduled.
- Full POSIX system call coverage (every POSIX-mandated call, on this ABI's own numbers and
  shapes) is part of the same work, not a separate goal.

### 3.2. v0.3.0: toolchain maturity, `std`, init, cleanup, sudo

Scope decided 2026-09-23 (items 1-3), extended 2026-09-24 (items 4-5).

| # | Item | State |
|---|---|---|
| 1 | GCC as an on-target port. | Not started |
| 2 | Finish the Rust `std` target: the surface a `/bin` utility needs, verified by a `std` coverage consumer; `std` binaries are PIEs; the native `bin/` utilities rewritten as `std` apps. | In progress: target landed 2026-09-17 (private forks `OxideBSD/rust-oxidebsd` and `OxideBSD/libc-crate-oxidebsd`, branch `oxidebsd`); dynamic PIEs on `/lib/libc.so` and `/lib/libgcc_s.so.1` since 2026-09-30 (`ab98faf`), `/bin` and `/sbin` static (`33a69e6`); `bin/` rewrite partly done (`bc401ba`: sleep, sync, link, unlink, rmdir, nproc, kill, test, chmod), the 12 original oxlibc utilities remain. |
| 3 | Native init: `/sbin/init` as a Rust `std` app, `/etc/rc`, `rc.d`, `rcorder`, `rc.conf` (`INIT.md`). | Done (`52656de`, `3e3241e`, `6899d9d`, `3295c7c`, `946dfa0`) |
| 4 | Cleanup: OxideBSD acts like a regular OS instead of taking shortcuts. Inventory: `CLEANUP.md`. | In progress |
| 5 | `sudo` via sudo-rs, with the kernel credentials, `/dev/tty`, pseudo-terminals and OpenPAM it needs; sudo-rs's `su` replaces BusyBox's (`SUDO.md`). | In progress: OpenPAM, getty, login and `/dev/tty` done (`093ec0e`, `fde98f6`); POSIX credentials, setuid exec and pseudo-terminals not started. |

Decisions:

- 2026-09-14: `rustrc` (AGPLv3, OpenRC-inspired) dropped in favour of a native BSD-style init and
  `rc.d`. **Rationale.** AGPLv3 conflicts with the project's permissive licensing, and `rustrc` was
  too generic.
- 2026-09-17: `std` links against the musl fork rather than a from-scratch syscall backend, and
  reuses `std::sys::pal::unix`; `target_os = "oxidebsd"` is a real target identity, listed in
  `library/std/build.rs`'s supported platforms (no `restricted_std`). Panics unwind.
- 2026-09-23: Clang rebuilding itself on target is not v0.3.0. **Rationale.** It needs Python
  (LLVM's CMake) and CMake, which come later.

Landed in this cycle: the C++ stage (libc++, on-target `clang++`), the `*at()` family, `ppoll(2)`,
demand-grown user stacks, ninja on target; terminals with a line discipline (`TTY.md`); devfs
(`DEVFS.md`); oxfs inode and block reclamation; OpenSSL 3.5 LTS with the system trust store
(`certctl(8)`) and the `openssl` crate; dynamic linking and `dlopen`; the loopback interface
(`UNIX.md` §11.4); syslog over TCP and TLS (`SYSLOG.md` §8); cron; time zones; a read-only page
cache (`PAGECACHE.md`). Placement of every binary: `HIER.md`.

### 3.3. v0.4.0: glibc and oxlibc

Decided 2026-09-23.

- A full glibc port (a `sysdeps/` port to the native ABI), alongside the musl port, for source
  compatibility with glibc-only software. Chosen over an Alpine-style compatibility layer on musl.
  Needs v0.3.0's GCC, and Python (glibc's build uses it).
- oxlibc pulled forward from v0.7.0: grown from scratch in `lib/oxlibc` until `std` on
  `x86_64-unknown-oxidebsd` runs on it instead of musl, with no change to the `std`-based
  utilities.
- A batch of userland work (not yet itemized).

### 3.4. v0.5.0: SMP

Real multi-core support. Much of the kernel's lock-safety argument is single-core (`SFMASK`
masking interrupts for a whole system call), so this is an architectural change. Scope: per-CPU
GDT/TSS/IDT and kernel stacks, SMP-safe locking, ACPI/MADT parsing to find the other cores, AP
startup, IPI-based scheduling and TLB shootdown.

### 3.5. v0.6.0: self-hosted `rustc`/`cargo`

Phase 3 from the Rust side: `rustc`, `cargo`, a linker and an assembler running as OxideBSD
processes, able to rebuild OxideBSD's kernel and userland on target. Builds on v0.3.0's `std`
target.

### 3.6. v0.7.0: oxlibc

OxideBSD's own from-scratch libc, BSD-3-Clause, alongside the musl and glibc ports rather than
replacing them. Not a fork of `relibc` or anything else under other terms. Partly pulled into
v0.4.0 (2026-09-23).

### 3.7. v0.8.0: graphics

Grows existing groundwork into a desktop: `/dev/fb0` (`process::mm::do_mmap_fb` maps the
framebuffer into a process) and the raw keyboard-event source (`SYS_GET_KEYEVENT`,
`console::keyevents`), both proven by the Doom port (`external/gpl2/doomgeneric`). Scope: mouse
support (no mouse driver exists, PS/2 or USB), a windowing and compositing model, display-mode
negotiation beyond the boot-time GOP/VBE mode.

### 3.8. v0.9.0: hardware support

Broader real hardware support, porting drivers from Linux and BSD sources with per-driver license
review (GPL and the BSD licenses are not interchangeable with this project's). It is the readiness
gate for running OxideBSD on the owner's Surface Pro as a daily driver: USB keyboard input is done
(the Surface has no PS/2); WiFi/networking and graphics acceleration remain.

### 3.9. v0.10.0: package manager

A package manager. Today every program is built into the image by `build.rs`; nothing is
independently installable. Not designed.

### 3.10. v0.11.0: v1.0.0 preparation

A stabilization and hardening pass before 1.0. Scope not defined.

## 4. Unscheduled ideas

Not assigned to a release.

- **uutils.** Replacing some BusyBox utilities with Rust `uutils` was raised and set aside; it is
  not a dependency of the GCC/Clang work.
- **Full `vim`.** `nano` and nvi (OpenVi) are ported; full (non-BusyBox) `vim` is not.
- **`SCHED_SPORADIC`** (POSIX Sporadic Server). Would turn the 13 `_POSIX_SPORADIC_SERVER`-gated
  `sched_setscheduler`/`sched_setparam` conformance files from UNSUPPORTED into tests. Needs an
  extended `struct sched_param` (musl header patch), a per-thread budget and priority state
  machine, and timer-driven replenishment. glibc and upstream musl don't implement it either.
