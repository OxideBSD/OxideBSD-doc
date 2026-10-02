# OxideBSD pseudo-terminals: design specification

Status: **implemented** (2026-10-02, `63fbf11`). Target release: v0.3.0. Companion to `TTY.md`
and `SUDO.md` §5.2.3.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Scope

This document specifies pseudo-terminals: pairs of a master descriptor, held by a program such as
a terminal emulator, `script(1)` or sudo-rs, and a slave terminal, `/dev/pts/N`, on which another
program runs as if on a real terminal. The slave is an ordinary terminal of `TTY.md` (line
discipline, job control, window size); this document covers only what the pair adds.

## 2. Names and devices

2.1. The master is opened from the clone device `/dev/ptmx` (character device 5:2, mode 0666):
every open creates a new pair and returns its master. This is NetBSD's and Linux's arrangement,
and what musl's `posix_openpt(3)` uses unchanged.

2.2. The slave is `/dev/pts/N` (character device 136:N), as on FreeBSD and NetBSD. `N` is the
lowest number not in use.

2.3. The slave's node is created when the pair is, owned by the opener's real user ID with mode
0600, and removed when both sides are closed. `grantpt(3)` has nothing to do (musl's does
nothing).

2.4. At most `kern.tty.pty_max` pairs exist at once (a boot-time tunable and writable sysctl,
default 256). Opening `/dev/ptmx` beyond it fails with `EAGAIN`.

**Rationale.** A clone device needs no C library change. Owner-only slave nodes keep other users
from writing to a session; nothing in the base system relies on writing to other users' terminals.

## 3. Lifecycle

3.1. A new pair is locked: opening its slave fails with `EIO` until the master's holder clears
the lock with `TIOCSPTLCK` (`unlockpt(3)`).

3.2. `TIOCGPTN` on the master returns `N` (`ptsname(3)`).

3.3. When the master is closed, the slave is hung up: its session, if it is one's controlling
terminal, receives `SIGHUP` and `SIGCONT` (the foreground process group and the session leader),
reads return end-of-file and writes fail with `EIO`, as after a modem hangup (`TTY.md` §5.4).

3.4. When every slave descriptor has been closed (after at least one open), reading the master
returns end-of-file (FreeBSD's behavior; Linux returns `EIO`), and writing it fails with `EIO`.

3.5. The pair, its number and its slave node are freed when both sides are closed.

## 4. Data

4.1. Output written to the slave passes through its output processing (`c_oflag`) and is queued
for the master; reading the master returns it. At most 8192 bytes are queued; a slave writer
beyond that blocks (or fails with `EAGAIN` when non-blocking) until the master reads.

4.2. Bytes written to the master are the slave's input, processed by its line discipline as
keyboard input is (echo, signal characters, canonical editing). When the slave's input queue is
full (`TTY.md`'s `TTYHOG`), a master writer blocks (or gets `EAGAIN`).

4.3. Echo produced by the slave's line discipline is queued for the master like output.

4.4. `poll(2)` and `select(2)`: the master is readable when output is queued or the slave side
has gone (§3.4), and writable when the slave's input queue has room.

## 5. Control requests on the master

5.1. `TCGETS`, `TCSETS`, `TCSETSW`, `TCSETSF`, `TIOCGWINSZ` and `TIOCSWINSZ` on the master act on
the slave's settings and window size, so that a terminal emulator can resize the slave (which
sends `SIGWINCH` to its foreground process group). `isatty(3)` is true for the master.

5.2. `TIOCSIG` (argument: a signal number) sends that signal to the slave's foreground process
group.

5.3. `TIOCPKT` (argument: nonzero to enable) turns packet mode on or off. In packet mode each
read of the master returns either a zero byte followed by data, or a single status byte when the
slave's state changed since the last read: `TIOCPKT_FLUSHREAD` (1), `TIOCPKT_FLUSHWRITE` (2),
`TIOCPKT_STOP` (4), `TIOCPKT_START` (8), `TIOCPKT_NOSTOP` (16), `TIOCPKT_DOSTOP` (32), combined
when several happened. They report, respectively, a flush of the slave's input or output queue,
output stopped or restarted with `VSTOP`/`VSTART`, and `IXON` turned off or on.

5.4. The request numbers are musl's (`<sys/ioctl.h>`, Linux's values), the interface the C
library and ported programs use.

## 6. Verification

6.1. An on-target test drives a pair from both sides: `openpty(3)`, `ptsname`, the lock, data in
both directions with echo and `ICANON`, `^C` as `SIGINT` to a slave process group, window size
and `SIGWINCH`, both hangups, `TIOCSIG`, `TIOCPKT` status bytes, and number reuse.

6.2. sudo-rs with `use_pty` (its default) runs a command (`SUDO.md` §7).
