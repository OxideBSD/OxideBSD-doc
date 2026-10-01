# OxideBSD floppy installer and El Torito boot: design specification

Status: **draft, not yet reviewed** (2026-09-30). Not scheduled for a release.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. It depends on `INIT.md` (the installer runs as init's single-user shell), `UNIX.md`
(the network stack) and `hier(7)` (what is installed where).

## 1. Scope

A network installer that fits on one 1.44 MB floppy: it boots, brings up a network interface,
downloads the system's file sets, verifies them, and installs them on a disk. The same image
also boots from a CD as an El Torito image, under BIOS and under UEFI. It is OxideBSD's
equivalent of OpenBSD's `floppy*.img` with `bsd.rd`.

## 2. The image

2.1. The image is a 1,474,560-byte FAT12 floppy (80 cylinders, 2 heads, 18 sectors). Its boot
sector holds the BIOS parameter block, as any FAT12 floppy's does, and OxideBSD's first-stage
loader in place of DOS's boot code.

2.2. It holds three files:

| File | Contents |
|---|---|
| `/LOADER.SYS` | The BIOS second stage (§3.2) |
| `/EFI/BOOT/BOOTX64.EFI` | The UEFI loader (§3.3), at most 4,096 bytes |
| `/OXIDEBSD.XZ` | The payload: the decompressor, the kernel and its ramdisk, compressed (§4) |

2.3. **El Torito.** The CD image (about 1.5 MB) is an ISO 9660 file system whose boot catalog has
two entries that both name the floppy image:

| Entry | Platform | Emulation | Started by |
|---|---|---|---|
| Initial/default | x86 BIOS (0) | 1.44 MB floppy | The BIOS, which presents the image as drive `0x00` |
| Section, one entry | EFI (`0xEF`) | none | UEFI firmware, which reads the image as a FAT file system |

Under BIOS the firmware emulates a floppy, so the floppy's own boot code runs unchanged. Under
UEFI the firmware mounts the same image as FAT and runs `\EFI\BOOT\BOOTX64.EFI`. One image, two
ways in; nothing in it knows whether it is on a floppy or a CD.

2.4. The image SHOULD also boot written raw to a USB stick (a "superfloppy" with no partition
table): BIOSes boot it as a floppy or a hard disk, and UEFI firmware generally reads a
partitionless FAT device.

## 3. Loaders

3.1. Both loaders end the same way: the payload is in memory, the machine is in 64-bit long
mode with interrupts off, and control passes to the decompressor's entry point (§4.1) with a
pointer to a **handoff block** in a register. The handoff block carries exactly what the kernel
otherwise takes from Limine (`sys/boot/mod.rs`):

| Field | BIOS source | UEFI source |
|---|---|---|
| Memory map | `int 15h, eax=E820h` | `GetMemoryMap` |
| Framebuffer (address, size, pitch, depth, colour masks) | VBE `int 10h, ax=4F0xh` | Graphics Output Protocol |
| ACPI RSDP | scan of the EBDA and `0xE0000`-`0xFFFFF` | the configuration table |
| Command line | fixed in the image (§5.3) | fixed in the image |
| Payload address and size | where stage 2 loaded it | where `BOOTX64.EFI` loaded it |

The direct-map offset is the decompressor's to choose (§4.2), not the loader's.

3.2. **BIOS.** The boot sector (512 bytes) reads `/LOADER.SYS` with `int 13h` and jumps to it.
Stage 2 finds `/OXIDEBSD.XZ` through the FAT12 root directory and file allocation table, reads
it into memory above 1 MiB (through unreal mode or bounce buffers below 1 MiB), fills in the
handoff block, enables A20, builds identity page tables, enters long mode, and jumps. It SHOULD
fit in 8 KB.

3.3. **UEFI.** `BOOTX64.EFI` MUST be at most 4,096 bytes, PE32+ included. It opens its own volume
(`LoadedImage` → `SimpleFileSystem`), reads `\OXIDEBSD.XZ` into pages from `AllocatePages`,
fills in the handoff block from GOP and the configuration table, calls `ExitBootServices`
(fetching the memory map again and retrying while the map key is stale), and jumps. It does
nothing else: it never decompresses or parses the kernel. It MAY be written in `no_std` Rust
(`opt-level = "z"`, `panic = "abort"`) or in assembly; whichever meets the limit.

3.4. Neither loader drives the floppy once the payload is read, and the kernel has no floppy
driver: as with OpenBSD's floppies, after boot the medium can be removed.

## 4. The payload

4.1. `/OXIDEBSD.XZ` is a small uncompressed **decompressor**, followed by the kernel and its
ramdisk compressed with xz (LZMA2). The decompressor is position-independent, runs in long mode
on the loaders' identity map, and:
1. decompresses the kernel into free memory taken from the handoff block's memory map;
2. builds the kernel's page tables: the kernel at its higher-half link address, and a direct map
   of all physical memory at the offset Limine would give (`physical_memory_offset`);
3. marks the memory it used in the map as reserved for the kernel, and jumps to the kernel's
   native entry point (§4.3) with the handoff block.

4.2. **Why xz.** Measured on OxideBSD's own binaries, xz is about 20% smaller than gzip (the
kernel's code and data: 270 KB with gzip, 212 KB with xz); a minimal LZMA2 decoder is a few
kilobytes more code than an inflate, which the saving repays many times over. The decompressor
is shared by both loaders, so the 4 KB limit doesn't apply to it.

4.3. **The kernel** gains a third boot path beside Limine and Multiboot2 (`sys/boot/native.rs`):
an entry point that takes the handoff block and builds the same `BootInfo` and `FbInfo` the other
two build. It is built in an installer configuration:
- no embedded system: oxfs embeds only the installer's files (the ramdisk, §5.1), not the
  300 MB of the normal image;
- only the modules the installer uses;
- the drivers the installer needs (§6.2) and no others.

## 5. The ramdisk

5.1. The ramdisk is oxfs's embedded image, as in every OxideBSD kernel, with only the installer's
files: oxfs already seeds its tree from images in the kernel, so a kernel that embeds little
*is* a ramdisk kernel. Nothing is written back to a disk (`no-disk`).

5.2. **One crunched binary.** Every installer tool is one static Rust program, `/instbin`, with
a link for each name, choosing its function by `argv[0]` (FreeBSD's `crunchgen`, OpenBSD's
`instbin`). A Rust program carries its own copy of `std`, which dominates small programs (a
stripped `/sbin/init` is 338 KB, 127 KB with xz): separate binaries would not fit, one binary
pays for `std` once. It is built with `opt-level = "z"`, link-time optimisation and
`panic = "abort"`, and stripped.

5.3. The kernel command line is fixed in the image and includes `-s`, so init (`INIT.md`) runs
no `/etc/rc` and starts the shell, whose profile starts the installer.

## 6. Installing

6.1. **Steps.** The installer, in order:
1. asks for a keyboard layout and a host name;
2. configures a network interface: DHCP, or an address, mask, gateway and name server typed in;
3. asks for a mirror (default `http://oxidebsd.org/pub/<release>/amd64/`; plain HTTP, §6.3)
   and fetches `SHA256.sig`;
4. asks for the target disk, partitions it (GPT, with an EFI system partition, or MBR), makes the
   file system (`newfs`) and mounts it;
5. fetches each chosen set (`base.tgz`, `man.tgz`, `comp.tgz`, ...), checks its SHA-256 against
   the verified `SHA256.sig`, and extracts it;
6. writes `/etc/fstab`, `/etc/rc.conf` (host name, network), `/etc/localtime`, and root's
   password in `/etc/master.passwd`;
7. installs the boot loader on the target disk;
8. offers to reboot.

6.2. **What OxideBSD lacks for this today**, each needed for more than the installer:
- interface configuration ioctls and a DHCP client (interfaces are static now);
- network drivers beyond the rtl8139: at least e1000 and virtio-net;
- `newfs` (and `fsck`) for oxfs, and a partitioning tool;
- native `tar` and gzip (on the BusyBox rewrite list);
- a release process that builds the sets and signs `SHA256`;
- the loaders, the decompressor and the kernel's native boot path (§§3-4).

6.3. **Trust without TLS.** OpenSSL is megabytes and cannot be on the floppy. The sets are
fetched over plain HTTP and verified as OpenBSD's are: `SHA256.sig` is a list of SHA-256 sums
signed with Ed25519 (`signify` format), and the release's public key is in the image. An
Ed25519 verifier and SHA-256 are a few kilobytes. A set whose sum doesn't match MUST NOT be
extracted.

## 7. Modern hardware

7.1. **USB floppy drives.** A USB floppy drive is a mass-storage device of subclass UFI, which
UEFI firmware built on EDK2 supports, as it supports FAT12. On removable media without a
partition table, UEFI treats the whole device as one volume and runs
`\EFI\BOOT\BOOTX64.EFI` from it (§2.4). Because the UEFI loader reads the payload through the
firmware's `SimpleFileSystem` and the kernel never touches the medium after
`ExitBootServices` (§3.4), OxideBSD needs no USB floppy driver of its own. Some firmware hides
the drive outside its one-time boot menu. A USB floppy reads at roughly 30-60 KB/s, so the
payload loads in 10-20 seconds.

7.2. **Secure Boot.** An unsigned `BOOTX64.EFI` does not run while Secure Boot is on; the user
turns it off. Signed boot (a `shim` and a vendor certificate) is outside this specification.

7.3. **Drivers the installer needs there.** On machines of the last decade the installer finds
nothing to install to and nothing to download through unless OxideBSD has, besides those of
§6.2:
- **NVMe** and **AHCI** (SATA) for the target disk; OxideBSD has virtio-blk and IDE only;
- network drivers for the common on-board chips (Intel I219/I225, Realtek RTL8111/8125), not
  only e1000 and virtio-net.

The xHCI keyboard driver and the GOP framebuffer already cover input and display.

7.4. QEMU cannot emulate a USB UFI drive. The partitionless-FAT path is tested with the image as
a USB stick under OVMF (§9.1); the USB floppy path itself only on real hardware.

## 8. Budget

Measured on 2026-09-30 builds where marked; the rest are estimates.

| Part | Size | |
|---|---|---|
| Boot sector, FAT12 tables, root directory | 15 KB | fixed by the format |
| `/LOADER.SYS` | ≤ 8 KB | target |
| `/EFI/BOOT/BOOTX64.EFI` | ≤ 4 KB | limit |
| Decompressor | about 20 KB | estimate |
| Kernel and modules, xz | about 250 KB | 212 KB measured for the kernel's code and data, plus modules |
| Ramdisk, xz | 250-350 KB | estimate for the crunched binary and the installer's files |
| **Total** | **about 0.6 MB** | of 1.44 MB |

The room left is for network drivers. For comparison, Limine's BIOS stage alone is 331 KB.

## 9. Verification

9.1. QEMU, all four ways in: `-fda` with SeaBIOS; `-cdrom` with SeaBIOS (El Torito floppy
emulation); `-cdrom` with OVMF (El Torito EFI); and the raw image as a USB disk with OVMF.

9.2. A test MUST fail the build if `BOOTX64.EFI` exceeds 4,096 bytes or the image exceeds
1,474,560 bytes.

9.3. An install into a blank QEMU disk from a local HTTP mirror, followed by a boot of the
installed system.

## 10. Open questions

1. PXE: Limine's PXE stage is 23 KB; the same payload booted over the network would be a
   netinstall for machines without a floppy or CD drive. Use Limine there, or a native PXE
   loader?
2. The boot loader installed on the target disk: Limine, as the ISO uses, or these loaders
   grown into a full one?
3. Whether the installer itself is an `init_sh` script or part of `/instbin`.
4. A serial-console variant of the image, for machines without a display.
