# OxideBSD user memory access: design specification

Status: **accepted** (2026-10-06; drafted 2026-10-02). Implemented through §5.5 (2026-10-08); §5.3 open. Target release: v0.3.0 (`CLEANUP.md` §2).

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
upper half. Under Multiboot2 (`sys/boot/multiboot2.rs`), the boot trampoline's identity map of
physical `[0, 64 MiB)` is also kernel-only and present in every address space, at virtual
`[0, 64 MiB)`: the boot stack lives in it. An address check against a single boundary is
therefore not enough; §5.1 makes it so.

2.2. **Faults.** A page fault in ring 0 reboots the machine, except where the user stack grows on
demand (`mm::try_grow_user_stack`, which already runs for kernel accesses too).

2.3. **Supervisor protections.** SMEP and SMAP are not enabled: the kernel can execute and read
user pages freely.

2.4. **Serialization.** Interrupts are masked for a whole system call and there is one CPU, so no
other thread runs while the kernel touches user memory. This stops being true with SMP (v0.5.0).

## 3. Rules

3.1. Kernel code (and module code) MUST NOT dereference a user pointer. It MUST copy data in or
out with the routines of §4, and operate on the kernel copy.

3.2. The user range is `[VM_MINUSER, VM_MAXUSER)`: `VM_MINUSER` is `0x1000` (page zero stays
unmapped, so a null pointer faults, as on the BSDs), `VM_MAXUSER` is `0x8000_0000_0000` (the end
of the canonical lower half). Fixed-address binaries load as low as `0x20_0000` (lld's default;
on-target `clang` and `lld` among them). The kernel MUST NOT map anything kernel-only inside the
user range (§5.1), and MUST NOT create a user mapping outside it: `execve`'s segments, `brk` and
`MAP_FIXED` are checked. A range is valid for a copy when it lies entirely inside the user range;
whether its pages are mapped, and writable, is found by performing the copy (§5.2).

3.3. A range that wraps around, or extends past either bound, is invalid without touching memory.

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

4.4. **Data transfer: `uio`.** `read`, `write` and their vector and positioned forms reach a
descriptor's backend through a `uio`, as on the BSDs (`uio(9)`, `uiomove(9)`), never through a
raw pointer.

| Field | Meaning |
|---|---|
| `iov` | The segments, copied in by the system call (`readv`/`writev`: the whole array, at most `IOV_MAX`; `read`/`write`: one) |
| `resid` | Bytes still to transfer; the call returns the original length minus `resid` |
| `offset` | The file position to use, when `FOF_OFFSET` is set (below) |
| `rw` | `Read` (the backend's data goes out to the segments) or `Write` (the segments' data comes in) |
| `seg` | `User` (segments are user addresses: `copyin`/`copyout`) or `Kernel` (kernel buffers, a plain copy: a module's I/O on its own descriptors, such as oxfs's format self-check, and later core dumps, `sendfile` and in-kernel file I/O) |

`uiomove(kbuf, uio)` moves up to `kbuf.len()` bytes between a kernel buffer and the next part of
the segments, in the direction `rw` gives, advancing them and lowering `resid`; it fails with
`EFAULT` like `copyin`/`copyout`. A backend may call it as often as it likes (a pipe once per
contiguous run of its ring buffer, a terminal once per line).

The descriptor operations become `read(real_fd, uio, flags)` and `write(real_fd, uio, flags)`.
`flags & FOF_OFFSET` asks for `uio.offset` instead of the description's own position, which
replaces the separate `pread`/`pwrite` operations; a backend with no position (pipe, terminal,
socket) fails it with `ESPIPE`. A `readv`/`writev` is one call into the backend, so a `writev` of
at most `PIPE_BUF` bytes to a pipe is as atomic as a `write` of the same length, and a terminal
read fills several segments from one line.

When an operation fails after transferring some bytes, the call returns the count if the error is
`EINTR`, `ERESTART` or `EAGAIN`, and the error otherwise (decision 3; FreeBSD's `dofileread`).

Modules see a `uio` as an opaque pointer, so its layout stays the kernel's: `sys/module.rs`
exports `oxidebsd_uiomove(kbuf, len, uio)` (the count moved, or `-errno`), `oxidebsd_uio_resid(uio)`
and `oxidebsd_uio_offset(uio)`, and `oxidebsd_uio_kernel_new(buf, len, rw)`/`oxidebsd_uio_free(uio)`
for a module that calls its own operations on its own buffers.

## 5. Implementation

5.1. **Address space layout.** The kernel heap moves from `0x4444_4444_0000` to the upper half,
L4 slot 386 (`0xffff_c100_0000_0000`), next to the module data pool (384) and the kernel stack
window (385). Like them it is mapped at boot, before any process exists, so every address space
aliases its L4 entry. The Multiboot2 path continues boot on the boot stack's alias in the direct
map and, once the kernel's own GDT is loaded, unmaps the low identity window (PML4 slot 0). A
boot-time check walks the lower half of the kernel's page tables and panics if any kernel-only
leaf lies in the user range. A PIE's `brk` heap starts after its randomized image (it used to
start at the unbiased image end, below 1 MiB, inside the Multiboot2 window). Done: `9fb6f67`,
`2e9a34f`.

5.2. **Fault recovery.** The copy routines have a recovery address: the instruction that touches
user memory lies between two labels, and a fault there resumes at a third, which returns `EFAULT`
(an exception table keyed on the faulting instruction, as Linux does, rather than the BSDs'
per-thread `pcb_onfault`; it needs no per-thread or per-CPU state). The ring-0 page fault handler
first tries demand growth
(`mm::try_grow_user_stack`, and any other demand-populated region); if that fails and the fault
happened inside a copy routine, it returns to the recovery address and the routine returns
`EFAULT`. A fault in ring 0 outside a copy routine still reboots. A write to a present read-only
page faults the same way. Together with §3.2's bounds check this is the whole validation: there
is no page-table walk.

Done: `sys/memory/usercopy.rs` (`copyin`, `copyout`, `copyin_val`, `copyout_val`, `copyin_vec`;
`oxidebsd_copyin`/`oxidebsd_copyout` for modules). Entering the kernel also clears the direction
flag now (`SYSCALL`'s `SFMASK`, `0af78c0`): with it set, the copies ran backwards.

5.3. **SMAP and SMEP (later stage).** With fault recovery in place, the kernel SHOULD enable SMEP
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
"pointer-validation gap" comment. Done (2026-10-07/08): `10eb730` (first conversions), `3cbd575` (`read`/`write`
through `uio`), `8c6b850` (output buffers), `b2102e5` (IPC), `900a8da` (signals, `poll`/`select`),
`76403a1` (`execve`), `5a30fda` (signal frames), `2cab95b` (oxfs; exec opens and reads in kernel
space), `b4d94a7` (sockets, credentials, `sysctl`, `sethostname`, which had no gap comment). No
raw user access remains; SMAP (§5.3) would now catch one that slipped in.

5.6. **`uio` conversion.** The `uio` type and `uiomove` first, then the system calls (`read`,
`write`, `readv`, `writev`, `pread`, `pwrite`, `preadv2`, `pwritev2`) build one, then every
backend moves to the new operations in one change, since the operation types are shared: pipes
and FIFOs, terminals and pseudo-terminals, sockets, message queues, `/dev/klog`, the devices in
`sys/module.rs`, and oxfs (files, device nodes, `/proc`). Their `(ptr, len)` gaps go with it.

## 6. Verification

6.1. A new smoke test (`usermem_syscall_smoke`), run as an unprivileged user, passes bad pointers
to a representative of every converted system call and expects `EFAULT` and a running system:
NULL; an unmapped user page; the kernel heap (`HEAP_START`); the kernel image and module
regions (upper half); a range that starts on a valid page and runs onto an invalid one; a
read-only page as an output buffer; a non-canonical address.

6.2. A signal handler on a stack set to an invalid address dies with `SIGSEGV`.

6.3. The existing smoke tests and the POSIX canary MUST pass unchanged: valid pointers behave as
before.

6.4. The test includes page zero, an address at the old heap location and one in the old
Multiboot2 identity window, and runs under both boot paths.

## 7. Decisions

Made 2026-10-06.

1. **No page-table walk; the heap moves.** Validation is a bounds check plus fault recovery
   (§5.1, §5.2), as on the BSDs. **Rationale.** Fault recovery is needed before SMP anyway and
   handles demand-grown regions naturally; a page-table walk would be thrown away. It is only
   sound once nothing kernel-only remains in the user range, which moving the heap achieves.
2. **`copyin_vec` takes a per-call bound.** Paths use `PATH_MAX` and fail with `ENAMETOOLONG`;
   `execve`'s arguments use `ARG_MAX` (`E2BIG`); every other caller passes its own. **Rationale.**
   Matches `copyinstr(9)`'s `maxlen`, and keeps each call's POSIX error.
3. **A partially valid buffer fails the whole call with `EFAULT`.** A `read` whose buffer is
   valid only at its start returns `EFAULT`, as on the BSDs (FreeBSD's `dofileread` masks only
   `ERESTART`, `EINTR` and `EWOULDBLOCK` after a partial transfer), not a short count as on
   Linux.
4. **`uio` for data transfer, as on the BSDs** (2026-10-07; §4.4): one `uio` per system call
   (vectored calls included), a kernel-segment mode from the start, modules see it opaquely
   through exports, and `pread`/`pwrite` fold into `read`/`write` with `FOF_OFFSET`.
   **Rationale.** A bounce buffer would cost a copy and kernel memory on every transfer (against
   the 128 MB floor, `ROADMAP.md` v0.3.0 item 6); per-backend `uiomove` is what the BSDs do, and
   it fixes `writev` atomicity on pipes.
