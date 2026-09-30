# OxideBSD cleanup: shortcuts to remove

Status: **working inventory**, started 2026-09-24. Target release: v0.3.0 for items marked so.

OxideBSD grew fast by taking shortcuts: behaviour that is good enough for the next milestone but
not what a regular Unix system does. v0.3.0 is also a cleanup release, whose goal is that OxideBSD
*acts like a regular OS*. This document lists every known shortcut, what a regular system does
instead, and where it is planned. It is sourced from the "known gap" notes in the main repository's
`CLAUDE.md` and from what recent work uncovered; add to it whenever a new shortcut is found.

**Target** is `v0.3.0`, a later release named in `ROADMAP.md`, or `later` (unscheduled). An item is
removed from this list when its fix lands, with the commit noted in the history section.

## 1. Security

| Shortcut today | A regular OS | Target |
|---|---|---|
| One uid and one gid per process; no real/effective/saved split; supplementary groups not stored (`getgroups` returns the caller's gid); setuid/setgid bits ignored at `execve`. | POSIX credentials; setuid executables | v0.3.0 (`SUDO.md` §5.1) |
| Syscalls dereference user pointers without validating them (`sys_read`/`sys_write` and others); a bad pointer faults instead of returning `EFAULT`. | `copyin`/`copyout` with `EFAULT` | v0.3.0 |
| No `NO_EXECUTE` on any page, no W^X; module pages all writable; ELF segments sharing a page don't union their flags. | NX stacks and data, read-only text | later |

## 2. Processes and signals

| Shortcut today | A regular OS | Target |
|---|---|---|
| pid 1 is a shell (`/bin/sh`, before that hush); no init, no `/etc/rc`, no getty/login at boot. | `/sbin/init` | v0.3.0 (`INIT.md`) |
| An orphan reparented to pid 1 is detached immediately (pid 1 has no reaping loop). | init reaps orphans | v0.3.0 (with init) |
| `setrlimit` limits are stored, never enforced. | Enforced | v0.3.0 (the ones that matter: `NOFILE`, `STACK`, `AS`, `CORE`) |
| `nice`/`setpriority` stored, no effect on scheduling. | Affects scheduling | later |
| `times()` reports `tms_stime`/`tms_cstime` as zero; `getrusage` system time stale. | Real user/system split | later |
| No kernel-mode preemption, and a syscall runs with interrupts masked for its whole duration: a long disk write freezes the machine. | Preemptible kernel, interruptible I/O | later (with SMP, v0.5.0) |
| Fork copies the whole address space eagerly. | Copy-on-write | later |

## 3. Files and descriptors

| Shortcut today | A regular OS | Target |
|---|---|---|
| oxfs's open-file table is system-wide and fixed-size. | Per-process tables with `RLIMIT_NOFILE` | v0.3.0 |
| `unlink`/`rmdir` never free blocks or inodes; tmpfs space is never reclaimed. | Freed on last link and last close | v0.3.0 |
| `flock` fails with `EAGAIN` instead of blocking without `LOCK_NB`. | Blocks | v0.3.0 |
| `rename` between the tmpfs pool and the real filesystem moves the entry instead of failing. | `EXDEV` across filesystems | v0.3.0 |
| Only four device nodes do anything (`/dev/random`, `urandom`, `null`, `zero`). No `/dev/tty`, `/dev/console`, ptys. | Real character devices | v0.3.0 (`SUDO.md` §5.2) |
| `/proc` is a special case inside oxfs; no VFS layer. | A VFS with filesystems mounted on it | later |
| The whole disk is loaded into RAM at mount; the block pool is a fixed ~1 GiB; `NUM_BLOCKS`/`MAX_INODES` are compile-time constants. | Block cache over the disk; size from the disk | later |
| A mounted disk never picks up a newer build's files; only a reformat does. | An installer and upgrades | later (v0.10.0, packages) |
| ATA is PIO and polled, with interrupts masked. | DMA, interrupt-driven | later (v0.9.0, hardware) |

## 4. Terminals

| Shortcut today | A regular OS | Target |
|---|---|---|
| The console's descriptors are one-way: fd 0 cannot be written, 1 and 2 cannot be read. | A tty opened read-write | v0.3.0 |
| No line discipline: `ICANON` is recorded, not acted on; every program does its own erase and echo; Ctrl+D is a plain byte to a program that didn't implement EOF itself. | Canonical mode in the kernel | v0.3.0 |
| One global termios and one controlling session, because there is one console. | Per-terminal state | v0.3.0 (with ptys) |
| No pseudo-terminals. | ptys | v0.3.0 (`SUDO.md` §5.2.3) |

## 5. Networking

| Shortcut today | A regular OS | Target |
|---|---|---|
| The guest's IP address and gateway are compiled in; no `ifconfig`, no DHCP client. | Configured at boot (`rc.conf`) | v0.3.0 (`INIT.md`: `ifconfig_*`) |
| A fixed route lookup (loopback, the connected subnet, one default gateway); two interfaces configured at build time. | A routing table and `ifconfig`/`route` | later |
| Incoming packets are only processed when a process calls into the network stack (the NIC is polled, not interrupt-driven), so `poll`/`select` on a socket must keep running instead of blocking, and can't also see keystrokes in the same call. | Interrupt-driven receive | v0.3.0 |
| TCP is stop-and-wait with a fixed 536-byte segment size, no window or congestion control. | Real TCP | later |
| No IPv6. | IPv6 | later |

## 6. Userland and build

| Shortcut today | A regular OS | Target |
|---|---|---|
| Every file on the system is embedded in the kernel's oxfs module at build time and seeded on format. | A root filesystem image built separately and installed | later (installer) |
| BusyBox applets are 195 separate static binaries at fixed load addresses. | A multi-call binary, or native replacements | v0.3.0 (native `bin/` rewrite as `std` apps) |
| The C ports built from their own build systems (BusyBox, bmake, vi, nano, ninja, doom, the POSIX corpus) link at fixed addresses whose floor has to move as the kernel grows. | Position-independent executables | v0.3.0 |
| `mprotect` enforcement limited to the `mmap` window. | Everywhere | later |
| A PIE's `brk` heap starts at its unbiased end address, low in memory, not after the randomized image; musl's allocator falls back to `mmap` when growing it fails. | The heap follows the image | later |
| After a partial `MAP_FIXED` over a file mapping (as `ld.so` does), the old region's record is kept whole, so a fault there can be reported as `SIGBUS` rather than `SIGSEGV`. | Regions split on overlap | later |
| The `libc` crate fork uses Linux's `SYS_*` numbers for OxideBSD (only `SYS_getrandom` is corrected), so a Rust crate calling `libc::syscall` directly reaches the wrong syscall for anything musl remaps. | The table matches the kernel | v0.3.0 |
| `/etc/passwd` and `/etc/group` can't be changed by any tool (`adduser`, `passwd`...). | They can | v0.3.0 |

## 7. History

Record removed shortcuts here as `date — item — commit`.

- 2026-09-24 — `AT_RANDOM` is 16 fresh random bytes per `execve` — f97971a (branch `cleanup-easy-shortcuts`)
- 2026-09-24 — `reboot(2)` is root-only — f97971a
- 2026-09-24 — `kill(-1, sig)` signals every permitted process except init and the caller — f97971a
- 2026-09-24 — `umask` applied by `mkdir` and `mknod` (`open` already did); `mkdir` also honours its mode, records its owner and checks parent permission, and `rmdir`/`rename` check permission — f97971a
- 2026-09-24 — `rename` of a directory rewrites `..`, refuses to move into its own subtree, and may replace an empty directory — f97971a
- 2026-09-24 — `poll`/`select` report real `POLLIN`/`POLLOUT`/`POLLHUP`/`POLLERR`, block for pipes and the console, and fail `EINTR` — f97971a
- 2026-09-24 — every errno constant matches musl's — f97971a
- 2026-09-24 — Rust `std`'s `getrandom` reaches `SYS_GETRANDOM` (libc fork, `SYS_getrandom = 526`) — f97971a
- 2026-09-25 — fd numbers are per process and the lowest free one (`open`/`pipe`/`socket`/`dup`/`accept`/`F_DUPFD`) — 124974b (branch `cleanup-fd-fifo-isn-guard`)
- 2026-09-25 — FIFOs: `mkfifo`/`mknod(S_IFIFO)` and blocking named-pipe `open()` — 124974b
- 2026-09-25 — TCP initial sequence numbers per RFC 6528 — 124974b
- 2026-09-25 — kernel stacks have guard pages (`memory::kstack`) — 124974b
- 2026-09-25 — a write that fails `EPIPE` raises `SIGPIPE` — a10bb36
- 2026-09-25 — a process killed while blocked in a FIFO `open()` gives back its reader/writer count — a10bb36
- 2026-09-30 — dynamically linked programs: every `ET_DYN` executable gets an ASLR bias, `PT_INTERP` or not (`execve`, the kernel's `spawn`); one musl build makes `libc.a` and `libc.so` — f9fb253, e40cc9f, a9b8d5b
- 2026-09-30 — a file `mmap` at a nonzero offset (it was `EINVAL`), so `ld.so` loads shared libraries and `dlopen` works — 026e9ba
- 2026-09-30 — Rust `std` programs are PIEs, dynamically linked on `/lib/libc.so` and `/lib/libgcc_s.so.1` (pid 1 static) — ab98faf
- 2026-09-30 — a loopback interface, `lo0`, and sockets with real local addresses; `/etc/hosts` — c22d920
- 2026-09-30 — TCP no longer drops data still buffered at `close()`/`shutdown(SHUT_WR)` — c22d920
