# OxideBSD virtual file system: design specification

Status: **accepted** (2026-10-15; the user's answers to the open questions are in §13). Step 0
of §11 implemented; steps 1-6 not yet. Target release: v0.3.0 for steps 0-4 of §11 (they unblock the kernel's msdosfs and
`RAM_FLOOR.md` §4.7-4.8); the rest may slip to v0.4.0.

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

3.1. **Modules get a real allocator** (decided 2026-10-15; implemented, §11 step 0). Before it
a module had no heap and no `core::fmt`; its state was `static mut` or pools taken from
`oxidebsd_module_alloc_zeroed` in `module_init`. Two kernel exports,
`oxidebsd_kmalloc(size, align, id) -> *mut u8` and `oxidebsd_kfree(ptr, size, align, id)`, allocate
from the kernel heap at any time a module runs (not only in `module_init`), and a small shared
crate, `lib/libkern-mod` (crate `kern_mod`), gives a module that depends on it a
`#[global_allocator]` over them, so module code uses `alloc` (`Box`, `Vec`, `BTreeMap`) as kernel
code does. Allocation failure returns null; through an infallible API that reaches
`__rust_alloc_error_handler`, which the loader points at a kernel function that is fatal to the
call, as any module panic is. Code that can fail cleanly uses `try_reserve` and returns `ENOMEM`.

Every allocation a module makes is charged to it: `libkern-mod` defines a `kern_mod_id` static, and
the loader writes the module's charge id into it after relocation and before `module_init`, so a
module cannot forget to identify itself (decided 2026-10-15, over FreeBSD-style malloc types and
over an explicit init call). The charge shows as `kern.module.<name>.alloc` (bytes) and
`kern.module.<name>.allocs` (allocations), so a leak is visible.

rustc generates its allocator shim only at a final link, which a module never has; the loader
resolves the two symbols that leaves undefined (`__rust_alloc_error_handler`,
`__rust_no_alloc_shim_is_unstable_v2`) by suffix, since their mangled names carry a toolchain hash.
No new relocation types were needed: `Box<dyn Trait>` vtables are `R_X86_64_64` in writable data.

`core::fmt` is allowed in modules (decided 2026-10-15): a heavy `format!` (integers, hex, padding,
`Debug` of a tuple) measured about 17 KB after `--gc-sections`, with only relocation types the
loader already applies.

Still, the VFS keeps the kernel's own objects kernel-allocated: a type declares the size of its
per-mount private data (`mnt_data`) and per-vnode private data (`v_data`); the kernel allocates
both, zeroed, with the `struct mount` and the vnode, and frees them after `vfs_unmount` /
`vop_reclaim`. Names, paths and directory records cross the boundary in kernel-owned buffers
(`struct componentname`, `uio`).

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

5.4. Locking (decided 2026-10-15): one giant sleepable lock for the VFS and every file system
module until SMP, replacing today's `fslock`, which is keyed to the single serialized module's code
range (a second file system module would break it). Per-vnode locks come with SMP (v0.5.0, §11
step 6); file systems are not written against vnode locks before then.

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

7.4. **A shared buffer cache** (decided 2026-10-15): the kernel gets FreeBSD's `buf` layer in
miniature (`sys/kern/vfs_bio.rs`): `bread(dev, blkno, size)`, `bwrite`, `bdwrite` (delayed),
`bawrite`, `brelse`, per-device, sized from RAM, with the delayed-write ordering and the clean
flag that oxfs's `bcache.rs` does today (`RAM_FLOOR.md` §3.2-3.3). oxfs drops `bcache.rs` and uses
it; msdosfs uses it from the start. `update(8)`'s 30-second flush becomes `sync(2)` through it.
Data blocks a file has mapped are in the page cache, metadata in the buffer cache; a block is
never in both writable at once (FreeBSD's rule before its unified cache).

## 8. Devices and the special file systems

8.1. `/dev` (devfs), `/proc` (procfs), tmpfs and nullfs become file system types of their own,
each its own module, split out of oxfs (§11 step 3). devfs keeps building its tree from the
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
zone: they are local time (decided 2026-10-15), as FreeBSD and Windows have them, converted with
the system's time zone (`/etc/localtime`, `TIMEZONE.md`), which the kernel learns from userland at
boot (FreeBSD's `adjkerntz(8)`/`machdep.adjkerntz` in shape; the mechanism is part of step 4).

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

0. **A module allocator** (§3.1): `oxidebsd_kmalloc`/`kfree`, `lib/libkern-mod`, then oxfs's fixed
   pools (`OPEN_FILES`, `PROC_RENDERS`) moved to the heap as the first user. **Done**: `8404fe5`
   (allocator, `tests/kmod_alloc_syscall_smoke`), `718bdaf` (oxfs: its resident data and bss
   went from 986,655 to 134,483 bytes; `/proc` files are no longer cut at 1 KiB), and `8b280ec`
   (`RLIMIT_NOFILE` enforced and `kern.maxfiles` sized from RAM, which oxfs's fixed table had
   stood in for).
1. **Descriptors and block devices.** `struct file` and `fileops` (§6.4-6.5); the kernel's
   `close`/`lseek`/`fstat`/`ioctl`/`ftruncate`/`fsync`; the block device interface (§8.2) and the
   shared buffer cache (§7.4), oxfs moved onto it and `bcache.rs` deleted. Files are still named
   by oxfs inode numbers.
2. **Vnodes and `namei`.** `struct mount`, `vfsops`, vnodes, the kernel's `namei` and name cache,
   `nmount`/`unmount`, `getdents` through `vop_readdir`, the one giant lock (§5.4); oxfs
   reimplemented as the `oxfs` type, still holding tmpfs, devfs and `/proc` inside it; cwd, root,
   the page cache (§7) and every other kernel holder of an inode number moved to vnodes;
   `oxidebsd_inode_in_use` deleted. The biggest step.
3. **Split out** tmpfs, devfs, procfs and nullfs as their own types and modules.
4. **msdosfs** (§9), the kernel's time zone offset; `/boot/efi` in `fstab` on systems with an ESP.
5. **The root switch** (`reboot -r`), for piece C's mfsroot and `oxupdate`.
6. **Per-vnode locks** with SMP (v0.5.0).

Steps 1 and 2 are the old single "VFS core" step split in two (Claude's call, 2026-10-15, open
to veto): descriptors and the buffer cache don't depend on vnodes, and landing them first keeps
each step reviewable and bisectable.

## 12. Open questions

None left from the review. New ones go here as steps uncover them.

## 13. Decisions

2026-10-15 (user): BSD vnodes; file systems as modules (over file systems in the kernel proper,
and over giving modules an allocator first); staged migration, suite green at each step; msdosfs
generic and read-write with `mount_msdosfs` semantics; this specification to be reviewed before any
code.

2026-10-15 (user, on review): modules get a real allocator (not per-mount kernel allocation
only); vnode locks with SMP, not before; msdosfs times are local time; oxfs drops its own buffer
cache for a shared one.

2026-10-15 (user, step 0): module allocations are charged per module through a loader-stamped id;
`core::fmt` is allowed in modules; the support crate is `lib/libkern-mod` (not `libkmod`, which on
Linux names the userland module library).
