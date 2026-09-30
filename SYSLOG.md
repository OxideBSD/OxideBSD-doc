# OxideBSD system logging: design specification

Status: **implemented** (TCP and TLS, §§8.3-8.5, in 2026-09-30). Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interfaces are documented in the manual pages `syslogd(8)`, `syslog.conf(5)`,
`newsyslog(8)`, `newsyslog.conf(5)`, `logger(1)`, `dmesg(8)` and `klog(4)`; this document records
the design. Where FreeBSD, NetBSD and OpenBSD agree it follows them; where they differ, the
majority, and FreeBSD for the configuration formats. It depends on `UNIX.md` (the log socket),
`SYSCTL.md` (`kern.msgbuf`), `TIMEZONE.md` (local time) and `TTY.md` §2.3.2, whose message
buffer it specifies.

## 1. Scope

The kernel message buffer and `/dev/klog`; the system log daemon, its configuration and its
network transport; log rotation; the `logger(1)` and `dmesg(8)` utilities; and where messages go
before the log daemon runs.

## 2. Components

| Path | Role | Source |
|---|---|---|
| `/dev/klog` | Reads the kernel message buffer | kernel |
| `/dev/log` | Local log socket (`AF_UNIX`, `SOCK_DGRAM`) | bound by `syslogd` |
| `/usr/sbin/syslogd` | System log daemon | Rust, `usr.sbin/syslogd` |
| `/etc/syslog.conf`, `/etc/syslog.d/` | Log routing (`syslog.conf(5)`) | `etc/syslog.conf` |
| `/usr/sbin/newsyslog` | Log rotation | Rust, `usr.sbin/newsyslog` |
| `/etc/newsyslog.conf`, `/etc/newsyslog.conf.d/` | Rotation rules (`newsyslog.conf(5)`) | `etc/newsyslog.conf` |
| `/usr/bin/logger` | Sends a message from the shell | Rust, `usr.bin/logger` |
| `/sbin/dmesg` | Prints the kernel message buffer | Rust, `sbin/dmesg` |
| `/etc/rc.d/syslogd`, `/etc/rc.d/newsyslog` | Start-up | `etc/rc.d` |
| `libssl`, `libcrypto`, `<openssl/*.h>`, `/usr/bin/openssl` | The system TLS library, first used here (§8.4) | OpenSSL 3, `external/apache2/openssl` |

BusyBox's `dmesg` stops being installed.

## 3. Kernel message buffer

3.1. The kernel MUST keep every message it prints in a 64 KiB circular buffer, in addition to
printing it. When the buffer is full the oldest bytes are overwritten.

3.2. Each line in the buffer is stored as the kernel printed it. A line from code that gives a
priority is stored with a `<N>` prefix, `N` being the `syslog(3)` priority; a line without one is
logged by `syslogd` as `kern.notice`. The kernel's own messages always carry facility `kern`.

3.3. The buffer is readable two ways:
1. `/dev/klog` (§4), which consumes what it reads, for `syslogd`;
2. the `kern.msgbuf` sysctl (`SYSCTL.md`), which returns the whole buffer without consuming it,
   for `dmesg(8)`. Writing any value to `kern.msgbuf_clear` empties the buffer.

3.4. User space cannot write to the kernel message buffer.

## 4. `/dev/klog`

4.1. `/dev/klog` is a character device, number (7, 0), mode `0600`, owner root.

4.2. It is exclusive: an open while another descriptor has it open fails with `EBUSY`.

4.3. `read(2)` returns the unread bytes of the buffer, up to the size requested, and advances the
reader's position. With nothing unread it blocks, or fails with `EAGAIN` under `O_NONBLOCK`. It
is readable for `poll(2)` when there is unread data. If the buffer has overwritten unread bytes,
reading resumes at the oldest byte still held.

4.4. Writing fails with `EOPNOTSUPP`.

## 5. Before the log daemon

5.1. Messages that programs send with `syslog(3)` before `/dev/log` exists are lost, as in the
BSDs; `syslog(3)` with `LOG_CONS` writes them to `/dev/console` instead.

5.2. `init` MUST open its log with `LOG_CONS`, so that its messages reach the console until
`syslogd` starts. This resolves `INIT.md` §13, question 2.

5.3. Kernel messages from boot are not lost: they wait in the buffer until `syslogd` reads them.
They are timestamped when read.

## 6. `syslogd`

6.1. **Inputs.** `syslogd` MUST read:
1. the local socket `/dev/log`, created with mode `0666` after removing any stale file at that
   path, plus one more socket for each `-l path` (mode `0666`, or as given by `-l mode:path`);
2. `/dev/klog`, as facility `kern`;
3. the network, unless `-s` or `-ss` is given: UDP port 514, and TCP and TLS when configured (§8).

6.2. **Options.** `syslogd` takes FreeBSD's: `-a allowed_peer`, `-b address[:service]`, `-C`
(create missing log files), `-d` (debug, foreground), `-F` (foreground), `-f config`, `-k` (keep
facility `kern` on messages that did not come from the kernel; by default they become `user`),
`-l [mode:]path`, `-m minutes` (mark interval, default 20, `0` off), `-N` (no network sockets at
all), `-n` (no name lookups), `-O format` (`bsd`/`rfc3164` or `syslog`/`rfc5424`), `-P
pidfile` (default `/var/run/syslog.pid`), `-s` (do not receive from the network; `-ss` also do
not send), `-T` (stamp messages from the network with the time of receipt), `-v` (log the facility and level of each message; `-vv` by name).

6.3. **Message parsing.** A message is an `<N>` priority followed by an RFC 3164 or RFC 5424
header and the text. A message without a priority is `user.notice`. A message without a time
stamp, or with one that cannot be parsed, is stamped with the time of receipt. Control characters
other than tab and newline are written as `^X`; a newline ends the message.

6.4. **Output format.** By default each line is written as RFC 3164: `Mmm dd hh:mm:ss host
tag[pid]: text`. With `-O rfc5424` it is RFC 5424: `<N>1 timestamp host app-name procid msgid
structured-data text`, with full-precision ISO 8601 time stamps and the UTC offset. Times are
local time (`TIMEZONE.md`).

6.5. **Repetition.** A message identical to the previous one from the same source is not
written again; `syslogd` counts it and writes `last message repeated N times` when a different
message arrives or after 30 seconds, then after 2 and 10 minutes for continued repeats, as in
the BSDs.

6.6. **Signals.** `SIGHUP` re-reads the configuration and reopens every file. `SIGTERM` and
`SIGINT` log a message and exit. `SIGPIPE` is ignored.

6.7. `syslogd` MUST start without its configuration file (logging `*.err` to the console) and
MUST continue when a single action cannot be carried out, reporting it once.

## 7. `syslog.conf`

7.1. The format is FreeBSD's. Each line is a selector and an action separated by white space.
`#` starts a comment. Lines of the form `name=value` are global options (§8), as in NetBSD.

7.2. **Selectors.** `facility.level`, several joined by `;`, and several facilities for one level
joined by `,`. `*` is every facility. A level selects that level and higher; `=level` only that
level, `<`, `<=`, `>`, `>=` compare, `!` negates; level `none` excludes the facility. Facilities
are `auth`, `authpriv`, `console`, `cron`, `daemon`, `ftp`, `kern`, `lpr`, `mail`, `mark`, `news`,
`ntp`, `security`, `syslog`, `user`, `uucp` and `local0`–`local7`.

7.3. **Actions.**

| Action | Meaning |
|---|---|
| `/path` | Append to the file, which MUST already exist (see `-C`); synchronized after each line |
| `-/path` | The same, not synchronized |
| `\|command` | Pipe to `/bin/sh -c command`, restarted when it exits; messages that arrive while it is restarting are lost |
| `@host[:port]` | Send to another host over UDP (§8.1) |
| `@@host[:port]` | Send over TCP (§8.3) |
| `@[host]:port(options)` | Send over TLS (§8.4) |
| `user1,user2` | Write to the terminals where these users are logged in (from `utmpx`) |
| `*` | Write to every logged-in user |
| `/dev/console`, a terminal | Write to that terminal |

7.4. **Blocks.** `!prog`, `!-prog`, `+host`, `-host` and `:property, [!]operator, "value"`
lines limit the lines that follow them, as in FreeBSD. `!*` and `+*` end a block.

7.5. `include path` reads another file, or each `*.conf` file of a directory in name order.

7.6. The default `/etc/syslog.conf`:

```
*.err;kern.warning;auth.notice;mail.crit		/dev/console
*.notice;authpriv.none;kern.debug;lpr.info;mail.crit;news.err	/var/log/messages
security.*					/var/log/security
auth.info;authpriv.info				/var/log/auth.log
mail.info					/var/log/maillog
cron.*						/var/log/cron
*.emerg						*
include						/etc/syslog.d
include						/usr/local/etc/syslog.d
```

7.7. The C library gains `LOG_NTP`, `LOG_SECURITY` and `LOG_CONSOLE` with FreeBSD's values
(facilities 12, 13 and 14).

## 8. Network transport

8.1. **UDP.** An `@host[:port]` action sends each message as one datagram (default port 514), in
RFC 3164 form, or RFC 5424 form (RFC 5426) with `-O rfc5424`. Without `-s`, `syslogd` receives on
UDP port 514 of the address given by `-b` (default all).

8.2. **Senders accepted.** Every `-a allowed_peer` (`address[/mask][:service]` or
`domain[:service]`) restricts which senders are accepted over UDP and TCP; without `-a`, all are.
The host field of a received message is its sender. `-s` disables every network input; `-ss` also
every network action. The default `syslogd_flags` is `-s`.

8.3. **TCP** (RFC 6587). An `@@host[:port]` action sends over a TCP connection (default port 514),
each message framed by octet counting (`LENGTH SP MESSAGE`). The action syntax is rsyslog's; no
BSD `syslogd` has plain TCP. Receiving is enabled by the global options `tcp_server=on`,
`tcp_bindhost` and `tcp_bindport` (default 514), and accepts octet-counted and newline-terminated
framing.

8.4. **TLS** (RFC 5425, NetBSD's configuration). An `@[host]:port(options)` action sends over TLS
(default port 6514), framed as in §8.3. The options are `subject="..."` (the certificate subject
or `subjectAltName` required), `fingerprint="SHA-256:..."` (the certificate required), `cert=file`
(pin a certificate) and `verify="off"`. Receiving and verification use the global options:

| Option | Meaning | Default |
|---|---|---|
| `tls_server` | Receive over TLS | `off` |
| `tls_bindhost`, `tls_bindport` | Where to listen | all, 6514 |
| `tls_keyfile`, `tls_certfile` | This host's key and certificate | none |
| `tls_ca`, `tls_cadir` | Trusted authorities | none |
| `tls_verify` | Verify peers' certificates | `on` |
| `tls_allow_fingerprints`, `tls_allow_clientcerts` | Peers accepted besides those the authorities vouch for | none |
| `tls_gen_cert` | Create a self-signed key and certificate if none exist | `off` |

TLS 1.2 is the minimum version. A connection whose peer fails verification is closed and the
failure logged. OpenSSL 3 is the TLS library.

8.5. **Disconnection.** For TCP and TLS actions, messages are queued while the connection is
down, up to 1024 messages or 1 MiB per action (the oldest are dropped first, and the number
dropped is logged), and `syslogd` reconnects with a delay that doubles from 10 seconds up to
10 minutes.

## 9. `newsyslog`

9.1. **Configuration.** FreeBSD's format: one line per log file, `logfile [owner:group] mode
count size when flags [pidfile|/path [signal]]`, where `size` is in KiB or `*`, and `when` is `*`,
a number of hours, `@` and an ISO 8601 time, or `$` and a day, week or month specification.
`include` works as in §7.5.

9.2. **Rotation.** When a file is due, `newsyslog` renames `file.N` to `file.N+1` down to
`file.0`, keeping `count` of them, creates a new empty `file` with the given owner and mode,
signals the process named by the pid file (default `syslogd`, `SIGHUP`), and compresses `file.0`
if a flag says so.

9.3. **Flags.** `B` (binary: no rotation message), `C` (create if missing, with `-C`), `D` (no
dump), `G` (the file name is a shell pattern), `N` (signal no process), `U` (the pid file names a
process group), `R` (run the command at the pid-file position instead of signalling), `J` (bzip2)
and `Z` (gzip). `X` (xz) and `Y` (zstd) are accepted and fail with a diagnostic while those
compressors are not installed.

9.4. **Options.** FreeBSD's: `-a directory`, `-C` / `-CC`, `-d directory`, `-F` (force), `-f
config`, `-N` (do nothing but `-C`), `-n` (dry run), `-r` (need not be root), `-S pidfile`, `-s`
(no signals), `-t format` (time-stamped names), `-v`.

9.5. `newsyslog` runs from `/etc/crontab` every hour (`CRON.md`), and at boot as `newsyslog -CN`
to create missing log files.

## 10. `logger` and `dmesg`

10.1. `logger` sends its arguments, or each line of standard input, to `/dev/log`, with FreeBSD's
options: `-4`, `-6`, `-A`, `-f file`, `-H hostname`, `-h host`, `-i`, `-P port`, `-p priority`,
`-S addr:port`, `-s` (also to standard error), `-t tag`.

10.2. `dmesg` prints `kern.msgbuf`, omitting lines with a `<N>` prefix other than kernel ones
unless `-a` is given, and removing the prefixes. `-c` clears the buffer after printing (root
only). `-M core` and `-N system` are not supported.

## 11. Start-up

11.1. `rc.d/newsyslog` (`REQUIRE: FILESYSTEMS`) runs `newsyslog $newsyslog_flags`.

11.2. `rc.d/syslogd` (`REQUIRE: FILESYSTEMS newsyslog`, `BEFORE: SERVERS`, `KEYWORD: shutdown`)
starts `syslogd $syslogd_flags`, and stops it at shutdown.

11.3. `/etc/defaults/rc.conf`:

```
syslogd_enable="YES"
syslogd_flags="-s"
newsyslog_enable="YES"
newsyslog_flags="-CN"
```

## 12. Verification

12.1. Host tests of the parsers (`syslog.conf`, `newsyslog.conf`, RFC 3164 and 5424 messages, RFC
6587 framing), of rotation against a scratch directory, and of TCP and TLS transport between two
host `syslogd`s (TLS with a test authority, a pinned fingerprint, and a rejected certificate).

12.2. `tests/syslog_syscall_smoke.rs`: on target, `syslogd` with a test configuration; messages
from `syslog(3)`, `logger` and the kernel land in the configured files; a selector with `!` and a
program block route correctly; a pipe action receives its lines; `SIGHUP` reopens a rotated file;
`/dev/klog` refuses a second open; `dmesg` shows boot messages.

## 13. Open questions

1. ~~A system bundle of trusted certificate authorities.~~ Settled: `/etc/ssl/cert.pem` and
   `/etc/ssl/certs`, maintained by `certctl(8)`, are OpenSSL's defaults, so a TLS action with no
   `tls_ca`/`tls_cadir` verifies against them.
