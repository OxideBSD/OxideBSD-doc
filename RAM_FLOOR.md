# OxideBSD 128 MB RAM floor: design specification

Status: **draft** (2026-10-12), under review. Target release: v0.3.0 (`ROADMAP.md`, item 6).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Scope and motivation

A console install (base `/bin`, `/sbin`, `/usr/bin`, networking and OpenSSL, man pages, nano and
vi, doom) MUST boot to a login prompt and stay usable in 128 MB of RAM (decided 2026-10-06).
Clang/LLVM is an optional set and is not expected to be usable at 128 MB.

Measured 2026-10-12 (`d92900b`), the floor is about 1.5 GiB:

| Consumer | Size | Where |
|---|---|---|
| Kernel image `.rodata` | 293 MiB | the oxfs module object, every seed file `include_bytes!`'d into it, is itself `include_bytes!`'d into the kernel (`sys/kernel_main.rs`) |
| Second copy of the module | ~290 MiB | `module::load` copies the module's sections into the module region |
| oxfs block pool | 1088 MiB | `init_pools`: `(NUM_BLOCKS + TMPFS_NUM_BLOCKS) * 4 KiB`, allocated at boot; `mount_from_disk` then reads every used block into it |
| oxfs write buffers | 256 MiB | `MAX_WRITE_BUFFERS * MAX_WRITE_BUFFER` (16 x 16 MiB), allocated at boot |
| oxfs open-file table | ~8 MiB | `OPEN_FILES`, 2048 slots of ~4 KiB (`DIR_LISTING_BUFFER` inside each) |
| Kernel heap | RAM / 8 | `allocator::compute_heap_size`; 16 MiB at 128 MB, acceptable |

Limine itself fails first at `-m 128` ("High memory allocator: Out of memory"): it can't load a
293 MiB kernel.

The work is three pieces, landed in this order:

- **A. The oxfs buffer cache** (§3): oxfs stops being a RAM disk backed by a disk and becomes a
  disk filesystem with a bounded cache. Largest RAM saving; independent of B and C.
- **B. The host image builder** (§4): the system image is built on the host by `makefs`-style
  tooling into dist sets, and the seed files leave the kernel.
- **C. mfsroot** (§5): a small root filesystem image Limine loads beside the kernel, for rescue,
  single-user and (later) installation.

An installer, which needs a driver for the boot medium, is a later milestone and out of scope.

## 2. Terms

- **Block**: an oxfs block, 4096 bytes. Disk block numbers are oxfs's; `DATA_BLOCK_OFFSET` maps
  them to device blocks as today.
- **Buffer**: one cache slot holding one block's contents plus its header (§3.2).
- **Metadata block**: a block of the inode file, the block-used bitmap, the superblock, a
  directory's data block, or an indirect block.
- **Data block**: a regular file's or symlink's data block.
- **Structural change**: a change to the namespace or to allocation: creating, linking, renaming
  or removing a name; allocating or freeing an inode; a link-count change; marking a block used
  or free.

## 3. Piece A: the oxfs buffer cache

### 3.1. Sizing and pools

3.1.1. The kernel MUST export `oxidebsd_physmem_bytes() -> u64` (usable RAM, as the heap sizing
already computes it) and `oxidebsd_block_device_blocks() -> u64` (the device's capacity in
512-byte sectors, 0 without a device).

3.1.2. The buffer cache is `clamp(RAM / 8, 2 MiB, 512 MiB)` of buffers, allocated once in
`module_init` with `oxidebsd_module_alloc_zeroed`: 16 MiB (4096 buffers) at 128 MB.

3.1.3. The filesystem size is no longer `NUM_BLOCKS`. `format` takes it from the partition's
size and records it in the superblock; mount reads it from there. Block numbers stay `u32`.
The block-used bitmap is **paged through the cache** like any other metadata block (FFS
cylinder-group style), so its RAM cost doesn't grow with the disk; a small resident array holds
each bitmap block's free count, so allocation skips full regions without reading them.

3.1.3.1. **No disk**: the kernel provides a memory-backed block device (an `md(4)` precursor,
`RAM / 4`), which oxfs formats and uses exactly as a disk, through the same cache. Piece C's
mfsroot reuses it.

3.1.4. tmpfs keeps a fixed in-memory pool, sized `clamp(RAM / 16, 8 MiB, 64 MiB)` at boot. Its
blocks never pass through the cache. tmpfs block numbers start at a fixed base above any disk
block number (`TMPFS_BLOCK_BASE`, like `TMPFS_INODE_BASE`) instead of at `NUM_BLOCKS`.

3.1.5. The per-descriptor write buffers (`WRITE_BUFFERS`, `OpenFile::Write`'s accumulation) are
removed: `write` stores through the cache into the inode's blocks directly (the `uio` write path
already works a block at a time). `close` no longer commits anything.

3.1.6. An `OPEN_FILES` slot MUST NOT embed a directory-listing buffer: a directory descriptor
reads its records incrementally by offset, as `getdents` callers already expect. The table keeps
2048 slots (`shm_open/23-1.c` needs over 1000), now a few bytes each. A per-process descriptor
table is a separate v0.3.0 item (`CLEANUP.md`, `RLIMIT_NOFILE`).

### 3.2. The cache

3.2.1. Each buffer has a header: block number, state (`INVALID`, `CLEAN`, `DIRTY`), whether it
is a metadata block, for a dirty data block its **owner** inode, and LRU links. A hash table by
block number finds a buffer; all of it lives in the module's preallocated storage (modules have
no `alloc`).

3.2.2. `read_block`/`write_block` keep their signatures and copy semantics. A miss reads the
block from the device into the least recently used `CLEAN` or `INVALID` buffer. `block_ref`
(4 call sites) is replaced by a scoped accessor, `with_block(n, |b| ...)`: oxfs is single-core
and syscall-serialized, and nothing inside the closure may touch another block, so no eviction
can happen under the borrow.

3.2.3. Mount MUST NOT read data blocks. It reads the superblock, the bitmap and nothing else;
everything else is read on first use.

3.2.4. A write to a block that will be overwritten whole (a freshly allocated block, a whole-block
`write`) MUST NOT read it from disk first.

3.2.5. Eviction prefers `CLEAN` buffers. When none are left, the least recently used `DIRTY`
buffer is written out under the ordering rules of §3.3, then reused. When dirty buffers exceed
half the cache, the writing system call flushes before returning (back-pressure), so a large
`write` degrades to write-through instead of failing.

3.2.6. Device I/O is synchronous inside the system call until §3.5 lands (interrupts are masked
for the whole call; `CLAUDE.md`).

### 3.3. Write policy: synchronous metadata, delayed data

The classic FFS default: a crash may lose recent file contents, never the filesystem's structure,
and never exposes another file's old data.

3.3.1. **Structural changes are written synchronously**, before the system call returns, in an
order that leaves the disk consistent at every step (a crash between two writes may leak a block
or an inode, which fsck reclaims, but never leaves a name pointing at garbage):

1. Mark a block or inode used in the bitmap/inode file **before** anything points at it.
2. Write a new inode **before** the directory record naming it.
3. Remove a directory record **before** decrementing the inode's link count, and clear an
   inode's pointers **before** marking its blocks free.
4. A rename writes the new name before removing the old one (a crash may leave both, which
   fsck resolves by the link count).

3.3.2. **Delayed**: a regular file's or symlink's data blocks, its indirect blocks, and its inode
record's size, times and block pointers. These buffers are marked `DIRTY` and written by a flush.

3.3.3. **Ordering of delayed writes**: a pointer MUST NOT reach the disk before the data it points
at. Before any inode-file block is written (synchronously or by a flush), the dirty data and
indirect blocks owned by the inodes in it are written first; before an indirect block is written,
its owner's dirty data blocks are. So after a crash, an inode on disk points only at blocks that
hold its own data: an older size, never another file's freed contents.

3.3.4. When a block is freed, a dirty buffer for it is discarded, not written.

3.3.5. **Flushes**:

- `fsync(fd)` writes the inode's dirty data, indirect blocks and inode record, in §3.3.3 order.
- `sync()` flushes every dirty buffer in §3.3.3 order and returns after it is on the device
  (POSIX lets `sync` return early; OxideBSD MUST NOT, since `update(8)` and shutdown rely on it).
- Reboot and poweroff: the kernel MUST call oxfs's flush hook (a new
  `oxidebsd_register_shutdown_hook`) before resetting, then oxfs marks the superblock clean.
  A panic does not flush.

3.3.6. **`update(8)`**: `/sbin/update`, started by an `/etc/rc.d` script, calls `sync()` every
30 seconds (4.3BSD's `update`; FreeBSD's syncer kproc does the same job in the kernel). Single
user mode doesn't start it: data reaches the disk at `sync`, eviction or shutdown.

### 3.4. Clean flag and fsck

3.4.1. The superblock gets a **clean flag**. Mount clears it on disk (synchronously) before the
first write; a complete shutdown flush sets it. A disk mounted with the flag clear was not
shut down cleanly.

3.4.2. `fsck_oxfs` checks and repairs an unclean filesystem: rebuilds the bitmap from the blocks
reachable from live inodes (leaked blocks freed), frees unreferenced inodes (what
`sweep_unnamed_inodes` does today), corrects link counts from directory records, and resolves
a rename's double name (§3.3.1).

3.4.3. `fsck_oxfs` is a static userland program in `/sbin` (BSD style), working on the raw disk
device. It runs from `/etc/rc` while the root is still mounted read-only: the kernel mounts the
root filesystem **read-only** at boot; `/etc/rc` runs `fsck_oxfs -p` (preen) when the clean flag
is clear, and stops in single-user mode if preening can't repair it; it then remounts the root
read-write (`mount -u -o rw /`). Prerequisites, each its own commit:

- raw disk devices in devfs (§3.4.5), registered with `make_dev`, readable and writable only
  by root;
- read-only mounts (`MNT_RDONLY`: every modifying operation returns `EROFS`) and the root mounted
  read-only at boot;
- `mount -u` (`MNT_UPDATE`) from read-only to read-write. The upgrade MUST invalidate the whole
  cache and reread the superblock and bitmap, since fsck changed the disk underneath it.

Once piece B's shared format crate exists, the same checker also builds for the host and checks
image files.

3.4.5. **Disks, partitions and the root device** (decided 2026-10-12):

- Disk names are OxideBSD's own, by bus: `nvme0`, `sata0`, `virt0` (virtio-blk), `sda0` (SCSI
  and USB mass storage), `mmc0`, `ide0`.
- Disks are partitioned. GPT partitions are `<disk>p<N>` (`virt0p1`), MBR partitions
  `<disk>s<N>` (`ide0s1`; the four primary entries, no extended/logical yet). oxfs gets its own
  GPT partition type GUID (generated once, recorded here) and an MBR type byte. oxfs lives in a
  partition, never on a whole disk.
- A blank disk is partitioned and formatted (a GPT with one oxfs partition) **only** when the
  kernel is booted with an explicit flag (`format-blank`), which the QEMU runner passes for test
  and dev disks. Real hardware is never partitioned by the kernel on its own.
- **`/etc/fstab`**, BSD format (device, mount point, type, options, dump, pass). `/etc/rc` runs
  `fsck -p` (a front end dispatching to `fsck_oxfs` by type) for every pass > 0 entry, then
  `mount -a`.
- The kernel finds the root filesystem from **`/boot/fsconf`**, a versioned binary form of
  `/etc/fstab` produced by `fsconf_mkdb(8)` (run explicitly after editing fstab, like
  `pwd_mkdb`). Limine loads it beside the kernel as a boot module, so it's readable before any
  filesystem is mounted; the boot partition carries the copy. Without it (or with no matching
  disk) the root is the RAM disk (§3.1.3.1). Its format gets its own short specification.

3.4.4. The superblock layout changes (size, clean flag): `SUPERBLOCK_VERSION` MUST be bumped.
Existing disks are reformatted.

### 3.5. Blocking I/O

3.5.1. A system call waiting for the disk MUST sleep through the scheduler, not spin with
interrupts masked: the request is issued, the process blocks, and the device's completion
interrupt wakes it (virtio-blk already has an IRQ; IDE DMA gets one, IRQ 15 for the secondary
channel). IDE PIO stays polled.

3.5.2. oxfs today relies on system calls being serialized: no other process can run while one is
inside it. Sleeping mid-operation breaks that. oxfs MUST take a sleepable **filesystem lock** at
every entry point (one owner process; others block on it through the scheduler and re-check after
waking, per `CLAUDE.md`), held across its own I/O sleeps. Finer locking is SMP work (v0.5.0).

3.5.3. The kernel page cache and `MAP_SHARED` write-back that read oxfs from inside other paths
(exec, page faults) go through the same lock.

3.5.4. With blocking I/O in place, `update(8)`'s flushes and dirty-buffer eviction no longer
freeze the machine; other processes run while the disk works.

### 3.6. Interfaces that stay

`content_changed` (the kernel page cache), `oxidebsd_inode_in_use`, `MAP_SHARED` write-back by
inode number and the mount table are unchanged: they sit above `read_block`/`write_block`.

### 3.7. Verification

- The existing suite and POSIX canary pass with the cache at its 128 MB size (forced by a test
  knob) as well as its default size.
- `/proc/meminfo` after boot to login: oxfs's resident memory is the cache plus the
  bitmap plus tmpfs, independent of the disk's contents.
- Crash test: a scripted write load, QEMU killed mid-run (`quit` over the monitor), reboot: mount
  sees the unclean flag, fsck repairs, every file is either its old or its new contents with no
  foreign data, and the test fixture compares checksums.
- Until piece B lands the kernel is still 293 MiB, so `-m 128` can't boot yet; piece A is
  verified by measured residency, not by the floor itself.

### 3.8. Commits

1. Kernel exports (§3.1.1); tmpfs sized from RAM and moved to `TMPFS_BLOCK_BASE`; incremental
   directory reads, slim `OPEN_FILES`.
2. Write buffers removed (§3.1.5).
3. The cache, still write-through: demand reads, mount reads only superblock and bitmap, bitmap
   as bits, filesystem size from the device, `SUPERBLOCK_VERSION` bump.
4. Delayed writes and their ordering (§3.3), `fsync`/`sync`, the shutdown hook, the clean flag.
5. `update(8)` and its rc.d script.
6. The oxfs filesystem lock (§3.5.2), still with polled I/O.
7. Interrupt-driven, sleeping disk I/O for virtio-blk and IDE DMA (§3.5.1).
8. Raw disk devices in devfs, GPT and MBR partitions, the oxfs partition type, `format-blank`
   (§3.4.5).
9. `/etc/fstab`, `fsconf_mkdb(8)`, `/boot/fsconf` as a Limine module, root selection.
10. Read-only mounts, the read-only root at boot, `mount -u` to read-write (§3.4.3).
11. `fsck_oxfs`, the `fsck(8)` front end and its `/etc/rc` step.

## 4. Piece B: the host image builder (outline)

Decided 2026-10-12; a full specification follows piece A.

- oxfs's on-disk format (superblock, `pack_inode`/`unpack_inode`, directory records, bitmap
  layout) moves into a `no_std`, `alloc`-free crate shared by the module and a host tool,
  `makefs-oxfs` (FreeBSD `makefs(8)`), so the two can't drift.
- `build.rs` stages each set's tree plus a manifest (mode, owner, symlinks) and `makefs-oxfs`
  writes the image. The ~400 `seed_*` calls in oxfs's `module_init` and every `include_bytes!` of
  a seed file go away, and the kernel shrinks to its code, its modules and the embedded init.
- **Dist sets**: `base`, `clang`, `tests` (the POSIX corpus and regress fixtures). A 128 MB install
  takes `base`; dev and test images take all three.
- **Dev disk**: rebuilding updates the persistent dev disk in place (an overlay/upgrade, in the
  spirit of `freebsd-update`), replacing base-system files and keeping local changes such as
  `/home` and edited `/etc` files. Each set's manifest records a hash per file, and the installed
  manifest is kept on the disk; a file whose current hash differs from the installed manifest's
  was changed locally and is kept (a changed `/etc` file gets a three-way merge or a `.new`
  beside it, as `etcupdate` does). Tests always start from a fresh image.

## 5. Piece C: mfsroot (outline)

- Limine loads a small oxfs image as a boot module (a new Limine `ModuleRequest`); the kernel
  exposes it as a memory disk (`md(4)`) that oxfs mounts as root when there is no disk, with
  `-s`, or when asked on the command line.
- Contents: static `/bin` and `/sbin`, `fsck_oxfs`, and later the installer. Size target: a few
  MiB, leaving the 128 MB machine its memory once the real root is mounted (or the mfsroot
  freed).

## 6. Decisions

2026-10-12: write-back with synchronous metadata (§3.3), a userland `update(8)` rather than
kernel threads, `fsck_oxfs` in `/sbin` (§3.4.3), blocking disk I/O (§3.5), host `makefs` with a
shared format crate, sets `base`/`clang`/`tests`, the dev disk upgraded in place with local
changes detected by manifest hash (§4); the bitmap paged through the cache, a RAM disk when there
is no disk, own disk names, GPT and MBR partitions, `/etc/fstab` compiled to `/boot/fsconf` for
root selection, kernel partitioning only under `format-blank` (§3.4.5).
