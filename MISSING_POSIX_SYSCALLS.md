# OxideBSD POSIX system calls: coverage

Status: **current** (2026-10-01, `946dfa0`). Highest assigned system call number: `584`
(`SYS_NMOUNT`).

## 1. Scope

This document tracks the POSIX.1-2017 (Issue 7) System Interfaces that need kernel support on a
real Unix system (process control, file I/O, directories, signals, IPC, sockets, clocks and timers,
threads, memory mapping, credentials, resource limits) against what the kernel registers. Pure
library interfaces (`string.h`, `math.h`, locale, `regex.h`, buffered stdio) are out of scope.
Conformance beyond the system call surface, and the test-suite numbers, are in
`POSIX_COMPLIANCE_CHECKLIST.md`.

Method: every `SYS_*` macro referenced in `external/mit/musl/src` was resolved through
`external/mit/musl/arch/x86_64/bits/syscall.h.in` and compared against the numbers registered with
`oxidebsd_register_syscall` by `sys/modules/*` (2026-10-01).

## 2. Numbering rules

2.1. Before assigning a number, check `sys/syscall/`, `sys/modules/*/src` and `syscall.h.in` for
the current highest. Invented numbers go at `471` and above (collision-free with musl `v1.2.6`);
the current highest is `584`.

2.2. Check the `__NR_*` macro name as well as the value: two macros with different names and the
same value compile without warning, and a duplicate name silently wins by textual order.

2.3. A system call OxideBSD plans to implement gets an OxideBSD-invented number, not a free real
Linux number, even when the Linux slot is unclaimed. OxideBSD is its own ABI.

2.4. A real, unremapped Linux number that musl already calls (`SYS_SELECT = 23`,
`SYS_SCHED_YIELD = 24`, `SYS_MSYNC = 26`, `SYS_FDATASYNC = 75`, `SYS_CLOCK_SETTIME = 227`, ...)
may be registered as is, after confirming no OxideBSD number collides with it.

**Rationale.** Number collisions between real musl macros and OxideBSD's own numbers misroute
calls silently (a call lands in an unrelated handler with misread arguments). A sweep on
2026-08-14 (`073a0fc`) found and remapped 33 such collisions; §7 records the result.

## 3. Missing: POSIX-mandated, no handler

Each row was checked on 2026-10-01: musl issues the system call and no module registers its
number, so the call fails with `ENOSYS` (or, where noted, the interface fails another way).

| POSIX interface(s) | Backing system call (number) | musl call site | Notes |
|---|---|---|---|
| `fcntl` `F_GETLK`/`F_SETLK`/`F_SETLKW`; `lockf` | `fcntl` (`151`) | `src/fcntl/fcntl.c`, `src/misc/lockf.c` | `sys_fcntl` (`sys/syscall/ffi.rs`) handles only `F_DUPFD`, `F_DUPFD_CLOEXEC`, `F_GETFD`, `F_SETFD`, `F_GETFL`, `F_SETFL`; other commands return `EINVAL`. `flock(2)` exists but is a BSD interface, not a substitute. |
| `posix_openpt`, `grantpt`, `unlockpt`, `ptsname` | `open("/dev/ptmx")` + tty ioctls | `src/misc/pty.c` | No pseudo-terminal driver: devfs has no `/dev/ptmx` or `/dev/pts`. |
| `truncate` | `truncate` (`76`) | `src/unistd/truncate.c` | Unpatched call site; `ftruncate` works. |
| `waitid` | `waitid` (`247`) | `src/process/waitid.c` | `wait4` exists; `waitid` has no handler. |
| `pselect` | `pselect6` (`270`) | `src/select/pselect.c` | `select` (`23`), `poll` (`148`) and `ppoll` (`575`) exist. |
| `setegid` | `setresgid` (`501`) | `src/unistd/setegid.c` | `seteuid` works (`setresuid`, `499`, `e6523ad`); the gid side was never added. |
| `setreuid`, `setregid` (XSI) | `setreuid` (`113`), `setregid` (`114`) | `src/unistd/setreuid.c`, `src/unistd/setregid.c` | |
| `pthread_mutexattr_setrobust(..., PTHREAD_MUTEX_ROBUST)`, `pthread_mutex_consistent` | `get_robust_list` (`274`) | `src/thread/pthread_mutexattr_setrobust.c` | musl probes `get_robust_list` and returns its error; `set_robust_list` (`273`) is a no-op success (`394984e`). |
| `posix_fadvise` | `fadvise64` (`221`) | `src/fcntl/posix_fadvise.c` | Advisory (ADV option). |
| `posix_madvise` | `madvise` (`28`) | `src/mman/posix_madvise.c` | `POSIX_MADV_DONTNEED` returns 0 inside musl; every other advice returns `ENOSYS`. Advisory (ADV option). |

## 4. Implemented with known limits

| Interface(s) | Limit |
|---|---|
| `mprotect` | Enforced only in the `mmap` window; elsewhere a no-op. No `NX` bit anywhere. |
| `setrlimit`/`getrlimit` (`prlimit64`) | Limits are stored and returned; only `RLIMIT_MEMLOCK` is enforced. No `SIGXCPU`/`SIGXFSZ`. |
| `msync` | Real (`66b9aef`); writeback also happens at `munmap` and exit. |
| `mlock`, `munlock`, `mlockall`, `munlockall` | No paging exists, so locking has no effect beyond `mlockall(MCL_FUTURE)`/`RLIMIT_MEMLOCK` accounting (`374ed00`). |
| `fork` | Eager full copy; no copy-on-write. |
| `sem_open`, `sem_close`, `sem_unlink`, `shm_open`, `shm_unlink` | No system call of their own: musl backs them with `open`/`mmap(MAP_SHARED)` in devfs's `/dev/shm` (`4b8ff01`) and shared futexes keyed on physical address (`7122adc`). |
| `getlogin`, `getlogin_r` | musl reads `LOGNAME`; no kernel involvement. |

## 5. Not system call gaps

| Interface(s) | Reason |
|---|---|
| `aio_*`, `lio_listio` | musl implements POSIX AIO with a userspace thread pool over `clone`/`futex`. |
| `posix_spawn`, `posix_spawnp` and their attribute/file-action families | musl implements them over `vfork`/`execve`, both present. |
| `fexecve` | musl calls `execveat(fd, "", AT_EMPTY_PATH)` (`574`, `9bb309e`). |
| `ttyname`, `ttyname_r` | musl reads `/proc/self/fd/N`; oxfs resolves a tty descriptor to `/dev/<name>` (`fde98f6`). |
| `tcgetsid` | `ioctl(TIOCGSID)`, handled by `SYS_IOCTL` (`8deb5e2`). |
| `dlopen`, `dlsym`, `dlclose`, `dlerror` | Userspace in musl's dynamic linker; exercised by OpenSSL loading its legacy provider (`regress/openssl-smoke`, `d2551f6`). |
| `pathconf`, `fpathconf`, `sysconf` | Constant tables in musl; no system call. |
| `fattach`, `fdetach`, `isastream`, `getmsg`, `getpmsg`, `putmsg`, `putpmsg` | XSI STREAMS; not implemented by Linux, musl or the BSDs. |
| `posix_trace_*` | Optional tracing option; musl does not implement it. |

## 6. Implemented

Smoke tests are `tests/<name>_syscall_smoke.rs` with a matching `regress/<name>-syscall-smoke/`
crate.

| POSIX interface(s) | Number(s) | Module | Commit | Notes |
|---|---|---|---|---|
| `raise`, `abort`, `pthread_kill` (via `tkill`) | `200` | `signal` | `55e7e23` | |
| `times` | `493` | `posix_compat` | `55e7e23` | Real per-process CPU time since `65d25e8`. |
| `sigpending` | `494` | `signal` | `55e7e23` | |
| `fchdir` | `81` | `oxfs` | `55e7e23` | |
| `sigtimedwait`, `sigwaitinfo`, `sigwait` | `495` | `signal` | `e755f20` | Smoke test `sig`. |
| `sigqueue` | `496` | `signal` | `e755f20` | Permission checks and `sig == 0` (`bb37033`); real-time signal queuing (`f1c8f47`). |
| `SA_SIGINFO` delivery | — | kernel | `179a0ea`, `e755f20` | Real `si_pid`/`si_uid`/`si_value`/`si_code`. Smoke test `sa_siginfo`. |
| `getentropy` (via `getrandom`) | `526` | `posix_compat` | `de7fa6e` | Smoke test `getrandom`. |
| `sysinfo` (not POSIX) | `527` | `posix_compat` | `c05b1e4` | Real `freeram`, `sharedram`, `loads` (`793fa53`). |
| `sigaltstack` | `528` | `signal` | `c05b1e4` | `SA_ONSTACK` honored since `10ab74d`. |
| `pause` | `529` | `signal` | `c05b1e4` | |
| `sigsuspend` | `530` | `signal` | `c05b1e4` | |
| `timer_create`, `timer_settime`, `timer_gettime`, `timer_getoverrun`, `timer_delete` | `531`-`535` | `clock` | `c05b1e4` | Smoke test `posix_timer`. |
| `mq_open`, `mq_unlink`, `mq_send`/`mq_timedsend`, `mq_receive`/`mq_timedreceive`, `mq_notify`, `mq_getattr`/`mq_setattr` | `536`-`541` | `posix_compat` | `cad354e` | `mq_close` is `close`. Smoke test `mq`. |
| `shmget`, `shmat`, `shmctl`, `shmdt` | `542`-`545` | `posix_compat` | `e755f20` | Attachments inherited across `fork` (`7bc2995`). Smoke test `sysv_shm`. |
| `semget`, `semop`, `semctl`, `semtimedop` | `546`-`549` | `posix_compat` | `e755f20` | `SEM_UNDO` supported. Smoke test `sysv_sem`. |
| `msgget`, `msgsnd`, `msgrcv`, `msgctl` | `550`-`553` | `posix_compat` | `ca9b0b7` | Smoke test `sysv_msg`. |
| `pthread_create`, `pthread_join` (via `clone`) | `555` | `native_abi` | `d1572ca` | Smoke tests `clone`, `pthread`. |
| `futex` (`FUTEX_WAIT`/`FUTEX_WAKE`) | `202` | `posix_compat` | `0f5fa94` | Cross-process (shared) futexes `7122adc`; `FUTEX_REQUEUE` at `557` (`07e3df0`). |
| `exit` (thread group) | `556` | `native_abi` | `a9e1856` | |
| `seteuid`, `setresuid` | `499` | `posix_compat` | `e6523ad` | |
| `sched_yield`, `sched_rr_get_interval`, `sched_setparam`, `clock_settime` | `24`, `508`, `507`, `227` | `posix_compat`, `clock` | `a549fcf` | `SCHED_FIFO`/`SCHED_RR` priority preemption `28419fd`. |
| `msync`, `mlock`, `munlock`, `mlockall`, `munlockall` | `26`, `509`-`512` | `native_abi`, `posix_compat` | `66b9aef` | See §4. |
| `select` | `23` | `socket` | `b70a3ed` | |
| `fdatasync` | `75` | `oxfs` | `394984e` | |
| `getsockname` | `559` | `socket` | `f93811c` | |
| `openat`, `mkdirat`, `mknodat`, `fchownat`, `fstatat`, `unlinkat`, `renameat`, `linkat`, `symlinkat`, `readlinkat`, `fchmodat`, `faccessat`, `utimensat`, `fexecve` (via `execveat`) | `560`-`574` | `oxfs`, `native_abi` (`execveat`) | `9bb309e` | `fchown`/`lchown` use `fchownat`. |
| `poll` with a signal mask (`ppoll`) | `575` | `socket` | `f895ffb` | `ppoll` is POSIX.1-2024. |
| `mkfifo`, `mkfifoat` (FIFO nodes) | `mknod`/`mknodat` | `oxfs` | `124974b` | |
| `sendmsg`, `recvmsg`, `getsockopt`, `setsockopt`, `getpeername` (`accept4` too) | `577`-`582` | `socket` | `a73d4a3` | |
| Background-process `SIGTTIN`/`SIGTTOU`, `tcgetsid` | — | `sys/tty` | `8deb5e2` | `TTY.md` §5.3. |

OxideBSD-specific system calls in the same range (not POSIX): `sethostname` (`576`, `b212178`),
`sysctl` (`583`, `f021210`), `nmount` (`584`, `8a7d30a`).

## 7. Number remappings

### 7.1. Collision sweep (2026-08-14, `073a0fc`)

Real musl macros that shared a value with an OxideBSD number were moved to fresh numbers. None had
a kernel handler at the time, so each remap turned a silent misroute into a clean `ENOSYS`.

| Macro | Old → new | Collided with |
|---|---|---|
| `times` | 100 → 493 | `SYS_MMAP` |
| `ptrace` | 101 → 497 | `SYS_MUNMAP` |
| `getpgrp` | 111 → 498 | `SYS_RENAME` |
| `setresuid` | 117 → 499 | `SYS_SIGACTION` |
| `getresuid` | 118 → 500 | `SYS_SIGPROCMASK` |
| `setresgid` | 119 → 501 | `SYS_SIGRETURN` |
| `getresgid` | 120 → 502 | `SYS_SETPGID` |
| `capget` | 125 → 503 | `SYS_DUP` |
| `capset` | 126 → 504 | `SYS_FSTAT` |
| `ustat` | 136 → 505 | `SYS_MKDIR` |
| `sysfs` | 139 → 506 | `SYS_NANOSLEEP` |
| `sched_setparam` | 142 → 507 | `SYS_SENDTO` |
| `sched_rr_get_interval` | 148 → 508 | `SYS_POLL` |
| `mlock` | 149 → 509 | `SYS_SOCKETPAIR` |
| `munlock` | 150 → 510 | `SYS_SET_TID_ADDRESS` |
| `mlockall` | 151 → 511 | `SYS_FCNTL` |
| `munlockall` | 152 → 512 | `SYS_SHUTDOWN` |
| `vhangup` | 153 → 513 | `SYS_READV` |
| `modify_ldt` | 154 → 514 | `SYS_READLINK` |
| `pivot_root` | 155 → 525 | `SYS_SYMLINK` |
| `_sysctl` | 156 → 515 | `SYS_SETITIMER` |
| `prctl` | 157 → 516 | `SYS_GETITIMER` |
| `arch_prctl` | 158 → 517 | `SYS_GETUID` |
| `adjtimex` | 159 → 518 | `SYS_GETEUID` |
| `setrlimit` | 160 → 519 | `SYS_GETGID` |
| `acct` | 163 → 520 | `SYS_SETGID` |
| `settimeofday` | 164 → 521 | `SYS_GETGROUPS` |
| `swapon` | 167 → 522 | `SYS_UTIMENSAT` |
| `get_kernel_syms` | 177 → 523 | `SYS_GETSID` |
| `query_module` | 178 → 524 | `SYS_SETGROUPS` |

Deliberate aliases left in place: `exit`/`exit_group`, `fork`/`vfork`, `getdents`/`getdents64`.
`__NR_mount` (165) and `__NR_umount2` (166) still collide with `SYS_CHMOD`/`SYS_CHOWN`, but no
musl call site uses them: `mount()`/`umount()`/`umount2()` go through `nmount(2)` (`0f94829`).

### 7.2. Pre-reserved batch (2026-08-15, `04e5119`)

Twenty-eight system calls planned for implementation were moved from free Linux numbers to
OxideBSD numbers in one musl bump, before their handlers existed. All 28 are implemented (§6).

| Number(s) | System call(s) | Former Linux number(s) |
|---|---|---|
| `526` | `getrandom` | `318` |
| `527` | `sysinfo` | `99` |
| `528` | `sigaltstack` | `131` |
| `529` | `pause` | `34` |
| `530` | `sigsuspend` | `130` (`rt_sigsuspend`) |
| `531`-`535` | `timer_create`, `timer_settime`, `timer_gettime`, `timer_getoverrun`, `timer_delete` | `222`-`226` |
| `536`-`541` | `mq_open`, `mq_unlink`, `mq_timedsend`, `mq_timedreceive`, `mq_notify`, `mq_getsetattr` | `240`-`245` |
| `542`-`553` | `shmget`, `shmat`, `shmctl`, `shmdt`, `semget`, `semop`, `semctl`, `semtimedop`, `msgget`, `msgsnd`, `msgrcv`, `msgctl` | `29`-`31`, `64`-`71`, `220` |

## 8. Non-POSIX interfaces without a handler

musl also references these Linux-specific system calls, which have no handler; none is required
by POSIX: `epoll_*`, `eventfd`, `inotify_*`, `fanotify_*`, `signalfd`, `timerfd_*`, the `*xattr`
family, `splice`/`tee`/`vmsplice`, `sendfile`, `copy_file_range`, `memfd_create`, `mremap`,
`mincore`, `membarrier`, `preadv`/`pwritev` (`pwritev2` exists), `sendmmsg`/`recvmmsg`, `statx`
(musl falls back to `fstatat`), `getresuid`/`getresgid`, `gettid` (musl caches the tid; only
`synccall` issues it), `sched_setaffinity`, `getcpu`, `setns`/`unshare`, `ptrace`, `prctl`,
`capget`/`capset`, `swapon`/`swapoff`, `quotactl`, `acct`, `vhangup`, `personality`,
`clock_adjtime`/`adjtimex`, `setfsuid`/`setfsgid`, `setdomainname`.
