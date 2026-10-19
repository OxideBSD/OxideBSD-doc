# OxideBSD install medium and installer: design specification

Status: **draft** (2026-10-18), for review. The decisions in §13 are the user's; the open
questions are in §12.
Asked for by `CLEANUP.md` §7 (no mfsroot), `RAM_FLOOR.md` §5 (piece C) and §4 (one data disk,
found once).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Motivation

OxideBSD runs only from a disk image built on the host (`build_install.rs`, `mkbootimg.sh`).
Nothing installs it onto a machine:

- The kernel finds **one data disk, once, at boot** (`sys/drivers/disk.rs`): a virtio-blk disk,
  else the IDE secondary master. A second disk, a CD, a USB stick or a SATA disk is invisible.
- The boot ISO carries only the kernel and Limine; the kernel can't read it after boot (it sits
  on virtio-scsi under QEMU, and on USB or SATA on real hardware), and no file system reads ISO
  9660.
- A boot without a disk gets an empty memory disk (`md`) and no programs: there is nothing to
  install or recover with.
- Partitioning exists only on the host (`mkimg`); the console keyboard is US-only.

The BSDs ship an install medium that boots a small root file system in memory with an installer
on it (FreeBSD's `bsdinstall` on disc1/memstick, NetBSD's `sysinst`, OpenBSD's `bsd.rd`). This
specification does the same.

## 2. Terms

- **Install medium**: one hybrid ISO 9660 image, bootable from CD/DVD and when written raw to a
  USB stick, on BIOS and UEFI (§3).
- **mfsroot**: a small oxfs image Limine loads into memory beside the kernel, mounted as the root
  file system from a memory disk (§4).
- **Sets**: the zstd-compressed archives `base`, `clang` and `tests` (`RAM_FLOOR.md` §4.3), on
  the medium's ISO 9660 file system.
- **Disk registry**: the kernel's list of every disk and partition it drives (§5).

## 3. The install medium

3.1. One image, `target/images/install.iso`, MUST boot from a CD/DVD and when written with `dd`
to a USB stick, on BIOS and UEFI (Limine's hybrid ISO, as the dev ISO already is).

3.2. Its ISO 9660 file system (with Rock Ridge, as `xorriso -R -J` writes it) holds:

```
/boot/kernel                 the kernel
/boot/mfsroot                the mfsroot image (§4)
/boot/limine/...             Limine and limine.conf
/EFI/BOOT/BOOTX64.EFI        UEFI boot
/OxideBSD/<version>/base.tzst, clang.tzst, tests.tzst, MANIFEST
```

`MANIFEST` lists each set's size and SHA-256 (FreeBSD's format), checked before extraction.

3.3. The medium boots only into the mfsroot (decided §13): `limine.conf` loads `/boot/mfsroot`
as a module and passes `mfsroot` on the kernel command line. Installed systems boot their disk;
they carry no mfsroot.

## 4. The mfsroot

4.1. The kernel MUST take Limine's module named `mfsroot` (a new `ModuleRequest`), give it to
`md` as its contents, and with `mfsroot` on the command line mount `md0` as the root file system
(read-write: changes live only in memory) in place of a disk's.

4.2. Contents (decided 2026-10-17): `/sbin/init` and `/etc/rc` adapted to start the installer on
the console (`/etc/rc` runs `/usr/libexec/installer` instead of getty when it finds
`/etc/installer`); `/bin` and `/sbin` (static); `newfs_oxfs`, `newfs_msdos`, `fsck_*`, `mount`,
`ifconfig`, `dhclient`, `route`, `zstd`, `tar`; `vi`; `/usr/libexec/installer`; `ncurses`'
terminfo for the console. No compilers, no BusyBox `/usr`, no `doom`.

4.3. Size: a few MiB. The whole install MUST work at 64 MB of RAM (the RAM rule covers console
install): the mfsroot, the installer, and a set extracted as a stream from the medium, never held
whole in memory.

4.4. Leaving the installer offers a shell on the console (recovery): the same mfsroot, the
target disk's partitions visible in `/dev`, its file systems mountable.

## 5. Disks: the registry and drivers

5.1. **Every disk the kernel drives is registered** at boot (`sys/drivers/disk.rs` grows from
"one disk" to a list), with its partitions, each a block device and a `/dev` node. Names by
driver, as the BSDs do, replacing today's bus names:

| Driver | Disks | CD/DVD |
|---|---|---|
| virtio-blk | `vtbd0` | |
| IDE (ATA/ATAPI) | `ada0` | `cd0` |
| AHCI (SATA) | `ada1`, ... | `cd1`, ... |
| virtio-scsi | `da0` | `cd2`, ... |
| USB mass storage | `da1`, ... | |
| memory disk | `md0` | |

Numbers are given in probe order across drivers sharing a name. Partitions are `<disk>p<N>` (GPT)
or `<disk>s<N>` (MBR), as today.

5.2. The root is still chosen as today (`/boot/fsconf`, else the first oxfs partition), from all
registered disks; `mfsroot` selects `md0`.

5.3. New drivers (decided §13), each probing at boot and registering what it finds:

- **ATAPI** over the existing IDE driver: packet commands (`READ CAPACITY(10)`, `READ(10)`),
  2048-byte sectors, read-only.
- **virtio-scsi**: the virtio transport `virtio.rs` already has, SCSI `READ(10)`/`WRITE(10)` for
  disks and CDs.
- **AHCI**: SATA disks (read-write) and ATAPI optical drives, with DMA and interrupt completion
  as the IDE and virtio drivers have.
- **USB mass storage**: bulk-only transport and SCSI over the existing xHCI driver (bulk
  endpoints are new there), for USB sticks and disks.

5.4. A CD's block device reports 2048-byte sectors; the block layer (`vfs_bdev`, `vfs_bio`) MUST
handle a device sector size other than 512.

## 6. cd9660

6.1. A new file system module, `cd9660` (FreeBSD's name), read-only: ISO 9660 with Rock Ridge
(POSIX names, modes, symlinks) and, without Rock Ridge, Joliet names, then plain 8.3 names. It
registers a `VfsConf` as the others do and is mounted with `mount -t cd9660 /dev/cd0 /mnt`.

6.2. It serves `vop_lookup`, `vop_readdir`, `vop_getattr`, `vop_read`, `vop_readlink` and
`vop_strategy` (file data is contiguous extents), and refuses every write with `EROFS`.

## 7. Keymaps

7.1. The console MUST support more layouts than US 104: the layouts `pc-keyboard` ships (US,
UK, German, French AZERTY, Dvorak, Colemak, JIS), for PS/2 and the USB HID keyboard alike.

7.2. Chosen by `keymap="<name>"` in `rc.conf` (FreeBSD's variable, through `rc.d/syscons`-like
`rc.d/keymap`) and at run time by `kbdcontrol -l <name>` (FreeBSD's tool), over a new console
ioctl.

## 8. Partitioning

8.1. A library, `lib/libpart` (shared with `mkimg`), reads and writes GPT (primary and backup
header and table, CRCs) and MBR (primary partitions), and the kernel re-reads a disk's
partitions after a change (a `DIOCGPARTRESCAN`-style ioctl on the disk's node).

8.2. The editor (in the installer, §9) MUST: show every disk and its partitions and free space;
create, delete and resize partitions (a resize only into adjacent free space, and an oxfs
partition only grown, with `growfs`-style help from `newfs_oxfs` if needed); keep existing
partitions untouched (dual boot); set types: oxfs, EFI system, BIOS boot, swap, other.

8.3. Several oxfs partitions MAY be made for `/`, `/usr`, `/var`, `/home`; each is written to
the new system's `/etc/fstab`. A swap partition MAY be made: recorded in `fstab` as `sw`, used
once OxideBSD pages out (not yet).

8.4. Boot: a disk with an EFI system partition already gets OxideBSD's kernel in its own
directory (`/EFI/OxideBSD/`) and an entry added to that ESP's `limine.conf`, or a fresh Limine if
there is none; no existing boot entry is removed. On BIOS, Limine's stage 2 goes into a BIOS boot
partition (GPT) or the MBR gap, as `mkimg -b` does; an existing MBR boot code is replaced only
after the user confirms.

## 9. The installer

9.1. `/usr/libexec/installer`: a Rust `std` program (`usr.sbin/installer` in the tree) drawing
with the in-tree ncurses through FFI (decided §13), on the console.

9.2. Steps, in order, each allowing a step back:

1. Keymap (applies at once) and host name.
2. Disks: the partition editor (§8), then which partition mounts where.
3. Sets: `base` required; `clang`, `tests` optional; their sizes against the target's space.
   The install medium is found by its volume label among the registered CD and USB devices,
   mounted `cd9660` read-only, and each set checked against `MANIFEST` and extracted as a
   stream (`zstd -d | tar -x`, the `RAM_FLOOR.md` set format) onto the new file systems.
4. Network: per interface, DHCP or a static address, router and name server; written to the
   new `rc.conf` and `resolv.conf`.
5. Time zone (`tzsetup`'s data) and whether the clock is UTC.
6. Root's password; users (name, full name, password, `wheel` or not) through `pw`.
7. Boot loader (§8.4), `fstab`, `rc.conf`; reboot, shell or back.

9.3. Everything is written only after a final confirmation listing what will be erased.

9.4. Scriptable: `installer -f <file>` reads every answer from a file (FreeBSD's
`installerconfig`), so the tests can install unattended.

## 10. Build

`build_install.rs` gains: the mfsroot set and image (`makefs -t oxfs`), and `install.iso`
(`xorriso`, Limine's hybrid boot) from the kernel, the mfsroot and the sets.

## 11. Steps and verification

Each step its own commit, the suite and the POSIX canary green, `ram_floor_boot` passing.

1. **Disk registry** (§5.1-5.2, 5.4), today's drivers renamed; test: two virtio-blk disks and an
   IDE disk all visible.
2. **ATAPI** and **cd9660** (§5.3, §6); test: an ISO on an IDE CD mounted and read.
3. **virtio-scsi**; test: the same on virtio-scsi.
4. **AHCI**; test: QEMU's `ich9-ahci` with a disk and a CD.
5. **USB mass storage**; test: QEMU's `usb-storage` stick.
6. **md from the mfsroot** and **the install medium** (§3, §4); test: boot it, reach the
   installer's first screen headlessly (serial).
7. **Keymaps** (§7); test: a German layout's `z`/`y` swap through `sendkey`.
8. **libpart** and the partition editor's backend (§8); host tests against `mkimg`'s images.
9. **The installer** (§9); test: `installer -f` installs onto a blank disk at 64 MB, and the
   installed disk boots to a login prompt on BIOS and on UEFI; a second test installs beside an
   existing partition and checks it untouched.

## 12. Open questions

1. Device names (§5.1): the BSD-style `vtbd`/`ada`/`da`/`cd` names replace today's `virt0`/
   `ide0`. `fstab` names the root by its GPT label (`/dev/gpt/rootfs`) and nothing in the tree
   names `/dev/virt0`, so nothing breaks. Rename, or keep bus names for the new drivers too
   (`sata0`, `usb0`, `scsi0`)?
2. Keymap tool (§7.2): FreeBSD's `kbdcontrol -l`, or NetBSD/OpenBSD's `wsconsctl
   keyboard.encoding=`?
3. Resizing (§8.2): only into free space, and only growing oxfs, or also shrinking other
   file systems (FAT, NTFS) to make room, as some installers do?

## 13. Decisions

- 2026-10-17 (user): the mfsroot holds an install and recovery set, no compilers.
- 2026-10-18 (user): the sets are read from the medium through a new cd9660 module (not loaded
  by Limine, not fetched); the mfsroot only on the install medium; the installer a Rust TUI over
  ncurses (FFI); steps keymap + hostname, partition + sets, network + time zone, root password +
  users; a partition editor for GPT and MBR that keeps other systems, makes several oxfs
  partitions and a swap partition; one hybrid ISO; drivers for ATAPI, virtio-scsi, USB mass
  storage and AHCI.
