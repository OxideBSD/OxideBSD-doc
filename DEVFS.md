# OxideBSD device filesystem: design specification

Status: **accepted design, not yet implemented.** Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interfaces are documented in the manual pages `devfs(4)` and `devfs.conf(5)`; this
document records the design. It follows FreeBSD, whose `devfs` it is modelled on; NetBSD and
OpenBSD still create static nodes with `MAKEDEV`, which is what OxideBSD had and what failed
(below).

## 1. Scope

The kernel's registry of devices, the file system that presents them at `/dev`, and how `/dev`
is customized at boot.

**Rationale.** Until now every node in `/dev` but four was an ordinary oxfs inode created once,
when the disk was formatted. A mount never created them again, so `rm /dev/fb0` removed the
framebuffer for good, surviving every reboot (issue #1). The four exceptions (`null`, `zero`,
`random`, `urandom`) were intercepted by name before path lookup. Device handling was split
between oxfs (those four and `fb0`) and the kernel (terminals, `klog`), by device number.

## 2. Components

| Part | Role | Source |
|---|---|---|
| Device registry | Every device: name, number, owner, group, mode, open function | kernel, `sys/fs/devfs.rs` |
| `oxidebsd_make_dev` | How a driver or module registers a device | kernel export |
| devfs | The file system mounted on `/dev`, built from the registry | oxfs, `MountKind::Devfs` |
| `/etc/devfs.conf` | Owners, modes and links applied at boot (`devfs.conf(5)`) | `etc/devfs.conf` |
| `/etc/rc.d/devfs` | Applies it | `etc/rc.d` |

## 3. The device registry

3.1. The kernel keeps one table of character devices. An entry has a name (a path relative to
`/dev`, which MAY contain `/`: `pts/0`), a major and minor number, an owner, a group, a mode, and
an open function that returns a descriptor or `-errno`.

3.2. `oxidebsd_make_dev(name, major, minor, uid, gid, mode, open)` adds an entry; a driver or
module calls it when its device exists (the framebuffer only when there is one). Adding a name
or number already present fails with `EEXIST`. `oxidebsd_destroy_dev(major, minor)` removes an
entry; its node leaves `/dev`, and opens already made are unaffected.

3.3. The registry changes a generation counter on every addition and removal, which devfs
reads to keep `/dev` current (§4.3).

3.4. Opening a device node, anywhere, goes through the registry by number: `oxidebsd_dev_open(
major, minor, flags)` calls the entry's open function, or fails with `ENXIO` if none is
registered. oxfs's own table of known devices, and the interception of the four names, are
removed; oxfs registers the devices it implements (`null`, `zero`, `random`, `urandom`, `fb0`)
like any other driver.

3.5. Device numbers are kept as they are (Linux's where one exists): `null` (1, 3), `zero`
(1, 5), `random` (1, 8), `urandom` (1, 9), `ttyv<n>` (4, n), `tty` (5, 0), `console` (5, 1),
`klog` (7, 0), `fb0` (29, 0).

## 4. devfs

4.1. oxfs mounts devfs on `/dev` during its own initialization, before any process runs, so it
is present from the first `open(2)`. devfs is held in memory, in the pool tmpfs mounts use, and
is created afresh at every boot: nothing in it is written to disk. The `/dev` directory on the
disk is only its mountpoint; whatever an older installation left there is hidden.

4.2. devfs holds a node for every registered device, with the entry's owner, group and mode,
and a directory `shm` (mode `01777`), where musl's `shm_open(3)` and `sem_open(3)` keep POSIX
shared memory and semaphores.

4.3. When a path lookup enters `/dev` and the registry's generation has changed, devfs adds
nodes for new entries and removes nodes of removed ones before the lookup continues.

4.4. **Changes last until reboot.** As in FreeBSD:
1. `unlink(2)` of a device node hides it; §4.3 does not bring it back. A reboot does.
2. `chmod(2)` and `chown(2)` of a node last until reboot (§5 makes such changes permanent).
3. `mknod(2)` in devfs fails with `EPERM`: devices come from drivers.
4. Other files can be created in devfs and last until reboot: sockets (`/dev/log`, bound by
   `syslogd`), symbolic links, directories, and ordinary files (under `/dev/shm`).

4.5. `mknod(2)` elsewhere in oxfs still creates device nodes on disk, which open through the
registry by number like devfs's.

4.6. `/proc/mounts` lists devfs as `devfs /dev devfs`.

## 5. `devfs.conf`

5.1. `/etc/devfs.conf` has FreeBSD's format. Each line is an action, a device name (a shell
pattern, relative to `/dev`) and an argument; `#` starts a comment:

| Line | Effect |
|---|---|
| `own	dev	user[:group]` | `chown(2)` the matching nodes |
| `perm	dev	mode` | `chmod(2)` them (octal) |
| `link	dev	name` | Create `/dev/name` as a symbolic link to `dev` |

5.2. `/etc/rc.d/devfs` (`REQUIRE: sysctl`, `BEFORE: tmp`) applies it at boot. A line naming a
device that doesn't exist is skipped with a warning.

5.3. The default `/etc/devfs.conf` has comments only: the registry's defaults are the BSDs'.

## 6. Verification

6.1. `tests/devfs_syscall_smoke.rs`: the registry's nodes exist with their owners and modes;
each opens (reading `/dev/zero`, writing `/dev/null`); `rm /dev/fb0` hides it and it stays
hidden across a lookup; `chmod` lasts; `mknod` in `/dev` fails with `EPERM`; a socket, a
symbolic link and a file under `/dev/shm` can be created; a node made by `mknod` on disk opens
through the registry; `rc.d/devfs` applies a test `devfs.conf`.

6.2. By hand, on a persistent disk (a test boots once): `rm /dev/fb0`, reboot, `/dev/fb0` is
back.

## 7. Open questions

None.
