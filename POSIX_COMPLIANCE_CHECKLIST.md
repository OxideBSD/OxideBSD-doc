# OxideBSD POSIX conformance: record

Status: **active** (2026-10-01). Latest full-corpus measurement: 2026-09-16 (`5646589`, release
0.2.0). Latest canary measurement: 2026-09-29 (`f021210`).

## 1. Scope

1.1. The target is technical conformance to POSIX.1-2017 (Issue 7): interfaces behave as the
standard describes, measured with an independent test suite. The goal is to do better than the
real BSD and Unix systems, not to reach 100% or certification. Linux with glibc is used as the
available point of comparison.

1.1.1. The Open POSIX Test Suite's pass rate is not a conformance measure (decided 2026-10-01):
the suite checks a hand-picked set of interface behaviors, leaves many UNTESTED or UNSUPPORTED by
design, and doesn't cover utilities, headers or most of the standard's requirements. Its results
find bugs and catch regressions; no release target is set on its pass rate.

1.2. The Open Group's UNIX trademark certification (VSX-PCTS, a paid submission per release) is
out of scope.

1.3. System-call-level coverage is tracked in `MISSING_POSIX_SYSCALLS.md`. This document holds the
test-suite numbers and the gaps outside the system call surface. Other documents refer here for
pass rates instead of quoting them.

## 2. Test suite and how to run it

2.1. The Open POSIX Test Suite (`external/gpl2/posixtestsuite`, OxideBSD's fork) is cross-compiled
against OxideBSD's musl and run on target in one boot, each file under the suite's `t0` timeout
wrapper: `tests/posix_conformance_smoke.rs`, `regress/posix-conformance-driver/`, and the seeded
`sys/modules/oxfs/src/posix_conformance.sh`. The pilot covers the full corpus (about 1687 files
in `conformance/interfaces/`).

2.2. `scripts/run_posix_pilot_supervised.sh [--reset]` runs the full corpus under a host-side
supervisor. `POSIX_PILOT_CANARY_ONLY=1` runs the curated regression subset (the canary).
`scripts/run_posix_pilot_host.sh` runs the same corpus on the host for comparison.

2.3. When the supervisor excludes a file for a stall, verify it in isolation before blaming it: it
often blames an innocent neighbour.

## 3. Measurements

"Excl. UNTESTED" divides PASS by the total minus files the suite itself reports as UNTESTED.

| Date | Commit | Run | PASS / total | Raw | Excl. UNTESTED |
|---|---|---|---|---|---|
| 2026-09-04 | — | OxideBSD, full corpus | — | 82.1% | 85.6% |
| 2026-09-06 | — | Artix Linux host (glibc, native) | — | 89.5% | 94.3% |
| — | — | OxideBSD, full corpus (after real AIO and oxfs `O_RDWR`) | — | 87.1% | 92.5% |
| 2026-09-13 | `1b70f94` | OxideBSD, full corpus, after the `pwritev2` fix (`17d5c39`) | 1515 / 1687 | 89.8% | 94.1% |
| 2026-09-15 | — | OxideBSD, full corpus, no exclusions | 1523 / 1687 | 90.3% | 94.6% |
| 2026-09-16 | `5646589` | OxideBSD, full corpus, no exclusions (release 0.2.0) | 1524 / 1687 | 90.3% | 94.7% (1524 / 1610) |
| 2026-09-29 | `f021210` | OxideBSD, canary subset | 127 / 173 | — | — |

3.1. The 2026-09-16 run is the latest full-corpus number. Work landed since then (the tty layer,
FIFOs, devfs, the page cache, sockets stages 2-4, `nmount`, mmap offset fixes) has been checked
against the canary only; the commit messages that report a canary run report it unchanged.

3.2. The host comparison was last run on 2026-09-06. OxideBSD's later 90.3% / 94.7% exceeds the
host's 89.5% / 94.3% from that run.

3.3. The 0.2.0 target of more than 91% / 95% was not met; the owner chose to ship.

## 4. Conformant areas

Each item is backed by a `SYSCALL`-level smoke test and pilot files; commits are in
`MISSING_POSIX_SYSCALLS.md` §6 unless given here.

- Process control: `fork`, `execve`, `wait4`, `exit`, sessions and process groups, job control.
- Signals: `sigaction` with `SA_SIGINFO`/`SA_ONSTACK`, `sigtimedwait`, `sigqueue`, real-time
  signal queuing (`f1c8f47`), permission checks (`bb37033`), multiple deliveries chained through
  a per-process signal stack (`52ab043`), fault-to-signal delivery (`5d2e1dd`).
- Threads: `clone`, `futex` (process-private and shared), `pthread_*` over musl.
- File I/O and directories, the `*at` family, hard and symbolic links, FIFOs (`124974b`).
- Memory: `mmap` (anonymous and file-backed, `MAP_SHARED`/`MAP_PRIVATE`/`MAP_FIXED`), `munmap`,
  `msync`, `mlock` family, `PROT_NONE` and scoped `mprotect` (`6db2e80`).
- IPC: POSIX message queues, POSIX semaphores (unnamed and named) and shared memory over
  `/dev/shm`, SysV messages, semaphores and shared memory.
- POSIX AIO over musl's thread pool.
- Clocks and timers: `clock_gettime`/`clock_settime`, `CLOCK_PROCESS_CPUTIME_ID` and
  `CLOCK_THREAD_CPUTIME_ID` (`5d2e1dd`), `nanosleep`/`clock_nanosleep`, `setitimer`, POSIX
  per-process timers; real per-process CPU time in `times`/`getrusage` (`65d25e8`).
- Scheduling: `SCHED_FIFO`/`SCHED_RR` priority preemption (`28419fd`), `sched_yield`.
- Terminals: per-device ttys with the POSIX line discipline, background `SIGTTIN`/`SIGTTOU`
  (`8deb5e2`), `ttyname`, `tcgetsid`.
- Sockets: UDP, TCP, `AF_UNIX`, `select`, `poll`, `ppoll`, `sendmsg`/`recvmsg`, socket options.
- Dynamic linking: `PT_INTERP` (`e72fc7d`) and `dlopen` (exercised by OpenSSL, `d2551f6`).
- Time zones: `/usr/share/zoneinfo` and `TZ` (`ad62ef1`, `TIMEZONE.md`).

## 5. Open gaps

5.1. System interfaces with no handler (detail in `MISSING_POSIX_SYSCALLS.md` §3):

- [ ] `fcntl` record locking (`F_GETLK`/`F_SETLK`/`F_SETLKW`) and `lockf`. `flock(2)` exists but
      is not the POSIX interface; `F_SETLKW` needs a blocking wait.
- [ ] Pseudo-terminals: `posix_openpt`, `grantpt`, `unlockpt`, `ptsname`, `/dev/pts`.
- [ ] `truncate`, `waitid`, `pselect`, `setegid`, `setreuid`, `setregid`, robust mutexes,
      `posix_fadvise`, `posix_madvise`.

5.2. Implemented but not enforced (may or may not affect the suite):

- [ ] Resource limits: stored and returned; only `RLIMIT_MEMLOCK` is enforced.
- [ ] `mprotect` is enforced only in the `mmap` window; no `NX`.

5.3. Outside the System Interfaces volume:

- [ ] Locale data beyond the `C`/`POSIX` locale: none is seeded.
- [ ] Shell: `/bin/sh` is OxideBSD's own (`lib/libsh`), tested by diffing against `dash`, not
      audited against the Shell and Utilities volume.
- [ ] Utilities: the base utilities (BusyBox applets and native rewrites) have not been audited
      option by option against the Shell and Utilities volume, and no utility-level test suite is
      run.

## 6. Next steps

6.1. Triage the remaining FAIL/UNRESOLVED set of the full corpus rather than growing the corpus.
Much of it is confirmed to be stock musl 1.2.6 bugs, reproduced against unmodified host musl.

6.2. Take a fresh full-corpus measurement; the last one is from 2026-09-16 (§3.1).
