# OxideBSD terminals: design specification

Status: **draft for review.** Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interfaces are documented in `tty(4)`, `termios(4)`, `console(4)` and `uart(4)`; this
document records the design. Pseudo-terminals build on it and are specified in `PTY.md`.

## 1. Scope

The kernel's terminal layer: terminal devices, the line discipline, controlling terminals and job
control, and the first two terminals, the console and a serial line. Today's terminal state is one
set of console-wide globals (`sys/console/stdin.rs`); this design replaces it.

## 2. Terminals

2.1. A **terminal** is a kernel object with its own input queue, `termios`, window size, session
and foreground process group, and an output driver. Every terminal device is one terminal; the
state MUST NOT be shared between them.

2.2. The first terminals:

| Device | Terminal | Input | Output |
|---|---|---|---|
| `/dev/ttyv0` | the framebuffer console | PS/2 and USB keyboards | the ANSI engine and framebuffer (`sys/console/vga.rs`) |
| `/dev/ttyu1` | the second serial port (COM2, I/O 0x2F8, IRQ 3) | UART receive interrupts | UART transmit |

2.3. **`/dev/console`** is the system console: opening it opens the terminal that is currently
the console, `ttyv0`. Kernel messages go to the console.

2.4. **`/dev/tty`** opens the calling process's controlling terminal, or fails with `ENXIO` if it
has none.

2.5. **COM1** is not a terminal. It carries the kernel's messages and a copy of everything written
to `ttyv0`, as it does today, because tests read their results from it.

**Rationale.** FreeBSD names the first serial port `ttyu0` and would give COM1 to it. Keeping COM1
as the log and test channel, and putting the login line on COM2, avoids moving every test.

2.6. Device numbers (`st_rdev`): `ttyv<n>` is major 4, minor n; `/dev/tty` is (5, 0);
`/dev/console` is (5, 1); `ttyu<n>` is major 6, minor n. oxfs seeds the nodes; opening one opens
the kernel terminal, not an oxfs file.

2.7. More virtual terminals (`ttyv1`… switched with Alt+F*n*) MAY be added later; the design does
not assume one.

## 3. Line discipline

3.1. Every terminal applies POSIX general terminal interface semantics (XBD chapter 11) itself,
between its device and its readers and writers.

3.2. **Input processing** (`c_iflag`): `ICRNL`, `INLCR`, `IGNCR`, `ISTRIP`, `IXON` and `IXOFF`
(`VSTOP`/`VSTART` flow control), `IXANY`, `IMAXBEL`.

3.3. **Canonical mode** (`ICANON`): input is held until a line ends (`NL`, `VEOL`, `VEOL2`, or
`VEOF`). `VERASE`, `VWERASE`, `VKILL`, `VREPRINT` and `VLNEXT` edit the pending line. `VEOF` at the
start of a line makes `read` return 0. A read returns at most one line.

3.4. **Non-canonical mode**: `VMIN` and `VTIME` MUST behave as POSIX specifies for all four
combinations.

3.5. **Echo** (`c_lflag`): `ECHO`, `ECHOE` (erase visually), `ECHOK`, `ECHOKE`, `ECHONL`,
`ECHOCTL` (`^X` for control characters), `ECHOPRT`. Echo goes to the terminal's own output.

3.6. **Signals** (`ISIG`): the characters in `c_cc[VINTR]`, `c_cc[VQUIT]` and `c_cc[VSUSP]` send
`SIGINT`, `SIGQUIT` and `SIGTSTP` to the terminal's foreground process group and flush pending
input unless `NOFLSH`. The characters come from `c_cc`, not fixed values.

3.7. **Output processing** (`c_oflag`): `OPOST`, `ONLCR`, `OCRNL`, `ONOCR`, `ONLRET`, `OXTABS`
(tab expansion). Output is bytes: the UTF-8 check on console writes is removed.

3.8. The default `termios` MUST be FreeBSD's `TTYDEF_*` values: `ICRNL|IXON|IXANY|IMAXBEL|BRKINT`,
`OPOST|ONLCR`, `CREAD|CS8|HUPCL`, `ICANON|ISIG|IEXTEN|ECHO|ECHOE|ECHOKE|ECHOCTL`, the standard
control characters, 9600 baud for serial lines.

**Rationale.** A line discipline is required for pseudo-terminals, and gives programs that don't
edit their own input (`cat`, `read`, `passwd`) the behavior every Unix has, including end-of-file
from `^D`.

## 4. Reading and writing

4.1. `read` blocks until data is available as §3 defines. It MUST return `EAGAIN` for a
non-blocking descriptor, and `EINTR` when a signal with a handler arrives while it waits.

4.2. `write` blocks while output is stopped (`VSTOP`) and on a full serial transmit queue, with the
same `EAGAIN`/`EINTR` rules.

4.3. `poll` and `select` report a terminal readable when a `read` would not block; in canonical
mode that means a complete line or end-of-file is pending.

## 5. Controlling terminals and job control

5.1. A session leader acquires a controlling terminal only with `TIOCSCTTY`, as in FreeBSD; opening
a terminal never does it implicitly, and `O_NOCTTY` is accepted and has no effect. `TIOCSCTTY`
fails if the terminal is another session's, unless the caller is root and passes a non-zero
argument.

5.2. `TIOCSPGRP` and `tcsetpgrp` MUST accept only a process group in the terminal's session.

5.3. A background process that reads its controlling terminal gets `SIGTTIN`; one that writes it,
with `TOSTOP` set, gets `SIGTTOU`; one that changes its settings gets `SIGTTOU`, unless the signal
is ignored or blocked, as POSIX specifies. The defaults of `SIGTTIN`/`SIGTTOU` become Stop.

5.4. When a session leader that has a controlling terminal exits, the terminal is hung up: its
foreground process group gets `SIGHUP` and `SIGCONT`, the terminal stops being the session's, and
later reads by that session's processes return 0 and writes fail with `EIO`.

5.5. `TIOCSWINSZ` stores the window size and sends `SIGWINCH` to the foreground process group.

5.6. `ioctl` requests: `TCGETS`, `TCSETS`, `TCSETSW` (drains output first), `TCSETSF` (also
discards input), `TIOCGWINSZ`, `TIOCSWINSZ`, `TIOCSCTTY`, `TIOCNOTTY`, `TIOCGPGRP`, `TIOCSPGRP`,
`TIOCGSID`, `FIONREAD`, `TCFLSH`, `TCXONC`, `TCSBRK`, `TIOCOUTQ`, `FIONBIO`. Each is valid only on
a terminal descriptor; on anything else they fail with `ENOTTY`, so `isatty` is true only for
terminals.

## 6. Descriptors

6.1. A terminal descriptor is a read-write file description that names its terminal. The
bootstrap descriptors 0, 1 and 2 of the first process are one read-write description of `ttyv0`.

6.2. `fstat` on a terminal descriptor MUST report the same `st_dev`, `st_ino` and `st_rdev` as
`stat` on its device node, so that `ttyname(3)` can match them.

6.3. `/proc/self` MUST name the calling process, and `readlink("/proc/<pid>/fd/<n>")` MUST return
the path of a terminal descriptor's device (and of any descriptor with a path), which is how
musl's `ttyname(3)` works.

6.4. `/proc/<pid>/stat` MUST report the real session, controlling terminal (`tty_nr`) and
terminal foreground process group (`tpgid`).

## 7. The console's keyboard and screen

7.1. The keyboard is input to `ttyv0`. Its special keys keep today's Linux-console sequences.

7.2. A process that maps `/dev/fb0` owns the screen and the keyboard, as today; while it does,
`ttyv0` neither draws nor receives keys.

7.3. The cursor-position reply (`ESC[6n`) goes into `ttyv0`'s input.

## 8. Serial line

8.1. The UART driver MUST use receive interrupts (IRQ 3) and a transmit queue; input is never
polled.

8.2. `c_cflag` speed, character size, parity and stop bits MUST program the UART. `HUPCL` drops
DTR on last close; `CLOCAL` ignores carrier.

8.3. Under QEMU, COM2 is attached with a second `-serial` option (for example a host pty), so a
host terminal emulator or a test can use `ttyu1`.

## 9. Verification

9.1. On-target tests through `ttyu1`, driven from the host: canonical line editing and `^D`,
`VMIN`/`VTIME`, echo flags, `^C` and `^Z` from `c_cc`, `SIGTTIN`/`SIGTTOU`, hang-up on session
leader exit, `SIGWINCH`, `ttyname`, and `poll`.

9.2. The existing interactive tests (`sendkey` into `ttyv0`) MUST keep passing.

## 10. Open questions

1. Whether `/dev/console` should become a separate device that can be redirected (`TIOCCONS`),
   as in FreeBSD, rather than an alias.
2. A kernel message buffer (`dmesg`) separate from the console.
