# OxideBSD device events: devctl(4) and devd(8), design specification

Status: **accepted** (2026-10-22); being implemented (§8).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Motivation

Devices now come and go while the system runs: AHCI drives are hot plugged (`INSTALLER.md`
§5.3), CDs change discs, and USB sticks are next. The kernel logs each change, but nothing in
userland can act on it: mount a stick, start a service, tell the user. The BSDs answer this with a
kernel event stream, `/dev/devctl`, and a daemon reading it, `devd(8)`, which runs the actions an
administrator configured. OxideBSD keeps that split and both names. The event format and devd's
configuration language are OxideBSD's own (§3, §5): events are shell-shaped text lines, and the
configuration is a real shell script run by OxideBSD's own shell, `lib/libsh`.

## 2. Terms

- **Event**: one change the kernel reports, one line on `/dev/devctl`.
- **Verb**, **class**: an event's first two words, what happened (`attach`) and to what kind of
  thing (`disk`).
- **Field**: one `name=value` pair after the class.
- **Rule**: devd's binding of a handler to the events that match it (§5.2).
- **Handler**: the shell text a rule runs for a matching event.

## 3. Events

3.1. **An event is one line**: the verb, a space, the class, then zero or more fields, each a
space and `name=value`, ended by a newline:

```
attach disk name=sata0.2 bus=ahci controller=0 port=2 model='WDC WD10EZEX-08W' sectors=1953525168
```

Verbs and classes are lower-case words (`[a-z][a-z0-9_]*`). Field names are valid shell variable
names in lower case (`[a-z_][a-z0-9_]*`), never `verb` or `class`, and none repeats in one event.

3.2. **Values are quoted as the shell quotes them.** A value of only `A-Z a-z 0-9 _ . / : + - , @
%` (and not empty) is written bare; any other is written in single quotes, an embedded single
quote as `'\''`. A value can't hold a newline or another control character (`0x00`-`0x1f`,
`0x7f`): the kernel writes `?` for each. So a line is always one line, and a device's own strings
(a model name a drive reports, a volume label) can't forge fields or lines.

3.3. **The events of this design** (more classes come with the drivers that need them; a reader
MUST ignore verbs, classes and fields it doesn't know):

| Line | When |
| --- | --- |
| `attach disk name= bus= model= kind= sectors= sector_size=` (+ the bus's own: AHCI's `controller= port=` and `pmp=` behind a multiplier) | a disk or CD drive is registered: at boot, or plugged in |
| `detach disk name= bus=` | a drive is pulled out (after its file systems are unmounted, §3.5) |
| `create dev name= major= minor=` | a `/dev` node is made (`make_dev`), `name` relative to `/dev` |
| `destroy dev name= major= minor=` | a `/dev` node goes |
| `media cd name= state=inserted sectors=` | a disc is found in a CD drive (`drivers::disk::media_check`) |
| `media cd name= state=ejected` | a CD drive's disc is gone |
| `lost root name= policy=eio` | the root file system's drive went and the system keeps running (`INSTALLER.md` §5.3) |
| `lost devctl count=` | `count` events were dropped before this one (§4.3) |

On attach the `attach disk` line comes first, then a `create dev` line for the whole disk and one
for each partition and label; on detach the `destroy dev` lines come first, then `detach disk`.

3.4. **Events start at boot.** The disks, CDs and `/dev` nodes found at boot are reported like
any found later (the queue holds them until devd opens `/dev/devctl`, §4.3), so a rule for
`attach disk` also sees the drives present at boot: one path for cold and hot plug.

3.5. A drive pulled out has its file systems unmounted by force before its `detach disk` (or, for
the root, as `INSTALLER.md` §5.3 says); the events say what happened, they never ask devd's leave.

## 4. `/dev/devctl`

4.1. A character device, root's, mode `0600`, registered with `make_dev` (`DEVFS.md`). **One open
at a time**: a second `open` fails with `EBUSY`, as FreeBSD's does.

4.2. `read` takes bytes off the front of the queue as a stream of lines: as many as fit, a line
that doesn't fit given in part and finished by the next `read`. With the queue empty it blocks
(interruptibly: `EINTR`), or fails with `EAGAIN` under `O_NONBLOCK`. `poll`/`select` report it
readable while the queue holds anything. `write` fails with `EBADF` (it's opened read-only;
`O_WRONLY`/`O_RDWR` opens fail with `EACCES`).

4.3. **The queue is bounded**: `kern.devctl.queue` lines (default 256, writable; at least 16). It
fills from boot whether or not anyone has the device open. When it's full the oldest line is
dropped and `kern.devctl.dropped` counts it; the next line read after a run of drops is
preceded by `lost devctl count=<n>`. Closing the device keeps the queue: a restarted devd reads on
from where the last one stopped. Events are made by the kernel only; nothing in userland can
write one.

4.4. Making an event MUST NOT sleep and MAY run in a kernel thread or a system call, never in an
interrupt handler (it allocates). It wakes a blocked reader and any `poll` waiting on the device.

## 5. devd(8)

5.1. **devd is `/sbin/devd`**, a static Rust std program (`hier(7)`: it runs before `/usr` is
mounted). `/etc/rc.d/devd` starts it after `devfs` and before the local file systems
(`REQUIRE: devfs`, `BEFORE: mountcritlocal`), so mount rules can see boot's drives. Options:
`-d` stays in the foreground and logs each event and rule to stderr; `-f <file>` reads that file
only instead of §5.3's list; `-n` checks the configuration and exits (status 0 if it loaded).

5.2. **The configuration is a shell script**, run by devd's own copy of OxideBSD's shell
(`lib/libsh`, linked in: no `/bin/sh` process for it). Everything sh has is there (functions,
variables, `case`, `.`); devd adds one builtin:

```
on VERB CLASS HANDLER [NAME=PATTERN ...]
```

which adds a rule: an event matches when its verb matches `VERB`, its class `CLASS` and, for each
`NAME=PATTERN`, its field `NAME` exists and matches `PATTERN` (each a sh glob, `case`'s rules:
`'*'` matches anything, `sata*` every AHCI name). `HANDLER` is shell text, run as `eval` would:
a function's name, or a command line in quotes. Rules match in the order `on` added them; every
matching rule runs, not only the first.

```
# /etc/devd.conf
ahci_plugged() {
	logger -t devd "drive $name ($model) plugged in"
}
on attach disk ahci_plugged bus=ahci

on media cd 'mount -t cd9660 "/dev/$name" /cdrom' state=inserted
on lost root 'wall "the root disk ($name) is gone; save your work elsewhere"'
```

5.3. **What it reads**: `/etc/devd.conf`, then every `/etc/devd/*.conf`, then every
`/usr/local/etc/devd/*.conf` (each directory in lexical order, a missing one skipped), each
sourced into the one shell, so a later file may use an earlier one's functions. A file that fails
to parse is reported (its name and line, to syslog and, under `-d`, stderr) and skipped; the rest
load. `SIGHUP` reloads all of them into a fresh shell; the rules in force until the reload ends
are the old ones.

5.4. **Running a handler.** For each event devd forks; in the child, the shell's variables
`verb`, `class` and each field's name are set to the event's values (and exported, so commands the
handler runs see them as environment variables), then each matching rule's handler runs in turn,
and the child exits. A handler's `exit`, `cd` or variable assignments end with the child, never
reaching devd or the next event. devd waits for the child before the next event, so events are
handled in the order they happened (an `attach disk` rule finishes before the `create dev` rules
for its partitions); a handler wanting to keep going in the background uses `&`. The fields are
values, never code: devd parses the line itself (§3.2) and assigns them; it never `eval`s an
event. A handler that quotes its variables (`"$model"`) is safe from any string a device reports.

5.5. **Following events** (FreeBSD's `devd.pipe`). devd listens on an `AF_UNIX` stream socket,
`/var/run/devd.pipe`, mode `0666`, and writes every event line it reads to every connected
client, before running its rules. A client that falls behind (the write would block) is
disconnected. Clients can't send anything; what they send is discarded. `cat` over a socket
(`nc -U /var/run/devd.pipe`) shows the events live.

5.6. devd logs to syslog (`daemon` facility): each handler that exits non-zero, with the event;
configuration errors; the reload. It runs as root.

## 6. Manual pages

`devctl(4)` (the device, §3-4), `devd(8)` (§5.1, 5.4-5.6), `devd.conf(5)` (§5.2-5.3, every event
of §3.3).

## 7. Security

Events say only what the kernel already logs to the msgbuf (`dmesg` is readable by all), so the
pipe is world-readable. `/dev/devctl` is root's only so that no user can steal the events from
devd (it has one reader). Device-supplied strings are quoted by the kernel and assigned, not
evaluated, by devd (§3.2, §5.4): the remaining risk is a handler that uses them unquoted, which
`devd.conf(5)` warns about.

## 8. Steps and verification

Each step is one commit, with its test; the suite and the POSIX canary stay green.

1. **`/dev/devctl`** (§3, §4) and the events of §3.3 from the disk registry, devfs and the media
   check (`lost root` with hot plug's root policy, `KTHREAD.md` step 5); test: a user program
   reads boot's `attach disk` and `create dev` lines from `/dev/devctl`, checks a second open
   fails with `EBUSY`, `poll`, `O_NONBLOCK`'s `EAGAIN`, and the drop count with a tiny queue.
2. **libsh embedding**: the builtin hook a program linking `lib/libsh` adds its own builtins
   through (`on`); host tests in `lib/libsh`.
3. **devd** (§5) with `/etc/rc.d/devd`, `/etc/devd.conf`, the pipe and the manual pages; test: a
   test kernel boots with a rule that writes each `attach disk` event to a file, and a client of
   the pipe sees a hot plug test's events (`KTHREAD.md` step 5's test hook).

## 9. Decisions

- 2026-10-22 (user): devctl now, with devd; the event format OxideBSD's own, one
  `verb class name=value` line per event, values sh-quoted; devd's configuration real sh, run in
  devd through `lib/libsh`, rules added by an `on` builtin; read from `/etc/devd.conf`,
  `/etc/devd/*.conf`, `/usr/local/etc/devd/*.conf`; the client pipe now; events for disk
  attach/detach, devfs nodes, CD media and a lost root.

## 10. Open questions

- Other buses' events (USB devices, network interfaces' link state, ACPI) come with their
  drivers; `ifconfig`-driven events wait for dynamic interfaces.
