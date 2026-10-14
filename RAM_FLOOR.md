# OxideBSD 128 MB RAM floor: design specification

Status: **piece A implemented** (2026-10-13, OxideBSD `c6b3691`..`f7bf9c9`; per-step commits in §3.8);
piece B specified (§4); piece C in outline. Target release: v0.3.0 (`ROADMAP.md`, item 6).

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

3.1.4. tmpfs's blocks are pages taken from the kernel on demand (amended 2026-10-13: it was a
fixed pool reserved at boot), up to a limit of `clamp(RAM / 16, 8 MiB, 64 MiB)`. Its
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
  `<disk>s<N>` (`ide0s1`; the four primary entries, no extended/logical yet). oxfs's GPT
  partition type GUID is `06026785-76ab-42c2-afe2-66ea3af562b8` (generated 2026-10-13); its MBR
  type byte is `0xA2` (chosen as absent from the common type lists; to be checked against
  others before an installer writes MBR disks). oxfs lives in a partition, never on a whole disk;
  the memory disk (`md`) is the exception, holding oxfs whole.
- Raw devices are character devices, `root:root 0600` (the BSDs' `operator` group doesn't exist
  yet), read-only until read-only mounts exist (§3.4.3): writing under a mounted file system
  would go around its cache.
- A blank disk is partitioned and formatted (a GPT with one oxfs partition) **only** when the
  kernel is booted with an explicit flag (`format-blank`), which the QEMU runner passes for test
  and dev disks. Real hardware is never partitioned by the kernel on its own. **Superseded by
  piece B** (§4.2.1): the kernel stops formatting altogether and `format-blank` is removed.
- **`/etc/fstab`**, BSD format (device, mount point, type, options, dump, pass). `/etc/rc` runs
  `fsck -p` (a front end dispatching to `fsck_oxfs` by type) for every pass > 0 entry, then
  `mount -a`.
- The kernel finds the root filesystem from **`/boot/fsconf`**, a versioned binary form of
  `/etc/fstab` produced by `fsconf_mkdb(8)` (run explicitly after editing fstab, like
  `pwd_mkdb`; format in `fsconf(5)`). Limine loads it beside the kernel as a boot module, so it's
  readable before any filesystem is mounted; the boot partition carries the copy (the QEMU
  runner builds it from `etc/fstab` with a host build of the same tool). Without it, or when the
  device it names isn't on the disk, the root is the disk's first oxfs partition (logged).
- The root line names the partition by **GPT label**, `/dev/gpt/rootfs` (FreeBSD's
  `/dev/gpt/<label>`), not by disk: dev runs use virtio (`virt0`) and tests IDE (`ide0`), and a
  label survives both. `format-blank` labels its partition `rootfs`; devfs adds
  `/dev/gpt/<label>` for every labelled GPT partition (major 253). (Decided while the user was
  away, 2026-10-13: open to change.)

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

## 4. Piece B: the host image builder

Decided 2026-10-12, specified 2026-10-13. Piece B takes every seed file out of the kernel: the
system is built on the host into dist sets and filesystem images, the way FreeBSD's `makefs(8)`
and `mkimg(1)` build release images. The in-place dev disk upgrade (§4.7) needs a VFS and lands
after it (§4.8).

### 4.1. liboxfs: the shared on-disk format

4.1.1. oxfs's on-disk format moves into `lib/liboxfs` (FreeBSD's `libufs`), a `no_std`,
`alloc`-free crate: the superblock and `SUPERBLOCK_VERSION`, `pack_inode`/`unpack_inode`,
directory records, the bitmap layout and its free-count array, the block layout constants
(`DATA_BLOCK_OFFSET`, the inode file), and the oxfs GPT type GUID and MBR type byte. It reads
and writes through a caller-supplied block device trait (`read_block`/`write_block` by number),
so the same code runs over the kernel's cache, a raw device on target and an image file on the
host.

4.1.2. The oxfs module, `fsck_oxfs` and every host tool below MUST use liboxfs for the format;
none keeps its own copy of a layout constant or a pack routine. A layout change is one edit and
one `SUPERBLOCK_VERSION` bump.

### 4.2. Tools

| Tool | Runs on | Does |
|---|---|---|
| `newfs_oxfs(8)` | target (`/sbin`, static) and host | writes an empty oxfs (superblock, bitmap, inode file, root, `lost+found`) to a partition or image file |
| `makefs(8)` | host and target (`/usr/sbin`) | writes a filesystem image from a staged tree and an mtree specification (§4.3): `-t oxfs`, later `-t msdos` (§4.4.4) |
| `mkimg(1)` | host and target (`/usr/bin`) | assembles partition images into a GPT (or MBR) disk image; GPT labels and type GUIDs per partition; later boot code (§4.4.4) |
| `fsck_oxfs(8)` | target and host | §3.4; on the host it checks image files, and `makefs -t oxfs`'s output is checked by it at build time |

4.2.1. **The kernel never formats a filesystem.** `format_fresh_filesystem`, every `seed_*`
routine and the `format-blank` boot flag are removed (§3.4.5 is amended accordingly). A disk with
no oxfs partition, or an unformatted one, is not mounted; the kernel says so and boot fails
(§4.6.3). Formatting is `newfs_oxfs`'s job, partitioning a future `gpart`-like tool's.

4.2.2. The memory disk (`md`, §3.1.3.1) stays as a device but is no longer formatted by the
kernel: piece C fills it from the mfsroot image. Until then a boot with no disk has no root
filesystem.

4.2.3. A raw disk device answers `DIOCGMEDIASIZE` (size in bytes, `i64`) and `DIOCGSECTORSIZE`
(`u32`, 512), FreeBSD's `<sys/disk.h>` names with OxideBSD's own request numbers
(`sys/drivers/disk.rs`), so `newfs_oxfs` sizes a partition without being told. (Decided
2026-10-13, as were `-L` with a 32-byte label in the superblock and `-i` preallocating inodes.)

4.2.4. `makefs` and `mkimg` take FreeBSD's names, paths and option shapes (`usr.sbin/makefs`,
`usr.bin/mkimg`), with the filesystem chosen by `-t`; they are built for the host (image
building) and installed on the target, so OxideBSD can build its own images once it hosts
itself. mtree(5) specifications are read and written by `lib/libmtree`, shared with `build.rs`
and, later, `oxupdate` and an `mtree(8)`. (Decided 2026-10-13.)

### 4.3. Sets and their manifests

4.3.1. **The install list**, `distrib/install.mtree`, says what is installed into the system's
file tree: mtree(5) syntax (read by `lib/libmtree`), each entry with its type, mode and owner,
plus where it comes from: `src=artifact:NAME` (a build product, by the name build.rs gives
it), `src=gen:NAME` (a list build.rs generates: zoneinfo, OpenSSL, the POSIX corpus...),
or a path in the source tree; `type=tree` installs a generated list under a directory and
`hardlink=` gives an entry another name. A file's mode defaults to 0755 for an ELF executable
or shared object and a `#!` script, 0644 otherwise. A path installed twice fails the build.

**The set lists**, `distrib/sets/lists/{base,clang,tests}` (NetBSD's `distrib/sets/lists`),
assign each installed path to a set by pattern (`*` within a component, `**` across
components); the most specific match wins (an exact path, then the longer pattern), and a
path no list claims, or two claim equally, fails the build.

`build.rs` (`build_install.rs`) stages everything into `target/destdir` and writes each set's
**mtree(5) specification**, `target/sets/<set>.mtree`: every entry with `type`, `mode`, `uid`,
`gid` and `time`, files with `size` and `sha256digest`, links with `link`, each set also
listing the directories above its paths so it stands alone. Hard links are staged as host
hard links and `makefs` keeps them as one inode. The image carries each set's specification as
`/etc/mtree/<set>.mtree`.

4.3.2. Sets:

- `base`: everything a console install needs (§1), including `/etc`, man pages, zoneinfo,
  OpenSSL and its certificates, ncurses and terminfo, nano, vi, doom, bmake, ninja.
- `clang`: Clang/LLVM, lld, compiler-rt, the musl and libc++ headers and libraries.
- `tests`: the POSIX corpus and `/usr/tests` (the regress fixtures oxfs seeds today).

A file belongs to exactly one set; `build.rs` MUST fail the build on an overlap or on a seeded
file that no set claims.

4.3.3. Timestamps in the mtree (`time=`) are a fixed build epoch, the time of the source tree's
`HEAD` commit, so an unchanged set produces a byte-identical image and archive (reproducible
builds; `SOURCE_DATE_EPOCH`'s rule). (Decided by Claude while writing this; open to change.)

4.3.4. **Set archives.** Each set is also written as `target/sets/<set>.tar.zst`: a `ustar`
archive of the staged tree, its mtree included as `./etc/mtree/<set>.mtree` (`base` only carries
`/etc/mtree` itself, so the specs of all installed sets live there), compressed with zstd. These
are the distribution format the installer and network installs will use. The target gets a
static `zstd` decompressor in `/sbin` (upstream zstd, vendored at `external/bsd/zstd`, BSD
licence; FreeBSD ships the same in base) so a set can be unpacked by a static `/sbin`
program before `/usr` exists. Unpacking itself is the installer's milestone.

### 4.4. Images

4.4.1. `makefs -t oxfs -s <size> -F <set>.mtree ... <out.img> <set dirs>` writes one oxfs partition
image from one or more sets (later sets' entries may not overwrite earlier ones, §4.3.2). It sets
the clean flag. Default image size: 1 GiB (`OXIDEBSD_DISK_MIB` overrides), as today's disks.

4.4.2. `mkimg -s gpt -p oxfs/rootfs:=<part.img> -o <disk.img>` (mkimg(1)'s syntax) writes a
GPT disk with one `rootfs`-labelled oxfs partition, the layout `format-blank` produces today.

4.4.3. The installed sets' specifications are on the image in `/etc/mtree`, so `oxupdate` (§4.7)
and a future `mtree -c` check can compare the disk against them.

4.4.4. **A bootable disk image** (decided 2026-10-13, lands after commit 5, once the kernel is
small): `mkimg` also writes an EFI system partition, a FAT filesystem made by
`makefs -t msdos` (a from-scratch FAT32 writer) holding Limine, `limine.conf` and the kernel,
and BIOS boot: Limine's MBR code and stage 2 in a BIOS boot partition, installed by `mkimg -b`
itself (FreeBSD mkimg's bootcode option), doing what `limine bios-install` does, so it works on
the target too. The QEMU runner keeps booting the ISO with the image as its data disk; a test
boots the disk image alone, on BIOS and on UEFI.

### 4.5. The QEMU runner

4.5.1. `build.rs` builds two images when their inputs change: `target/images/test.img` (base,
clang, tests) and the dev image (the same three sets). A build with unchanged sets doesn't
rewrite them.

4.5.2. **Tests** copy `test.img` to a fresh disk per run (`cp --reflink=auto`, falling back to a
sparse copy), so no test sees another's writes, as now.

4.5.3. **The dev disk** (`target/oxfs_disk.img`) until `oxupdate` exists: the runner records the
sets' hashes beside it (`target/oxfs_disk.sets`). When a set changed, the disk is replaced by a
fresh copy of the new dev image, with a loud message that local changes on it are gone (what a
reformat does today). `OXIDEBSD_KEEP_DISK=1` keeps the old disk. `OXIDEBSD_DISK_IMAGE` disks
are created from the dev image when missing and never replaced.

4.5.4. The runner keeps passing `/boot/fsconf` (§3.4.5); it no longer passes `format-blank`.

### 4.6. The kernel

4.6.1. Every `include_bytes!` of a seed file and the generated seed manifests
(`*_MANIFEST_PATH`) leave the oxfs module; the module keeps only filesystem code. Test kernels
still embed their own regress ELFs (`tests/*.rs`): those are test fixtures spawned by the test,
not seed files.

4.6.2. **Nothing userland is embedded in the kernel**: `/sbin/init`, `/bin/sh`,
`/sbin/emergency` and `sys/kern/start_init` are removed from the kernel image. This reverses
INIT.md §9.6 (embedded so a damaged filesystem can't stop init), which MUST be amended: rescue
from a damaged root becomes piece C's mfsroot.

4.6.3. pid 1 is started from the root filesystem, as on the BSDs (FreeBSD's `start_init`): the
kernel creates process 1 and has it `execve` the first path that exists in `init_path`
(`/sbin/init` by default, `init=`/`init_path=` override, colon-separated). The
kernel's `execve` therefore gains a kernel-initiated entry, a path executed in a fresh process
with no caller image to preserve. If no path can be executed, or no root filesystem is mounted,
the kernel prints why and panics (`no init found`). The repeated-failure program (§9.4) is
`/sbin/emergency` read from the root filesystem at the time it's needed.

4.6.4. Expected size: the kernel image loses the 293 MiB of `.rodata` and the second copy made
by `module::load` (§1). Measured result recorded here when B lands.

### 4.7. oxupdate: the dev disk upgraded in place (after the VFS)

4.7.1. `oxupdate(8)` installs a newer set over the running system: the runner attaches the new
set's oxfs image as a second, read-only disk; `oxupdate` mounts it (this needs a second mounted
filesystem: the VFS, §4.8) and, for every file in the new set's mtree:

- not on the disk, or matching the **installed** mtree's `sha256`: replaced;
- changed locally (hash differs from the installed mtree's): kept; under `/etc`, the new file
  is merged three-way against the old installed version, or written beside it as `<name>.new`
  when the merge conflicts (`etcupdate`'s behaviour);
- in the installed mtree but not the new one: removed, unless changed locally.

Then the new mtree replaces `/etc/mtree/<set>.mtree`. It runs at boot from an rc.d script when
the second disk is present. Tests never use it: they always start fresh (§4.5.2).

### 4.8. Dependency on a VFS

Mounting a second oxfs means per-instance filesystem state: the device, superblock, bitmap,
inode file and cache all live as module globals today. The user chose (2026-10-13) to build a
**real VFS layer** (vnodes, filesystem types with instances; oxfs, tmpfs, devfs and procfs as
separate types) instead of multi-instance oxfs. It gets its own specification (`VFS.md`, not yet
written) after piece B lands. `oxupdate` (§4.7) and piece C's handover from mfsroot to the disk
root both wait on it.

### 4.9. Verification

- Every existing test passes booting from `test.img`, and the canary matches its baseline.
- `fsck_oxfs` (host build) passes on every image `makefs -t oxfs` writes, at build time.
- Building twice from the same commit gives byte-identical images and archives (§4.3.3).
- The kernel image size and `/proc/meminfo` at the login prompt are recorded (§4.6.4).
- **The floor**: with the disk image, `OXIDEBSD_QEMU_MEM=128` boots to a login prompt. Piece B
  is where this first becomes possible (piece C isn't needed for a disk boot); a test boots to
  login at 128 MB and stays in the suite.

### 4.10. Commits

1. `lib/liboxfs`: the format moved out of the module; module uses it; no behaviour change.
2. `newfs_oxfs` (target and host): the format writer in liboxfs (`Writer`, over a
   `BlockDevice`), `-N`/`-L`/`-i`/`-s`, a volume label in the superblock (`SUPERBLOCK_VERSION`
   7), and `DIOCGMEDIASIZE`/`DIOCGSECTORSIZE` on raw disk devices (§4.2.3). The host builds of
   both tools land with their first use, in commit 4.
3. `lib/libmtree`, `makefs -t oxfs` and `mkimg` (a GPT data disk), for the host and the target.
4. Sets staged with mtree specs by `build.rs`; images built and checked; still unused. Landed
   with the install list and set lists (§4.3.1). Checked by comparing the image entry by entry
   with a filesystem the kernel seeded: identical in every path, type, mode, owner, content and
   hard-link group but for the self-check's leftovers and `/etc/mtree`. Found on the way: the
   seeding put `/usr/lib/libunwind.a` in twice (two records of one name), and neither the
   writer nor `fsck_oxfs` caught duplicate names; both do now.
5. The switch: the runner boots from the images (§4.5); seeding, `format_fresh_filesystem` and
   `format-blank` removed from the kernel. Landed: the oxfs module object went from 299 MB to 1.1 MB and
   the (debug) kernel image from 333 MB to 35 MB. The format self-check went with the seeding
   (its fixtures are in the tests set), and with it the module's kernel-segment copy path.
5b. `makefs -t msdos`, the EFI system partition and BIOS boot in `mkimg`; the disk-boot test
   (§4.4.4).
6. pid 1 from the root filesystem (§4.6.3); `init`, `sh`, `emergency` and `start_init` no longer
   embedded; INIT.md amended. Landed: the boot kernel image went from 6.0 MB to 3.5 MB (debug
   sections stripped), its read-only data from 3.8 MB to 1.25 MB.
7. Set archives (`.tar.zst`) and the static `zstd` in `/sbin`.
8. The 128 MB boot-to-login test (§4.9).

Measured 2026-10-13 after commit 5 (and a debug-stripped boot kernel, tmpfs on demand): the
system boots to login in 128 MB under UEFI (OVMF and Limine fail below ~128 MB before the kernel
runs) and in 48 MB under BIOS; at 32 MB `/etc/rc` runs out of memory at syslogd's libcrypto.
After commit 6: 32 MB under BIOS boots cleanly to login (48 MB leaves 41 MB usable, 27.5 MB
free at a root shell); at 28 MB syslogd can't fork.

## 5. Piece C: mfsroot (outline)

- Limine loads a small oxfs image as a boot module (a new Limine `ModuleRequest`); the kernel
  exposes it as a memory disk (`md(4)`) that oxfs mounts as root when there is no disk, with
  `-s`, or when asked on the command line. Mounting the disk root from it and switching over
  (`reboot -r`-style) needs the VFS (§4.8).
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

2026-10-13: liboxfs at `lib/liboxfs`; mtree(5) set specifications; the kernel never formats
(`newfs_oxfs` instead, `format-blank` removed); `makefs -t oxfs` writes partition images and
`mkimg` wraps them; `md` kept, unformatted until piece C; nothing userland embedded in the
kernel, pid 1 exec'd from the root filesystem; set archives zstd-compressed; `oxupdate` runs on
target at boot from a set image on a second disk, which needs a real VFS, built after piece B;
until then the dev disk is replaced when a set changes (§4).
