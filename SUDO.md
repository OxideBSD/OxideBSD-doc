# OxideBSD privilege escalation: sudo-rs

Status: **accepted plan, not yet implemented.** Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Scope

This document specifies how `sudo` and `su` come to OxideBSD: the port of sudo-rs, and the kernel,
device and library work it depends on. Most of that work is not sudo-specific. It is part of the
v0.3.0 cleanup (`CLEANUP.md`): OxideBSD today has one uid per process, no setuid, no `/dev/tty`
and no pseudo-terminals, and a regular OS has all four.

## 2. Decisions

| Question | Decision | Why |
|---|---|---|
| Which tool | **sudo-rs** (Trifecta Tech Foundation; Apache-2.0 OR MIT) | Desktop users expect `sudo`; sudo-rs is a memory-safe implementation |
| Pseudo-terminals | **Built as part of this work** | sudo-rs runs commands in a pty by default (`use_pty`); every terminal emulator needs ptys too |
| PAM | **Port OpenPAM**, modules linked statically | FreeBSD's PAM, BSD-licensed; `login` and future display managers expect PAM |
| `su` | **sudo-rs's `su` replaces BusyBox `su`** | One audited implementation for both |
| Default policy | **`%wheel ALL=(ALL:ALL) ALL`** | The BSD convention; the seeded `user` account is in `wheel` |

Rejected: a `doas`-style tool of OxideBSD's own (the BSD base-system tradition, OpenBSD's choice),
because desktop users expect `sudo`; patching PAM out of sudo-rs, because every later PAM consumer
would need the same patch.

## 3. Components and placement

| Path | Mode | Source |
|---|---|---|
| `/usr/bin/sudo` | 4755, root | sudo-rs |
| `/usr/bin/sudoedit` | link to `sudo` | sudo-rs |
| `/usr/bin/su` | 4755, root | sudo-rs (BusyBox `su` leaves the roster) |
| `/usr/sbin/visudo` | 0755 | sudo-rs |
| `/etc/sudoers` | 0440, root | `%wheel ALL=(ALL:ALL) ALL` |
| `/etc/pam.d/sudo`, `/etc/pam.d/su`, `/etc/pam.d/login` | 0644 | `pam_unix` |
| `/var/run/sudo-rs/ts` | 0700, root | sudo-rs timestamp records |
| `libpam.a` | | OpenPAM, `/usr/lib` (a porting-layer library) |

`/etc/group` gains `wheel:x:0:root,user`.

## 4. What sudo-rs needs

Established by reading sudo-rs 0.2.15 (commit `bc73403`):

- It builds only for Linux and FreeBSD (`compile_error!` otherwise); about 45 `target_os` gates
  choose platform code. Crate dependencies: `libc` and `glob`. It links `libpam` and has OpenPAM
  bindings (`src/pam/sys_openpam.rs`).
- Credentials: `setresuid`, `setresgid`, `setgroups`, `getgrouplist`, `setuid`, `setgid`, and a
  setuid-root executable.
- Terminals: opens `/dev/tty` read-write to prompt for the password; `ttyname_r`; `openpty` (unless
  `Defaults !use_pty`); `setsid`, `TIOCSCTTY`, `tcsetpgrp`, `killpg`.
- Process identity: on Linux, reads `/proc/<pid>/stat` field 22 (start time) to tie a timestamp
  record to its session; enumerates `/proc/self/fd` to close descriptors.
- Other: `flock`, `pipe2`, `poll`, `sigaction`, `umask`, `chown`, `clock_gettime`, `libc::syslog`.

## 5. Prerequisites

### 5.1. Kernel credentials

5.1.1. Each process MUST carry a real, effective and saved user ID and group ID, and a
supplementary group list (`NGROUPS_MAX` entries at least), all shared across threads.

5.1.2. `execve` of a file with `S_ISUID`/`S_ISGID` set MUST set the effective (and saved) ID to the
file's owner/group. The kernel MUST then pass `AT_SECURE=1` in the auxiliary vector, so the C
library runs in secure mode.

5.1.3. `setuid`, `setgid`, `seteuid`, `setegid`, `setreuid`, `setregid`, `setresuid`, `setresgid`,
`getresuid`, `getresgid`, `setgroups` and `getgroups` MUST follow POSIX and FreeBSD semantics.

5.1.4. File permission checks MUST use the effective IDs and the supplementary groups; `access(2)`
MUST use the real IDs. Signal permission MUST follow POSIX (real or effective sender ID against
the target's real or saved ID).

5.1.5. A write to, or `chown` of, a file MUST clear its `S_ISUID`/`S_ISGID` bits unless the caller
is root. oxfs MUST store and report both bits and `S_ISVTX`.

5.1.6. New syscall numbers follow `CLAUDE.md`'s collision rule (continue past the highest assigned
invented number), each with a matching musl remap.

### 5.2. Terminal devices and pseudo-terminals

5.2.1. `/dev/tty` (the caller's controlling terminal) and `/dev/console` MUST be real character
devices that open read-write. The console's descriptors 0, 1 and 2 are one-way today (fd 0 cannot
be written); a descriptor from opening either device MUST NOT be.

5.2.2. `ttyname(3)` MUST resolve a terminal descriptor to its device path.

5.2.3. Pseudo-terminals MUST exist: a master/slave pair with a line discipline on the slave
(canonical input, echo, signal characters), window-size passthrough, and job-control signals, so
that `openpty(3)` and `posix_openpt(3)` work. The device naming and the line discipline's scope
are specified separately (`PTY.md`, to be written).

### 5.3. Process information

5.3.1. `/proc/<pid>/stat` field 22 (start time, clock ticks since boot) MUST be the real value.

5.3.2. Linux syscall 318 (`getrandom`), which Rust's `std` calls directly, SHOULD be served, so
`std` stops falling back to `/dev/urandom`.

### 5.4. OpenPAM

5.4.1. OpenPAM is vendored under `external/bsd/openpam` and built as a static `libpam.a` with its
modules linked in, since OxideBSD has no `dlopen`. That OpenPAM supports static modules needs
confirming against its current release before work starts.

5.4.2. `pam_unix` MUST authenticate against `/etc/shadow` with `crypt(3)` (musl's).

## 6. The sudo-rs port

6.1. sudo-rs is forked as `OxideBSD/sudo-rs-oxidebsd` (an `oxidebsd` branch, the same convention as
the Rust and `libc` forks). The fork adds `target_os = "oxidebsd"` to each platform gate, choosing
the Linux or FreeBSD code path per gate. The `libc` crate fork gains whatever constants and
functions the port needs.

6.2. It is built by `build.rs`'s `build_std_oxidebsd_userland_crate` and seeded per §3.

## 7. Verification

7.1. On-target tests, run as the unprivileged `user` account:

- a setuid-root test binary gets effective ID 0, can drop it, and cannot regain it afterwards;
- `sudo id` with the right password prints `uid=0`; a wrong password is refused and logged;
- a second `sudo` within the timestamp window doesn't prompt; one from a different session does;
- `su` to root and back;
- `sudo` inside a pty behaves the same as on the console.

7.2. Unit tests for the credential rules in §5.1.

## 8. Order of work

1. Kernel credentials (§5.1).
2. `/dev/tty`, `/dev/console`, `ttyname` (§5.2.1–5.2.2); `/proc` start time and syscall 318 (§5.3).
3. Pseudo-terminals (§5.2.3), after `PTY.md` is written and accepted.
4. OpenPAM (§5.4). Independent of 3.
5. The sudo-rs port and seeding (§6), then §7.

## 9. Open questions

1. Pseudo-terminal naming (`/dev/ptmx` + `/dev/pts/N`, which FreeBSD also uses today, or
   BSD-style `/dev/ptyXX`) and how complete the line discipline must be. For `PTY.md`.
2. Whether OpenPAM's static-module build works as expected (§5.4.1).
3. Where sudo's syslog messages go: OxideBSD has no `/dev/log` yet (that needs named `AF_UNIX`
   datagram sockets, also an init-system prerequisite, `INIT.md`). Until then they are dropped.
