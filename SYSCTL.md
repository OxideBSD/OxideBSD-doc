# OxideBSD sysctl: design specification

Status: **accepted design, implemented** (not yet: the optional module interface of §3.6). Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interfaces are documented in the manual pages `sysctl(3)`, `sysctl(8)` and
`sysctl.conf(5)`; this document records the design. It follows FreeBSD, whose interface NetBSD and
OpenBSD share in its essentials (numeric names, `sysctl(3)`, `sysctl(8)`); FreeBSD's self-describing
tree is used because `sysctl -a` and `sysctlbyname(3)` need one. `SYSLOG.md` depends on it
(`kern.msgbuf`).

## 1. Scope

The kernel's management information base (MIB): a tree of named, typed variables that user space
reads and, where allowed, writes; the `sysctl(2)` system call and its C library interface; the
`sysctl(8)` utility; `/etc/sysctl.conf`, applied at boot by `rc.d/sysctl`; boot-time tunables; and
the load average and memory statistics the `vm` variables report.

## 2. Components

| Path | Role | Source |
|---|---|---|
| `sys/kern/kern_sysctl.rs` | The MIB tree, the system call, the kernel's variables | kernel |
| `sys/modules/sysctl` | Registers the system call | kernel module |
| `<sys/sysctl.h>`, `sysctl(3)`, `sysctlbyname(3)`, `sysctlnametomib(3)` | C interface | `external/mit/musl` |
| `/sbin/sysctl` | Reads and sets variables | Rust, `sbin/sysctl` |
| `/etc/sysctl.conf`, `/etc/sysctl.conf.local` | Settings applied at boot | `etc/sysctl.conf` |
| `/etc/rc.d/sysctl` | Applies them | `etc/rc.d` |

BusyBox's `sysctl` stops being installed; it reads Linux's `/proc/sys`, which OxideBSD does not
have.

## 3. The tree

3.1. Every variable has a numeric name (an array of integers, the OID), a dotted text name, a
type, access flags and a one-line description. Interior nodes have children and no value.

3.2. **Numbering.** Top-level nodes use the BSDs' numbers: `kern` 1, `vm` 2, `vfs` 3, `net` 4,
`debug` 5, `hw` 6, `machdep` 7, `user` 8. Below them, a variable with a number assigned in
FreeBSD's `<sys/sysctl.h>` (`KERN_OSTYPE`, `KERN_HOSTNAME`, `HW_NCPU` and so on) MUST use that
number; every other variable is numbered automatically from 256 upward at registration, as
FreeBSD's `OID_AUTO` does. Automatic numbers are stable only within one boot; programs MUST use
text names for them.

3.3. **Types**, with FreeBSD's `CTLTYPE_*` values and format strings: node, `int` (`I`),
`unsigned int` (`IU`), `long` (`L`), `unsigned long` (`LU`), `int64_t` (`Q`), `uint64_t` (`QU`),
string (`A`), and opaque structures (`S,name`, for example `S,timeval`).

3.4. **Access.** Each variable is read-only, read-write, or a tunable (§6). Anyone may read; only
root may write (`EPERM` otherwise). A variable MAY be flagged writable only before multi-user
start-up; there is no securelevel yet, so this flag has no effect until one exists.

3.5. **Meta-variables.** The `sysctl` node, number 0, describes the tree itself, with FreeBSD's
numbers: `{0, 1, ...}` returns the text name of the OID that follows, `{0, 2, ...}` the next
variable after it in depth-first order, `{0, 3}` converts the text name written as new data into
an OID, `{0, 4, ...}` returns the type and format, and `{0, 5, ...}` the description.

3.6. Kernel modules MAY register variables through the kernel API, under the node of their
subsystem (`vfs.oxfs`, for example). A module's variables disappear if its registration is
withdrawn.

## 4. `sysctl(2)`

4.1. `sysctl(name, namelen, oldp, oldlenp, newp, newlen)` has six arguments; the native ABI
passes them as one pointer to a structure of those six, system call number 583.

4.2. **Semantics** (FreeBSD's):
1. With `oldp` null and `oldlenp` not null, `*oldlenp` is set to the size of the value, and nothing
   is copied.
2. With `oldp` not null, the value is copied and `*oldlenp` set to its size. If `*oldlenp` was too
   small, as much as fits is copied and the call fails with `ENOMEM`.
3. With `newp` not null, the variable is set after the old value is read. A value of the wrong
   size fails with `EINVAL`.
4. An OID that names nothing fails with `ENOENT`; `namelen` over 24 or under 2 fails with
   `EINVAL`; reading an interior node fails with `EISDIR`.

4.3. The C library provides `sysctl(3)`, `sysctlbyname(3)` (through `{0, 3}`) and
`sysctlnametomib(3)`, in a new `<sys/sysctl.h>` holding FreeBSD's `CTL_*`, `KERN_*`, `HW_*` and
`CTLTYPE_*` values, `struct clockinfo`, and `struct timeval` for `kern.boottime`. The system-call
macro is `__NR_sysctl`, distinct from musl's existing `__NR__sysctl`.

## 5. Initial variables

| Name | Type | Access | Value |
|---|---|---|---|
| `kern.ostype` | string | read | `OxideBSD` |
| `kern.osrelease` | string | read | as `uname -r` |
| `kern.version` | string | read | as `uname -v`, then a newline |
| `kern.hostname` | string | read-write | as `sethostname(2)`/`gethostname(3)`; one value |
| `kern.domainname` | string | read-write | the NIS domain name, empty by default |
| `kern.boottime` | `S,timeval` | read | time of boot |
| `kern.hz` | int | read | the clock-interrupt rate, 100 |
| `kern.clockrate` | `S,clockinfo` | read | `hz`, `tick`, `profhz`, `stathz` |
| `kern.maxproc` | int | tunable | process table limit |
| `kern.maxfiles` | int | tunable | open-file limit |
| `kern.argmax` | int | read | `execve(2)` argument limit (2 MiB) |
| `kern.ngroups` | int | read | supplementary group limit |
| `kern.iov_max` | int | read | 1024 |
| `kern.msgbuf` | string | read | the kernel message buffer (`SYSLOG.md` §3) |
| `kern.msgbufsize` | int | tunable | its size, 65536 |
| `kern.msgbuf_clear` | int | write | any value empties the buffer |
| `hw.machine` | string | read | the port: `amd64` (§5.1) |
| `hw.machine_arch` | string | read | the processor architecture: `amd64` (§5.1) |
| `hw.model` | string | read | the processor's brand string (`CPUID`) |
| `hw.ncpu` | int | read | 1 |
| `hw.byteorder` | int | read | 1234 |
| `hw.pagesize` | int | read | 4096 |
| `hw.physmem` | unsigned long | read | usable memory in bytes |
| `hw.usermem` | unsigned long | read | memory not wired by the kernel |
| `vm.loadavg` | `S,loadavg` | read | the load average (§9) |
| `vm.vmtotal` | `S,vmtotal` | read | process and memory totals (§10) |
| `vm.stats.vm.v_page_count` | unsigned int | read | pages of usable memory |
| `vm.stats.vm.v_free_count` | unsigned int | read | free pages |
| `vm.stats.vm.v_wire_count` | unsigned int | read | pages the kernel holds (heap, stacks, page tables, modules) |
| `vm.stats.vm.v_user_count` | unsigned int | read | pages mapped into processes |
| `vm.pagecache.entries` | unsigned int | read | files with pages in the read-only page cache (`PAGECACHE.md`) |
| `vm.pagecache.pages` | unsigned int | read | frames the page cache holds |
| `vm.pagecache.hits` | unsigned long | read | cached pages mapped since boot |
| `vm.pagecache.misses` | unsigned long | read | pages read into the cache since boot |
| `vm.pagecache.limit` | unsigned int | read | frames files no process uses may hold |
| `vm.pagecache.list` | string | read | a line per entry: inode, size, frames held, uses |

5.1. **Architecture names** are FreeBSD's, `hw.machine` naming the port and `hw.machine_arch`
the processor architecture:

| Architecture | `hw.machine` (`uname -m`) | `hw.machine_arch` (`uname -p`) |
|---|---|---|
| x86-64 | `amd64` | `amd64` |
| 64-bit ARM | `arm64` | `aarch64` |
| 64-bit RISC-V | `riscv` | `riscv64` |
| 64-bit little-endian POWER | `powerpc` | `powerpc64le` |

`uname(2)`'s `machine` field MUST equal `hw.machine`, so `uname -m` changes from `x86_64` to
`amd64`; `uname -p` prints `hw.machine_arch`. The
compiler's target triple (`x86_64-unknown-oxidebsd`) is unaffected; triples and machine names are
separate namespaces in the BSDs too.

## 6. Boot-time tunables

6.1. A tunable is a variable whose value is fixed when the kernel starts, because it sizes or
configures something set up early in boot. It is read-only afterwards (FreeBSD's
`CTLFLAG_RDTUN`).

6.2. FreeBSD's loader passes tunables from `/boot/loader.conf`. OxideBSD's loader is Limine, so
tunables come from the kernel command line: a token `name=value` whose name contains a `.` and
names a tunable sets it. A token that names no tunable, or a value out of range, is logged and
ignored. The command line's other tokens (`-s`, `-D`, `-h`, `no-ata`, `console.underline=`) are
unchanged.

6.3. Initial tunables: `kern.msgbufsize` (4096 to 16 MiB), `kern.maxproc` and `kern.maxfiles`.

6.4. `kern.hz` stays read-only: the scheduler's quantum and every tick-based timeout assume 100.

## 7. `sysctl(8)`

7.1. `sysctl [-bdehiNnoqtx] [-f file] name[=value[,value...]] ... | -a`, with FreeBSD's meaning:
`-a` every variable, `-b` raw binary value, `-d` the description, `-e` `name=value` output, `-f`
apply a file (§8), `-h` human-readable numbers, `-i` ignore unknown names, `-N` names only, `-n`
values only, `-o` opaque values in hexadecimal, `-q` quiet, `-t` the type, `-x` all opaque
values in hexadecimal.

7.2. Structures `timeval`, `clockinfo`, `loadavg` and `vmtotal` are printed as FreeBSD prints them
(`{ sec = N, usec = N } Www Mmm dd hh:mm:ss yyyy` for `kern.boottime`).

## 8. `sysctl.conf`

8.1. One `name=value` per line; `#` starts a comment; blank lines are ignored. A value MAY be
quoted.

8.2. `rc.d/sysctl` (`PROVIDE: sysctl`, no requirements, so that it runs first) applies
`/etc/sysctl.conf` and then `/etc/sysctl.conf.local` with `sysctl -f`. An unknown name or a failed
write is reported on the console and does not stop the rest.

## 9. Load average

9.1. Every 5 seconds the kernel counts the runnable processes (running or ready to run) and
updates three averages, decaying with time constants of 1, 5 and 15 minutes (factors
`exp(-5/60)`, `exp(-5/300)`, `exp(-5/900)`), in fixed point with `FSCALE` 2048, as the BSDs do.

9.2. `vm.loadavg` returns `struct loadavg` (`ldavg[3]`, `fscale`). `getloadavg(3)` reads it, and
`sysinfo(2)`'s `loads` reports the same averages scaled to its own 16-bit fraction.

## 10. Memory statistics

10.1. The frame allocator MUST count free frames, and the kernel MUST count the frames it holds
itself and those mapped into processes, so that §5's `vm.stats.vm.*` values and `hw.usermem` are
exact rather than estimates.

10.2. `vm.vmtotal` returns FreeBSD's `struct vmtotal`: processes by state (`t_rq` runnable,
`t_dw` in disk wait, `t_pw` in page wait, always 0, `t_sl` sleeping, `t_sw` always 0) and memory
totals in pages (`t_free` and the virtual and real totals).

10.3. `sysinfo(2)`'s `freeram` becomes `v_free_count` pages instead of all memory.

## 11. Verification

11.1. `tests/sysctl_syscall_smoke.rs` with a C fixture: every variable of §5 reads with the right
type and size; `sysctlbyname(3)` and `sysctlnametomib(3)` agree; a walk with `{0, 2}` visits every
variable once; the size probe, `ENOMEM` truncation, `EPERM` for a non-root write, `ENOENT` and
`EISDIR` cases; `kern.hostname` and `gethostname(3)` agree after writes through each.

11.2. `sysctl -a` on target lists every variable.

11.3. A boot with `kern.msgbufsize=131072` on the command line reports that value; an unknown
tunable is logged. A test that keeps two processes runnable for a minute sees `vm.loadavg`'s
one-minute value rise above 1.0. `v_free_count` falls by the size of a large allocation and
recovers after the process exits.

## 12. Open questions

None.
