# OxideBSD kernel threads: design specification

Status: **accepted** (2026-10-21); being implemented (§10).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Motivation

Some kernel work is set off by an interrupt but can't be done in one: registering a disk plugged
into a running system reads its partition table (it sleeps) and makes `/dev` nodes (it
allocates), and pulling one out unmounts its file systems. Until now every sleeping path in the
kernel has run on behalf of a process inside a system call. Kernel threads give such work a
context of its own, as FreeBSD's `kthread(9)`, `kproc(9)` and `taskqueue(9)` do. The first user
is AHCI hot plug (`INSTALLER.md` §5.3); USB storage plug-in (§5.3) and, later, a page daemon or a
buffer flusher are the next.

## 2. Terms

- **Kernel thread**: a schedulable thread that runs only kernel code, in ring 0, and never
  returns to user mode.
- **The kernel process**: process 0, named `kernel` (FreeBSD's `proc0`), whose threads the kernel
  threads are.
- **Wait channel**: an address a sleeping thread waits on, the BSDs' `chan`; any value unique to
  what is waited for (usually the address of the thing).
- **Task**: a function and its argument, queued to be called once by a taskqueue's thread.
- **Taskqueue**: a queue of tasks and the kernel threads that run them.

## 3. The kernel process

3.1. **Kernel threads are entries of the process table whose thread-group id is 0**: the threads of
process 0. No entry has pid 0, which keeps meaning "no process" (`scheduler::current_pid` before
the first switch); each kernel thread has a thread id of its own from the pid space, as a user
thread has.

3.2. The kernel's threads share one address space whose user half is empty (as a thread group
shares one), root's credentials, the root directory as current and root directory, a umask of
`022`, and the kernel's descriptor table (thread group 0, where `fs::fd` already keeps the
console's descriptors for the processes the kernel starts).

3.3. No kernel thread is a thread-group leader (no entry has `pid == tgid` with `tgid` 0), so every
walk of the process table that looks at processes by their leaders (`kill(-1, ...)`, the OOM
killer's choice, `setpriority(PRIO_PGRP/PRIO_USER)`, `RLIMIT_NPROC`) passes them over by
construction. A kernel thread has no parent, process group and session 0 (which no user process
can have), and no controlling terminal; orphans are never given to it.

3.4. **Kernel threads take no signals.** `kill(2)` on a kernel thread's id fails with `EPERM`, as
FreeBSD's does on a system process; so do the other calls that act on a process or thread by id
(`setpriority`, `sched_setparam`, `sched_setscheduler`, `procctl`, `ptrace` when it exists). A
signal posted to one by the kernel itself is discarded. They neither stop nor dump core.

3.5. Shutdown and reboot don't wait for kernel threads.

## 4. Running

4.1. A kernel thread runs in ring 0 with interrupts masked, as a system call does (`SFMASK`), and
the system call rules hold for it (CLAUDE.md, "Syscall ABI"): it MUST NOT `hlt` or wait for
`ticks()` to move, and it waits for anything interrupt-driven by sleeping through the scheduler,
which idles with interrupts enabled.

4.2. **Kernel threads are cooperative.** A kernel thread runs until it sleeps (§5.3), yields
(`kthread_yield`) or exits; the timer never preempts it (kernel-mode preemption stays a known gap
until SMP, `ROADMAP.md` v0.5.0). A kernel thread that runs for more than 100 ms without giving up
the CPU is logged, the first 8 times: `[kthread] <name> ran <n> ms without sleeping`.

4.3. Kernel threads are scheduled in a band of their own between the real-time threads and the
time-sharing ones, as in FreeBSD (whose kernel priorities lie between `PRI_MIN_REALTIME`'s band
and `PRI_MIN_TIMESHARE`'s): a runnable kernel thread runs before any time-sharing thread, after any
real-time one. Kernel threads of equal standing take turns.

4.4. A new kernel thread starts at its function, with its argument; returning from that function
ends the thread as `kthread_exit` does.

4.5. A kernel thread MAY be created before the scheduler starts (from a driver's `init` at boot);
it first runs once the scheduler does.

## 5. Interface

5.1. `kthread_add(func: fn(usize), arg: usize, name: &str) -> Result<Pid, Errno>` creates a kernel
thread; its id, or `ENOMEM`. The name is at most 19 characters (FreeBSD's `MAXCOMLEN`), longer
ones cut.

5.2. `kthread_exit() -> !` ends the calling kernel thread; its kernel stack is freed once the
scheduler has switched off it.

5.3. **Sleep and wakeup**, FreeBSD's `tsleep(9)` (in `kern_synch`):

- `tsleep(chan: usize, timeout: Option<u64>) -> Slept` sleeps on wait channel `chan` until woken
  or, with a timeout, until that many timer ticks have passed: `Slept::Woken` or
  `Slept::TimedOut`. Not interrupted by signals.
- `wakeup(chan)` wakes every thread asleep on `chan`; `wakeup_one(chan)` the one that has slept
  longest.
- `pause(ticks)`: sleeps for `ticks` ticks on a channel no one wakes.

A sleeper MUST check its condition again when it wakes, and sleep again if the condition doesn't
hold (CLAUDE.md, "Processes, scheduling"): a wakeup is a hint, not a promise. Kernel code runs with
interrupts masked, so a wakeup from an interrupt handler can't fall between the check and the
sleep. `wakeup` never sleeps and MAY be called from an interrupt handler; `tsleep` MAY be called by
any thread in kernel code (a system call too), never by an interrupt handler.

5.4. `kthread_yield()` gives the CPU to any ready thread and returns when the caller runs again.

## 6. Taskqueues

6.1. A **task** (`struct task`, FreeBSD's) holds a function `fn(arg: usize, pending: u32)`, its
argument, and its queue state. Its owner allocates it statically (or otherwise keeps it alive for
as long as it may be queued) and enqueues it by reference; queueing allocates nothing.

6.2. `taskqueue_enqueue(queue, task)` queues `task` if it isn't queued, else adds one to its count
of pending enqueues, and wakes the queue's thread. It never sleeps or allocates, and MAY be called
from an interrupt handler.

6.3. A queue's thread runs its tasks in the order queued, calling each one's function with the
number of enqueues it absorbed (`pending`, reset first). A task enqueued again while its function
runs is queued again and runs again after it.

6.4. **`taskqueue_thread`** is the system's queue, run by one kernel thread named `taskq`; most
users need nothing else. `taskqueue_create(name)` and `taskqueue_start_threads(queue, n)` give a
subsystem a queue and threads of its own.

6.5. `taskqueue_drain(queue, task)` returns once `task` is neither queued nor running; it sleeps,
so it isn't for interrupt handlers.

## 7. Modules

7.1. Kernel modules MAY create kernel threads and use taskqueues: the kernel exports
`oxidebsd_kthread_add`, `oxidebsd_kthread_exit`, `oxidebsd_kthread_yield`, `oxidebsd_tsleep`,
`oxidebsd_wakeup`, `oxidebsd_wakeup_one`, `oxidebsd_taskqueue_enqueue` (the system queue) and
`oxidebsd_taskqueue_drain`. The task structure is `#[repr(C)]` and defined once, in a crate the
kernel and the modules both use, as the VFS interface types are (`lib/libvfs`).

7.2. A module's kernel thread runs the module's code: that's safe only because modules are never
unloaded. Module unload, when it comes, MUST first end the module's threads and drain its tasks.

## 8. Visibility

8.1. **procfs.** `/proc`'s listing doesn't show kernel threads' ids, and `/proc/<tid>` of one
doesn't exist. `/proc/0` is the kernel process: its `stat` line has pid 0, name `kernel`, parent 0,
and the number of its threads (field 20); its state is `R` if any of its threads is runnable, else
`S`. `/proc/0/task/<tid>/stat` is each kernel thread's own line, its name the thread's. User
threads keep their own `/proc/<tid>` entries as before.

8.2. **ps.** `ps -x` (or `-A`) shows the kernel process as one line, `[kernel]`. `-H` (FreeBSD's:
threads) shows each kernel thread instead, as `[kernel/<name>]` (`[kernel/taskq]`); user threads
are listed one line each already, as they each have a `/proc` entry.

## 9. First users

- AHCI hot plug (`INSTALLER.md` §5.3): the controller's interrupt sees a port's connection change
  (`PxIS.PCS`, `PxIS.PRCS`) and enqueues the port's task on `taskqueue_thread`, which waits for the
  link to settle (`pause`), then registers the drive or retires it.
- USB mass storage plug-in (`INSTALLER.md` step 5), the same way.

## 10. Steps and verification

Each step is one commit, with its test; the suite and the POSIX canary stay green.

1. **Sleep and wakeup, kernel threads, the kernel process** (§3, §4, §5): `tsleep`/`wakeup`, a new
   block reason for them; `kthread_add`/`exit`/`yield`; the kernel band in the scheduler; the
   100 ms log; `EPERM` for calls on kernel threads. Test: a test kernel starts kernel threads that
   sleep, time out, wake each other and exit, and a user program checks that `kill` on one fails
   with `EPERM` and that `kill(-1, ...)` passes them over.
2. **Taskqueues** (§6): `taskqueue_thread` and its `taskq` thread at boot; test: tasks enqueued
   from a kernel thread and from an interrupt handler run, with the right pending counts.
3. **Visibility** (§8): `/proc/0`, `/proc/0/task`, `ps` `[kernel]` and `-H`; test: `ps -axH`
   lists `[kernel/taskq]`.
4. **Module exports** (§7); test: a test module's task and thread.
5. **AHCI hot plug** (§9), tried on real hardware (`INSTALLER.md` §11 step 4).

Progress: step 1 done (2026-10-21): `sys/kern/kern_kthread.rs` (`kthread_add`, `kthread_exit`,
`kthread_yield`, the 100 ms log), `kern_synch::{tsleep, wakeup, wakeup_one, pause}`
(`BlockReason::KernelSleep`), the kernel band (`sched_4bsd::PRI_KERN`), `EPERM` from `kill`,
`sigqueue`, `setpriority`, `sched_setscheduler`, `sched_setparam` and `procctl`, kernel-posted
signals discarded. Kernel threads' ids skip 1. Tested in `kern_syscall_smoke` (section `kthread`).
Step 2 done (2026-10-21): `sys/kern/subr_taskqueue.rs` (`Task`, `enqueue`, `drain`, `create`,
`start_threads`; `TASKQUEUE_THREAD` and its `taskq` thread, started after pid 1). Tested in
`kern_syscall_smoke`: coalesced enqueues (`pending` 3), an enqueue from an interrupt handler (IRQ
13 raised with `int`), a task enqueued again while it runs, `drain` over a sleeping task, a queue of
one's own.

## 11. Decisions

- 2026-10-20 (user): hot plug's work runs in real kernel threads, not at return to user mode and
  not on an explicit rescan.
- 2026-10-21 (user): kernel threads are FreeBSD's: threads of pid 0 (`[kernel]`, `[kernel/<name>]`
  under `-H`); `kthread_add` plus `taskqueue(9)`; exported to modules; cooperative, with a log for
  one that runs too long. procfs hides kernel threads' ids and shows `/proc/0`; user threads keep
  their entries; `ps -H` implemented now.

## 12. Open questions

- User threads are listed in `/proc` one entry each (each its own `ps` line); grouping them under
  their process (Linux's `/proc/<pid>/task`) is left for later.
- Interrupt threads (FreeBSD's ithreads: interrupt handlers run as kernel threads) are not
  planned; with kernel threads in place they become possible.
