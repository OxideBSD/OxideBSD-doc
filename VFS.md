# OxideBSD virtual file system: design specification

Status: **draft, under review** (2026-10-15). Not implemented. Target release: v0.3.0 for steps 1-3
of §11 (they unblock the kernel's msdosfs and `RAM_FLOOR.md` §4.7-4.8); the rest may slip to
v0.4.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Scope and motivation

OxideBSD has no VFS: the oxfs module is one. It does path lookup, holds the mount table (eight
entries), implements tmpfs and devfs as second pools of its own inodes, answers `/proc` by matching
the literal path prefix, keeps flock tables, and registers the descriptor-generic system calls
(`close`, `lseek`, `fstat`, `getdents`, `fsync`, `ftruncate`). The kernel knows a file only as a
bare `u64` oxfs inode number: in a process's cwd and root (with a tag bit for `/proc`
directories), as the page cache's key, in `MAP_SHARED` bookkeeping, FIFOs and `AF_UNIX` names. The
page cache reads the disk directly, with block numbers relative to the one root partition. A
second file system has nowhere to plug in.

Three things need one: the kernel's FAT file system (decided 2026-10-15: generic, read-write,
FreeBSD `mount_msdosfs` semantics), `oxupdate` (`RAM_FLOOR.md` §4.7-4.8), and piece C's switch
from the mfsroot to the disk root.

This document specifies a BSD vnode VFS, in FreeBSD's and NetBSD's shape and vocabulary, with file
systems as loadable kernel modules, and the staged migration of today's code onto it. It does
not change the system call ABI.

Decided with the user (2026-10-15):

- **BSD vnodes**: `struct mount` with per-type `vfsops`, vnodes with an operations vector, a kernel
  `namei`, a name cache.
- **File systems are modules**, as oxfs is today, not code in the kernel proper.
- **Staged migration**, the full suite green at every step (§11).
- msdosfs follows FreeBSD's `mount_msdosfs` (§9).

## 2. Terms

- **Vnode**: the kernel's in-memory object for one file of one mounted file system, reference
  counted. Everything in the kernel that names a file holds a vnode reference, never a file
  system's internal number.
- **File system type** (`vfsconf`): what a module registers: a name (`oxfs`, `msdosfs`,
  `tmpfs`, ...) and its `vfsops`.
- **Mount**: one instance of a type, attached at a vnode of another mount (or as root).
- **File ID**: a file system's own number for a file (oxfs's inode number, msdosfs's directory
  entry position). Unique within a mount.
- **Descriptor** (`struct file`): what an open file descriptor points at: a type, `fileops`, an
  offset, flags. Vnode files, pipes, sockets, ttys and kqueue-like objects are kinds of it.

## 3. Module constraints and what follows from them

3.1. Kernel modules have no heap and no `core::fmt`; their state is `static mut` or pools taken
from `oxidebsd_module_alloc_zeroed` in `module_init`. This stays true (decided). The VFS is
therefore shaped so that **the kernel allocates and a file system fills**:

- A type declares, at registration, the size of its per-mount private data (`mnt_data`) and of
  its per-vnode private data (`v_data`). The kernel allocates both, zeroed, alongside the
  `struct mount` and the vnode, and frees them after `vfs_unmount` / `vop_reclaim`.
- Names, paths and directory records cross the boundary in kernel-owned buffers (`struct
  componentname`, `uio`), never as allocations a module makes.
- A file system that needs a variable-size table (a FAT, an inode table) gets it per mount from a
  new kernel export, `oxidebsd_mount_alloc(mp, bytes)`, freed with the mount. This is allocation
  owned by the kernel and scoped to a mount, not a module heap. **Open question 1** (§12).

3.2. The interface is C ABI throughout (`extern "C"`, `#[repr(C)]`), as the module boundary is
today. A type registers with `oxidebsd_vfs_register(&VfsConf)`; the vnode operations are a
`#[repr(C)]` table of function pointers (§5.2), one per type, with a kernel default for every
operation a type leaves null.

3.3. Modules still never call each other. nullfs, which must call the file system below it,
does so through vnode operations dispatched by the kernel (`VOP_*` on the lower vnode), as
FreeBSD's nullfs does.

## 4. Mounts

4.1. `struct mount` (kernel-owned): the type, the vnode it covers (`mnt_vnodecovered`, null for
the root), its root vnode, flags (`MNT_RDONLY`, `MNT_NOSUID`, `MNT_NOEXEC`, `MNT_WXALLOWED`, ...),
`statfs` data, an `f_fsid`, the private data pointer, and a list of its vnodes. Mounts form a
list in mount order; the number of mounts is limited only by memory.

4.2. `vfsops`: `mount(mp, opts)`, `unmount(mp, flags)`, `root(mp) -> vnode`, `statfs(mp)`,
`sync(mp, waitfor)`, `vget(mp, fileid) -> vnode`, `fhtovp` later (no NFS). `mount` receives the
`nmount(2)` option list as today's `oxfs_nmount` parses it (`fstype`, `fspath`, `from`, flags),
parsed once by the kernel; type-specific options are passed through.

4.3. `nmount(2)` and `unmount(2)` move into the kernel (still registered by a module, a small
`vfs` syscall module, per the rule that new syscalls go in modules). Mounting covers a vnode:
`namei` crossing into a covered directory continues at the mount's root, and `..` at a mount's root
continues at `..` of the covered vnode (FreeBSD's `VV_ROOT` handling). This fixes today's bind-mount
`..` (it reaches the bind source's parent) and makes `getcwd` correct inside mounts (§10).

4.4. Unmount fails with `EBUSY` while a vnode of the mount is referenced (by a descriptor, a cwd
or root, a mapping, a mount on top of it), unless `MNT_FORCE`, which revokes descriptors (`VOP_REVOKE`
to a dead vnode, `deadfs`).

4.5. Per-mount read-only: `MNT_RDONLY` on any mount, and `MNT_UPDATE` to change it, replace the
root-only `ROOT_RDONLY` flag. `EROFS` is decided by the VFS for every modifying operation before
the file system is called.

## 5. Vnodes

5.1. A vnode holds: its mount, its type (`VREG`, `VDIR`, `VLNK`, `VCHR`, `VFIFO`, `VSOCK`), a use
count and a hold count, flags (`VV_ROOT`, ...), the file ID, `v_data`, a pointer to its page
cache object (§7), and, for `VCHR`, the device (§8) and, for `VFIFO`/`VSOCK`, the pipe or socket
it rendezvouses with. The kernel keeps a hash `(mount, file ID) -> vnode` so one file has one
vnode.

5.2. Vnode operations (the subset this system needs, FreeBSD's names): `lookup`, `create`,
`mknod`, `open`, `close`, `access`, `getattr`, `setattr`, `read`, `write`, `ioctl`, `poll`,
`fsync`, `remove`, `link`, `rename`, `mkdir`, `rmdir`, `symlink`, `readdir`, `readlink`,
`inactive`, `reclaim`, `bmap`, `strategy` (later), `pathconf`, `advlock`, `getpages` (later).

5.3. Life cycle: a vnode with use count 0 is inactive (`vop_inactive` lets the file system free
an unlinked file's storage: this replaces `oxidebsd_inode_in_use` and oxfs's orphan sweep); an
inactive vnode may be recycled (`vop_reclaim`, then the memory reused). The number of vnodes is
bounded by `kern.maxvnodes`, sized from RAM, so the 64 MB floor holds.

5.4. **Open question 2**: locking. Today one giant sleepable lock (`fslock`) serializes the one
file system module, keyed to that module's code range. The VFS keeps a giant lock in step 1 (one
for all file system modules, not keyed to a code range) and moves to per-vnode locks with SMP
(v0.5.0). Whether to introduce vnode locks now, as no-ops on one CPU, so file systems are
written against them from the start, is the question.

## 6. Lookup (`namei`) and descriptors

6.1. `namei` is the kernel's (`sys/kern/vfs_lookup.rs`): component by component through
`vop_lookup`, symbolic links followed up to `MAXSYMLINKS` (32, as FreeBSD) with targets up to
`PATH_MAX`, mount crossings and `..` per §4.3, the process's root vnode as the chroot boundary.
`*at()` resolves relative to the directory descriptor's vnode, passed explicitly (today's global
`AT_BASE_OVERRIDE` goes away).

6.2. A name cache (`(directory vnode, name) -> vnode`, plus negative entries) sized from RAM,
purged by `remove`, `rename` and `rmdir`, and per mount at unmount.

6.3. A process's cwd and root become vnode references in `ThreadGroupShared`. The synthetic
`/proc` cwd encoding (bit 63) goes away: `/proc` is a mount (§8.3).

6.4. `struct file` replaces today's `Description`: type (`DTYPE_VNODE`, `DTYPE_PIPE`,
`DTYPE_FIFO`, `DTYPE_SOCKET`, `DTYPE_PTS`, ...), `fileops` (`read`, `write`, `ioctl`, `poll`,
`stat`, `close`, `truncate`, `seek`), the offset, open flags (`O_APPEND`, `O_NONBLOCK`, access
mode), and the object (a vnode, pipe, socket). `close`, `lseek`, `fstat`, `ioctl`, `ftruncate`,
`fsync` and `getdents` become kernel calls through `fileops`/vnode operations for every
descriptor type; `lseek` on a pipe or socket gives `ESPIPE` (POSIX; today `EBADF`). The
hard-coded `ioctl` chain becomes the descriptor's `ioctl` operation.

6.5. The fd table itself (`(tgid, fd) -> struct file`, lowest free number, `FD_CLOEXEC`, fork
inheritance, `SCM_RIGHTS`) stays as `sys/fs/fd.rs` has it, now holding `struct file`
references; the kernel may hold a `struct file` with no fd (exec's open, a mount's device).

## 7. Page cache and demand paging

7.1. The page cache is keyed by vnode (a per-vnode object, FreeBSD's `vm_object` in miniature),
not by oxfs inode number, so two file systems never collide.

7.2. Demand paging (`DEMANDPAGE.md`) keeps filling pages without going through the file system's
read path: the file system's `vop_bmap` maps a file block to a **device** block, and the fill
reads that device through §8.2's block interface. Today's `CONTENT_BLOCK_MAP` callback and the
direct `oxidebsd_block_read` on the root partition (`pagecache.rs`) go away. A file system with
no block device (tmpfs, procfs) fills through `vop_read`, as tmpfs does today.

7.3. `content_changed` becomes the VFS's own invalidation on `vop_write`, `vop_setattr` (size)
and reclaim; file systems no longer call it.

## 8. Devices and the special file systems

8.1. `/dev` (devfs), `/proc` (procfs), tmpfs and nullfs become file system types of their own,
each its own module, split out of oxfs (§11 step 2). devfs keeps building its tree from the
kernel's device registry (`DEVFS.md`); tmpfs instances each get their own pool and their own
`f_fsid`/`st_dev` (today all tmpfs mounts and devfs share device 2); `/dev/shm` stays a tmpfs.

8.2. **Block devices for file systems.** A mount names its device by path (`from=/dev/gpt/efi`).
The kernel opens it as a `struct file` (no fd) and gives the file system a handle with
`oxidebsd_bdev_read(handle, block, count, buf)` / `write` / `size` / `sector_size`, bounded to the
partition, in device blocks. Today's `oxidebsd_block_*`, hard-wired to the root partition, become
this. Two file systems on two partitions of one disk (the ESP and the root) are the case to test.

8.3. procfs answers `/proc` as a mount, so it obeys chroot and every spelling of the path
(today `/./proc` misses it, and a chroot doesn't hide it).

## 9. msdosfs

9.1. A module, `msdosfs`, over `lib/libmsdosfs` (the format crate `makefs -t msdos` already uses).
FAT12, FAT16 and FAT32, read and write, long names.

9.2. Semantics are FreeBSD's `mount_msdosfs(8)`: `-u uid`, `-g gid`, `-m mask`, `-M dirmask`
(owner, group and permission of every file, since FAT keeps none); the read-only attribute clears
the write bits; lookup is case-insensitive and creation case-preserving; `-s` shows short names
only, `-l` long names (the default); a name not representable is `EINVAL`. FAT times carry no
zone: FreeBSD converts them with the kernel's UTC offset, so they read as local time (what
Windows writes); OxideBSD's choice is **open question 3**.

9.3. File IDs are the position of the file's directory entry (cluster and offset), as FreeBSD's;
a rename moves the entry, so the vnode's file ID is updated in place under the VFS's hash.

9.4. `fsck_msdosfs` and `newfs_msdos` are not in this document.

## 10. Bugs this fixes, found while surveying (unverified unless noted)

Found by reading the code on 2026-10-15, not yet reproduced; each gets a regression test before
its step lands, or is struck from this list:

- A nullfs bind's `..` reaches the source directory's parent, not the mountpoint's.
- `getcwd` inside a tmpfs or bind mount stops at the mount and returns a truncated path; paths
  are capped at 32 levels and 256 bytes.
- `/proc` is matched by literal prefix: inside a chroot it is still reachable, and `/./proc` or a
  symbolic link to it misses it.
- Symbolic link targets are cut at 256 bytes.
- `lseek` on a pipe gives `EBADF`; POSIX wants `ESPIPE`.
- An open FIFO's inode isn't counted by `oxidebsd_inode_in_use`, so unlinking an open FIFO may let
  its inode number be reused while the pipe is keyed to it.

## 11. Migration

Each step is its own commits; the suite and the POSIX canary stay at their baseline between
steps.

1. **VFS core with oxfs behind it.** `struct mount`, vnodes, `namei`, the name cache,
   `struct file` and `fileops`, the kernel's `close`/`lseek`/`fstat`/`getdents`/`nmount`, the
   block device interface; oxfs reimplemented as the `oxfs` type (its namei, mount table and fd
   syscalls removed), still holding tmpfs, devfs and `/proc` inside it as today, mounted through
   the VFS. Vnode-keyed page cache (§7). The big step.
2. **Split out** tmpfs, devfs, procfs and nullfs as their own types and modules.
3. **msdosfs** (§9); `/boot/efi` in `fstab` on systems with an ESP.
4. **The root switch** (`reboot -r`), for piece C's mfsroot and `oxupdate`.
5. **Per-vnode locks** with SMP (v0.5.0).

## 12. Open questions

1. Per-mount kernel allocation for file system modules (§3.1): `oxidebsd_mount_alloc`, or modules
   get a real allocator (the option set aside on 2026-10-15)?
2. Vnode locks now (no-ops on one CPU) or with SMP (§5.4)?
3. msdosfs times: local time like FreeBSD and Windows, or UTC (§9.2)?
4. Does oxfs keep its own buffer cache (`bcache.rs`), or does the VFS get a shared buffer cache
   (FreeBSD's `buf`) that msdosfs uses too? A shared one is more work now and less duplication.
5. Is step 1 small enough? It could be split (vnodes and namei first with `struct file` as is,
   then `struct file`), at the price of an interim adapter layer.

## 13. Decisions

2026-10-15 (user): BSD vnodes; file systems as modules (over file systems in the kernel proper,
and over giving modules an allocator first); staged migration, suite green at each step; msdosfs
generic and read-write with `mount_msdosfs` semantics; this specification to be reviewed before any
code.
