# OxideBSD device filesystem: design specification

Status: **implemented** (2026-09-30, `342fda3`; its own module, FreeBSD's semantics, several views and `/dev/shm` a tmpfs since 2026-10-17, `a27ca0d`, `VFS.md` §11 step 3c). Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interfaces are documented in the manual pages `devfs(4)` and `devfs.conf(5)`; this
document records the design. It follows FreeBSD, whose `devfs` it is modelled on; NetBSD and
OpenBSD create static nodes with `MAKEDEV`.

## 1. Scope

The kernel's registry of devices, the file system that presents them at `/dev`, and how `/dev`
is customized at boot.

**Rationale.** Static nodes on a persistent disk can be lost for good (`rm /dev/fb0` survived
every reboot, issue #1), and they split device handling between oxfs and the kernel. A registry
the kernel owns, presented afresh at every boot, keeps `/dev` matching the devices present.

## 2. Components

| Part | Role | Source |
|---|---|---|
| Device registry | Every device: name, number, owner, group, mode, open function | kernel, `sys/fs/devfs.rs` |
| `oxidebsd_make_dev` | How a driver or module registers a device | kernel export |
| devfs | The file system mounted on `/dev`, built from the registry | `sys/modules/devfs` |
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
registered. No file system intercepts device names; the kernel registers `null`, `zero`,
`random`, `urandom` (`sys/drivers/null.rs`) and `fb0` (`sys/drivers/fbdev.rs`) at boot like any
other driver.

3.5. Device numbers are kept as they are (Linux's where one exists): `null` (1, 3), `zero`
(1, 5), `random` (1, 8), `urandom` (1, 9), `ttyv<n>` (4, n), `tty` (5, 0), `console` (5, 1),
`klog` (7, 0), `devctl` (7, 1), `fb0` (29, 0); the disks (`INSTALLER.md` §5), one major per driver and minor
`unit << 8` for a whole disk, `unit << 8 | N` for its partition N: `ide<u>` (3, u << 8) and
`ide<u>p<N>`/`ide<u>s<N>` (3, u << 8 | N), `scsi<u>` (8, u << 8), `virt<u>` (252, u << 8) and
their partitions likewise, `sata<C>.<P>[.<M>]` (251, u << 8) with u its place, `C << 9 | P << 4 |
M` (`M` 15 for a drive on the port itself), `gpt/<label>` (253, in the order found), `gptid/<guid>`
(254, in the order found). Numbers are in musl's `makedev` encoding (`st_rdev`),
whose minor has 20 bits.

## 4. devfs

4.1. The kernel mounts devfs on `/dev` when the devfs module registers, after the root, before
any process runs, so it is present from the first `open(2)`. devfs is held in memory (its own
nodes on the kernel heap) and is created afresh at every boot: nothing in it is written to disk.
The `/dev` directory on the disk is only its mountpoint; whatever an older installation left
there is hidden. devfs MAY be mounted elsewhere too (`mount -t devfs devfs /jail/dev`); each
mount is a view of its own, and what §4.4 says holds per view, until it is unmounted.

4.2. devfs holds a node for every registered device, with the entry's owner, group and mode,
and an empty directory `shm` (mode `01777`), the mount point of the tmpfs where musl's
`shm_open(3)` and `sem_open(3)` keep POSIX shared memory and semaphores (the default
`/etc/fstab` mounts it; `tmpfs(5)`), as FreeBSD's devfs has `fd` for fdescfs.

4.3. When a lookup or a listing reaches a view and the registry's generation has changed, devfs
adds nodes for new entries and removes nodes of removed ones first.

4.4. **Changes last until reboot.** As in FreeBSD:
1. `unlink(2)` of a device node hides it; §4.3 does not bring it back. A reboot does.
2. `chmod(2)` and `chown(2)` of a node last until reboot (§5 makes such changes permanent).
3. `mknod(2)` of a device or a FIFO in devfs fails with `EPERM`: devices come from drivers.
4. Directories, symbolic links and sockets (`/dev/log`, bound by `syslogd`, as on OpenBSD) can be
   made and removed, and last until reboot; ordinary files (`EOPNOTSUPP`), hard links and renames
   can't, as on FreeBSD (decided 2026-10-17, `VFS.md` §13).
5. A view remembers every node removed from it.

4.5. `mknod(2)` elsewhere (oxfs, tmpfs) still creates device nodes, which open through the
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
hidden across a lookup; `chmod` and `chown` last; `mknod` in `/dev` fails with `EPERM`; an
ordinary file, a hard link and a rename are refused; a symbolic link and a directory can be
made; `/dev/shm` is a tmpfs and a file can be made in it; a second view has the registry's nodes,
a node removed from `/dev` included, and removing one there leaves `/dev`'s; a node made by
`mknod` on disk opens through the registry; `rc.d/devfs` applies a test `devfs.conf`.

6.2. By hand, on a persistent disk (a test boots once): `rm /dev/fb0`, reboot, `/dev/fb0` is
back.

## 7. Open questions

None. FreeBSD's rulesets (`devfs(8)`, `devfs.rules(5)`: per-view hide and unhide) come later,
with jails (CLEANUP.md).
