# UEFI runtime services: design specification

Status: **accepted** (2026-10-23), with the user's answers (§11). Asked for by `INSTALLER.md`
§9.6 (step 9c): the installer adds an `OxideBSD` boot entry to the firmware's NVRAM so a dual-boot
install boots without taking over another system's files.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Motivation

On UEFI the firmware boots what its NVRAM boot entries name (`Boot####`, in `BootOrder`), and
only when none works, the removable-media path `\EFI\BOOT\BOOTX64.EFI`. A blank disk can rely on
that path (step 9a does). A disk that already holds Windows or Linux can't: the path belongs to
whoever installed first, Windows rewrites it on updates, and taking it hides the other system
behind Limine. Every other OS's installer (FreeBSD's `bsdinstall` through `efibootmgr(8)`,
Windows', Linux's `efibootmgr`) adds an NVRAM entry of its own instead.

NVRAM is reached through the UEFI **runtime services** (`GetVariable`, `SetVariable`,
`GetNextVariableName`, ...), firmware code that stays in memory after `ExitBootServices`. The
kernel doesn't call them today.

## 2. Terms

- **Runtime services**: the UEFI functions callable after boot (UEFI 2.10 §8): variables, time,
  reset, capsules. This design uses the variable ones and, optionally, `ResetSystem`.
- **Runtime regions**: the EFI memory map's descriptors with `EFI_MEMORY_RUNTIME`: the services'
  code and data, which the firmware expects at their physical addresses unless
  `SetVirtualAddressMap` moved them.
- **EFI page table**: a page table of the kernel's own, used only during a runtime call (§4).

## 3. What Limine gives

At this kernel's base revision (`BaseRevision::MAX_SUPPORTED`, 6; Limine's `PROTOCOL.md`):

- the **EFI system table** (`LIMINE_EFI_SYSTEM_TABLE_REQUEST`), as an HHDM address, and the table,
  its runtime services table, configuration tables and vendor string mapped and reported as
  `RESERVED_MAPPED`;
- the **EFI memory map** (`LIMINE_EFI_MEMMAP_REQUEST`), in bootloader-reclaimable memory: copied
  by `boot::snapshot` before `memory::reclaim_bootloader_memory` (CLAUDE.md);
- the runtime regions as `RESERVED_MAPPED`: never handed to the frame allocator, and reachable
  through the HHDM;
- no `SetVirtualAddressMap` call: the services still run at their physical addresses.

Under BIOS, or Multiboot2, there's no response, and nothing here exists (§7).

## 4. Calling the firmware

4.1. **One-to-one mapping, no `SetVirtualAddressMap`** (FreeBSD's `efirt` on amd64, OpenBSD's
`efi`; decided §11). At boot the kernel builds the EFI page table: the kernel's own upper
half (shared, as every address space's is) and, in the lower half, every runtime region mapped at
its physical address. Code regions are mapped read-only and executable, data regions writable and
`NO_EXECUTE`, using the firmware's `EFI_MEMORY_ATTRIBUTES_TABLE` (a configuration table) where it
gives finer attributes; with neither, a code region is writable and executable, logged, as
Linux and FreeBSD allow for old firmware. The table's lower half is supervisor-only, so SMEP and
SMAP hold during the call. It is never the CR3 of any process.

4.2. **A call** (`efirt::call`): under the runtime lock (one call at a time, as the specification
requires), interrupts off, the current FPU/SSE state saved (`FXSAVE`: the firmware uses SSE, which
the kernel itself never does, and the interrupted process's registers are live), CR3 switched to
the EFI page table (PCID 0, flushed), the service called through an `extern "efiapi"` pointer
(the Microsoft x64 convention) on the current kernel stack (at least 128 KiB, CLAUDE.md), then CR3
and the FPU state restored. A fault inside the firmware is caught by a recovery point set before
the call: the call fails with `EFAULT`, runtime services are switched off for the rest of the boot,
and the kernel keeps running (Linux's `efi_crash_gracefully_on_page_fault`).

4.3. KPTI (`cpu::pti`): the EFI page table maps the full kernel half, so no entry-area rules apply;
an NMI during the call runs on it, and takes no locks (CLAUDE.md).

4.4. The kernel MUST NOT call a runtime service from interrupt context or holding a spin lock;
a call may take milliseconds (a flash write).

## 5. The interface: `/dev/efi`

5.1. The kernel (`sys/efirt.rs`), when the firmware has runtime services, registers the device
`/dev/efi` (`make_dev`, (7, 2), mode 0600 root), beside the calls, as `/dev/devctl` is beside
its queue. (A module was planned; none makes a device yet, and one would have needed a kernel
export per call as well as the copy routines.) Its ioctls (OxideBSD's numbers, FreeBSD's
shapes, `efi(4)`):

| Request | Does |
|---|---|
| `EFIIOC_VAR_GET` | `GetVariable(name, guid)` into the caller's buffer, with its attributes |
| `EFIIOC_VAR_NEXT` | `GetNextVariableName`: walks every variable |
| `EFIIOC_VAR_SET` | `SetVariable(name, guid, attributes, data)`; empty data deletes |
| `EFIIOC_GET_TABLE` | a configuration table's GUID and address (for `efitable(8)`, later) |

5.2. **Writing is limited** (decided §11): by default `EFIIOC_VAR_SET` takes only the
variables a boot manager edits: `Boot####`, `BootOrder`, `BootNext`, `Timeout`, `Driver####`,
`DriverOrder` and `OsIndications` under the EFI global GUID, and anything under OxideBSD's own vendor GUID. Others are refused with
`EPERM` unless the sysctl `machdep.efi.unsafe_writes` is 1. Some firmware has bricked machines on
writes it didn't expect (Samsung laptops, 2013), and a determination beast with root could
otherwise wipe the platform keys.

5.3. sysctls: `machdep.efi.runtime` (1 when the services are usable), `machdep.efi.vendor`,
`machdep.efi.revision`.

## 6. The tools

6.1. `efivar(8)` (FreeBSD's options): list, print and set variables by name and GUID.

6.2. `efibootmgr(8)` (FreeBSD's options and output): show `BootOrder`, `BootCurrent`, `BootNext`
and each `Boot####`; create an entry (`-c -l <loader path on an ESP> -L <label>`) from a device
path built from the ESP's GPT partition GUID, its start and size (`HD(...)/File(\EFI\...)`), as
FreeBSD's `efivar_unix_path_to_device_path` does; activate, deactivate, delete, reorder, set
`BootNext` and the timeout. Device paths are parsed and printed by a library,
`lib/libefivar` (no_std, host-tested against FreeBSD's examples).

6.3. The installer (step 9c) runs `efibootmgr -c -a -l /boot/efi/EFI/OxideBSD/BOOTX64.EFI -L
OxideBSD`, putting the entry first in `BootOrder`; it leaves the other entries in place. It
copies Limine to `\EFI\OxideBSD\` and never writes `\EFI\BOOT\` on a disk with another system.

## 7. Without UEFI

Under BIOS (or Multiboot2) the module doesn't load and `/dev/efi` doesn't exist; `efibootmgr`
says so and exits 1; the installer uses the BIOS path (§8.4 of `INSTALLER.md`).

## 8. Testing

8.1. QEMU with OVMF in two flash devices (`OVMF_CODE.4m.fd` read-only, a copy of
`OVMF_VARS.4m.fd` writable) instead of today's single `-bios` image, so variables persist across
a reboot. The runner gains `QEMU_UEFI_VARS=<file>` for the tests that need it.

8.2. `efirt_syscall_smoke`: lists the variables (OVMF's `Boot####`, `BootOrder`, `Lang`), reads
one, writes and deletes one under OxideBSD's GUID, checks a write outside the allowed set is
refused, and that `efibootmgr -c` makes an entry `efibootmgr` then shows.

8.3. Step 9c's test installs beside a disk with an existing ESP and partition, reboots with the
same VARS file, and checks the firmware boots OxideBSD from the new entry (its `BootCurrent`).

8.4. A real-hardware check on the Mac mini and the ThinkPad before 9c is called done: firmware
differs more here than anywhere else.

## 9. Reset

`ResetSystem` is a fallback only (decided §11): reboot and power-off stay ACPI's (and the
keyboard controller's); on a UEFI machine where those return, `reboot(2)` calls
`ResetSystem(EfiResetCold)` or `EfiResetShutdown` before giving up.

## 10. Steps

Each step its own commit, the suite and the POSIX canary green.

1. The EFI system table and memory map snapshotted; the EFI page table built; `efirt::call` with
   the fault recovery; `GetTime` called once at boot and logged as the first proof; the
   `ResetSystem` fallback (§9).
2. `/dev/efi`; `efivar(8)`; the OVMF VARS runner support; the smoke test.
3. `lib/libefivar` and `efibootmgr(8)`.
4. The installer's use of it (`INSTALLER.md` step 9c).

Progress: step 1 done (2026-10-23): `sys/efirt.rs`; the boot snapshot keeps the system table and
memory map; the EFI page table maps the runtime regions with the memory attributes table's
attributes (OVMF: 838 pages, none writable and executable); `efirt_call` (Microsoft x64, a
recovery point) and `fixup_fault`, which the page fault and exception handlers ask first;
`GetTime` logged at boot; `ResetSystem` after the keyboard controller's reset and ACPI's S5.
`efirt_smoke` checks the clock and a caught fault. The reset fallback is untested: ACPI works
under QEMU, so it never runs there.
Step 2 done (2026-10-23): the variable calls, `/dev/efi` (`EFIIOC_VAR_GET`/`NEXT`/`SET`,
`EFIIOC_GET_TIME`; `efi(4)`), the allow-list and `machdep.efi.*`; `efivar(8)`; the runner's
`QEMU_UEFI_VARS` (OVMF's code and a variable store copy as two flash devices);
`efirt_syscall_smoke` runs `efivar` through listing, printing, writing, appending, deleting, a
refused write and `unsafe_writes`. OxideBSD's vendor GUID is
`916e441e-ead7-4301-9aaf-6e0ba5a85339`.
Step 3 done (2026-10-23): `lib/libefivar` (GUIDs, device paths both as bytes and in the
specification's text form, `EFI_LOAD_OPTION`, the `/dev/efi` calls), host-tested with hostile
input; `efivar -d` and `--load-option`; `efibootmgr(8)` with FreeBSD's options and output (`-k`
and `-e`, for FreeBSD's loader, refused). `-c` finds the loader's mount, its partition (by its
node's device number, or a `/dev/gpt/<label>` mount by the GPT name: the label node is a device
of its own) and its GPT entry, and builds `HD(...)/File(...)`. `OsIndications` joined the write
allow-list for `-f`/`-F`. `efirt_syscall_smoke` gained a disk with an empty ESP and runs
`efibootmgr` through making, listing, deactivating, `BootNext`, the timeout, `-f`/`-F`, reordering
and deleting an entry: 34 checks.

## 11. Decisions

- 2026-10-23 (user): the firmware runs in a one-to-one page table of its own, with no
  `SetVirtualAddressMap` (§4.1); userland reaches it through `/dev/efi` ioctls, FreeBSD's shape,
  with `efivar(8)` and `efibootmgr(8)` (§5, §6); writes are limited to the boot manager's
  variables and OxideBSD's unless `machdep.efi.unsafe_writes` (§5.2); `ResetSystem` only when ACPI
  reset or power-off fails (§9).
