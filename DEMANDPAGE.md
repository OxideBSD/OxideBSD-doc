# OxideBSD demand-paged file mappings: design specification

Status: **implemented** (2026-10-14). Answers `PAGECACHE.md` §6 open question 1. Specified
with the user; implementation follows.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Motivation

A page cache mapping (`PAGECACHE.md` §3) is filled whole when it's made: `mmap` and `execve`
read every page of the file into the cache before returning. Measured 2026-10-14 at 28 MB (BIOS):
`syslogd` maps `libcrypto.so.3` (1549 pages) and `libssl.so.3` (274 pages), touches a small part
of either, and the cache grows from 3.6 MB to 9.5 MB, all of it in use; free memory falls from
7 MB to 580 KB and the next `execve`s (`update`, `cron`) fail with `ENOMEM`. Every BSD instead
maps a file's pages on their first touch. This specification does the same.

## 2. Scope

2.1. Demand-paged: every page cache mapping, that is `execve`'s read-only segments (§3.1 there)
and `mmap` with `MAP_PRIVATE` and without `PROT_WRITE` (§3.2 there).

2.2. Unchanged, filled when made: `MAP_SHARED` file mappings (`mm::MMAP_FILE_CACHE`, written
back), writable private file mappings and writable `PT_LOAD` segments (copied), anonymous memory.
Copy-on-write private file mappings, made from cache pages, are a later step (§7).

## 3. Mapping

3.1. `mmap` and `execve` register the entry as used by the address space
(`AddressSpace::use_cached`) **before anything else** (the 2026-10-14 reclaim race, `72dd178`)
and give each page a **`FILE_LEAF` entry** (`memory::address_space`, PTE bit 54): not present,
owning no frame, its address bits holding the cache entry (20 bits) and the file page (20 bits),
its `USER_ACCESSIBLE` and `NO_EXECUTE` the permissions the page will get. The fault reads
everything it needs from the entry itself: no table or region lookup, no lock. Cache entry ids
are reused once their entry is gone (only then does no page table name them), so they stay
small; a file past 4 GiB, or an id that doesn't fit, is filled when mapped instead.

3.3. The page table walks treat a `FILE_LEAF` entry as follows: `fork` copies it as it is (the
child shares the entry, `pagecache::fork_uses`); `munmap` and teardown forget it; `mprotect` and
`mlock` fill it first (a page made `PROT_NONE` must not become readable at its first touch; a
locked page is resident).

3.2. A cache entry in use by any address space keeps its inode in use
(`oxidebsd_inode_in_use`), as a mapped file's region does today (`mm::content_mapped`): an
unlinked program or library keeps its blocks while anything maps it.

## 4. The fault

4.1. A not-present fault, from ring 3 or from a copy routine in ring 0, at an address inside such
a region and below its mapped length resolves by getting the page from the cache
(`pagecache::frame`, which fills it if needed) and mapping it as today
(`SHARED_LEAF | CACHED_LEAF`, without `WRITABLE`); the instruction then retries. An address
past the file's real length stays a `SIGBUS` (`mm::signal_for_user_fault`).

4.2. Filling may sleep on the disk. From ring 3 that is as for a system call. From ring 0 the
interrupted system call may hold the filesystem lock (`fs::fslock`) and be midway through an oxfs
operation: a path, a `write` buffer, a `stat` record in a demand-paged page (a string literal in a
program's `.rodata` is the common case) faults *inside* oxfs, and oxfs is not re-entrant (its
state is plain `static mut`s). Filling MUST therefore not call into oxfs (§5).

4.3. Out of memory, the fault goes to the OOM killer (`COW.md` §6) as a copy-on-write fault does.

## 5. Filling without the filesystem

5.1. **Block map.** When a cache entry is made, the kernel asks oxfs once (under the filesystem
lock, as any call) for the file's **block map**: the disk block holding each file page, as runs
of consecutive blocks (`(file page, disk block, length)`), so a file written in one piece costs a
few runs whatever its size. The entry keeps it.

5.2. A fill reads the page's block straight from the disk driver (`drivers::disk`), not through
oxfs, so it can't land inside an oxfs operation. It still takes the filesystem lock, which is
what serializes the disk (recursive: a fault inside oxfs already holds it). A page past the end
of the file is zero; a hole in the file (no block) is zero.

5.2.1. **Who may wait.** A system call or a ring-3 fault holds no spin lock: it may wait for the
lock and sleep for the disk. A fault in a copy routine may not know what the interrupted code
holds (a system call copies in under the process table's lock, found at 28 MB: the disk wait
then spun on that lock forever), so its fill waits for nothing: it fails (`EFAULT`, logged
`[vm] ...`) if another process holds the filesystem lock, takes the frame allocator only if it's
free, polls the disk instead of sleeping (`fslock::NoSleep`), and releases the lock without
waking anyone (`fslock::exit_quiet`): waking takes the process table's lock too, and a process
still counted as waiting was already woken by the holder before (found: `do_mmap` copying in
under the table's lock hung `sudo`, `clang++` and `ninja`).

5.3. **Change.** oxfs calls `oxidebsd_content_changed` before it rewrites or frees any of a file's
blocks (`release_inode`, the write and resize paths). For an entry still in use, the kernel then
fills every page not yet filled, from the old block map, before returning: mappings keep the
contents they mapped, as today, and never read blocks oxfs has since given to another file. Then
the entry is retired as today. (Its cost is the file's unfilled pages, once, and only when a
mapped program or library changes.)

5.4. oxfs's buffer cache delays a file's data writes. The block map call puts the file's
delayed writes on the disk first (`sync_file`), and every later change goes through §5.3, so the
disk holds what the entry's pages must show. A tmpfs file, in memory rather than on the disk, has
no block map and is filled when mapped, as before.

## 6. Verification

- `regress/pagecache-smoke` grows a case: a large library mapped and one page read leaves
  `vm.pagecache.pages` near one page for it, not the whole file.
- A demand page reached from ring 0 inside oxfs: `open()` of a path string that lives in a
  not-yet-touched page of an `mmap`ed file, and `write()` from one.
- A mapped file truncated, overwritten and unlinked while mapped: the mapping reads its original
  contents throughout; nothing reads another file's blocks.
- RAM floor: the 28 MB BIOS boot (`update`, `cron`) passes; the floor is re-measured.
- The suite, the POSIX canary, `pagecache_syscall_smoke`'s exec timings.

## 7. Later

Copy-on-write private file mappings (`MAP_PRIVATE` with `PROT_WRITE`, writable `PT_LOAD`
segments): cache pages mapped `COW_LEAF`, copied on first write (`COW.md` §4), instead of copied
at map time.

## 8. Decisions

2026-10-14: demand-paged file mappings rather than per-program workarounds (the user's choice,
over loading OpenSSL lazily in `syslogd` or accepting the 32 MB BIOS floor). Fills go through
§5's block map, bypassing oxfs (the user's choice), rather than every oxfs entry point copying
user buffers into kernel memory before taking the filesystem lock.
