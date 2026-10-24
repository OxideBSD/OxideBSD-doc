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
names: `us`, `uk`, `de`, `fr`, `us.dvorak`, `us.colemak`, `jp`, and `no`, `fi`, `sv`, which
`pc-keyboard` also has), over the console terminal's `KBDIOC_GETENCODING`/`KBDIOC_SETENCODING`
(`ttyv0` only, setting root's; OxideBSD's numbers), and at boot from `/etc/wsconsctl.conf` by
`rc.d/wsconsctl` (decided §12).

7.3. A layout's keys reach the terminal as UTF-8, and the console shows each character its font
(code page 437) has; `IUTF8` (on by default) makes erasing take a whole character (`TTY.md`
§3.7). `SGR 11`/`SGR 10` (the `linux` terminfo's `smacs`/`rmacs`) switch the console to drawing
bytes as the font's glyphs and back, for curses' line drawing.

## 8. Partitioning

8.1. A library, `lib/libpart` (shared with `mkimg`, `gpart` and the kernel's reader), reads and
writes GPT (primary and backup header and table, CRCs; a damaged primary read from the backup)
and MBR (primary partitions), keeping what it doesn't interpret (boot code, GUIDs, attributes,
other systems' types). The kernel re-reads a disk's partitions after a change: on `DIOCRESCAN`
(`_IO('d', 130)`, on the whole disk's node open for writing), and when the whole disk's last
writer closes it (FreeBSD's GEOM retaste), both only if the table changed; with a partition
mounted or open the reread waits until the last one is let go (decided §13).

8.1.1. `gpart(8)` (FreeBSD's verbs and output: show, create, destroy, add, delete, resize,
modify, set/unset active) edits tables by hand, also on image files, and is in the mfsroot's
`rescue`.

8.2. The editor (in the installer, §9) MUST: show every disk and its partitions and free space;
create, delete and resize partitions (a resize only into adjacent free space, and an oxfs
partition only grown, by `growfs(8)`; other systems' file systems are never resized: the user
makes room with their own tools first, decided §12); keep existing partitions untouched (dual
boot); set types: oxfs, EFI system, BIOS boot, swap, other. Its edits are staged: each disk's
table is a copy until the install writes it, after the last screen (decided §13). A blank disk
asks for GPT (the default) or MBR. One install may span disks (`/` on one, `/home` on another);
the disk with the EFI system partition boots, and gets the BIOS boot code.

8.2.1. `growfs(8)` grows an unmounted, clean oxfs to fill its partition. The bitmap lies before
the data and is sized by it, so past the room in its last block every used data block moves
further in (only device positions change: all of oxfs's pointers are data block numbers), the
highest first, then the new bitmap blocks are zeroed and the superblock written last. The move
is not safe against a crash; `growfs` asks first unless given `-y`.

8.3. Several oxfs partitions MAY be made for `/`, `/usr`, `/var`, `/home`; each is written to
the new system's `/etc/fstab`. A swap partition MAY be made: recorded in `fstab` as `sw`, used
once OxideBSD pages out (not yet).

8.4. Boot: the EFI system partition, a new one or the one the disk has, gets Limine as
`\EFI\OxideBSD\BOOTX64.EFI`, and the kernel and `fsconf` in a directory of this install's own,
`\EFI\OxideBSD\<id>\` (`<id>` the first 8 hex digits of its root's GPT GUID), so two OxideBSDs
can share one partition; the kernel takes the boot module whose path ends `/fsconf`. The menu is
`/boot/limine/limine.conf` on that partition, which every Limine there reads (`\EFI\OxideBSD`'s,
the removable fallback's and BIOS's, Limine's `CONFIG.md`): a new one, or the existing one with
OxideBSD's entry added at its end; no entry is ever removed. The removable fallback
`\EFI\BOOT\BOOTX64.EFI` is written only if no system has taken it. On BIOS, Limine's stage 1 always
replaces the disk's boot code (decided §13), its stage 2 going into a BIOS boot partition of
OxideBSD's own (GPT; another system's is left alone) or the MBR gap, as `mkimg -b` does.

8.5. An installed system names its partitions in `fstab` and `fsconf` by GPT GUID,
`/dev/gptid/<guid>` (FreeBSD's names, lower case), which no other disk shares: labels are only
the first of their name (`/dev/gpt/rootfs` on two disks is the first one registered).

## 9. The installer

9.1. `/usr/libexec/installer`: a Rust `std` program (`usr.sbin/installer` in the tree) drawing
with the in-tree ncurses through FFI (decided §13), on the console.

9.2. Steps, in order, each allowing a step back:

1. Keymap (applies at once) and host name.
2. Disks: the disk, then Beside (offered when its largest free space holds the guided layout),
   Whole, the partition editor (§8, step 9b2), or Shell (`gpart` by hand), then which partition
   is for what: an oxfs one `/` or another mount point, an EFI system partition kept or
   formatted, a swap one swap; other types are left alone.
3. Sets: `base` required; `clang`, `tests` optional; their sizes against the target's space.
   The install medium is found by its volume label among the registered CD and USB devices,
   mounted `cd9660` read-only, and each set checked against `MANIFEST` and extracted as a
   stream (`zstd -d | tar -x`, the `RAM_FLOOR.md` set format) onto the new file systems.
4. Network: per interface, DHCP or a static address, router and name server, tried on the
   install medium there and then (`dhclient`, `ifconfig`, `route`; decided §13), so a mistake
   shows before the reboot; written to the new `rc.conf` and `resolv.conf`.
5. Time zone (`zone1970.tab`'s regions and zones, on the medium; the new system's `tzsetup`
   makes the link) and whether the hardware clock keeps UTC or local time
   (`/etc/wall_cmos_clock`, `TIMEZONE.md` §4.3), local suggested when Windows is found.
6. Root's password; users (name, full name, password, `wheel` or not) through `pw`. The base
   set's development account `user` is removed from every installed system. The console is
   `insecure` (root logs in only through `su`/`sudo`), unless no user is made: then the new
   `ttys` marks the `ttyv` terminals `secure`, so root can log in (decided §13).
7. Boot loader (§8.4), `fstab`, `rc.conf`; reboot, shell or back.

9.3. Everything is written only after a final confirmation listing what will be erased: every
question is asked first, then one screen lists the disk's partitions and what happens to each
(erased, formatted, kept, new), the sets, the settings and the users, its default button Back;
the install then runs unattended under a progress bar (decided §13).

9.4. Scriptable: `installer -f <file>` reads every answer from a file in FreeBSD's
`installerconfig` format (decided §13), so the tests can install unattended. The file is a
preamble of shell variables, read by running it with `/bin/sh` as bsdinstall does, then
optionally a line `#!/bin/sh` and a script run in the new system (`chroot`) after the install:

```
PARTITIONS="ide0 GPT { 512K bios, 260M efi, auto oxfs / }"   # or DEFAULT: the guided layout
DISTRIBUTIONS="base.tar.zst clang.tar.zst"                     # base is always taken
HOSTNAME=oxide KEYMAP=de ROOTPASS=secret                       # OxideBSD's additions
#!/bin/sh
pw useradd alice -m -G wheel
```

`PARTITIONS` is FreeBSD's syntax: a disk, a scheme, and `{ size type [mountpoint], ... }` with
sizes in `K`/`M`/`G` or `auto` (the rest); types `oxfs`, `efi`, `bios`, `swap`; this makes a new
table, erasing the disk. `DEFAULT` (or no `PARTITIONS`) is the guided layout (§9.5) on the first
disk, and `[disk] [BESIDE | WHOLE]` on the disk named: `WHOLE` erases it, `BESIDE` keeps its
table and installs in its largest free space, and neither word means `WHOLE` on a disk with no
partition table and `BESIDE` on one with, so a disk is erased only when an answer file says so
(decided §13).

9.5. **Guided layout** beside the editor (decided §13): on a whole disk, or in its largest free
space, so installing next to another system is one choice. A blank disk gets GPT with a BIOS
boot partition (512 KiB), an ESP (260 MiB, FreeBSD's size), and one oxfs `/` over the rest; a
disk with other systems keeps them, reuses an existing ESP (OxideBSD's files in their own
directories, §8.4), and makes only what's missing, in the free space chosen: its own BIOS boot
partition (512 KiB, GPT), an ESP if there is none, and `/`, at least 1 GiB.

9.6. **Dual boot made easy** (decided §13): on UEFI, the installer adds an `OxideBSD` boot entry
to the firmware's NVRAM (`efibootmgr(8)`, over UEFI runtime services the kernel calls,
`EFIRT.md`, not yet written) pointing at `\EFI\OxideBSD\BOOTX64.EFI`, and never touches another
system's files. OxideBSD's Limine menu lists the other systems it finds (decided §13): every ESP
of every disk is scanned, each `\EFI\<dir>` but `\EFI\BOOT` (a copy of another loader) and the
new system's own giving at most one chainload entry -- Windows' `bootmgfw.efi`, shim before
GRUB, systemd-boot, another Limine (a loader whose text names `limine.conf`), else the
directory's first `.efi` -- naming its partition by GPT GUID (`guid(...)`); on BIOS, a chainload
of each MBR disk's active partitions (by disk signature, `mbr_id`) and of each GPT disk's FreeBSD
boot partitions. An entry the menu has already (its path, or its partition) isn't added again.
The confirm screen (§9.3) lists the entries; none is ever removed.

9.7. **Looks**: bsdinstall's and sysinst's boxed dialogs (a title, buttons such as `[ OK ]` and
`[ Back ]`), in rust colours instead of blue (decided §13).

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
9. **The installer** (§9), in three commits (decided §13):
   - 9a, the engine: `installer -f` (§9.4) partitions, makes the file systems, extracts the sets
     from the medium, writes the boot loader, `fstab`, `fsconf`, `rc.conf` and root's password;
     test: an install onto a blank disk at 64 MB, then the installed disk boots to a login prompt
     on BIOS and on UEFI.
   - 9c, dual boot (§9.6), before 9b (decided §13): UEFI runtime services and `efibootmgr`
     (`EFIRT.md`), the loader scan; test: an install beside an existing partition and ESP, which
     are checked untouched.
   - 9b, the screens (§9.2, §9.5, §9.7) over the engine, in two commits (decided §13): 9b1
     every screen, the disk step with Beside, Whole and Shell; 9b2 the partition editor
     (Manual), `growfs`, and installs over several disks. Tests `install_screens` and
     `install_editor`: every answer a key on the serial line, at 64 MB, the new system's files
     checked, then booted on UEFI and BIOS; the editor's over two disks, beside a "Windows"
     partition left byte for byte as it was, an existing oxfs grown and kept as `/home`.

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
Step 7 done (2026-10-22): the layouts of §7.2 for PS/2 and USB, `wsconsctl`, `rc.d/wsconsctl`,
UTF-8 keys and output on the console (§7.3); tested in `install_boot` (QEMU's `sendkey` through
a new runner hook, `QEMU_MONITOR_INPUT`: German `z`, `y`, `[` give `yzü`). Found on the way:
libsh wrote characters U+0080..U+00FF as single bytes (`ü` as `0xFC`); raw bytes now live as
private-use characters, and text leaves as UTF-8.
Step 8 done (2026-10-22): `lib/libpart` (host tests), `mkimg` on it (the same images, byte for
byte), the kernel's reader on it, `DIOCRESCAN` and the retaste (§8.1), `gpart` (host tests on
image files; `install_boot` partitions the blank disk, makes and checks an oxfs, and deletes a
partition while another is open). The partition editor's screens are step 9's. Before step 9
(2026-10-23, user): oxfs mounts any number of file systems at once (`RAM_FLOOR.md` §4.8), so the
installer mounts the new root next to the mfsroot; `install_boot` mounts one.
Step 9a done (2026-10-23): `installer -f` (§9.4) with the guided layout and explicit
`PARTITIONS`; Limine's BIOS boot code moved from `mkimg` into libpart (`set_bios_bootcode`, the
same images byte for byte) and onto the medium (`limine-bios-hdd.bin`). `install_disk` installs at
64 MB, then boots the installed disk to its login prompt on UEFI and on BIOS, at 64 MB too. Found
on the way: Limine started from a disk's ESP holds 3 MB more than from the medium, and the kernel
reclaimed the loader's memory only before pid 1, after the root's mount had already run out at
64 MB; it now reclaims it once the drivers have their DMA buffers, before the file systems load.
Step 9c done (2026-10-23): `BESIDE`/`WHOLE` and the automatic choice (§9.4), the beside layout
(§9.5), the ESP layout and shared `limine.conf` (§8.4), `/dev/gptid` names (§8.5), the loader
scan and the firmware's boot entry (§9.6; `efibootmgr` crunched into the medium's `rescue`).
`install_beside` installs at 64 MB beside a "Windows" ESP and a partition of random bytes, boots
the installed disk on UEFI through its firmware entry and on BIOS, and checks the other partition
byte for byte. Found on the way: under UEFI at 64 MB, OVMF keeps about 5 MB more when any disk is
partitioned, and the medium's mfsroot no longer fitted beside the kernel's file, which Limine kept
for nothing; our Limine fork now frees it when the kernel doesn't ask for it.

## 12. Open questions

None left. Answered 2026-10-18 (user): devices keep bus names (§5.1); the keymap tool is
`wsconsctl` (§7.2); resizing only into free space, never another system's file system (§8.2).

## 13. Decisions

- 2026-10-24 (user): an install that makes no users marks the console `secure` in the new
  system, so root can log in there; with users it stays `insecure`. The base set's `user`
  account never reaches an installed system.

- 2026-10-24 (user), step 9b2: the editor's changes are staged and written after the last
  screen; an existing oxfs may grow (a `growfs` for oxfs, written now); an install may span
  several disks; a blank disk asks for GPT or MBR, GPT first.

- 2026-10-24 (user), step 9b: every question first, then one confirmation, then an unattended
  install; 9b in two commits, the screens (9b1) before the partition editor (9b2); the network
  step tries its settings on the medium there and then; the keys are `dialog(1)`'s plus F1 for
  help and F10 for a shell, from any dialog. The clock question gets real support: a CMOS clock
  keeping local time (`TIMEZONE.md` §4.3), suggested when Windows is on the machine.

- 2026-10-23 (user), step 9c: installing beside is said both ways -- `BESIDE`/`WHOLE` outright,
  and a disk alone (or `DEFAULT`) choosing by whether it has a table, so an answer file erases a
  disk only when it says so; installed systems name partitions by `/dev/gptid/<guid>`, always;
  on BIOS Limine's boot code always replaces the disk's (no confirmation), its menu chainloading
  the others; the loader scan covers Windows, shim/GRUB, systemd-boot, other Limines and any
  other `\EFI\<dir>`'s `.efi`.

- 2026-10-23 (user): the screens use the "true rust" palette (cream dialogs, copper titles,
  burnt-orange selection on iron oxide), set through Linux's `ESC ] P` palette escape, which the
  console now draws; OxideBSD's own 16-colour `rust` palette is an option for the whole console
  (`wsconsctl display.palette=rust`), off by default. Users are optional, with a warning if none
  is made, so a machine can be installed for an OEM-style setup on its first boot (a later
  program, not yet designed). 9c's NVRAM boot entry (`EFIRT.md`) comes before 9b's screens, so
  installing beside another system works fully when the screens land.

- 2026-10-23 (user): step 9 lands engine first (9a `installer -f`, 9b screens, 9c dual boot).
  The answer file is FreeBSD's `installerconfig`. A guided layout beside the editor, built to
  make dual booting painless (§9.5, §9.6). The screens are bsdinstall-style dialogs in rust
  colours. On UEFI, a real NVRAM boot entry through UEFI runtime services and `efibootmgr`, and
  Limine's menu chainloads the other systems it detects.

- 2026-10-22 (user): the kernel rereads a changed table both on an ioctl and on a writer's last
  close; step 8 also builds `/sbin/gpart` over libpart.

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
