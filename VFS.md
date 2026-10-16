# OxideBSD virtual file system: design specification

Status: **accepted** (2026-10-15; the user's answers to the open questions are in §13). Steps 0
and 1 of §11 implemented, step 2 in progress (2a done); 3-6 not yet. Target release: v0.3.0 for steps 0-4 of §11 (they unblock the kernel's msdosfs and
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
to a dead vnode, `deadfs`: its reads give end of file, everything else `EBADF`/`EIO` as FreeBSD's
`dead_vnodeops`). Forced unmount and deadfs land in step 2 (decided 2026-10-16), and with them
`revoke(2)` (all three BSDs have it; `getty`/`login` use it to take a terminal from an old
session): it revokes every descriptor opened through the named vnode, and for a device every
descriptor of that device. A descriptor remembers the vnode it was opened through (`f_vnode`), even
when its operations are a device's or a FIFO's.

4.6. `getfsstat(2)` (FreeBSD's shape, an OxideBSD number; decided 2026-10-16) lists the mounts
as `struct statfs` records; `mount(8)` and `df(1)` use it, and procfs renders `/proc/mounts` from
the same kernel list.

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
`inactive`, `reclaim`, `bmap`, `strategy` (later), `pathconf`, `advlock`, `revoke`, `getpages`
(later).

The vector is a positional `#[repr(C)]` table, one `extern "C"` function per operation taking
plain arguments (`lookup(dvp, cnp, vpp)`, `read(vp, uio, ioflag)`), not FreeBSD's one-struct
`vop_xxx_args` with an `a_desc` header (decided 2026-10-16): simpler from Rust, at the cost of
nullfs writing a forwarder per operation instead of one `vop_bypass`.

`getattr` fills, and `setattr` takes, a kernel-defined `struct vattr` in FreeBSD's shape (type,
mode, nlink, uid, gid, fsid, fileid, size, blocksize, times, rdev, bytes, flags; `VNOVAL` for a
field `setattr` leaves alone); the kernel makes `stat(2)`'s record from it, so no file system
knows the userland ABI's layout (decided 2026-10-16).

Permission checks are the file system's `access`, which normally calls the kernel's
`vaccess(type, mode, uid, gid, want, cred)` with the file's attributes (msdosfs with its mount's
`-u`/`-g`/`-m`, procfs with its own), FreeBSD's split (decided 2026-10-16). `namei` asks for
`VEXEC` on every directory it searches; the VFS asks before every operation that needs a
permission, as FreeBSD's system call layer does.

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

6.4. `struct file` replaces the old `Description` (done, §11 step 1a): one static `#[repr(C)]`
`FileOps` table per kind of file (`read`, `write`, `close`, `ioctl`, `poll`, `stat`,
`truncate`, `sync`, and `content_id`/`fb_geometry` for `mmap`; a null entry takes the kernel's
default), the object (`data`), `f_flag` (`FREAD`, `FWRITE`, `O_APPEND`, `O_NONBLOCK`, made from
`open(2)`'s flags as FreeBSD's `FFLAGS` does), and the offset. There is no `seek` operation: a
table marked `DFLAG_SEEKABLE` has the kernel keep the offset, passing it in the uio
(`FOF_NEXTOFF`, or `FOF_OFFSET` for `pread`/`pwrite`) and storing it back. The kernel checks the
access mode before `read`/`write` (`EBADF`). `close`, `lseek`, `fstat`, `ioctl`, `ftruncate`,
`fsync` and `fdatasync` are kernel calls through the table for every descriptor type (the `vfs`
module registers them); `lseek` on a pipe or socket gives `ESPIPE`, `ftruncate`/`fsync` on one
`EINVAL`, as POSIX has them. The hard-coded `ioctl` and `poll` chains became each type's
operations. Still to come: `getdents` moves with `vop_readdir` (step 2), and `fstat` of a file
whose table has no `stat` (FIFOs, terminals, devices) is answered by oxfs's registered fallback
until devfs is split out (step 3). The `DTYPE_*` type isn't a field yet: the old `FdKind` tag
serves `/proc/<pid>/fd` links until vnodes name files.

6.5. The fd table itself (`(tgid, fd) -> struct file`, lowest free number, `FD_CLOEXEC`, fork
inheritance, `SCM_RIGHTS`) stays as `sys/fs/fd.rs` has it, now holding `struct file`
references; the kernel may hold a `struct file` with no fd (exec's open, a mount's device):
`fd::kernel_open` runs a file system's open so that the file it makes is held, not installed
(done for exec, §11 step 1a).

## 7. Page cache and demand paging

7.1. The page cache is keyed by vnode (a per-vnode object, FreeBSD's `vm_object` in miniature),
not by oxfs inode number, so two file systems never collide.

7.2. Demand paging (`DEMANDPAGE.md`) keeps filling pages without going through the file system's
read path: the file system's `vop_bmap` maps a file block to a **device** block, and the fill
reads that device through §8.2's block interface (since step 1b the fill reads the root's
`vfs_bdev` handle; the `CONTENT_BLOCK_MAP` callback goes with step 2). A file system with
no block device (tmpfs, procfs) fills through `vop_read`, as tmpfs does today.

7.3. `content_changed` becomes the VFS's own invalidation on `vop_write`, `vop_setattr` (size)
and reclaim; file systems no longer call it.

7.4. **A shared buffer cache** (decided 2026-10-15, done in step 1b): FreeBSD's `buf` layer in
miniature (`sys/kern/vfs_bio.rs`): `bread(dev, blkno, size, ahead)`, `getblk`, `bwrite`,
`bdwrite` (delayed), `brelse`, `bflush`, `bdiscard`, `binval`, `binvalall`, for every block
device. A buffer is `(device, block in sectors, size)`, the size a whole number of sectors up to
`MAXBSIZE` (64 KiB); a file system never reads overlapping buffers of different sizes. Each
buffer owns a 64 KiB slot of a kernel window (level-4 slot 387) with only the pages its size
needs mapped, within a budget of `RAM / 8` (2-512 MiB). The write ordering is the file
system's, through a pre-write hook it sets for its device (FreeBSD's `bioops` shape): the cache
calls it before any dirty buffer goes to the disk, and it writes what that buffer depends on
first; its answer says whether the buffer may share a disk command with its neighbours. oxfs's
`bcache.rs` is gone: its block kinds are tags and its ordering rules its hook (`src/buf.rs`); the
clean flag stays oxfs's. msdosfs uses it from the start. `update(8)`'s 30-second flush becomes `sync(2)` through it.
Data blocks a file has mapped are in the page cache, metadata in the buffer cache; a block is
never in both writable at once (FreeBSD's rule before its unified cache).

## 8. Devices and the special file systems

8.1. `/dev` (devfs), `/proc` (procfs), tmpfs and nullfs become file system types of their own,
each its own module, split out of oxfs (§11 step 3). devfs keeps building its tree from the
kernel's device registry (`DEVFS.md`); tmpfs instances each get their own pool and their own
`f_fsid`/`st_dev` (today all tmpfs mounts and devfs share device 2); `/dev/shm` stays a tmpfs.

8.2. **Block devices for file systems** (done in step 1b, `sys/kern/vfs_bdev.rs`). Every disk,
partition, GPT label and the memory disk is a handle bounded to its extent, read and written in
512-byte sectors (`oxidebsd_bdev_read(handle, sector, count, buf)`, `_write`, `_sectors`); the
drivers take sectors. The root's handle is chosen at boot (`/boot/fsconf`); from step 2 a mount
names its device by path (`from=/dev/gpt/efi`), which the kernel resolves to its handle. Raw
`/dev` nodes are uncached, as FreeBSD's, and a raw write to a device overlapping one a file
system has mounted read-write is refused. Two file systems on two partitions of one disk (the
ESP and the root) are the case to test, with msdosfs (step 4).

8.3. procfs answers `/proc` as a mount, its own module from step 2 (decided 2026-10-16:
the synthetic `/proc` cwd goes with step 2, and procfs uses only the kernel's process accessors,
never oxfs's storage, so it moves once instead of twice), so it obeys chroot and every spelling of the path
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
   by oxfs inode numbers. Split in two (decided 2026-10-15): **1a, descriptors, done**: `0ee960f`
   (`FileOps`, kernel-kept flags and offset, the kernel's own descriptor types moved),
   `7a0f930` (oxfs moved, the per-descriptor callbacks deleted), `d134d8a` (the `vfs` module and
   the kernel's descriptor calls, `ioctl`/`poll` through the table; found: `ftruncate` through a
   read-only descriptor truncated the file), `af2d000` (exec reads a kernel-held file, so a
   process at its `RLIMIT_NOFILE` can exec). **1b, block devices and the buffer cache, done**:
   `22ec7bb` (`vfs_bdev`, sector-granular drivers), `ebb8540` (`vfs_bio`, oxfs on it,
   `bcache.rs` and `oxidebsd_block_*` deleted; found: the boot frame allocator couldn't free a
   frame before every module had loaded).
2. **Vnodes and `namei`.** `struct mount`, `vfsops`, vnodes, the kernel's `namei` and name cache,
   `nmount`/`unmount`, `getdents` through `vop_readdir`, the one giant lock (§5.4); oxfs
   reimplemented as the `oxfs` type, still holding tmpfs and devfs inside it; procfs its own
   module; cwd, root, the page cache (§7) and every other kernel holder of an inode number moved
   to vnodes; `oxidebsd_inode_in_use` deleted; forced unmount, deadfs, `revoke(2)` and
   `getfsstat(2)`. The biggest step, landed in four parts (decided 2026-10-16), the suite green
   after each: **2a** mounts and vnodes, oxfs registered as a type and the root mounted through
   it, the VFS's giant lock (**done**: `386e2fe`; the interface types are a crate the kernel and
   the modules share, `lib/libvfs`; `sync(2)` and the unmount at reboot go through the mounts); **2b** the kernel's `namei` and name cache and every path system call
   in the kernel through `vop_*`, the procfs module, oxfs's `resolve_path_impl` and
   `AT_BASE_OVERRIDE` deleted; **2c** every holder of an inode number moved to vnode references,
   `oxidebsd_inode_in_use` and the orphan sweep deleted; **2d** `getfsstat`, `MNT_FORCE`, deadfs
   and `revoke(2)`. Plain `nmount`/`unmount` and the mount table, and cwd and root as vnodes, go
   with 2b instead: the kernel's `namei` crosses mounts and starts from the cwd (found while
   planning 2b).
3. **Split out** tmpfs, devfs and nullfs as their own types and modules.
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

2026-10-16 (user, step 2): vnode operations are a positional table, not args structs; procfs
becomes its own module in step 2; permission checks are FreeBSD's (`vop_access` calling the
kernel's `vaccess`); forced unmount, deadfs and `revoke(2)` in step 2; `getfsstat(2)` plus
`/proc/mounts`; `getattr` fills a FreeBSD-style `struct vattr`; step 2 lands as 2a-2d.

2026-10-16 (user, step 1b): the buffer cache keeps a file system's crash ordering through a
pre-write dependency hook per device (FreeBSD's `bioops`/soft-updates shape), over ordered write
classes or synchronous metadata.

2026-10-15 (user, step 1): step 1 lands as 1a (descriptors) then 1b (block devices and the
buffer cache), the suite and the canary green between; a module describes a kind of file with a
static `FileOps` table (FreeBSD's `fileops`), not per-descriptor callbacks; the descriptor calls
are registered by a new module named `vfs`; the buffer cache has variable-size buffers
(FreeBSD's `bread(dev, blkno, size)`; a file system never reads overlapping buffers of different
sizes).

2026-10-15 (user, step 0): module allocations are charged per module through a loader-stamped id;
`core::fmt` is allowed in modules; the support crate is `lib/libkern-mod` (not `libkmod`, which on
Linux names the userland module library).
