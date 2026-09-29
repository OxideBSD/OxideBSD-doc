# OxideBSD init, step 2 and 3: work plan

A working list, not a specification: what remains of init's step 2 (sockets, sysctl, the
message buffer, syslog, cron, time zones) and step 3 (`/sbin/init` itself), in order, with the
decisions already taken, the traps already found, and how each part is verified. The design is in
`UNIX.md`, `SYSCTL.md`, `SYSLOG.md`, `CRON.md`, `TIMEZONE.md`, `INIT.md`, `INIT_SH.md`, `LOGIN.md`
and `TTY.md`; this file doesn't repeat it. Update it as parts land.

Last updated 2026-09-29.

## Done

| Part | Commits | Notes |
|---|---|---|
| Specs (UNIX, SYSLOG, SYSCTL, CRON, TIMEZONE), INIT.md §§11-13 updated | doc `419c264`, `48d6e1c`, `c3179b8` | all accepted |
| Website `/doc/` renders the specs | doc `3edd514` | `website/doc.sh`, lowdown |
| BSD source layout: `sys/netinet`, rtl8139 in `sys/drivers`, `sys/modules/socket` | `3a7c686` | |
| Sockets stage 1: socket layer and protocol switch (`sys/kern/uipc_socket.rs`) | `d6f73cd` | UDP, TCP, raw ICMP are `Protocol`s |
| Sockets stage 2: `sendmsg`/`recvmsg` (577/578), `get/setsockopt` (579/580), `getpeername` (581), `accept4` (582), flags, options, timeouts, blocking socket waits, UDP `connect`, TCP non-blocking `connect`/`shutdown`/`SO_ERROR` | `a73d4a3`, musl `b37feab1` | `regress/socket-smoke`, 64 checks |
| Sockets stage 3: local sockets (`sys/kern/uipc_usrreq.rs`), oxfs socket inodes, `socketpair` on them | `38bbcb4` | `regress/socket-smoke`, 165 checks; `wget` HTTPS checked by hand |

Next free syscall number: **583** (reserved for `sysctl` by `SYSCTL.md` §4.1); then 584 upward.

## Order

1. ~~Sockets stage 3: local sockets.~~ Done.
2. Sockets stage 4: descriptor and credential passing.
3. Sockets stage 5: manual pages; UNIX.md closed out.
4. sysctl, the message buffer and `/dev/klog`, load average, memory statistics, tunables.
5. syslogd, logger, dmesg, newsyslog (without TLS).
6. OpenSSL 3, then syslog over TCP and TLS.
7. cron, crontab, periodic.
8. Time zones.
9. BusyBox roster cut (one rebuild for everything replaced).
10. `/sbin/init` (step 3).

Steps 4, 7 and 8 don't depend on the socket work and may move earlier. syslogd (5) needs local
datagram sockets (1). init (10) needs syslog (5) and uses sysctl (4).

## 1. Sockets stage 3: local sockets — done (`38bbcb4`)

As planned, with these details settled in the code: oxfs registers one pair of callbacks
(`oxidebsd_register_socket_nodes(create, lookup)`), each `(path_ptr, path_len) -> inode | -errno`;
the kernel keys sockets by inode number alone (inode numbers are unique across oxfs's pools). No
`SUPERBLOCK_VERSION` bump: the socket kind is a new code in the existing kind byte. `mknod(2)` with
`S_IFSOCK` stays `EINVAL`, as in FreeBSD. Stream control-data attachment (§6.4) waits for stage 4:
the receive queue is already a list of messages, so a message carrying control data will simply
not be merged into.

A disk image formatted before stage 2's musl change still holds BusyBox binaries that call the
retired syscall 142; delete `target/oxfs_disk.img` to reseed.

## 2. Sockets stage 4: descriptors and credentials (`UNIX.md` §§8-9)

- `sendmsg`/`recvmsg` control data (today `sendmsg` with control is `EOPNOTSUPP`, `recvmsg` returns
  none): parse and build `cmsghdr`s (musl alignment), 4096-byte limit.
- `SCM_RIGHTS`: `sys/fs/fd.rs` needs in-flight references, i.e. a description reference held by
  a message, not by any `(tgid, fd)` slot, and "install a description into the receiver at the
  lowest free fd" (with `MSG_CMSG_CLOEXEC`). Discarded messages release their references.
  `MSG_CTRUNC` when the buffer is short (the excess is closed).
- Garbage collection: mark-and-sweep over in-flight local-socket descriptions, run when a local
  socket with descriptions in flight is closed (the BSDs' `unp_gc`).
- Limits: 1024 in flight per user, 4096 system-wide (root: system-wide only), `ETOOMANYREFS`.
- Credentials: `LOCAL_PEERCRED` (`struct xucred`), `SO_PEERCRED` (`struct ucred`),
  `getpeereid(3)`, `SCM_CREDS` (`cmsgcred`, filled by the kernel), `LOCAL_CREDS` (`sockcred`) and
  `LOCAL_CREDS_PERSISTENT` (`sockcred2`, `SCM_CREDS2`), `SO_PASSCRED`/`SCM_CREDENTIALS` with the
  `EPERM` rule. Effective IDs equal real ones until `SUDO.md`'s work.
- musl: `SOL_LOCAL`, the `LOCAL_*` and `SCM_*` constants and the four structs in
  `<sys/socket.h>`/`<sys/un.h>` (values must not collide with musl's existing `SOL_*`, `SO_*`,
  `SCM_*`: musl already has `SCM_RIGHTS = 1`, `SCM_CREDENTIALS = 2`), and `getpeereid(3)`.

Verification: socket-smoke sections for each; a descriptor sent over its own socket and
collected; the limits.

## 3. Sockets stage 5: manual pages

mdoc pages in `share/man` (lint clean with `oxdoc -T lint`): `unix.4`, `socket.2`, `sendmsg.2`
(and `send`/`sendto` links), `recvmsg.2`, `getsockopt.2`, `getpeereid.3`, `accept.2`, `bind.2`,
`connect.2`, `listen.2`, `shutdown.2`, `socketpair.2`. Seed them; `build_man_index` picks them up.
Mark `UNIX.md` implemented.

## 4. sysctl, message buffer, `/dev/klog`, load average, memory statistics (`SYSCTL.md`, `SYSLOG.md` §§3-4)

- `sys/kern/kern_sysctl.rs` (the BSD name; update `SYSCTL.md` §2's `sys/sysctl.rs`): the MIB tree,
  `OID_AUTO` numbering from 256, meta-OIDs `{0,1..5}`, types and format strings, access and
  tunable flags; `SYS_SYSCTL = 583` with a packed six-field struct; registered by a module
  (`posix_compat`, or a new one); a kernel API for modules to add nodes.
- Variables of `SYSCTL.md` §5. `kern.hostname` shares `sethostname(2)`'s state.
- `uname -m` becomes `amd64` (`sys/syscall/ffi.rs`, `machine: utsname_field("x86_64")`); check
  what reads it: bmake's `MACHINE`, `config.guess` in the self-hosting builds, any test expecting
  `x86_64`.
- Tunables from the kernel command line (`boot::parse_cmdline`): `kern.msgbufsize`,
  `kern.maxproc`, `kern.maxfiles`; unknown ones logged.
- Load average: sample runnable processes every 5 s in the timer interrupt, three FSCALE-2048
  averages; `vm.loadavg`, `getloadavg(3)`, `sysinfo(2)`'s `loads`.
- Memory statistics: the frame allocator counts free frames (free list plus bump remainder), the
  kernel counts wired and user frames; `vm.stats.vm.*`, `vm.vmtotal`, `hw.usermem`, `sysinfo`'s
  `freeram`.
- Message buffer: a ring (size from `kern.msgbufsize`) fed by every kernel print
  (`console::serial::_print` and the modules' `oxidebsd_log`), `<N>` tags for prioritised lines.
  `kern.msgbuf`, `kern.msgbuf_clear`.
- `/dev/klog`: a new character major (oxfs `Device` dispatch hands it to the kernel, like the tty
  majors 4-6), mode 0600, exclusive (`EBUSY`), consuming read, blocking with wakeup, `poll`.
- musl: `<sys/sysctl.h>`, `sysctl(3)`, `sysctlbyname(3)`, `sysctlnametomib(3)`
  (`__NR_sysctl`, not musl's `__NR__sysctl`).
- Userland: `/sbin/sysctl` (Rust), `/sbin/dmesg` (Rust), `etc/sysctl.conf`, `etc/rc.d/sysctl`.
- Tests: `sysctl_syscall_smoke` (C fixture, `SYSCTL.md` §11), a `/dev/klog` check, a tunable
  boot.

## 5. syslogd, logger, dmesg, newsyslog (`SYSLOG.md`, without §8.3-8.4)

- `usr.sbin/syslogd` (Rust std): `syslog.conf` parser (FreeBSD format, `include`, blocks,
  NetBSD-style `name=value` options), inputs `/dev/log` (local datagram), `/dev/klog`, UDP 514;
  outputs file, `-file`, pipe, `@host`, users (utmpx), `*`, terminals; RFC 3164 and 5424 output;
  repetition; `SIGHUP`; `-k` translation; `LOCAL_CREDS` for real sender PIDs. The FreeBSD flag
  set of `SYSLOG.md` §6.2.
- `usr.bin/logger`, `usr.sbin/newsyslog` (Rust; compression through BusyBox `gzip`/`bzip2`).
- musl: `LOG_NTP`, `LOG_SECURITY`, `LOG_CONSOLE`.
- `etc/syslog.conf`, `etc/newsyslog.conf`, `etc/rc.d/syslogd`, `etc/rc.d/newsyslog`,
  `etc/defaults/rc.conf` entries.
- Tests: host tests of the parsers and formatting; `syslog_syscall_smoke` (`SYSLOG.md` §12.2).

## 6. OpenSSL 3; syslog over TCP and TLS (`SYSLOG.md` §§8.3-8.5)

- Vendor OpenSSL 3 at `external/apache2/openssl` (a plain release tree or a fork, as decided when
  starting). `build.rs`: `Configure` with a custom OxideBSD target (static, `no-shared`,
  musl-gcc), install `libssl.a`/`libcrypto.a`/headers into the sysroot, seed `/usr/bin/openssl`.
  The build is Perl-driven and long: stamp it like the LLVM builds.
- Rust binding for syslogd: the `openssl` crate against the sysroot (`OPENSSL_DIR`,
  `OPENSSL_STATIC`); `openssl-sys`'s build script may need the `oxidebsd` target added (the libc
  crate fork shows how).
- syslogd: RFC 6587 framing, `@@host`, `tcp_server`; RFC 5425 with `@[host]:port(...)`, the
  `tls_*` options, verification, queueing and reconnect (§8.5).
- Open: a system CA bundle (`/etc/ssl`, `certctl(8)`), `SYSLOG.md` §13.

## 7. cron, crontab, periodic (`CRON.md`)

- A shared table parser (a small library crate) used by both programs.
- `usr.sbin/cron` (Rust std): tables, `cron.d`, reload by mtime, jitter, `@reboot` via
  `/var/run/cron.reboot`, clock-change handling, login class and PAM service `cron`
  (`etc/pam.d/cron`), output to syslog, `/var/run/cron.pid`.
- `usr.bin/crontab` (Rust): root-only until set-user-ID exists (as `passwd`).
- `usr.sbin/periodic` (sh), `etc/periodic/{daily,weekly,monthly}`, `etc/defaults/periodic.conf`,
  `etc/crontab`, `etc/rc.d/cron`.
- Tests: host tests with an injected clock; `cron_syscall_smoke` (`CRON.md` §9.2).

## 8. Time zones (`TIMEZONE.md`)

- Vendor IANA tzdata + tzcode at `external/public-domain/tz`; build `zic` for the host, compile
  the zones, seed `/usr/share/zoneinfo`; build `zic`/`zdump` for the target; `usr.sbin/tzsetup`
  (Rust).
- **Check oxfs's inode budget first**: `MAX_INODES = 8192`, and the zones add ~600 files. Raising
  it changes the on-disk layout (`SUPERBLOCK_VERSION` bump, automatic reformat).
- syslogd and cron re-read the zone on `SIGHUP`.
- Test: `tz_syscall_smoke`.

## 9. BusyBox roster cut

BusyBox's `dmesg`, `sysctl`, `crond`, `crontab` stop being installed once their replacements
exist. Editing `build_busybox.rs` costs a ~30-minute BusyBox rebuild: make all four removals in
one edit, together with any other pending roster change.

## 10. `/sbin/init` (`INIT.md`, step 3)

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

## After step 3

Interface configuration ioctls and `rc.d/netif`; a loopback interface (would make network tests
possible without the gateway); `/sbin/initconf`; `daemon(8)` for `<name>_restart`; the
`LOGIN.md` leftovers (`tty01` serial tests, `who`).

## Traps and methods

- **Build caching**: a musl change used to leave `std` programs and oxfs's embedded copies stale.
  Fixed in `build.rs` (stale executables relinked, `OXIDEBSD_EMBED_STAMP`); if in doubt,
  `objdump -d` the executable and look for the syscall numbers. Never `touch build.rs`.
- **Regression set** for socket and network changes, one `cargo tv --test` each:
  `socket_syscall_smoke basic_boot rtl8139_smoke udp_smoke tcp_smoke poll_smoke ping_smoke
  icmp_smoke socketpair_smoke readv_smoke udp_syscall_smoke tcp_syscall_smoke poll_syscall_smoke
  ppoll_syscall_smoke ping_syscall_smoke socketpair_syscall_smoke rc_syscall_smoke
  std_hello_oxidebsd_syscall_smoke std_process_fs_oxidebsd_syscall_smoke
  std_thread_net_signal_oxidebsd_syscall_smoke sh_syscall_smoke at_syscall_smoke`.
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
