# OxideBSD per-process address-space map: design specification

Status: **accepted** (2026-10-17), with the user's answers to the open questions (§13).
Asked for by `CLEANUP.md` §3 (`RLIMIT_AS`) and §7 (`MAP_FIXED` region splitting).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Motivation

What the kernel knows about a process's user address space today (`sys/process/mm.rs`,
verified against `f075a86`):

- Anonymous `mmap` takes its address from **one system-wide bump pointer**
  (`mm::NEXT_MMAP_PAGE`, a 16 TiB window): every process's mappings come out of the same
  counter, and an address is never handed out again after `munmap`. SysV `shmat` has a second
  one (`sysv_shm::NEXT_SHM_PAGE`).
- Anonymous memory is **allocated whole when mapped**: `mmap(1 GiB)` takes 262144 frames at
  once or fails. Programs that reserve large regions and touch little of them (allocator arenas,
  thread stacks, language runtimes) pay for all of it, against the 64 MB rule.
- `PROT_NONE` maps nothing and records nothing; `mprotect` later "reifies" it by guessing.
- The only regions recorded are file mappings (`MmapFileRegion`) and `/dev/fb0`
  (`MmapPhysRegion`), found by their **exact start address**: `munmap` of part of one, or
  `MAP_FIXED` over part of one, leaves the record whole (`CLEANUP.md` §7).
- Nothing can say how much address space a process uses (`RLIMIT_AS`), list its mappings
  (`/proc/<pid>/map`, `procstat -v`), or write them to a core file (`CLEANUP.md` §3).

Every BSD keeps a map of regions per address space (FreeBSD's and OpenBSD's `vm_map`, NetBSD's
UVM `vm_map`), and the page tables are only a cache of it (the `pmap`). This specification does
the same.

## 2. Terms

- **Map**: one address space's list of entries (`VmMap`, in `mm::VmState`, shared by
  everything sharing the page tables: threads and a vfork child, as `VmState` already is).
- **Entry**: a page-aligned, non-empty range `[start, end)` with a protection, a maximum
  protection, an inheritance and a backing kind (§3.2).
- **Resident**: an entry's page that has a frame (or a `FILE_LEAF`) in the page tables.

## 3. The map

3.1. The map MUST be a `BTreeMap<u64, VmEntry>` keyed by start address. Entries MUST be
disjoint, page-aligned and non-empty; adjacent entries MAY be merged when every field matches
(FreeBSD's `vm_map_simplify_entry`), and MUST be split where an operation's range begins or
ends inside one.

3.2. An entry is

```rust
struct VmEntry {
    end: u64,
    prot: Prot,          // PROT_READ | PROT_WRITE | PROT_EXEC
    max_prot: Prot,      // what mprotect may raise prot to
    shared: bool,        // MAP_SHARED: fork shares it; else fork copies it (copy-on-write)
    kind: VmKind,
    wired: bool,         // mlock'd
}

enum VmKind {
    Anon,                                  // zero-filled on first touch (§5)
    File { vnode: u64, page: u64, eof_page: u64 }, // a file at page offset `page`; past
                                           // `eof_page`, SIGBUS (POSIX MPR)
    Phys { base: u64 },                    // device memory (/dev/fb0), never RAM
    Shm { shmid: i32 },                    // a SysV segment's frames
    Stack,                                 // the main thread's stack: grows down (§6)
    Heap,                                  // the break (brk)
    Text { vnode: u64, page: u64 },        // a PT_LOAD segment of the program or its
                                           // interpreter (private, page cache backed)
    Kernel,                                // the fault trampoline and its scratch page:
                                           // never unmapped, counted, dumped or listed
}
```

`max_prot` follows FreeBSD: a `MAP_SHARED` mapping of a file opened read-only has no
`PROT_WRITE` in it, nor does a `Text` entry; anonymous memory has all three, and W^X (§9) is
checked on top.

3.3. **The map is the authority.** A user page-table entry MUST lie inside an entry whose `prot`
allows what the PTE allows. A debug audit (`memory::wx`'s style) SHOULD check this at fork and
at exit when `debug.vm.audit=1`.

3.4. The map's `size` (the sum of entry lengths, `Kernel` excluded, the stack counted as far as
it has grown) MUST be kept up to date by every operation that changes the map: it is what
`RLIMIT_AS` and `vm.stats`-style reporting read.

## 4. Choosing addresses

4.1. Each exec picks a random **mmap base** inside the mmap window `[MMAP_REGION_BASE,
MMAP_REGION_CEILING)` (`process::aslr`, page-aligned, as the PIE bias is). `mmap` without
`MAP_FIXED` and `shmat` without an address MUST then allocate the **first free gap at or above**
the hint, or above the mmap base when the hint is zero or unusable, bottom-up (FreeBSD's
`vm_map_find` with `VMFS_ANY_SPACE`); wrapping to the window's bottom when nothing above fits.

4.2. An address freed by `munmap` or `shmdt` MUST be usable again by that process.
`NEXT_MMAP_PAGE` and `NEXT_SHM_PAGE` are removed; SysV segments map from the same window.

4.3. `MAP_FIXED|MAP_EXCL` (FreeBSD's) MUST fail with `EINVAL` when its range overlaps an entry,
instead of replacing it; musl's `MAP_FIXED_NOREPLACE` is accepted as the same request (with
`EEXIST`, its documented error). Otherwise `MAP_FIXED` MUST replace whatever entries (or parts of entries) its range overlaps, as one
operation: the old pages go as `munmap` would make them go (§7), then the new entry is
inserted. `MAP_FIXED` over a `Kernel` entry MUST fail with `EINVAL`.

## 5. Anonymous memory on demand

5.1. `mmap(MAP_ANON)` and `brk` MUST NOT allocate frames: they insert or grow an entry only.
The first touch of a page in an `Anon` or `Heap` entry whose `prot` allows the access faults;
the fault handler finds the entry (§5.3) and maps a zeroed frame, from ring 3 or from a copy
routine in ring 0, as stack growth does today.

5.2. `mlock`, `mlockall(MCL_CURRENT|MCL_FUTURE)` and `MAP_POPULATE` (if added) fill the range
when called; `wired` entries are never left non-resident. `MAP_NORESERVE` changes nothing: memory
is overcommitted, and the OOM killer (`COW.md` §6) takes over when frames run out.

5.3. **The fault never waits.** The handler reads the map of the running address space through
a pointer the scheduler sets at each switch (as `mm::STACK_LIMIT` is today), with `try_lock` on
`VmState`. Therefore code holding the `VmState` lock MUST NOT copy to or from user memory; an
audit of every `.vm()` user is part of step 1 (§11). A fault that finds the lock taken anyway
is a kernel bug, reported as one (`[vm] fault with the map locked`), and fails like an unmapped
access.

5.4. `PROT_NONE` is an entry with no access: a touch is `SIGSEGV`. `mprotect` raising it makes
later touches fault in normally; no reifying guess is left.

## 6. The stack

6.1. Exec inserts one `Stack` entry covering the eagerly mapped top (`lifecycle::
user_stack_eager_pages`), and reserves the gap below it down to `USER_STACK_TOP -
USER_STACK_RESERVE` for growth: no other entry may be placed there (FreeBSD's stack guard,
`stack_guard_page` and `MAP_STACK` reservation). A fault in the reserve, within `RLIMIT_STACK`
and `RLIMIT_AS`, grows the entry down to the faulting page (`mm::try_grow_user_stack`).

6.2. Thread stacks are ordinary `Anon` entries from `mmap` (`MAP_STACK` is accepted and changes
nothing).

## 7. Removing and changing

7.1. `munmap(addr, len)` MUST remove exactly the pages in its range from every entry it
touches, splitting entries at both ends. Resident private frames go through `refs::release`;
`File` pages that are dirty and shared are written back first; a `File` or `Text` piece keeps
its own reference on the vnode (a split takes one more). `munmap` of a range with nothing mapped
succeeds (POSIX).

7.2. `mprotect(addr, len, prot)` MUST fail with `ENOMEM` if any page in the range is outside
every entry, and with `EACCES` if `prot` exceeds any entry's `max_prot`, changing nothing in
either case; otherwise it splits at both ends, sets `prot` and updates resident PTEs.

7.3. `msync` and `mincore` work by range over the entries.

## 8. Fork, exec, vfork, exit

8.1. Fork copies the map: a `shared` entry stays shared (the same frames, or the same file
pages), a private one is copied entry for entry and its resident frames become copy-on-write
(`COW.md` §3, unchanged). `wired` is not inherited (POSIX `mlock`).

8.2. Exec starts a new map; vfork shares the parent's (`VmState` is already shared); exit drops
it with the address space.

## 9. Limits and reporting

9.1. `RLIMIT_AS`: `mmap`, `shmat`, `brk` and stack growth MUST fail (`ENOMEM`, or `SIGSEGV` for
stack growth) when the map's `size` would pass the soft limit.

9.2. `RLIMIT_DATA` stays what it is (`brk` past the break's start; `CLEANUP.md` §8), as on
FreeBSD.

9.3. W^X (`THREAT_MODEL.md` §3.3) is checked against `prot` when an entry is made or changed,
as now.

9.4. `/proc/<pid>/map` lists the entries, one line each, in FreeBSD procfs's `map` format:
start, end, resident pages, private resident pages, object, protection, reference counts,
copy-on-write and need-copy flags, type (`default`/`vnode`/`phys`/`swap`), and the vnode's path
where the name cache knows it. `/proc/<pid>/maps` lists the same entries in Linux's format
(`start-end perms offset dev inode path`), for ported tools that parse it. `RLIMIT_AS`'s measure
is reported as `vsz` by `ps`.

## 10. Core dumps

Core dumps (`CLEANUP.md` §3, decided 2026-10-17: ELF `ET_CORE`) write one `PT_LOAD` per entry
that is readable and not `Kernel` or `Phys`, with file size zero for pages never touched; they
are specified separately and come after this.

## 11. Steps

Each step its own commit, the suite and the POSIX canary green, `ram_floor_boot` passing.

1. **Record.** The map exists and records every mapping made today (exec segments, stack, brk,
   anonymous, file, `/dev/fb0`, SysV, the trampoline), with the debug audit (§3.3); behaviour
   unchanged. Audit of `VmState` lock holders against §5.3.
2. **Allocate.** Per-process addresses (§4); `munmap`/`mprotect`/`MAP_FIXED` by range with
   splitting (§7); `MmapFileRegion`/`MmapPhysRegion` folded into entries. Closes the
   `MAP_FIXED` row.
3. **On demand.** Anonymous memory and `brk` zero-filled on first touch (§5); `PROT_NONE`
   entries; `mprotect`'s reifying removed.
4. **Limits.** `RLIMIT_AS` (§9.1), `/proc/<pid>/map`, `ps`'s `vsz`.

## 12. Verification

- A `vm` section in `regress/kern-smoke` (run by `tests/kern_syscall_smoke.rs`): address reuse
  after `munmap`, partial `munmap` and `mprotect` splitting, `MAP_FIXED` over part of a file
  mapping (`SIGSEGV` not `SIGBUS` after it), `mprotect` errors (`ENOMEM`, `EACCES`), a 1 GiB
  anonymous mapping costing nothing until touched, `RLIMIT_AS` on `mmap`, `brk` and the stack,
  `/proc/self/map` against what was mapped.
- The POSIX canary and the full suite unchanged or better; `ram_floor_boot` at 64 MB with
  more free memory after boot than before (anonymous memory no longer allocated up front).

## 13. Open questions

None left (§14).

## 14. Decisions

- 2026-10-17 (user): a real per-address-space map, not a mapped-bytes counter; spec first.
- 2026-10-17 (user): both `/proc/<pid>/map` (FreeBSD) and `/proc/<pid>/maps` (Linux) now (§9.4);
  bottom-up first fit from a random base, with `MAP_EXCL` and `MAP_FIXED_NOREPLACE` (§4); SysV
  `shmat` folded into the mmap window (§4.2).
