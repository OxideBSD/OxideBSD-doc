# OxideBSD user memory access: design specification

Status: **draft** (2026-10-02). Target release: v0.3.0 (`CLEANUP.md` §2).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Scope

This document specifies how the kernel and its modules read and write memory through pointers
that come from user space: system call arguments, structures they point to, and the user stack
during signal delivery. It replaces direct dereferences of user pointers with copy routines in the
style of the BSDs' `copyin(9)`/`copyout(9)`, which fail with `EFAULT` instead of faulting.

**Rationale.** Today the kernel dereferences user-supplied pointers without checking them
(`CLAUDE.md`'s known gaps; about 90 call sites carry a "pointer-validation gap" comment, and
oxfs alone has some 40 `from_raw_parts` over user pointers). Before real credentials existed
this let a process crash only itself, or the machine. Since set-user-ID programs and `sudo`
(`SUDO.md`), it is a privilege escalation: any user can pass a kernel address to a system call
and have the kernel read or overwrite kernel memory on its behalf.

## 2. The current state

2.1. **Address space.** User and kernel mappings share one page table per process. The kernel
heap (`allocator::HEAP_START`, `0x4444_4444_0000`) lies in the lower canonical half, between
the PIE window (`0x3000_0000_0000`-`0x4000_0000_0000`) and the user stack
(`USER_STACK_TOP`, `0x5000_0000_0000`); module code, module data and kernel stacks are in the
upper half. An address check against a single boundary is therefore not enough.

2.2. **Faults.** A page fault in ring 0 reboots the machine, except where the user stack grows on
demand (`mm::try_grow_user_stack`, which already runs for kernel accesses too).

2.3. **Supervisor protections.** SMEP and SMAP are not enabled: the kernel can execute and read
user pages freely.

2.4. **Serialization.** Interrupts are masked for a whole system call and there is one CPU, so no
other thread runs while the kernel touches user memory. This stops being true with SMP (v0.5.0).

## 3. Rules

3.1. Kernel code (and module code) MUST NOT dereference a user pointer. It MUST copy data in or
out with the routines of §4, and operate on the kernel copy.

3.2. A user address range is valid for reading when every page in it is mapped with the
user-accessible bit set (`PageTableFlags::USER_ACCESSIBLE`), or lies in a region the fault path
would populate on demand (the user stack reserve). It is valid for writing when, in addition,
every such page is writable. The user-accessible bit is the test: kernel mappings never carry
it, wherever they are in the address space (§2.1).

3.3. A range that wraps around, or extends past the canonical lower half, is invalid.

3.4. A failed copy MUST leave the system call failing with `EFAULT` (or, for signal delivery,
the process receiving `SIGSEGV`, §5.4). It MUST NOT fault in ring 0, reboot, or partially
perform the operation in a way POSIX forbids.

3.5. Data copied in is used from the kernel copy only: a value MUST NOT be read twice from user
memory (a second thread could change it between the reads).

## 4. Interface

4.1. In the kernel (`sys/memory/usercopy.rs`, a new file):

| Function | Does |
|---|---|
| `copyin(src: UserPtr, dst: &mut [u8]) -> Result<(), Errno>` | Copies user bytes into a kernel buffer |
| `copyout(src: &[u8], dst: UserPtr) -> Result<(), Errno>` | Copies kernel bytes to user memory |
| `copyin_val::<T: Pod>(UserPtr) -> Result<T, Errno>` | One plain-data value (`termios`, `timespec`, ...) |
| `copyout_val::<T: Pod>(&T, UserPtr) -> Result<(), Errno>` | The same, outward |
| `copyin_vec(UserPtr, len, max) -> Result<Vec<u8>, Errno>` | A length-prefixed buffer (this ABI's paths, `RawAtPath`), bounded by `max` |

`UserPtr` is a newtype over the raw address, so a user pointer can't be dereferenced by accident;
`Pod` marks types any byte pattern is valid for.

4.2. For modules, `sys/module.rs` exports `oxidebsd_copyin`, `oxidebsd_copyout` (and the
`_val` forms as macros over them in each module's FFI shim). oxfs, socket, signal, sysctl,
posix_compat and native_abi convert their user accesses to these.

4.3. musl and user space are unaffected: the ABI does not change, only the errors a bad pointer
produces.

## 5. Implementation

5.1. **Validation (first stage).** Each copy walks the caller's page tables for the range
(§3.2), populating the stack reserve first if the range falls in it, then copies. This is sound
while §2.4 holds: nothing can unmap a page between the walk and the copy.

5.2. **Fault recovery (second stage, required before SMP).** The copy routines record a recovery
address before touching user memory, as the BSDs' `pcb_onfault` does. The ring-0 page fault
handler, after trying demand growth, returns to that address instead of rebooting when a fault
happens inside a copy routine, and the routine returns `EFAULT`. The page-table walk of §5.1 can
then be dropped. Faults in ring 0 outside a copy routine still reboot.

5.3. **SMAP and SMEP (third stage).** With fault recovery in place, the kernel SHOULD enable SMEP
(the kernel never executes user pages) and SMAP (the kernel reads and writes user pages only
inside the copy routines, bracketed by `stac`/`clac`), where the CPU supports them. A stray
dereference of a user pointer then faults instead of silently working.

5.4. **Signal delivery.** Building a signal frame on the user stack, and `sigreturn` reading it
back, go through `copyout`/`copyin`. A frame that can't be written delivers `SIGSEGV` with the
default action instead (as on the BSDs), so a process with a bad stack dies rather than the
kernel faulting.

5.5. **Conversion order.** By exposure: (1) everything reachable by an unprivileged process with
an arbitrary pointer and a write (read, pread, ioctl, getsockopt, getresuid, sysctl, wait4,
pipe, clock_gettime, the stat family, uname, getrandom...); (2) structure inputs (setsockopt,
sigaction, nanosleep, termios, iovecs, msghdr and control data, execve's argv and envp); (3)
paths and every remaining module access; (4) signal frames. Each converted site loses its
"pointer-validation gap" comment.

## 6. Verification

6.1. A new smoke test (`usermem_syscall_smoke`), run as an unprivileged user, passes bad pointers
to a representative of every converted system call and expects `EFAULT` and a running system:
NULL; an unmapped user page; the kernel heap (`HEAP_START`); the kernel image and module
regions (upper half); a range that starts on a valid page and runs onto an invalid one; a
read-only page as an output buffer; a non-canonical address.

6.2. A signal handler on a stack set to an invalid address dies with `SIGSEGV`.

6.3. The existing smoke tests and the POSIX canary MUST pass unchanged: valid pointers behave as
before.

6.4. After stage two, the same test runs again with the walk of §5.1 removed.

## 7. Open questions

1. Whether stage one (the page-table walk) is worth doing at all, or the work should go straight
   to fault recovery (§5.2), which SMP needs anyway and which handles demand growth naturally.
2. Where the per-call bound for `copyin_vec` comes from: a fixed 1 MiB, `PATH_MAX` for paths, or
   per call.
3. Whether a partial `read` into a buffer that is valid only for its first part returns the bytes
   that fit (as Linux does) or `EFAULT` for the whole call (as the BSDs do).
