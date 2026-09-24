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
| `AT_RANDOM` is the fixed 16 bytes `OxideBSDNotRealX` for every process (`sys/process/user_stack.rs`), so musl's stack-protector canary and `arc4random` seed are predictable. A real generator (`sys/random.rs`) has existed for a while. | 16 fresh random bytes per `execve` | v0.3.0 |
| One uid and one gid per process; no real/effective/saved split; supplementary groups not stored (`getgroups` returns the caller's gid); setuid/setgid bits ignored at `execve`. | POSIX credentials; setuid executables | v0.3.0 (`SUDO.md` §5.1) |
| Syscalls dereference user pointers without validating them (`sys_read`/`sys_write` and others); a bad pointer faults instead of returning `EFAULT`. | `copyin`/`copyout` with `EFAULT` | v0.3.0 |
| `reboot(2)` has no permission check. | Root only | v0.3.0 |
| No `NO_EXECUTE` on any page, no W^X; module pages all writable; ELF segments sharing a page don't union their flags. | NX stacks and data, read-only text | later |
| Kernel stacks have no guard page; an overflow silently corrupts memory. | Guard pages | v0.3.0 |

## 2. Processes and signals

| Shortcut today | A regular OS | Target |
|---|---|---|
| pid 1 is a shell (`/bin/sh`, before that hush); no init, no `/etc/rc`, no getty/login at boot. | `/sbin/init` | v0.3.0 (`INIT.md`) |
| `kill(-1, sig)` signals pid 1's process group. | Every process the caller may signal, except itself and init | v0.3.0 |
| An orphan reparented to pid 1 is detached immediately (pid 1 has no reaping loop). | init reaps orphans | v0.3.0 (with init) |
| `setrlimit` limits are stored, never enforced. | Enforced | v0.3.0 (the ones that matter: `NOFILE`, `STACK`, `AS`, `CORE`) |
| `nice`/`setpriority` stored, no effect on scheduling. | Affects scheduling | later |
| `umask` stored, never applied when oxfs creates a file. | Applied to every create | v0.3.0 |
| `times()` reports `tms_stime`/`tms_cstime` as zero; `getrusage` system time stale. | Real user/system split | later |
| No kernel-mode preemption, and a syscall runs with interrupts masked for its whole duration: a long disk write freezes the machine. | Preemptible kernel, interruptible I/O | later (with SMP, v0.5.0) |
| Fork copies the whole address space eagerly. | Copy-on-write | later |

## 3. Files and descriptors

| Shortcut today | A regular OS | Target |
|---|---|---|
| Descriptor numbers come from one global counter shared by every process and are never reused (`sys/fs/fd.rs`). | Lowest free number, per process (POSIX requires it) | v0.3.0 |
| oxfs's open-file table is system-wide and fixed-size. | Per-process tables with `RLIMIT_NOFILE` | v0.3.0 |
| `unlink`/`rmdir` never free blocks or inodes; tmpfs space is never reclaimed. | Freed on last link and last close | v0.3.0 |
| `flock` fails with `EAGAIN` instead of blocking without `LOCK_NB`. | Blocks | v0.3.0 |
| Renaming a directory to a new parent doesn't update its `..`. | Updated | v0.3.0 |
| No FIFOs (`mkfifo` was removed from the roster). | Named pipes | v0.3.0 |
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
| One routing rule (off-subnet goes to the gateway). | A routing table | later |
| TCP is stop-and-wait with a fixed 536-byte segment size, no window or congestion control. | Real TCP | later |
| `poll` reports only `POLLIN`. | All events | v0.3.0 |
| No loopback interface; no named or datagram `AF_UNIX` sockets (so no `/dev/log`, no syslog). | Both | v0.3.0 (syslog needs them, `INIT.md`) |
| Several errno values are FreeBSD's where musl expects Linux's (`ENOTSOCK`, `EDESTADDRREQ`, `EADDRINUSE`, `EHOSTUNREACH`, TCP's set, and oxfs's `ENOTEMPTY`). | Match the C library | v0.3.0 |
| No IPv6. | IPv6 | later |

## 6. Userland and build

| Shortcut today | A regular OS | Target |
|---|---|---|
| Every file on the system is embedded in the kernel's oxfs module at build time and seeded on format. | A root filesystem image built separately and installed | later (installer) |
| BusyBox applets are 195 separate static binaries at fixed load addresses. | A multi-call binary, or native replacements | v0.3.0 (native `bin/` rewrite as `std` apps) |
| User programs link at fixed addresses whose floor has to move as the kernel grows. | Position-independent executables | v0.3.0 (static-PIE `std` binaries) |
| No `dlopen`; `mprotect` enforcement limited to the `mmap` window. | Both | later |
| Rust `std` calls Linux syscall 318 (`getrandom`), unregistered here, and falls back. | Served | v0.3.0 |
| `/etc/passwd` and `/etc/group` can't be changed by any tool (`adduser`, `passwd`...). | They can | v0.3.0 |

## 7. History

Record removed shortcuts here as `date — item — commit`.
