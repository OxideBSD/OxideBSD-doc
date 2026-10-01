# OxideBSD read-only page cache: design specification

Status: **implemented** (2026-10-01, `sys/memory/pagecache.rs`). Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Scope and motivation

Every `execve` copies the whole program into fresh pages, and every library `ld.so` maps with
`MAP_PRIVATE` is copied again. Measured with `debug.syscall.stats` (2026-09-30): bmake's
`configure` on target spends 13 of its 29 seconds in `execve`, almost all of it copying `clang`
(73 MB) and `ld.lld` into memory, about 300 times over. This specification adds a cache of
file pages that read-only mappings share instead of copying: each page of a program's code and
read-only data is read and copied once, then mapped into every process that runs it.

Out of scope: writable private mappings (copy-on-write needs fault handling that doesn't exist);
`MAP_SHARED` mappings, which keep their own cache (`mm::MMAP_FILE_CACHE`, written back to the
file); demand paging (cached pages are filled when mapped, not on first touch).

## 2. The cache

2.1. An **entry** is one file: its content id (the oxfs inode number, `fd::content_id_of`), its
size when the entry was made, and one physical frame per file page, each filled on first use
with that page of the file (zero beyond the end of the file).

2.2. An entry has a **use count**: the number of address spaces that map, or have mapped, any of
its frames. An address space records the entries it uses (`AddressSpace::cached`), and `fork`
copies that list and increments each count; teardown decrements. A count may overstate (a range
`munmap`ed still counts until teardown); it never understates.

2.3. Cached frames are mapped **without `WRITABLE`** and with `SHARED_LEAF`, so that teardown
doesn't free them and `fork` aliases them instead of copying (both as for SysV shared memory),
and with `CACHED_LEAF` (PTE bit 10), which tells `mprotect` a page is the cache's rather than a
`MAP_SHARED` or SysV page (3.2). Frames are freed only when their entry is no longer in the cache
and its use count is 0.

2.3.1. The kernel runs with `CR0.WP` set, so a system call writing through a user pointer into a
cached page faults instead of changing every process's copy.

2.4. **Invalidation.** oxfs MUST call the kernel's `oxidebsd_content_changed(inode)` whenever an
inode's contents change (a write, a truncation) or the inode is freed. The entry for that inode,
if any, leaves the cache at once: later execs and mappings read the new contents; processes
already running keep the pages they mapped, until they exit. A lookup also checks the size
recorded in 2.1.

2.5. **Size.** The cache MUST NOT hold more than a quarter of physical memory in entries no
address space uses. Past that, unused entries are freed, least recently used first. Entries in
use are never freed.

## 3. Users

3.1. **`execve`**, for the program and its interpreter. A `PT_LOAD` segment without `PF_W` maps
from the cache every page it covers that no other `PT_LOAD` segment touches and whose file
offset and virtual address agree modulo the page size; a page shared with a writable segment,
and every page of a writable segment, is copied as before. `execve` reads only what it copies,
and the ELF headers, rather than the whole file.

3.2. **`mmap` with `MAP_PRIVATE` and without `PROT_WRITE`** of a regular file maps its pages from
the cache. `mprotect` adding `PROT_WRITE` to such a page MUST first replace it with a private copy
(made at that moment; there is no copy-on-write fault).

3.3. Position-independent programs and libraries share pages whatever their load address:
relocations are applied by `ld.so`, to writable pages only. A program with text relocations
(`DT_TEXTREL`) would `mprotect` its text writable, and so gets private copies (3.2).

## 4. Observability

`vm.pagecache.entries`, `.pages` (frames held), `.hits`, `.misses` and `.limit` (sysctl).

## 5. Verification

5.1. On target: two runs of one program share frames (the second exec's `execve` phase "load
ELF" falls and `vm.pagecache.hits` rises); a program rebuilt in place runs the new code at its
next exec; a library mapped read-only and then made writable with `mprotect` doesn't change
other processes' copy; `fork` keeps the pages shared and the counts right.

5.2. bmake's `configure` on target, timed against the 29 s of 2026-09-30.

Measured 2026-10-01: 15 s (rc 0). `execve` is 1.5 s over 991 calls (1.5 ms each), against 13 s
before; `fork`'s eager copy (1.7 ms each) is now the costliest system call. The cache ended
holding 33 files in 29,787 pages, with 3.76 million hits to 29,791 misses.

## 6. Open questions

1. Filling entries lazily on page faults (demand paging) instead of when mapping.
2. Sharing writable pages until first write (copy-on-write), for data segments and `fork`.
