# OxideBSD init steps 2 and 3: work plan

Status: **steps 1-10 done; remaining work in §3** (2026-10-01, 946dfa0).

## 1. Scope

The order of work for init's step 2 (sockets, sysctl, the message buffer, syslog, cron, time
zones) and step 3 (`/sbin/init` itself). The design is in `UNIX.md`, `SYSCTL.md`, `SYSLOG.md`,
`CRON.md`, `TIMEZONE.md`, `INIT.md`, `INIT_SH.md`, `LOGIN.md` and `TTY.md`; this file does not
repeat it. The per-step narratives that used to be here are in `HISTORY.md` and the commit
messages.

## 2. Steps

| # | Part | Commits |
|---|---|---|
| 1 | Sockets stage 3: local sockets (`sys/kern/uipc_usrreq.rs`) | `38bbcb4` |
| 2 | Sockets stage 4: descriptor and credential passing | `4d48d3d`, musl `2af0e5a2` |
| 3 | Sockets stage 5: manual pages; `UNIX.md` implemented | `60d0b7f` |
| 4 | sysctl, message buffer, `/dev/klog`, load average, memory statistics, tunables | `f021210`, `75c6e7d`, `1005023` |
| 5 | syslogd, logger, newsyslog | `9056be8` |
| 6 | OpenSSL 3, trust store, dynamic Rust programs, loopback, syslog over TCP and TLS | `d2551f6`, `31c5c69`, `d33a27d`, `a9b8d5b`, `ab98faf`, `d346cb0`, `c22d920`, `b07c19d` |
| 7 | cron, crontab, periodic | `6dc085d`, `dc01885`, `c4261e9`, `bb68898` |
| 8 | Time zones | `58a2945`, `ad62ef1` |
| 9 | BusyBox roster cut | `98cf1fc` |
| 10 | `/sbin/init` | `52656de`, `3e3241e`, `6899d9d`, `3295c7c`, `946dfa0` |

Next free syscall number: **585** (`nmount(2)` took 584).

## 3. Remaining work

1. Interface configuration ioctls and `rc.d/netif` (`INIT.md` §11).
2. `/sbin/initconf` and running service blocks (`INIT_SH.md` §4.1-4.4).
3. `daemon(8)` for `<name>_restart` (`INIT.md` §8.2).
4. The `LOGIN.md` leftovers: the `tty01` serial tests (§9.2) and `who`.
5. Manual pages referenced but not written: `re_format(7)`, `utmpx(5)`, `syslog(3)`.
6. A kernel API for modules to add sysctl variables (`SYSCTL.md` §3.6, a MAY; `vfs.oxfs` first).
7. `/proc/meminfo` reports `MemFree == MemTotal`; `vm_meter::stats` could feed it.

## 4. Known open issues

- oxdoc: `.Op` inside `.Oo`/`.Oc` on an `.It` line swallows the item's body; `dmesg.8`'s
  `.Sm off`/`.Ql` idiom renders wrong; lint does not flag an unknown `.St`.
- `wget` over TCP is slow (stop-and-wait). BusyBox `tar` has no gzip support (`tar xzf` fails;
  `gunzip -c | tar xf -` works).
- `daily/110.clean-tmps` is not exercised by a test (off by default; relies on BusyBox `find`'s
  `-mindepth`, `-empty` and `-atime`). `crontab(1)` refusing a non-root caller is not tested.

## 5. Traps and methods

- **Build caching**: a musl change used to leave `std` programs and oxfs's embedded copies stale.
  Fixed in `build.rs` (stale executables relinked, `OXIDEBSD_EMBED_STAMP`); if in doubt,
  `objdump -d` the executable and look for the syscall numbers. Never `touch build.rs`.
- **Regression set** for socket, network, fd or process changes, one `cargo tv --test` each
  (about 25 minutes in all; run it in the background):
  `socket_syscall_smoke basic_boot rtl8139_smoke udp_smoke tcp_smoke poll_smoke ping_smoke
  icmp_smoke socketpair_smoke readv_smoke udp_syscall_smoke tcp_syscall_smoke poll_syscall_smoke
  ppoll_syscall_smoke ping_syscall_smoke socketpair_syscall_smoke rc_syscall_smoke
  std_hello_oxidebsd_syscall_smoke std_process_fs_oxidebsd_syscall_smoke
  std_thread_net_signal_oxidebsd_syscall_smoke sh_syscall_smoke at_syscall_smoke
  sysctl_syscall_smoke sysctl_tunables_smoke tty_syscall_smoke init_respawn_smoke fork_wait`.
  After a musl change also `POSIX_PILOT_CANARY_ONLY=1 cargo tv --test posix_conformance_smoke`,
  compared per file with `target/canary_run3.log` (current numbers: `POSIX_COMPLIANCE_CHECKLIST.md`).
- Build logs contain the POSIX pilot's expected per-file compile errors; filter for
  `panicked at`, `could not compile`, `^error:` instead.
- A test that uses socket calls must load the `socket` module (`socketpair`/`shutdown` moved
  there from `posix_compat`). A test using the network must call `rtl8139::init` before loading
  modules: the card's DMA addresses are 32-bit, and after oxfs's pools the driver refuses.
- `spin::Mutex` is not re-entrant: a second `STATE.lock()` while a guard is alive spins forever.
  A hang: sample it with gdb through the QEMU monitor (`OXIDEBSD_QEMU_MONITOR=<port>`, monitor
  command `gdbserver tcp::<port>`, then `addr2line` against the test ELF under
  `target/x86_64-oxidebsd/debug/build/oxidebsd/*/out/`).
- musl: `__syscall(...)` counts its arguments; a compound literal passed to it must be
  parenthesized (braces don't protect commas). Never write the macro prefix `__NR_` in a
  `syscall.h.in` comment. Check new `__NR_*` names and numbers for collisions.
- New `tests/*.rs` need a `[[test]] harness = false` entry in `Cargo.toml`.
- **A musl change relinks all of BusyBox** (about 40 minutes, since `libc.a` gets newer). Batch
  musl edits into one change. The canary (above) then has to be rerun too.
- **A persistent disk keeps what it was seeded with**: `target/oxfs_disk.img` is mounted, never
  reseeded, so new files in `/etc`, `/sbin` or rebuilt BusyBox applets only appear after deleting
  it (the owner has OK'd that; it reformats in seconds). Tests always use a fresh disk.
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
- oxfs buffers writes per descriptor; a lookup, open or read through another descriptor commits
  them first (`2e49de9`). A new path into file contents that bypasses those three (a new syscall
  reading an inode directly) must call `force_commit_pending_writes` too.
- **Run every syscall-reachable change's test before believing either side**: a failing check can
  be a wrong expectation in the test as easily as a kernel bug. Check which it is before changing
  either.
