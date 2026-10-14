# OxideBSD copy-on-write fork: design specification

Status: **in progress** (2026-10-14): commits 1-5 of §9 landed (frame lock rule, reference
counts, COW fork and the write fault, the OOM killer, `oom_adj` with `procctl(2)` and `protect(1)`);
real vfork remains.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Terms

- **Private page**: a user leaf that isn't `SHARED_LEAF` (`memory::address_space`): anonymous
  memory, a program's writable data, a private mapping's copy, a stack page. The only kind COW
  applies to. `SHARED_LEAF` pages (SysV, `MAP_SHARED`, the page cache) are shared on purpose and
  keep their current handling.
- **COW page**: a private page mapped into more than one address space, or marked to be copied
  before its next write.
- **Reference count** of a frame: how many address spaces map it as a private page.

## 2. Reference counts

2.1. The kernel keeps a reference count for every physical frame: a dense array of `u16`, one per
frame of usable RAM, indexed by frame number (FreeBSD's `vm_page` array, in miniature), allocated
at boot from the memory map: 64 KiB at 128 MB.

2.2. A frame's count is 0 while it's free or owned by the kernel, 1 while one address space maps
it privately, and n while n do (after fork). The frame allocator's free path MUST NOT free a frame
whose count is above 1; dropping a reference (teardown, `munmap`, a COW copy replacing it) frees
the frame only when the count reaches 0.

2.3. A count can't overflow: fork fails with `EAGAIN` rather than raise a count to `u16::MAX`.

## 3. Fork

3.1. Fork still copies the page tables (no table sharing); for every present or `PROT_NONE`
private leaf it maps the **same** frame into the child, increments its count, and marks the entry
`COW_LEAF` (a new software bit, `PageTableFlags::BIT_53`) without `WRITABLE`, in the parent as in
the child. An entry that was writable keeps that fact in `COW_LEAF` (only a writable or
`MAY_WRITE`-able page is ever copied on write; a read-only page just stays shared).

3.2. The parent's TLB entries for pages it made read-only MUST be flushed before fork returns
(a full flush: CR3 reload).

3.3. `SHARED_LEAF` pages are aliased as today (§1). Page cache entries' uses are inherited as
today (`pagecache::fork_uses`).

## 4. The write fault

4.1. A write fault (present, protection violation) on a `COW_LEAF` page resolves the copy:

1. If the frame's count is 1 (the other side already copied or exited), the entry just becomes
   writable again and loses `COW_LEAF`: no copy.
2. Otherwise a frame is allocated, the page copied into it, the entry pointed at it writable and
   without `COW_LEAF`, the old frame's count decremented, and the page's TLB entry invalidated
   (`invlpg`).

4.2. This MUST work for faults from ring 3 **and** from ring 0 inside the copy routines
(`memory::usercopy`): `copyout` into a COW page of the caller (`CR0.WP` is on) resolves the copy
and retries; only a fault that isn't a COW fault reaches `usercopy::fixup_fault` and fails the copy
with `EFAULT`.

4.3. A read fault never copies.

4.4. **The frame allocator lock MUST NOT be held across anything that can sleep.** Exec's and
`mmap`'s page cache fills (`pagecache::frame`, which reads the disk and may sleep) currently run
inside `with_frame_allocator`; they're restructured to take the lock only around each allocation.
With that rule, a ring-3 fault always finds the lock free (single core: nothing in the kernel holds
it while user code runs), and a ring-0 COW fault inside a copy routine can't have been raised while
holding it (copy routines run with no frame allocator lock held).

## 5. Everything else that touches private pages

5.1. **Teardown and `munmap`** drop a reference per private leaf instead of freeing the frame
(§2.2).

5.2. **`mprotect`**: making a `COW_LEAF` page writable records it in `COW_LEAF` and leaves
`WRITABLE` off (the first write copies); making it read-only clears the "copy on write" intent but
keeps it shared. `PROT_NONE` COW pages stay shared and non-present.

5.3. **Exec** builds a fresh address space and drops the old one's references (§5.1).

5.4. **Threads** (`clone` with `CLONE_VM`) share one address space: no COW between them.

5.5. **`MAP_PRIVATE` of a file** whose page cache frame is mapped read-only (`CACHED_LEAF`) keeps
its current private-copy-on-`mprotect` behaviour; COW applies to the private copies once made.

## 6. Out of memory (OOM)

Fork overcommits: it never reserves the pages a later COW fault may need (decided 2026-10-13).
When a COW fault (or any allocation for a user page) finds no free frame, after the page cache has
given back what it can (`pagecache::reclaim`):

6.1. The kernel picks a **victim**: the process with the highest **OOM score** -- its private
resident pages, scaled by its `oom_adj` (§6.3) -- never pid 1 and never a process with `oom_adj`
-1000. It's killed with `SIGKILL`, logged to the console and the message buffer as
`pid N (name), N pages: killed, out of memory` (FreeBSD's `vm_pageout_oom` wording).

6.2. If the victim is the faulting process, the fault doesn't return to it. Otherwise, from a
ring-3 fault (where the kernel holds nothing, as at a system call), the victim is terminated on
the spot as `kill(2)` would, and the faulting instruction retries (after the filesystem lock's
holder finishes, when the termination had to wait for it). From a ring-0 fault inside a copy
routine the kernel doesn't know what the interrupted system call holds, and terminating a process
closes its files: the victim is only sent `SIGKILL` and the copy fails with `EFAULT`. If no victim
can be found, the faulter itself is killed (from ring 0: `SIGKILL` at the end of the call).
Amended 2026-10-14 (the original said the faulter always sleeps until the victim's memory is
freed).

6.2a. Delivering a fault signal writes the fault trampoline's scratch page (`process::
fault_trampoline`), so that page is never shared copy-on-write: fork gives the child its own copy
(failing with `ENOMEM` if it can't), or the OOM killer's own `SIGKILL` could need a frame to land.

6.3. **`oom_adj`**: a per-process value from -1000 to 1000, default 0, inherited across fork and
exec: score = private pages × (1000 + `oom_adj`) / 1000; -1000 means never chosen. Only root may
lower it. Set through a new system call in the process module (OxideBSD's own number, after
FreeBSD's `procctl(2)` shape: `procctl(P_PID, pid, PROC_OOM_ADJ_CTL, &value)`), read back through
`PROC_OOM_ADJ_STATUS`, and shown as `/proc/<pid>/oom_adj`; a userland tool, `protect(1)`
(FreeBSD's name, which marks a process protected from the OOM killer), sets -1000 for
`protect pid`/`protect command` and `-a VALUE` for any other value.

6.4. Specified with the commit (2026-10-14, the user's choices): `procctl(2)` is system call 585,
a general per-process control call in its own kernel module (`procctl`), FreeBSD's
`procctl(idtype, id, cmd, data)` shape with musl's `idtype_t` values (`P_PID` 1, `P_PGID` 2; id 0
names the caller or its group) and OxideBSD's own commands: `PROC_OOM_ADJ_CTL` (1) and
`PROC_OOM_ADJ_STATUS` (2, `P_PID` only), `data` an `int *`. Raising a process's value needs
`kill(2)`'s permission over it; lowering it needs the superuser. Over a group the call succeeds if
it changed any process. `protect(1)` takes FreeBSD's options, `protect [-i] [-a adj] command` and
`protect [-cdi] [-a adj] -g pgrp | -p pid` (`-c` sets 0, `-d` also descendants, found through
`/proc`; `-i` is accepted, the value always being inherited). Man pages `procctl.2`, `protect.1`.

## 7. Real vfork

7.1. `vfork()` and `clone(CLONE_VM|CLONE_VFORK)` (musl's `posix_spawn`) create a child that
**borrows the parent's address space** (no page table copy); the parent sleeps until the child
execs or exits, then resumes (the BSDs' semantics). The child runs on the stack it was given
(`clone`) or the parent's (`vfork`), and must not return from the calling function (POSIX).

7.2. Today's `vfork.s` patch in musl (vfork degraded to fork) is reverted to a real vfork.

## 8. Verification

- A regress program checks fork semantics: writes after fork are private on both sides, at every
  page kind (heap, stack, data, `PROT_NONE` made accessible, `mprotect`ed); a write through
  `read(2)` into a COW buffer (ring-0 copy) is private; fork of a large heap followed by `_exit`
  copies nothing (frame counts via `/proc/meminfo`).
- The suite and POSIX canary pass; `shm_open/23-1.c` is timed before and after.
- The OOM killer: a test allocates and touches memory past RAM in a child with `oom_adj` 1000 while
  a protected (`-1000`) sibling survives; the victim's log line appears.
- RAM floor: `ram_floor_boot` keeps passing, and the BIOS floor is re-measured (28 MB failed on
  syslogd's fork).

## 9. Commits

1. The frame allocator lock never held across a sleep (§4.4): page cache fills in exec and `mmap`
   take it per allocation.
2. Frame reference counts (§2), used by teardown and `munmap` (no behaviour change: every count is
   1).
3. COW fork and the write fault, rings 3 and 0 (§§3-5), with the fork regress test.
4. The OOM killer (§6.1-6.2).
5. `oom_adj`, its system call, `/proc/<pid>/oom_adj`, `protect(1)` (§6.3).
6. Real vfork (§7), musl's `vfork.s` and `posix_spawn` path.

## 10. Decisions

2026-10-13: overcommit with an OOM killer choosing the largest process, adjustable per process
(`oom_adj`, `protect(1)`); real vfork; reference counts in a dense per-frame array. Made while
writing this, open to change: the COW bit is `BIT_53`; page tables stay copied; `oom_adj`'s range
and scaling follow Linux's `oom_score_adj`, its interface FreeBSD's `procctl(2)`.
