# OxideBSD init and rc: design specification

Status: **accepted design, not yet implemented.** Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interface-level documentation lives in the manual pages `init(8)`, `rc(8)`,
`rc.conf(5)` and `ttys(5)`; this document records the design and its rationale.

## 1. Scope

This document specifies process 1 (`/sbin/init`), the boot and shutdown scripts (`/etc/rc`,
`/etc/rc.shutdown`), the service framework (`/etc/rc.d`, `/sbin/rcorder`, `/etc/rc.conf`), terminal
session management (`/etc/ttys`), and the kernel's obligations toward process 1, including
recovery when it dies.

The design follows FreeBSD and NetBSD (`init(8)`, `rc.d`, `rcorder(8)`) except where §9 and §10
deliberately depart from them.

## 2. Components

| Path | Role |
|---|---|
| `/sbin/init` | Process 1. A Rust `std` program. |
| `/sbin/rcorder` | Orders `rc.d` scripts by their dependency headers. A Rust `std` program. |
| `/sbin/init_sh` | Interpreter for `/etc/rc`, `rc.shutdown` and `rc.d` scripts (see `INIT_SH.md`). |
| `/sbin/initconf` | Controls and configures services: `initconf <action> <service>` (see `INIT_SH.md` §4.4). |
| `/etc/rc` | Boot script, run by init in the `runcom` state. |
| `/etc/rc.shutdown` | Shutdown script, run by init before terminating processes. |
| `/etc/rc.subr` | Kept for compatibility; its functions are `init_sh` built-ins (`INIT_SH.md` §4.7). |
| `/etc/rc.d/<service>` | One `init_sh` script per service (`INIT_SH.md` §4.1). |
| `/etc/defaults/rc.conf` | Default settings. MUST NOT be edited locally. |
| `/etc/rc.conf` | Local settings. Overrides `/etc/defaults/rc.conf`. |
| `/etc/ttys` | Terminals on which init runs login sessions. |
| `/usr/libexec/getty` | Terminal line setup and login prompt. |
| `/usr/sbin/daemon` | Optional per-service supervisor (§8). |
| `/sbin/reboot`, `/sbin/halt`, `/sbin/poweroff`, `/sbin/shutdown` | Request state changes from init (§6). |

## 3. States

Init is a state machine. Exactly one state is current at any time.

| State | Behavior | Leaves to |
|---|---|---|
| `single-user` | Runs `/bin/sh` on the console; no other processes are started. | `runcom` when the shell exits |
| `runcom` | Runs `/etc/rc` and waits for it. | `multi-user` on success; `single-user` if `/etc/rc` fails |
| `multi-user` | Runs and supervises the sessions listed in `/etc/ttys`; reaps all orphans. | `clean-ttys` or `shutdown` on request |
| `clean-ttys` | Stops starting new sessions and terminates existing ones. | `single-user` |
| `shutdown` | Runs `/etc/rc.shutdown`, terminates all processes, synchronizes storage, invokes `reboot(2)`. | none |
| `recovery` | Entered only by a respawned init (§9). Restores missing sessions and services. | `multi-user` |

**Rationale.** A single-user state that the boot falls back to on failure is the traditional BSD
repair path; it guarantees an interactive shell whenever the system cannot come up on its own.

## 4. Boot

4.1. The kernel MUST start `/sbin/init` as process 1. Boot flags from the kernel command line MUST
be passed to init as arguments: `-s` requests the `single-user` state.

4.2. Init MUST NOT depend on inherited environment variables. It MUST construct the environment
for its children explicitly, including at least `PATH`, `HOME`, `SHELL` and `TERM`. The default
`PATH` for root is `/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin`.

4.3. Without `-s`, init enters `runcom` and runs `/sbin/init_sh /etc/rc autoboot`.

4.4. `/etc/rc` MUST load `/etc/defaults/rc.conf` and then `/etc/rc.conf`, obtain the service order
from `rcorder /etc/rc.d/*`, and run each script with the argument `start`.

4.5. A script whose `<name>_enable` variable is not `YES` MUST exit successfully without starting
anything.

4.6. **Failure policy.** When an individual `rc.d` script fails, `/etc/rc` MUST report the failure
on the console and MUST continue with the remaining scripts. Only a failure of `/etc/rc` itself
(a non-zero exit) causes init to enter `single-user`.

4.7. Each `rc.d` script MUST declare its dependencies for `rcorder`, either with the `provide`,
`require`, `before` and `keyword` fields of a service block (`INIT_SH.md` §4.2) or, for classic
FreeBSD-style scripts, with comment headers:

```
# PROVIDE: cron
# REQUIRE: FILESYSTEMS
# BEFORE:  LOGIN
# KEYWORD: shutdown
```

## 5. Terminal sessions

5.1. In `multi-user`, init MUST read `/etc/ttys` and, for each entry marked `on`, run the entry's
command (normally `/usr/libexec/getty`) on that terminal.

5.2. When a session process exits, init MUST start a new one for the same entry.

5.3. Init MUST rate-limit restarts of an entry whose session exits immediately, so that a broken
entry cannot monopolize the processor.

5.4. The console entry MUST be marked `insecure` by default. On an `insecure` console, entering
`single-user` MUST require root's password.

5.5. `SIGHUP` causes init to re-read `/etc/ttys` and start or stop sessions to match it.

**Rationale.** Init supervises login sessions because a system without a working console login is
unusable; it does not supervise services (§8).

## 6. Signals

Init MUST handle the following signals as specified. The utilities in `/sbin` request state
changes by sending these signals to process 1.

| Signal | Meaning |
|---|---|
| `SIGHUP` | Re-read `/etc/ttys`. |
| `SIGTERM` | Enter `clean-ttys`, then `single-user`. |
| `SIGINT` | Shut down and reboot. |
| `SIGUSR1` | Shut down and halt. |
| `SIGUSR2` | Shut down and power off. |
| `SIGTSTP` | Stop starting new sessions; existing sessions continue. |
| `SIGCHLD` | Reap exited children (§7). |

These meanings are FreeBSD's and differ from BusyBox init's (where `SIGTERM` means reboot).
OxideBSD's `/sbin` utilities MUST use the table above; BusyBox's `halt`, `poweroff` and `reboot` are
not installed.

## 7. Reaping

7.1. Every process whose parent exits is reparented to process 1.

7.2. Init MUST collect the exit status of every child, including reparented orphans, so that no
exited process remains a zombie.

## 8. Services

8.1. Services are started and stopped only by their `rc.d` scripts (`start`, `stop`, `restart`,
`status`). Init does not monitor services.

8.2. **Opt-in supervision.** Setting `<name>_restart="YES"` in `rc.conf` causes the service's
script to run the service under `/usr/sbin/daemon -r`, which restarts it after it exits, with a
back-off delay between restarts. Without this setting, a service that exits stays stopped.

**Rationale.** The default preserves BSD semantics: a daemon that crashes stays down and its
failure is visible. Restart-on-exit is useful for some services and is available per service,
without making init itself a service manager.

## 9. Death of init

This section departs from the BSDs, whose kernels halt the system when process 1 exits.

9.1. **Protection.** The kernel MUST discard any signal sent to process 1 from user space for which
process 1 has not installed a handler. `SIGKILL` and `SIGSTOP` sent from user space MUST be
discarded. Faults generated by init itself (for example `SIGSEGV`) are not discarded.

9.2. **Respawn.** When process 1 terminates, the kernel MUST:
1. record the cause (exit status, or terminating signal and fault address);
2. start a new `/sbin/init` as process 1 with the argument `-R`;
3. reparent every process whose parent was the old process 1 to the new one.

9.3. **Recovery mode.** An init started with `-R` MUST NOT run `/etc/rc`. It MUST:
1. start a session for every `on` entry in `/etc/ttys` that has no running session;
2. run `status` for each enabled `rc.d` service and `start` any that is not running;
3. report on the console that init was restarted, and why;
4. enter `multi-user`.

9.4. **Repeated failure.** If process 1 terminates three times within 30 seconds, the kernel MUST
NOT start init again. It MUST instead start an emergency shell on the console that:
1. lists each recorded termination with its time and cause;
2. offers two choices: open a root shell to repair the system, or restart the computer.

When the repair shell exits, the kernel MUST attempt to start init again.

**Rationale.** A crash in init should not end a running system when the rest of it is healthy.
Respawning preserves running work; the repeated-failure limit prevents a crash loop from consuming
the processor, and the emergency shell gives the operator the information needed to repair it.

## 10. Shutdown

10.1. Init MUST run `/etc/rc.shutdown`, which stops `rc.d` services in the reverse of their start
order, using each script's `stop` argument. Only scripts with the `shutdown` keyword are stopped.

10.2. If `/etc/rc.shutdown` has not finished after `rcshutdown_timeout` seconds (default 90), init
MUST terminate it and continue.

10.3. Init MUST then send `SIGTERM` to all processes except itself, wait up to 5 seconds, send
`SIGKILL` to any that remain, call `sync()`, and invoke `reboot(2)` with the requested action.

## 11. Kernel requirements

The design depends on the following kernel behavior, some of which does not exist yet:

| Requirement | Section | Status |
|---|---|---|
| `kill(-1, sig)` signals every process except process 1 and the caller | 10.3 | Done (f97971a) |
| Boot flags passed to init as arguments | 4.1 | Done in the kernel (27dbcb1): `-s` on the kernel command line gives `/sbin/init -s`, as FreeBSD/OpenBSD's `start_init()` do; used once `/sbin/init` is process 1 |
| Signal protection for process 1 | 9.1 | Not implemented |
| Respawn, reparenting and repeated-failure shell | 9.2, 9.4 | Not implemented (process 1 exiting currently leaves the system idle) |
| Interface configuration ioctls | `rc.d/netif` | Not implemented |
| Named `AF_UNIX` datagram sockets (`/dev/log`) | `rc.d/syslogd` | Not implemented |

## 12. Initial services

The first release ships these `rc.d` scripts: `hostname`, `tmp` (a `tmpfs` on `/tmp`), `sysctl`,
`cron`, `netif`, `syslogd`. `netif` and `syslogd` require the kernel features listed in §11.

## 13. Open questions

1. Getty restart rate limit (§5.3): the exact threshold and delay.
2. Where init records messages before `syslogd` is running.
3. Whether a `/dev/console` device node is required, or getty continues to use the terminal
   descriptors inherited from init.

## 14. Future work

Graphical login managers (`sddm`, `gdm`, `lightdm` and others) will be provided as `rc.d`
services. `/etc/ttys` and getty remain the text-console path.
