# OxideBSD threat model: design specification

Status: **draft** (2026-10-07).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Scope

This document lists the tools an attacker has against OxideBSD, what defends against each one
today, and what does not yet. It is the reference new code is checked against: a change that
hands an attacker a new tool, or takes away a defence, says so here.

The project's name for this attacker is a **determination beast**: an adversary who will find and
use *every* reachable bug, however obscure, and chain them. The model never assumes a bug is too
unlikely to be found.

## 2. The adversary

2.1. **Local, unprivileged.** The primary adversary: a process running arbitrary native code as an
ordinary user (`user` in the default install), able to make any system call with any arguments,
from any number of processes and threads. Goals: run code as root or in ring 0, read or change
other users' data or kernel memory, or take the system down.

2.2. **Local, through a privileged program.** The same user, attacking a set-user-ID program
(`sudo`, `su`, `passwd`) through its arguments, environment, open descriptors, signals, resource
limits and terminal.

2.3. **Remote.** A host on the same network, sending arbitrary Ethernet frames to the `rl0`
interface: ARP, IPv4, ICMP, UDP, TCP, and replies to the system's own DNS queries.

2.4. **Out of scope** (for now): physical access to a running machine (the console is
`insecure`: single-user mode asks for root's password, `INIT.md`), a malicious bootloader or
firmware, crafted disk images (oxfs has no removable media yet), and side channels other than
§3.10.

## 3. The tools

Each tool is listed with what defends against it. **Gap** means no defence yet; **Target** is the
release that closes it (`ROADMAP.md`, `CLEANUP.md`).

### 3.1. System call arguments

| Tool | Defence | Gap / Target |
|---|---|---|
| A pointer argument aimed at kernel memory, an unmapped page, a read-only page, page zero or a non-canonical address | `copyin`/`copyout` bounds-check against `[VM_MINUSER, VM_MAXUSER)` and recover from faults with `EFAULT` (`USERMEM.md`) | Done across the kernel and its modules (`b4d94a7`, 2026-10-08) |
| Reading a value twice from user memory while another thread changes it | Every value is copied in once and used from the kernel copy (`USERMEM.md` §3.5) | — |
| A huge length or count, to make the kernel allocate | Bounded before allocating: `IOV_MAX` (iovecs), `kern.maxfiles` (`poll`), `PATH_MAX` (paths), `MAX_EXEC_ARG_BYTES` (`execve`), message size limits (message queues, `msgsnd`), 1 MiB chunks (`sendmsg`), 256 bytes (socket addresses), 4 KiB (socket options, `sysctl` values) | Every new length MUST be bounded the same way |
| An unregistered system call number | `ENOSYS` | — |
| Flags or values out of range | Checked per call (`EINVAL`) | Not audited systematically |

### 3.2. CPU state at kernel entry

| Tool | Defence | Gap / Target |
|---|---|---|
| `RFLAGS` set before `SYSCALL` (direction, trap, alignment-check, nested-task flags) | `SFMASK` clears IF, DF, TF, AC and NT on entry (`0af78c0`) | — |
| The user stack pointer at entry | The kernel switches to the process's own kernel stack (`gdt::CURRENT_RSP0`); kernel stacks have guard gaps (`memory::kstack`) | — |
| FPU/SSE state | Saved and restored per process (`FXSAVE`/`FXRSTOR`) | — |
| A signal frame on a bad stack, or a broken `ucontext` at `sigreturn` | Written and read through `copyout`/`copyin`; failure kills the process with `SIGSEGV` (`5a30fda`) | — |

### 3.3. Memory

| Tool | Defence | Gap / Target |
|---|---|---|
| Mapping over kernel memory (`MAP_FIXED`, `brk`, ELF segments) | User mappings are confined to the user range; `munmap` skips kernel-only pages (`2e9a34f`) | — |
| Executing data: injected code on the stack, heap, `.data`, an `mmap` page | `EFER.NXE` (`cpu::nx`): every user page is `NO_EXECUTE` unless it is an ELF `PF_X` segment or mapped `PROT_EXEC` | **Gap:** a CPU without NX, or with it disabled in firmware, boots with a warning and no defence |
| A page writable and executable at once (W^X) | `mmap`/`mprotect` asking for `PROT_WRITE \| PROT_EXEC` fail with `ENOTSUP` and are logged (`kern.wxabort=1` adds `SIGABRT`), as on OpenBSD. Code must be written, then `mprotect`ed to `PROT_READ \| PROT_EXEC`. Escape hatch: a program linked `-z wxneeded` (`PT_OXIDEBSD_WXNEEDED`) run from a `wxallowed` mount | **Gap:** a program whose `PT_GNU_STACK` has `PF_X` gets a writable and executable stack, without the escape hatch (a deliberate choice, logged). ELF segments sharing a page get the union of their permissions; a page that ends up W+X is mapped and logged (none in the build as of `606e5b1`) |
| Writing to code or read-only data | `.text` and `.rodata` are mapped read-only; `CR0.WP` binds the kernel too | — |
| The kernel's own pages writable and executable | No kernel page is both (`memory::wx`, an audit at boot and after the modules load, like Linux's `CONFIG_DEBUG_WX`): the direct map, heap, kernel stacks, MMIO and module data are `NO_EXECUTE`; module text is read-only; the GOT read-only after relocation; under Multiboot2 the image's 2 MiB pages are split per section | — |
| The kernel executing or reading user pages by mistake | SMEP and SMAP where the CPU has them; AC cleared at every kernel entry (`046a164`) | **Gap** on CPUs without them (pre-Haswell SMEP, pre-Broadwell SMAP): they boot unprotected |
| Guessing addresses | PIE executables get a randomised load bias (`process::aslr`) | **Gap:** fixed-address executables (BusyBox, the C ports) and the kernel itself are at fixed addresses: no KASLR |
| `mprotect` to change protections | Enforced across the user range, all or nothing; `EACCES` for `PROT_WRITE` on a shared page its owner doesn't allow writing (`MAY_WRITE_LEAF`: a `MAP_SHARED` mapping of a file open read-only, an `SHM_RDONLY` attachment) | Found and fixed (2026-10-11): such a page could be made writable, changing every other mapping's frames |
| A `PROT_NONE` page across `fork` | `PROT_NONE` is a non-present leaf that keeps its frame (`PROT_NONE_LEAF`), copied by `fork` and freed by teardown | Found and fixed (2026-10-11): it was a present leaf without `USER_ACCESSIBLE`, which `fork` aliased into the child; the child could free the frame while the parent still mapped it (`d838d47`) |
| A null dereference reaching mapped memory | Page zero is never mapped (`VM_MINUSER = 0x1000`) | — |

### 3.4. Kernel information leaks

| Tool | Defence | Gap / Target |
|---|---|---|
| Padding bytes in structures copied out | Copied-out types are `Pod`: no implicit padding, explicit zeroed fields instead. Found and fixed: `sysinfo` (8 bytes), `ipc_perm` (4), `stack_t` (4) | Every new copied-out type MUST be `Pod` with a size assert |
| Reading kernel memory through the CPU (Meltdown-class) | KPTI (`cpu::pti`): ring 3 runs on a second page table that maps only the entry area and the process's own user pages, never the rest of the kernel, so a speculative read of a kernel address has no translation to resolve. On by default for a `GenuineIntel` CPU without `RDCL_NO`, off otherwise; `pti=`/`kpti=`/`meltdown=` on\|off override it, and `vm.pmap.pti`/`machdep.kpti`/`hw.meltdown` report the state. Only the entry stubs, the IDT/GDT/TSS and the trampoline stacks are mapped during a transition; CR3 switches on every entry and exit (NMI/#DF/#MC save and restore CR3 on their IST stacks). PCID, where the CPU has it, keeps the kernel TLB across a syscall and flushes only the user TLB on return. A boot audit (`[kpti]`) confirms the user table maps nothing of the kernel outside the entry area, and `meltdown-poc` checks it from a live process | **Gap:** no KASLR (§3.3), so whatever leaks through some other channel is at a known address. Other speculative classes (Spectre, L1TF, MDS) are not mitigated |

### 3.5. Privilege

| Tool | Defence | Gap / Target |
|---|---|---|
| Set-user-ID executables | Real, effective and saved IDs; `AT_SECURE` for musl; `nosuid` mounts (`282249f`) | — |
| Signalling or rescheduling other users' processes | Permission checks (`kill`, `Cred::may_schedule`) | — |
| Authentication | OpenPAM, `pam_unix` against `master.passwd` (mode `0600`); `sudo` via sudo-rs, `%wheel` | — |
| Running `/sbin/init` | Refuses unless root and pid 1 (`9e1644f`) | — |
| Rust crates calling `libc::syscall` directly | — | **Gap:** the `libc` crate fork's `SYS_*` numbers are Linux's, so such calls reach the wrong system call (v0.3.0) |

### 3.6. Resource exhaustion

| Tool | Defence | Gap / Target |
|---|---|---|
| Opening descriptors | `kern.maxfiles` (`ENFILE`); descriptors in flight over `AF_UNIX`: 1024 per user, 4096 total | **Gap:** oxfs's open-file table is fixed at 2048, system-wide (v0.3.0) |
| `setrlimit` limits | Stored | **Gap: not enforced** (v0.3.0: `NOFILE`, `STACK`, `AS`, `CORE`) |
| A long system call | — | **Gap:** a system call runs with interrupts masked and the kernel isn't preemptible, so one long disk write freezes the machine (with SMP, v0.5.0) |
| Filling the disk or memory | — | **Gap:** oxfs's block pool and the kernel heap are fixed pools; no quotas (the 128 MB work, v0.3.0, revisits the pools) |
| Forking repeatedly | — | **Gap:** fork copies the whole address space eagerly (no COW, later) |

### 3.7. Kernel panics

Any `panic!`, failed `expect`, or ring-0 fault reachable from user input or the network is a
denial of service: a ring-0 fault reboots, and a panic in oxfs reboots (`CLAUDE.md`). New code
MUST NOT panic on anything a user or peer controls; the existing `expect`s on the process table
assume invariants the kernel maintains, not inputs, and are not yet audited as such.

### 3.8. Network

| Tool | Defence | Gap / Target |
|---|---|---|
| Malformed frames and packets | Parsed in Rust with bounds checks | **Gap:** not fuzzed; a reachable panic is a remote denial of service (§3.7) |
| Flooding | — | **Gap:** no firewall or rate limiting; static interfaces and routes (later) |
| TCP | — | **Gap:** stop-and-wait, fixed segment size, no window or congestion control (later) |

### 3.9. Filesystem

| Tool | Defence | Gap / Target |
|---|---|---|
| Long paths and symlink targets | `PATH_MAX` (4096), `ENAMETOOLONG` | — |
| Permissions | Mode, owner and group checks on access; `master.passwd` `0600` | Not audited systematically |

### 3.10. Timing and side channels

Single core, no SMP: no cross-core channels yet. Meltdown is mitigated by KPTI (§3.4); other
speculative-execution attacks (Spectre, L1TF, MDS) are not modelled.

## 4. Rules for new code

4.1. Kernel and module code MUST NOT dereference a user pointer (`USERMEM.md`).

4.2. Every length, count or size from user space MUST be bounded before it sizes an allocation or
a loop.

4.3. Every type copied out to user space MUST have no implicit padding (`Pod`, with a size
assert).

4.4. Code reachable from user input or the network MUST NOT panic on that input.

4.5. Anything acting on another user's resources MUST check credentials.

4.6. A change that adds a tool to §3, or removes a defence, MUST update this document.

4.7. Every new mapping MUST be `NO_EXECUTE` (`cpu::nx::no_execute()`) unless it holds code, and
no mapping may be writable and executable at once. The boot audit (`memory::wx`) MUST report no
writable and executable kernel pages.

4.8. A page-table walk MUST NOT take a non-`USER_ACCESSIBLE` entry in the user range for
kernel-owned: nothing kernel-only is mapped there. Software bits mark what a leaf is
(`SHARED_LEAF`, `CACHED_LEAF`, `PROT_NONE_LEAF`, `MAY_WRITE_LEAF`).

## 5. Verification

5.1. `tests/usermem_syscall_smoke.rs`: bad pointers to every converted call get `EFAULT`; the
direction flag can't make the kernel copy backwards; an unwritable signal frame is `SIGSEGV`.

5.2. The POSIX canary, unchanged by each hardening step (127 / 173 as of 2026-10-07; 126 / 173
from 2026-10-11, losing `mmap/5-1.c`, which treats a refused `PROT_READ | PROT_WRITE |
PROT_EXEC` as a failure although POSIX lets `mmap` refuse a combination it doesn't support).

5.3. `tests/wx_syscall_smoke.rs`: calling an `mmap` page, the stack, `.data` and the `brk` heap
is `SIGSEGV`, and so is writing `.text`; W|X from `mmap` and `mprotect` is `ENOTSUP`; written code
`mprotect`ed to RX runs; `PROT_NONE` pages are copied by `fork`; `mprotect` works on `.data`;
an `SHM_RDONLY` attachment can't be made writable; W|X only for a `wxneeded` program on a
`wxallowed` mount. The boot log's `[wx]` lines report the kernel audit.

## 6. Open questions

1. Fuzzing: a syzkaller-style system call fuzzer, and a packet fuzzer for the network stack.
2. Order of the remaining hardware protections (NX and W^X landed 2026-10-11, KPTI 2026-10-12).
3. Whether KASLR is worth it before every executable is a PIE.
