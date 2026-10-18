# OxideBSD shortcuts: cleanup inventory

Status: **working inventory** (started 2026-09-24, verified against `c2595d0` on 2026-10-15).
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

## 3. Processes and signals

| Shortcut today | A regular OS | Target |
|---|---|---|
| `RLIMIT_AS` and `RLIMIT_CORE` are stored, not enforced: there is no map of a process's regions to measure (anonymous `mmap` takes address space from one system-wide bump pointer, never reused, and allocates every page at once), and no core dumps. `RLIMIT_CPU` and `RLIMIT_RSS` aren't either. | Enforced, over a per-process `vm_map` and real core dumps | v0.3.0 |
| No kernel-mode preemption, and a syscall runs with interrupts masked for its whole duration: a long disk write freezes the machine. | Preemptible kernel, interruptible I/O | later (with SMP, v0.5.0) |

## 4. Files and descriptors

| Shortcut today | A regular OS | Target |
|---|---|---|
| devfs has no rulesets: every view shows every device. | FreeBSD's `devfs(8)`/`devfs.rules(5)`, per-view hide and unhide | with jails |
| Disk writes from mapping, exec, close and other non-syscall paths into oxfs still poll the disk with interrupts masked (`fslock::Guard::for_call`); only syscall dispatch and descriptor reads and writes sleep. | Every path sleeps | v0.5.0 (SMP rework) |
| One data disk, found once at boot; the memory disk has no `/dev` node. | A block layer with every disk | later |
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
| No mfsroot: a boot with no disk has no root file system to install or recover from. | A small mfsroot loaded beside the kernel | v0.3.0 (`RAM_FLOOR.md` piece C) |
| BusyBox applets are 119 separate static binaries at fixed load addresses. | A multi-call binary, or native replacements | v0.3.0 (native `bin/` rewrite as `std` apps) |
| The C ports built from their own build systems (BusyBox, bmake, vi, nano, ninja, doom, the POSIX corpus) link at fixed addresses whose floor has to move as the kernel grows. | Position-independent executables | v0.3.0 |
| After a partial `MAP_FIXED` over a file mapping (as `ld.so` does), the old region's record is kept whole, so a fault there can be reported as `SIGBUS` rather than `SIGSEGV`. | Regions split on overlap | later |
| msdosfs keeps out of the name cache (`VFCF_NOCACHE`): a case-insensitive lookup would cache the case the caller used, and `getcwd` reports it. Every msdosfs lookup reads the directory. | The cache folds case for such mounts | v0.4.0 |

## 8. History

Removed shortcuts, as `date — item — commit`.

- 2026-10-18 — the libc crate fork used Linux's `SYS_*` numbers and Linux musl's `struct statvfs`: OxideBSD's own — 2216b96
- 2026-10-18 — no tool but `passwd(1)` could change the account database: `useradd` family, `pw(8)`, `vipw(8)`, `adduser(8)`, `rmuser(8)` — f7579fa
- 2026-10-18 — `touch(1)` took only `-c`: POSIX's `-a -c -m -r -t -d` — e61dbca
- 2026-10-18 — `nice` had no effect on scheduling; `times`/`getrusage` reported no system time (and `getrusage` nothing); `reboot -q -n` synced anyway: the 4BSD scheduler, a user/system split, `RB_NOSYNC` — bc62a1c
- 2026-10-18 — `flock` failed with `EAGAIN` instead of waiting; the kernel reaped orphans adopted by pid 1 instead of init; a restarted pid 1 was read from disk while running as the retired one: `flock` waits (`EINTR` on a signal), init reaps every orphan with `waitpid`, pid 1 reads its program in its own context (FreeBSD's `start_init`) — d486876
- 2026-10-17 — `setrlimit` stored limits without enforcing them and without checking them (a soft limit above the hard one, any user raising a hard one); `SCM_RIGHTS` ignored `RLIMIT_NOFILE`; the lowest free fd was a walk over the open ones: `STACK`, `DATA`, `FSIZE`, `NPROC` and `NOFILE` enforced, POSIX's `EINVAL`/`EPERM`, `EMSGSIZE` with the rights discarded, a two-level fd bitmap — aba24c9
- 2026-10-17 — tmpfs, devfs and `/dev/shm` were oxfs's: one memory pool for every tmpfs mount and devfs (one `st_dev`, `rename` between it and the disk moved the entry instead of `EXDEV`), the memory devices oxfs's descriptors: tmpfs and devfs modules of their own, the devices the kernel's, `/dev/shm` a tmpfs from `fstab` (`VFS.md` steps 3a-3c) — 338d6d0, fe0e363, a27ca0d
- 2026-10-16 — `/proc` was matched by path prefix inside oxfs, `fstat` of FIFOs, terminals and devices answered by oxfs's nodes, oxfs kept its own open-file table: the kernel's VFS (`VFS.md` step 2) — 80ba24b, dcf4f5d

- 2026-10-16 — the descriptor calls (`close`, `lseek`, `fstat`, `ftruncate`, `fsync`, `fdatasync`) were oxfs's and misanswered other descriptors (`lseek`/`ftruncate` on a pipe `EBADF`), `ioctl` and `poll` were hard-coded chains of type checks, each backend checked its own access mode (`ftruncate` through a read-only descriptor truncated): `struct file` with static `FileOps` tables, the kernel keeping the flags and offset (`VFS.md` step 1a) — 0ee960f, 7a0f930, d134d8a
- 2026-10-16 — exec opened the program as a descriptor of the caller, so a process at its `RLIMIT_NOFILE` couldn't exec: a kernel-held file (`fd::kernel_open`) — af2d000
- 2026-10-15 — modules had no heap and no `core::fmt`: `lib/libkern-mod`, charged per module (`kern.module.<name>.alloc`); oxfs's open-file table and `/proc` renders moved to it (`/proc` files were cut at 1 KiB) — 8404fe5, 718bdaf
- 2026-10-15 — `RLIMIT_NOFILE` wasn't enforced and `kern.maxfiles` was a flat 8192: enforced (`EMFILE`), 1024 soft and `kern.maxfilesperproc` hard, `kern.maxfiles` one per 32 KiB of RAM — 8b280ec
- 2026-10-15 — BusyBox's `ipcs` and `ipcrm` replaced by native ones over `kern.ipc` sysctls; `security.bsd.see_other_uids` — 34b5b55
- 2026-10-14 — `vfork` was a plain fork: the child borrows the parent's address space, the parent sleeps until exec or exit (`COW.md` §7) — 9786905, a0f9b73
- 2026-10-14 — file mappings were filled at `mmap`/exec: demand-paged from the disk (`DEMANDPAGE.md`) — 2183878
- 2026-10-13 — fork copied the whole address space eagerly: copy-on-write, with an OOM killer for overcommit (`COW.md`) — 560540e, adfef05
- 2026-10-13 — every file on the system was embedded in the kernel's oxfs module and seeded on format (about 298 MiB of `.rodata`): the system is a separately built disk image, pid 1 is read from it (`RAM_FLOOR.md` piece B) — 26a3646, f7b6fa3
- 2026-10-13 — `fsck_oxfs` freed files that lost their names: reconnected in `/lost+found` as `#<inode>` (made at format, or by fsck when missing) — 61dab9e
- 2026-10-13 — every used disk block loaded into a fixed 1 GiB RAM pool at mount, `NUM_BLOCKS` compile-time: a RAM-sized buffer cache over the whole partition, demand reads, delayed writes in crash-safe order, sleeping disk I/O under a filesystem lock, a read-only root checked by `fsck_oxfs` (`RAM_FLOOR.md` piece A) — c6b3691 … f7bf9c9
- 2026-10-11 — NX and W^X: no page writable and executable, kernel (Limine and Multiboot2) or user, with OpenBSD's `wxneeded`/`wxallowed` escape hatch; `mprotect` across the user range; fixture linker scripts page-aligned — 4f0c6d1, 4e2d6fd, d838d47, 13829d6, 6cc872c, 606e5b1
- 2026-10-11 — test fixtures and samples out of `/` (into `/usr/tests`, `/usr/share/examples`); the borrowed-std spike and `/test_busybox.sh` removed; the `hello` module no longer loaded at boot — 2d65b62, b7ac29d
- 2026-10-08 — system calls copy user memory through `copyin`/`copyout` (`EFAULT` for a bad pointer, never a kernel fault), `read`/`write` through `uio` (`USERMEM.md`) — 10eb730 … b4d94a7
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
