# OxideBSD init, step 2 and 3: work plan

A working list, not a specification: what remains of init's step 2 (sockets, sysctl, the
message buffer, syslog, cron, time zones) and step 3 (`/sbin/init` itself), in order, with the
decisions already taken, the traps already found, and how each part is verified. The design is in
`UNIX.md`, `SYSCTL.md`, `SYSLOG.md`, `CRON.md`, `TIMEZONE.md`, `INIT.md`, `INIT_SH.md`, `LOGIN.md`
and `TTY.md`; this file doesn't repeat it. Update it as parts land.

Last updated 2026-09-29, end of the session that did sockets stage 5 and step 5.

## Where things stand

Sockets (all five stages), step 4 and step 5 are done and committed (OxideBSD `60d0b7f`,
`2e49de9`, `9056be8`; not yet pushed). **Next: step 6 (OpenSSL, then syslog over TCP and TLS) or step 7 (cron).** Nothing is in flight. The website has `robots.txt`
(search engines and archives welcome, AI crawlers refused), a sitemap and meta descriptions
(`b316818`, deployed); what's left there is the owner's Search Console setup.

## Done

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

## Order

| # | Part | Status |
|---|---|---|
| 1 | Sockets stage 3: local sockets | done |
| 2 | Sockets stage 4: descriptor and credential passing | done |
| 3 | Sockets stage 5: manual pages; `UNIX.md` marked implemented | done |
| 4 | sysctl, message buffer, `/dev/klog`, load average, memory statistics, tunables | done |
| 5 | syslogd, logger, newsyslog (without TLS) | done |
| 6 | OpenSSL 3, then syslog over TCP and TLS | **next** (or 7/8) |
| 7 | cron, crontab, periodic | to do |
| 8 | Time zones | done |
| 9 | BusyBox roster cut (one rebuild for everything replaced) | to do |
| 10 | `/sbin/init` (init's step 3) | to do |
| — | After step 3: netif ioctls, loopback, `initconf`, `daemon(8)`, `LOGIN.md` leftovers | later |

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

## 2. Sockets stage 4: descriptors and credentials — done

As planned. Settled in the code: `SOL_LOCAL` is 0x200 and `LOCAL_PEERCRED`/`LOCAL_CREDS`/
`LOCAL_CREDS_PERSISTENT` are 0x1001-0x1003 (FreeBSD's 0 and 1-3 collide with `SOL_IP` and `SO_*`
in musl); `SCM_CREDS`/`SCM_CREDS2` keep FreeBSD's 3 and 8. A peek shows credentials but leaves
descriptors in the message. `gc` also runs when a descriptor of an in-flight description is
closed (a socket sent over itself is never destroyed otherwise). Once a socket's own descriptors
are gone nobody can read its queue, so it's garbage even while its peer is open.

## 3. Sockets stage 5: manual pages — done (`60d0b7f`)

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

## 4. sysctl, message buffer, `/dev/klog`, load average, memory statistics — done

The musl leftovers (`struct loadavg`/`vmtotal`/`CTLFLAG_SKIP`, `getloadavg(3)` via `vm.loadavg`, and
step 5's `LOG_NTP`/`LOG_SECURITY`/`LOG_CONSOLE`) went in with sockets stage 4 (musl `2af0e5a2`). Not done: a kernel API for modules to add variables (`SYSCTL.md`
§3.6 is a MAY; add it when a module has something to export, `vfs.oxfs` first). `/proc/meminfo`
still reports `MemFree == MemTotal`; `vm_meter::stats` could feed it.

## 5. syslogd, logger, newsyslog — done (`9056be8`)

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

## 6. OpenSSL 3; syslog over TCP and TLS (`SYSLOG.md` §§8.3-8.5)

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
  `tests/openssl_syscall_smoke.rs` covers it. Still to do in this step: `openssl-sys`, syslogd
  over TCP/TLS.
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
- Rust binding for syslogd: the `openssl` crate against the sysroot (`OPENSSL_DIR`,
  `OPENSSL_STATIC`); `openssl-sys`'s build script may need the `oxidebsd` target added (the libc
  crate fork shows how).
- syslogd: RFC 6587 framing, `@@host`, `tcp_server`; RFC 5425 with `@[host]:port(...)`, the
  `tls_*` options, verification, queueing and reconnect (§8.5).
- Open: `SYSLOG.md` §13 (beyond the trust store above).

## 7. cron, crontab, periodic (`CRON.md`)

- A shared table parser (a small library crate) used by both programs.
- `usr.sbin/cron` (Rust std): tables, `cron.d`, reload by mtime, jitter, `@reboot` via
  `/var/run/cron.reboot`, clock-change handling, login class and PAM service `cron`
  (`etc/pam.d/cron`), output to syslog, `/var/run/cron.pid`.
- `usr.bin/crontab` (Rust): root-only until set-user-ID exists (as `passwd`).
- `usr.sbin/periodic` (sh), `etc/periodic/{daily,weekly,monthly}`, `etc/defaults/periodic.conf`,
  `etc/crontab`, `etc/rc.d/cron`.
- Tests: host tests with an injected clock; `cron_syscall_smoke` (`CRON.md` §9.2).

## 8. Time zones — done (`ad62ef1`)

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
