# OxideBSD install medium and installer: design specification

Status: **accepted** (2026-10-18), with the user's answers to the open questions (§12, §13).
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
/OxideBSD/<version>/base.tar.zst, clang.tar.zst, tests.tar.zst, MANIFEST
```

`MANIFEST` lists each set's size and SHA-256 (FreeBSD's format), checked before extraction.

3.3. The medium boots only into the mfsroot (decided §13): `limine.conf` loads `/boot/mfsroot`
as a module and passes `mfsroot` on the kernel command line. Installed systems boot their disk;
they carry no mfsroot.

## 4. The mfsroot

4.1. The kernel MUST take Limine's module named `mfsroot` (a new `ModuleRequest`), give it to
`md` as its contents, and with `mfsroot` on the command line mount `md0` as the root file system
(read-write: changes live only in memory) in place of a disk's.

4.2. Contents (decided 2026-10-17): `/sbin/init`, a short `/etc/rc` of its own, and an
`/etc/ttys` that runs `/usr/libexec/installer -t` on the console in getty's place (FreeBSD's
install media do the same), so init starts it again whenever it exits; `/bin` and `/sbin` (static); `newfs_oxfs`, `newfs_msdos`, `fsck_*`, `mount`,
`ifconfig`, `dhclient`, `route`, `zstd`, `tar`; `vi`; `/usr/libexec/installer`; `ncurses`'
terminfo for the console. No compilers, no BusyBox `/usr`, no `doom`.

4.3. Size: a few MiB. The tools are crunched into one program, `/rescue/rescue` (`rescue/`,
FreeBSD's `crunchgen`): each tool's own source included as a module, picked by `argv[0]`, one copy
of `std` and libc for all (one static Rust program each made 25.8 MB; crunched, 8.5 MB with `vi`,
`zstd` and the installer beside it). The image is then compressed in 64 KiB chunks, each a zstd
frame (FreeBSD's `geom_uzip`; format in `sys/drivers/md.rs`), and `md` decompresses a chunk as
it's read, with `ruzstd`: 2.8 MB in RAM. The whole install MUST work at 64 MB of RAM (the RAM rule covers console
install): the mfsroot, the installer, and a set extracted as a stream from the medium, never held
whole in memory.

4.4. Leaving the installer offers a shell on the console (recovery): the same mfsroot, the
target disk's partitions visible in `/dev`, its file systems mountable.

## 5. Disks: the registry and drivers

5.1. **Every disk the kernel drives is registered** at boot (`sys/drivers/disk.rs` grows from
"one disk" to a list), with its partitions, each a block device and a `/dev` node. Devices keep
today's naming by bus (decided §12): one counter per bus, in probe order, disks and optical
drives alike; except AHCI, named by where the drive is plugged in (decided §13).

| Driver | Names |
|---|---|
| virtio-blk | `virt0`, `virt1`, ... |
| IDE (ATA and ATAPI) | `ide0`, ... |
| AHCI (SATA) | `sata<C>.<P>`, `sata<C>.<P>.<M>` |
| virtio-scsi | `scsi0`, ... |
| USB mass storage | `usb0`, ... |
| memory disk | `md0` |

Whether a device is an optical drive is in its kind (`kern.disks`, §5.5), not its name.
Partitions are `<disk>p<N>` (GPT) or `<disk>s<N>` (MBR), as today.

An AHCI drive's name is its controller `C` (in PCI order, from 0), its port `P` (0-31, as the
controller numbers them) and, behind a port multiplier, the multiplier's port `M` (0-14):
`sata0.3`, `sata0.3.2`. The name stays with the connector: an empty port leaves a gap, and a
drive moved to another port changes name (`/etc/fstab` and `/boot/fsconf` name a GPT label for
that reason).

5.2. The root is still chosen as today (`/boot/fsconf`, else the first oxfs partition), from all
registered disks; `mfsroot` selects `md0`.

5.3. New drivers (decided §13), each probing at boot and registering what it finds:

- **ATAPI** over the existing IDE driver: packet commands (`READ CAPACITY(10)`, `READ(10)`),
  2048-byte sectors, read-only.
- **virtio-scsi**: the virtio transport `virtio.rs` already has, SCSI `READ(10)`/`WRITE(10)` for
  disks and CDs.
- **AHCI**: SATA disks (read-write) and ATAPI optical drives, with DMA and interrupt completion
  as the IDE and virtio drivers have, one command at a time per controller (no NCQ until the
  block layer issues concurrent I/O). It takes the controller from the firmware first (BIOS/OS
  handoff) where the controller offers that; a controller without 64-bit addressing gets DMA
  memory below 4 GiB; drives behind a port multiplier are registered too (command-based
  switching). **Hot plug**: a drive plugged into a port is registered under the port's name, a
  drive pulled out is retired (its file systems unmounted by force, as a CD's when its disc
  goes, open descriptors failing with `EIO`). That work sleeps and allocates, so it runs in a
  kernel thread the controller's interrupt wakes, not in the interrupt (kernel threads: a design
  of their own, built before hot plug).
- **USB mass storage**: bulk-only transport and SCSI over the existing xHCI driver (bulk
  endpoints are new there), for USB sticks and disks.

AHCI hot plug in detail (decided 2026-10-22):

- After boot's probe, each implemented port's `PxIE` adds port connect change (`PCS`) and PhyRdy
  change (`PRCS`), their boot-time status cleared first. The interrupt handler clears the
  `PxSERR` bits behind them (`DIAG.X`, `DIAG.N`: the interrupt is level-triggered and stays
  asserted until they're clear) and enqueues the port's task, one static task per port, on
  `taskqueue_thread` (`KTHREAD.md` §9).
- **Port multipliers report their own ports' changes** by asynchronous notification: at probe a
  multiplier has notification enabled (`GSCR[96]` bit 3) for PhyRdy changes on its ports
  (`GSCR[33]` bit 16). Its Set Device Bits FIS with the notification bit (`PxSNTF` with
  `CAP.SSNTF`, else the received SDB FIS) enqueues the port's task too, which reads `GSCR[32]`
  for the multiplier ports that changed, clears their `PSCR[1]`, and handles each as below.
- The task waits 500 ms for the link to settle (`pause`; the enqueues it absorbs meanwhile
  coalesce), takes the giant lock (`fslock`), then: link down, the port's drives are retired (all
  of a multiplier's when it goes); link up with nothing registered, the port is brought up and
  probed as at boot, sleeping rather than spinning while the drive spins up, and what answers is
  registered; link up and registered, the drive is identified again and, if its model, serial
  number or size differ, the old drive is retired and the new one registered (a reset of the
  driver's own also signals a change: an unchanged drive is left alone).
- **Retiring a drive**: it's marked gone first (so the forced unmounts' writes fail at once,
  not after a command timeout each), then every file system on its devices is unmounted by force
  (descriptors on them go to deadfs: reads at end of file, writes failing `EIO`), its raw `/dev`
  descriptors fail with `EIO`, its nodes and block devices go. Its registry entry stays: a drive plugged into the same place gets that entry back,
  with the same name and device numbers.
- **The root's drive** going panics by default (`root device <name> is gone`); with
  `kern.disk.root_lost=eio` (a writable sysctl, and a boot tunable: `kern.disk.root_lost=eio`
  on the kernel command line), the root stays mounted with every read and write failing `EIO`, and a
  `lost root` event (`DEVD.md`) goes out. The drive coming back isn't the root again.
- Each change is logged (`[disk] sata0.2: attached ...`, `detached`) and reported on
  `/dev/devctl` (`DEVD.md` §3).
- QEMU emulates no AHCI hot plug: writing a drive's name to `debug.disk.unplug` (root, like
  `debug.kill_init`) has its port's task retire it as if pulled, then find it still there and
  register it again; the interrupt path and multipliers are tried on real hardware.

5.4. A CD's block device reports 2048-byte sectors; the block layer (`vfs_bdev`, `vfs_bio`) MUST
handle a device sector size other than 512.

5.5. `kern.disks` (FreeBSD's sysctl) lists the registered disks, and a new `kern.disk.<name>`
node gives each one's kind (`disk`, `cd`, `memory`), size, sector size and model. A dot in a
disk's name is a level of the tree: `kern.disk.sata0.3.kind`.

## 6. cd9660

6.1. A new file system module, `cd9660` (FreeBSD's name), read-only: ISO 9660 with Rock Ridge
(POSIX names, modes, symlinks) and, without Rock Ridge, Joliet names, then plain 8.3 names. It
registers a `VfsConf` as the others do and is mounted with `mount -t cd9660 /dev/ide0 /mnt` (the
drive's bus name, §5.1).

6.2. It serves `vop_lookup`, `vop_readdir`, `vop_getattr`, `vop_read`, `vop_readlink` and
`vop_strategy` (file data is contiguous extents), and refuses every write with `EROFS`.

## 7. Keymaps

7.1. The console MUST support more layouts than US 104: the layouts `pc-keyboard` ships (US,
UK, German, French AZERTY, Dvorak, Colemak, JIS), for PS/2 and the USB HID keyboard alike.

7.2. Set at run time by `wsconsctl keyboard.encoding=<name>` (NetBSD's and OpenBSD's tool and
names: `us`, `uk`, `de`, `fr`, `us.dvorak`, `us.colemak`, `jp`), over a new console ioctl, and at
boot from `/etc/wsconsctl.conf` by `rc.d/wsconsctl` (decided §12).

## 8. Partitioning

8.1. A library, `lib/libpart` (shared with `mkimg`), reads and writes GPT (primary and backup
header and table, CRCs) and MBR (primary partitions), and the kernel re-reads a disk's
partitions after a change (a `DIOCGPARTRESCAN`-style ioctl on the disk's node).

8.2. The editor (in the installer, §9) MUST: show every disk and its partitions and free space;
create, delete and resize partitions (a resize only into adjacent free space, and an oxfs
partition only grown, with `growfs`-style help from `newfs_oxfs` if needed; other systems' file
systems are never resized: the user makes room with their own tools first, decided §12); keep existing
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

`build_install.rs` makes, at every build: `target/images/mfsroot.img` (`makefs -t oxfs`) from the
paths `distrib/mfsroot/list` takes from the installed tree, `distrib/mfsroot/etc/` and the
installer; and `target/sets/MANIFEST`. `build.rs` runs before the kernel is linked, so the image
itself is the QEMU runner's: `scripts/mkinstalliso.sh` (`xorriso`, Limine's hybrid boot) makes
`target/images/install.iso` from the kernel, the mfsroot and the sets at every `cargo run`, and
`OXIDEBSD_BOOT_INSTALLER=1` boots it, with a blank disk (`target/install_target.img`) to install
on. `OXIDEBSD_NO_INSTALLER=1` makes none of it, in either place.

## 11. Steps and verification

Each step its own commit, the suite and the POSIX canary green, `ram_floor_boot` passing.

1. **Disk registry** (§5.1-5.2, 5.4), today's drivers renamed; test: two virtio-blk disks and an
   IDE disk all visible.
2. **ATAPI** and **cd9660** (§5.3, §6); test: an ISO on an IDE CD mounted and read.
3. **virtio-scsi**; test: the same on virtio-scsi.
4. **AHCI**; test: QEMU's `ich9-ahci` with a disk and a CD. Then kernel threads, then AHCI hot
   plug. QEMU emulates neither hot plug on AHCI ("Bus 'ahci.1' does not support hotplugging")
   nor port multipliers: those are tried on real hardware.
5. **USB mass storage**; test: QEMU's `usb-storage` stick.
6. **md from the mfsroot** and **the install medium** (§3, §4); test: boot it, reach the
   installer's first screen headlessly (serial).
7. **Keymaps** (§7); test: a German layout's `z`/`y` swap through `sendkey`.
8. **libpart** and the partition editor's backend (§8); host tests against `mkimg`'s images.
9. **The installer** (§9); test: `installer -f` installs onto a blank disk at 64 MB, and the
   installed disk boots to a login prompt on BIOS and on UEFI; a second test installs beside an
   existing partition and checks it untouched.

Progress: step 1 done (2026-10-18): the registry, `kern.disks`/`kern.disk.<name>`, IDE on all
four positions with per-channel DMA and LBA48, every virtio-blk unit; its test is part of
`tests/devfs_syscall_smoke.rs` (two virtio-blk disks and a 130 GiB IDE disk beside the system's).
Step 2 done (2026-10-18): ATAPI over the IDE driver (PIO packet commands, a disc's size checked
again at each open and mount, the tray locked while mounted, a hybrid image's partitions read on
a CD too), cd9660 (`sys/modules/cd9660` over `lib/libcd9660`: Rock Ridge, Joliet, plain names,
`norrip`/`nojoliet`), `cd9660(5)`; test `tests/cd9660_syscall_smoke.rs` (three discs and an empty
drive on IDE). Not yet exercised by a test: a disc changing under a running system, Rock Ridge's
relocated directories (xorriso doesn't relocate), files of several extents.
Step 3 done (2026-10-19): virtio-scsi (`sys/drivers/virtio_scsi.rs`) under a shared SCSI command
layer (`sys/drivers/scsi.rs`: INQUIRY, TEST UNIT READY, READ CAPACITY(10/16), READ/WRITE(10/16),
SYNCHRONIZE CACHE, medium lock) that ATAPI now uses too; every target's LUN 0 registered as
`scsi<N>`, disks and CDs; disks of 4096-byte sectors (their GPT counted in them; `mkimg -S`). The
kernel now reads the medium it booted from under QEMU (`scsi0`). Tested in
`cd9660_syscall_smoke`.
Step 4 done (2026-10-20), except hot plug: AHCI (`sys/drivers/ahci.rs`): disks by DMA (LBA48, else
28-bit), ATAPI drives as SCSI transports, every controller and implemented port, BIOS/OS handoff,
32-bit DMA memory where the controller lacks 64-bit addressing, port multipliers; the system's disk
may be one (`OXIDEBSD_QEMU_DISK=sata`). Tested in `cd9660_syscall_smoke` (two controllers: a disk
with a file system, a 130 GiB disk, a disc and an empty drive). Not exercised by a test: port
multipliers (QEMU has none), the handoff and 32-bit DMA (QEMU's controller needs neither), 28-bit
disks, sectors other than 512 bytes (QEMU's ATA disks have only those).
Step 6 done (2026-10-22, before step 5 by the user's choice, §13): the mfsroot (`md` over the
loaded image, compressed or not; `/rescue/rescue`), `install.iso` (`scripts/mkinstalliso.sh`), and
the installer's first screen; tests `install_boot` and `install_boot_bios` boot it at 64 MB and
check the mfsroot from its shell. Hot plug for step 4 landed with `KTHREAD.md` step 5.

## 12. Open questions

None left. Answered 2026-10-18 (user): devices keep bus names (§5.1); the keymap tool is
`wsconsctl` (§7.2); resizing only into free space, never another system's file system (§8.2).

## 13. Decisions

- 2026-10-22 (user): step 6 (the mfsroot and the medium) and the installer before step 5 (USB
  mass storage), all testable from a CD in QEMU. USB waits for MSI, built first, and then
  covers Bulk-Only Transport, hubs, hot plug with devd events, and UAS. The install medium is
  made at every build, and `OXIDEBSD_NO_INSTALLER` stops it. The mfsroot's memory disk reads the
  loaded image in place, a block copied to a frame of its own at its first write.
- 2026-10-22: the installer replaces getty in the mfsroot's `/etc/ttys` (§4.2), not a check in
  `/etc/rc`. **Rationale.** init already restarts a session when it ends, and FreeBSD's media
  work so. The mfsroot holds a chosen list of programs, not every static one: all of `/bin` and
  `/sbin` is about 30 MiB, which a 64 MB machine can't keep in RAM.

- 2026-10-17 (user): the mfsroot holds an install and recovery set, no compilers.
- 2026-10-18 (user): the sets are read from the medium through a new cd9660 module (not loaded
  by Limine, not fetched); the mfsroot only on the install medium; the installer a Rust TUI over
  ncurses (FFI); steps keymap + hostname, partition + sets, network + time zone, root password +
  users; a partition editor for GPT and MBR that keeps other systems, makes several oxfs
  partitions and a swap partition; one hybrid ISO; drivers for ATAPI, virtio-scsi, USB mass
  storage and AHCI.
- 2026-10-20 (user): AHCI drives named by controller, port and multiplier port
  (`sata<C>.<P>[.<M>]`, nested in `kern.disk`); one command at a time; BIOS/OS handoff, 32-bit
  DMA fallback, port multipliers and hot plug all in; removing a mounted drive unmounts it by
  force; hot plug's work in real kernel threads (a separate design, before hot plug); hot plug
  and port multipliers checked on the Mac mini later, not in QEMU.
