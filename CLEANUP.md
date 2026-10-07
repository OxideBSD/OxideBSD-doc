# OxideBSD shortcuts: cleanup inventory

Status: **working inventory** (started 2026-09-24, verified against `946dfa0` on 2026-10-01).
Target release: v0.3.0 for items marked so.

## 1. Scope

This inventory lists every known shortcut: behaviour good enough for an earlier milestone but not
what a regular Unix system does. v0.3.0 is also a cleanup release whose goal is that OxideBSD acts
like a regular OS (`ROADMAP.md` §3.2). Add a row whenever a new shortcut is found.

**Target** is `v0.3.0`, a later release named in `ROADMAP.md`, or `later` (unscheduled). When a
fix lands, the row moves to §8 with its commit.

## 2. Security

| Shortcut today | A regular OS | Target |
|---|---|---|
| Syscalls dereference user pointers without validating them (`sys_read`/`sys_write` and others); a bad pointer faults instead of returning `EFAULT`. | `copyin`/`copyout` with `EFAULT` | v0.3.0 |
| No `NO_EXECUTE` on any page, no W^X; module pages all writable; ELF segments sharing a page don't union their flags. | NX stacks and data, read-only text | later |

## 3. Processes and signals

| Shortcut today | A regular OS | Target |
|---|---|---|
| An orphan reparented to pid 1 is reaped by the kernel at exit (`Process::adopted`, treated like `SA_NOCLDWAIT`), although `/sbin/init` now reaps with `waitpid(-1, WNOHANG)`. | init reaps orphans | v0.3.0 |
| `setrlimit` limits are stored, never enforced (only `RLIMIT_MEMLOCK`, for `mlockall(MCL_FUTURE)`). | Enforced | v0.3.0 (the ones that matter: `NOFILE`, `STACK`, `AS`, `CORE`) |
| `nice`/`setpriority` stored, no effect on scheduling. | Affects scheduling | later |
| `times()` reports `tms_stime`/`tms_cstime` as zero; `getrusage` returns an all-zero `struct rusage`. | Real user/system split | later |
| No kernel-mode preemption, and a syscall runs with interrupts masked for its whole duration: a long disk write freezes the machine. | Preemptible kernel, interruptible I/O | later (with SMP, v0.5.0) |
| Fork copies the whole address space eagerly. | Copy-on-write | later |

## 4. Files and descriptors

| Shortcut today | A regular OS | Target |
|---|---|---|
| oxfs's open-file table is system-wide and fixed-size (`MAX_OPEN_FILES = 2048`). | Per-process tables with `RLIMIT_NOFILE` | v0.3.0 |
| `flock` fails with `EAGAIN` instead of blocking without `LOCK_NB`. | Blocks | v0.3.0 |
| `rename` between the tmpfs pool and the real filesystem moves the entry instead of failing (`link` already fails `EXDEV`). | `EXDEV` across filesystems | v0.3.0 |
| `/proc` is a special case inside oxfs; no VFS layer. | A VFS with filesystems mounted on it | later |
| Every used block of the disk is loaded into RAM at mount; the block pool is a fixed 1 GiB, allocated and zeroed at mount whatever the disk size; `NUM_BLOCKS` is a compile-time constant. | Block cache over the disk; size from the disk | v0.3.0 (128 MB floor) |
| A mounted disk never picks up a newer build's files; only a reformat does. | An installer and upgrades | later (v0.10.0, packages) |

## 5. Terminals

| Shortcut today | A regular OS | Target |
|---|---|---|

## 6. Networking

| Shortcut today | A regular OS | Target |
|---|---|---|
| The guest's IP address and gateway are compiled in; no `ifconfig`, no DHCP client. | Configured at boot (`rc.conf`) | v0.3.0 (`INIT.md`: `ifconfig_*`) |
| A fixed route lookup (loopback, the connected subnet, one default gateway); two interfaces (`lo0`, `rl0`) configured at build time. | A routing table and `ifconfig`/`route` | later |
| Incoming packets are processed only by processes waiting in the network stack: the rtl8139 interrupt only sets a flag and wakes waiters, and a wait involving a socket wakes every 50 ms to drive the NIC. | Interrupt-driven receive | v0.3.0 |
| TCP is stop-and-wait with a fixed 536-byte segment size, no window or congestion control. | Real TCP | later |
| No IPv6. | IPv6 | later |

## 7. Userland and build

| Shortcut today | A regular OS | Target |
|---|---|---|
| Every file on the system is embedded in the kernel's oxfs module at build time and seeded on format: about 298 MiB of kernel `.rodata`, resident from boot, and copied again into the block pool. | A root filesystem image built separately; a small mfsroot for install and recovery | v0.3.0 (128 MB floor) |
| BusyBox applets are 128 separate static binaries at fixed load addresses. | A multi-call binary, or native replacements | v0.3.0 (native `bin/` rewrite as `std` apps) |
| The C ports built from their own build systems (BusyBox, bmake, vi, nano, ninja, doom, the POSIX corpus) link at fixed addresses whose floor has to move as the kernel grows. | Position-independent executables | v0.3.0 |
| `mprotect` enforcement limited to the `mmap` window. | Everywhere | later |
| After a partial `MAP_FIXED` over a file mapping (as `ld.so` does), the old region's record is kept whole, so a fault there can be reported as `SIGBUS` rather than `SIGSEGV`. | Regions split on overlap | later |
| The `libc` crate fork uses Linux's `SYS_*` numbers for OxideBSD (only `SYS_getrandom` is corrected), so a Rust crate calling `libc::syscall` directly reaches the wrong syscall for anything musl remaps. | The table matches the kernel | v0.3.0 |
| Only `passwd(1)` changes `/etc/master.passwd` and `/etc/passwd` (through `pam_unix`); no tool adds or removes users or groups (`adduser`, `pw`, `vipw`). | They can | v0.3.0 |

## 8. History

Removed shortcuts, as `date — item — commit`.

- 2026-10-06 — a PIE's `brk` heap starts after its randomized image, not at its unbiased end — 2e9a34f
- 2026-10-06 — `MAP_FIXED`, `brk` and ELF segments are confined to the user range; the kernel heap moved to the upper half (`USERMEM.md` §5.1) — 9fb6f67, 2e9a34f
- 2026-10-02 — pseudo-terminals: `/dev/ptmx` and `/dev/pts/N` (`PTY.md`) — 63fbf11
- 2026-10-01 — real, effective and saved user and group IDs, supplementary groups, set-user-ID and set-group-ID `execve` with `AT_SECURE`, `access(2)` on the real IDs, the `nosuid` mount option — 282249f
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
- 2026-09-26 — terminals: a per-device tty layer with its own termios, window size, session and foreground group; the POSIX line discipline (canonical mode, echo, `ISIG`, `VMIN`/`VTIME`) in the kernel; fds 0-2 of the console are one read-write description — 8deb5e2
- 2026-09-26 — `/dev/ttyv0`, `/dev/tty` (the controlling terminal) and `/dev/console` — fde98f6
- 2026-09-26 — disk I/O by DMA (virtio-blk, IDE bus-master), interrupt-driven completion with a polling fallback — 2992d55
- 2026-09-27 — getty, login and `passwd(1)` in the image (OpenPAM, utmpx, `master.passwd`) — 093ec0e
- 2026-09-28 — socket waits block with interrupts enabled instead of spinning; an rtl8139 interrupt wakes them — a73d4a3
- 2026-09-29 — `unlink`/`rmdir`/`rename` over a name/last close free an inode and its blocks once nothing refers to it, in the disk and tmpfs pools; inode tables grow and shrink instead of a fixed `MAX_INODES` — 13113f8, 475e995
- 2026-09-29 — devfs: a kernel device registry (`make_dev`), `/dev` rebuilt every boot — 342fda3
- 2026-09-30 — dynamically linked programs: every `ET_DYN` executable gets an ASLR bias, `PT_INTERP` or not (`execve`, the kernel's `spawn`); one musl build makes `libc.a` and `libc.so` — f9fb253, e40cc9f, a9b8d5b
- 2026-09-30 — a file `mmap` at a nonzero offset (it was `EINVAL`), so `ld.so` loads shared libraries and `dlopen` works — 026e9ba
- 2026-09-30 — Rust `std` programs are PIEs, dynamically linked on `/lib/libc.so` and `/lib/libgcc_s.so.1` (`/bin` and `/sbin` static) — ab98faf, 33a69e6
- 2026-09-30 — a loopback interface, `lo0`, and sockets with real local addresses; `/etc/hosts` — c22d920
- 2026-09-30 — TCP no longer drops data still buffered at `close()`/`shutdown(SHUT_WR)` — c22d920
- 2026-10-01 — pid 1 is `/sbin/init` (`INIT.md`): `/etc/rc`, `/etc/ttys` sessions with getty, signals, syslog, utmpx boot/shutdown records, recovery, `init=`/`init_path=` — 52656de, 3e3241e, 6899d9d, 3295c7c, 946dfa0
