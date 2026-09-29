# OxideBSD sockets and local sockets: design specification

Status: **draft for review.** Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interfaces are documented in the manual pages `socket(2)`, `sendmsg(2)`, `recvmsg(2)`,
`getsockopt(2)`, `getpeereid(3)` and `unix(4)`; this document records the design. Where FreeBSD,
NetBSD and OpenBSD agree it follows them; where they differ, the majority. Linux interfaces are
provided alongside where §8 and §9 say so. `SYSLOG.md` depends on this document (`/dev/log`).

The source layout is the BSDs': the socket layer and local sockets are interprocess communication
and live in `sys/kern` (`uipc_*`), the Internet protocols in `sys/netinet`, interfaces in
`sys/net`.

## 1. Scope

1.1. A generic socket layer in the kernel, into which every address family plugs: the existing
`AF_INET` protocols (UDP, TCP, raw ICMP) and the new `AF_UNIX`.

1.2. `AF_UNIX` (`AF_LOCAL`) sockets of types `SOCK_STREAM`, `SOCK_DGRAM` and `SOCK_SEQPACKET`,
named in the file system or in the abstract namespace, or unnamed.

1.3. Descriptor passing (`SCM_RIGHTS`) and credential passing, in the BSD form and the Linux form.

1.4. A socket system-call interface that carries every argument POSIX defines, replacing the
reduced forms in use today (§4).

1.5. Out of scope: `AF_INET6`, a loopback interface, and `SO_PASSSEC`/`SCM_SECURITY`.

## 2. Components

| Path | Role |
|---|---|
| `sys/kern/uipc_socket.rs` | The socket object, the protocol switch, and the family-independent system calls |
| `sys/kern/uipc_usrreq.rs` | `AF_UNIX`: addresses, connections, buffers, descriptor and credential passing |
| `sys/netinet/` | `AF_INET` protocols (`ip`, `udp`, `tcp`, `icmp`, `arp`), as protocol-switch entries |
| `sys/net/` | Interfaces and Ethernet |
| `sys/drivers/rtl8139.rs` | The network interface driver (moved from `sys/net/`) |
| `sys/modules/socket` | Registers the socket system calls, for every family (renamed from `sys/modules/net`) |
| `sys/modules/oxfs` | Socket inodes (`S_IFSOCK`) |
| `external/mit/musl` | `src/network/*` wrappers, `getpeereid(3)`, credential structures |

## 3. The socket layer

3.1. Every socket is an open file description of kind `Socket` referring to one kernel socket
object. The object records the domain, type and protocol; its state (bound, listening, connecting,
connected, read side shut, write side shut); its pending error (`SO_ERROR`); its options; a receive
buffer; and the protocol's own control block.

3.2. **Protocol switch.** Each supported `(domain, type, protocol)` has one entry providing:
attach, bind, connect, listen, accept, send, receive, shutdown, readiness, local and peer address,
option get and set, and detach. The generic layer MUST NOT contain code specific to a family.
`socket(2)` with an unsupported domain fails with `EAFNOSUPPORT`, an unsupported type or protocol
with `EPROTONOSUPPORT` (or `EPROTOTYPE` for a protocol that exists under another type).

3.3. **Family-independent behavior** implemented once by the generic layer:
1. `SOCK_CLOEXEC` and `SOCK_NONBLOCK` in `socket(2)`, `socketpair(2)` and `accept4(2)`.
2. Blocking, `O_NONBLOCK`, `MSG_DONTWAIT`, `SO_RCVTIMEO` and `SO_SNDTIMEO` (`EAGAIN` on expiry).
3. Interruption by a signal: `EINTR`, or a restart under `SA_RESTART` when no data has been
   transferred and no timeout is set, as for any other slow system call.
4. The `MSG_*` flags: `MSG_PEEK`, `MSG_WAITALL`, `MSG_DONTWAIT`, `MSG_TRUNC`, `MSG_CTRUNC`,
   `MSG_EOR`, `MSG_NOSIGNAL`, `MSG_CMSG_CLOEXEC`. A flag that a protocol does not support
   (`MSG_OOB` on `AF_UNIX`, for example) fails with `EOPNOTSUPP`; flags are never ignored.
5. The `SOL_SOCKET` options `SO_TYPE`, `SO_DOMAIN`, `SO_PROTOCOL`, `SO_ERROR`, `SO_ACCEPTCONN`,
   `SO_RCVBUF`, `SO_SNDBUF`, `SO_RCVLOWAT`, `SO_RCVTIMEO`, `SO_SNDTIMEO`, `SO_REUSEADDR`,
   `SO_KEEPALIVE`, `SO_LINGER`, `SO_NOSIGPIPE` and `SO_PEERCRED` (§9.2). An unknown option fails with
   `ENOPROTOOPT`.
6. `SIGPIPE`: sending on a stream or sequenced-packet socket whose write side is shut down, or
   whose peer is gone, fails with `EPIPE` and sends `SIGPIPE` to the calling thread, unless
   `MSG_NOSIGNAL` or `SO_NOSIGPIPE` is set.
7. `read(2)`, `write(2)`, `readv(2)` and `writev(2)` on a socket are `recvmsg`/`sendmsg` with no
   address, no control data and no flags.
8. `fstat(2)` reports `S_IFSOCK`.
9. Readiness for `poll(2)`, `ppoll(2)` and `select(2)`: readable when data, end-of-file, a pending
   error or (on a listening socket) a pending connection is available; writable when the send
   would not block. `POLLHUP` once both directions are shut down or the peer is gone.

3.4. **Waiting.** `AF_UNIX` sockets change state only when another process runs, so a waiter
blocks and is woken, as for pipes. `AF_INET` sockets keep the existing pulled model (the network
interface is serviced by the waiter).

**Rationale.** Today each socket call walks a fixed chain (UDP, then TCP, then ICMP) and the C
library drops arguments the system calls cannot carry. A protocol switch is how every BSD kernel
structures sockets; it makes a new family a table entry instead of another link in the chain.

## 4. System-call interface

4.1. The native ABI passes at most four arguments. Calls that need more take a pointer to a
structure in the caller's memory, as the `*at()` family does.

4.2. The socket system calls are:

| Call | Number | Arguments |
|---|---|---|
| `socket` | 140 | `(domain, type, protocol)` |
| `bind` | 141 | `(fd, addr, addrlen)` |
| `connect` | 145 | `(fd, addr, addrlen)` |
| `listen` | 146 | `(fd, backlog)` |
| `accept` | 147 | `(fd, addr, addrlen_ptr)` |
| `socketpair` | 149 | `(domain, type, protocol, sv)` |
| `shutdown` | 152 | `(fd, how)` |
| `getsockname` | 559 | `(fd, addr, addrlen_ptr)` |
| `sendmsg` | 577 | `(fd, msghdr, flags)` |
| `recvmsg` | 578 | `(fd, msghdr, flags)` |
| `getsockopt` | 579 | `(fd, sockopt)` |
| `setsockopt` | 580 | `(fd, sockopt)` |
| `getpeername` | 581 | `(fd, addr, addrlen_ptr)` |
| `accept4` | 582 | `(fd, addr, addrlen_ptr, flags)` |

`msghdr` is the C library's `struct msghdr`. `sockopt` points to `{ int64 level; int64 name;
uint64 optval; uint64 optlen; }`, where `optlen` is the option's length for `setsockopt` and the
address of a `socklen_t` for `getsockopt`.

4.3. `sendto`, `recvfrom`, `send` and `recv` MUST be implemented in the C library over `sendmsg`
and `recvmsg`. Every address length passed in is honored and every address length returned is the
actual length of the address (§5.4).

4.4. The former `sendto` (142), `recvfrom` (143) and three-argument `setsockopt` (144) numbers are
retired: they MUST fail with `ENOSYS` and MUST NOT be reassigned.

4.5. Limits: at most `IOV_MAX` (1024) elements in `msg_iov`; at most 4096 bytes of control data
per message.

## 5. Local socket addresses

5.1. An `AF_UNIX` address is the C library's `struct sockaddr_un` (`sun_family`, then a
108-byte `sun_path`). There are three kinds, told apart by `addrlen` and the first path byte:

| Kind | Form | Name |
|---|---|---|
| Unnamed | `addrlen == sizeof(sa_family_t)` | none |
| Path name | `sun_path[0] != '\0'` | the bytes up to the first NUL or the end of `addrlen` |
| Abstract | `sun_path[0] == '\0'`, `addrlen > sizeof(sa_family_t)` | exactly `sun_path[1 .. addrlen - 2]`; NUL bytes are part of it |

5.2. **Path names.** `bind(2)` with a path name MUST create a new file of type `S_IFSOCK` with mode
`0777 & ~umask`, owned by the caller. It fails with `EADDRINUSE` if anything exists at the path,
and with the usual path errors (`ENOENT`, `ENOTDIR`, `EACCES` for want of write and search
permission on the directory, `ENAMETOOLONG`, `ELOOP`, `EROFS`). The file names the socket, not the
reverse: closing the socket leaves the file, and removing the file leaves the socket working for
already-connected peers. Renaming the file moves the name. `connect(2)` and sending to a path name
require write permission on the file (`EACCES`); a socket file with no socket bound to it gives
`ECONNREFUSED`; a file of another type gives `ENOTSOCK`. `open(2)` on a socket file fails with
`EOPNOTSUPP`.

5.3. **Abstract names** (from Linux) exist only while a socket is bound to them. They are not
files, carry no permissions, are not subject to `chroot(2)`, and are released when the socket is
closed. `bind(2)` to a name already bound fails with `EADDRINUSE`. Binding with an unnamed
address (`addrlen == sizeof(sa_family_t)`) binds the socket to a fresh abstract name of five
hexadecimal digits, as Linux does ("autobind").

5.4. `getsockname(2)`, `getpeername(2)`, `accept(2)` and `recvmsg(2)` return:
`offsetof(sun_path) + strlen(path) + 1` for a path name, `sizeof(sa_family_t)` for an unnamed
socket, and `sizeof(sa_family_t) + 1 + length` for an abstract name. A returned path name is the
path as given to `bind(2)`.

**Rationale.** The BSDs keep a `sun_len` byte and a 104-byte path; the C library here is musl,
whose `struct sockaddr_un` is Linux's, and the kernel follows the library. The abstract namespace
is Linux's; it is provided because ported software uses it and the planned Linux compatibility
layer needs it.

## 6. Stream and sequenced-packet sockets

6.1. `listen(2)` marks a bound socket as accepting connections, with a queue of at most
`min(backlog, 128)` connections not yet accepted; a negative or zero backlog means 1. `listen(2)` on an
unbound socket fails with `EINVAL`.

6.2. `connect(2)` to a listening socket completes at once: the new connection enters the
listener's queue, and both sides may send immediately. It fails with `ECONNREFUSED` when the
queue is full, as in the BSDs; it does not wait. `accept(2)` takes connections from the queue in
arrival order.

6.3. Each direction of a connection has one buffer, sized by the receiver's `SO_RCVBUF` (default
64 KiB, range 512 bytes to 1 MiB). A send blocks while the buffer lacks room.

6.4. `SOCK_STREAM` carries bytes without boundaries, except that a receive MUST NOT return data
from two sends if the later one carried control data: control data stays attached to the bytes it
was sent with.

6.5. `SOCK_SEQPACKET` keeps record boundaries. A record larger than the receive buffer given is
truncated, the rest of it is discarded, and `MSG_TRUNC` is set in `msg_flags`. Every record
ends with `MSG_EOR`.

6.6. **Shutdown and close.** After `shutdown(SHUT_WR)` the peer reads end-of-file once the buffer
is drained. After `shutdown(SHUT_RD)` data arriving is discarded. When a side closes, the other
reads the remaining data and then end-of-file, and its sends fail with `EPIPE` (§3.3.6).
Connections still queued when a listener closes are reset: their reads fail with
`ECONNRESET`.

## 7. Datagram sockets

7.1. Messages keep their boundaries. A message larger than the sender's `SO_SNDBUF` (default
64 KiB) fails with `EMSGSIZE`. A message larger than the receiver's buffer given is truncated and
`MSG_TRUNC` is set.

7.2. Each receiving socket queues at most `SO_RCVBUF` bytes (default 64 KiB). A message that does
not fit is dropped and the send fails with `ENOBUFS`, as in the BSDs.

7.3. `connect(2)` sets the default destination for sends without an address. It does not filter
what the socket receives. Connecting to an unnamed address (`AF_UNSPEC`) removes the default
destination.

7.4. When the default destination's socket is closed, a send without an address fails with
`ENOTCONN`; the sender may connect again.

7.5. A message from a sender with no name arrives with an unnamed address.

## 8. Descriptor passing

8.1. A control message of level `SOL_SOCKET`, type `SCM_RIGHTS`, carrying an array of `int`,
sends the descriptions those descriptors refer to. Every descriptor MUST be open in the sender
(`EBADF` otherwise). The kernel holds a reference to each description from the send until it is
received or discarded; closing the sender's descriptors does not affect a message in flight.

8.2. On receipt, each description is installed in the receiver at the lowest free descriptor,
with `FD_CLOEXEC` set if `MSG_CMSG_CLOEXEC` was given. If the control buffer is too small for all
of them, or the receiver cannot open more descriptors, the descriptions that were not installed
are closed and `MSG_CTRUNC` is set.

8.3. A message discarded unread (by `SHUT_RD`, by closing its socket, or by a datagram overflow)
closes the descriptions it carried.

8.4. **Garbage collection.** A socket descriptor in flight may make itself unreachable (sent over
itself, or in a cycle of sockets). When a local socket that has descriptors in flight is closed,
the kernel MUST run a mark-and-sweep collection over in-flight socket descriptions, as the BSDs'
`unp_gc` does, and close those no process can reach.

8.5. At most 1024 descriptions sent by one user may be in flight at once, and at most 4096
system-wide; a send beyond either limit fails with `ETOOMANYREFS`. Root is subject to the
system-wide limit only.

## 9. Credentials

9.1. A process's credentials here are its process ID, user ID and group ID. Until effective and
saved IDs exist (`SUDO.md`), the effective IDs equal the real ones, and the group list is the
single group ID.

9.2. **Connection credentials** are recorded when a connection is made: the connecting side
records the listener's credentials as of `listen(2)`, the accepted side records the connector's as
of `connect(2)`, and each end of a `socketpair(2)` records its creator's. They are read by:
1. `getpeereid(3)` (all three BSDs): the peer's effective user and group IDs;
2. `getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED)` (FreeBSD): a `struct xucred` (`cr_version`
   `XUCRED_VERSION`, `cr_uid`, `cr_ngroups`, `cr_groups[16]`, `cr_pid`);
3. `getsockopt(fd, SOL_SOCKET, SO_PEERCRED)` (Linux): a `struct ucred` (`pid`, `uid`, `gid`).

Each fails with `ENOTCONN` on an unconnected socket and `EINVAL` on a socket of another family.

9.3. **Per-message credentials, BSD form.** A sender that includes a control message of type
`SCM_CREDS` has its contents replaced by the kernel with the sender's `struct cmsgcred`
(`cmcred_pid`, `cmcred_uid`, `cmcred_euid`, `cmcred_gid`, `cmcred_ngroups`,
`cmcred_groups[16]`), which the receiver gets unchanged. The sender cannot forge it.

9.4. **Per-message credentials, Linux form.** A receiver with `SO_PASSCRED` set receives an
`SCM_CREDENTIALS` control message (`struct ucred`) with every message. A sender may supply one
itself; the kernel MUST reject it with `EPERM` unless its `pid` is the sender's and its `uid` and
`gid` are the sender's, or the sender is root. Without one, the kernel supplies the sender's own.

9.5. **Per-message credentials, receiver-requested (FreeBSD, NetBSD).** A receiver that sets
`LOCAL_CREDS` (level `SOL_LOCAL`) gets an `SCM_CREDS` control message holding the sender's
`struct sockcred` (`sc_uid`, `sc_euid`, `sc_gid`, `sc_egid`, `sc_ngroups`, `sc_groups[]`): with
every message on a datagram socket, and with the first receive only on a stream or
sequenced-packet socket. `LOCAL_CREDS_PERSISTENT` instead gives an `SCM_CREDS2` control message
holding `struct sockcred2`, which adds `sc_version` and `sc_pid`, with every message. The two
options are mutually exclusive (`EINVAL`). While either is set, an `SCM_CREDS` message supplied by
the sender (§9.3) is dropped, so the receiver sees one set of credentials, the kernel's.

9.6. `SOL_LOCAL`, `LOCAL_PEERCRED`, `LOCAL_CREDS`, `LOCAL_CREDS_PERSISTENT`, `SCM_CREDS`,
`SCM_CREDS2`, `struct xucred`, `struct cmsgcred`, `struct sockcred`, `struct sockcred2` and
`getpeereid(3)` are added to the C library. Their values MUST NOT collide with any `SOL_*`,
`SO_*` or `SCM_*` value musl already defines.

## 10. Socket pairs

10.1. `socketpair(AF_UNIX, type, 0, sv)` accepts all three types and returns two unnamed sockets
connected to each other. It replaces the pipe-based pair in `sys/fs/pipe.rs`, which is removed.

10.2. Any other domain fails with `EOPNOTSUPP`.

## 11. Internet sockets on the socket layer

11.1. UDP, TCP and raw ICMP become protocol-switch entries without changing their protocol
behavior. They gain what the generic layer provides (§3.3): the `MSG_*` flags, timeouts,
`SO_ERROR`, `getpeername(2)`, honest address lengths.

11.2. An option or flag an `AF_INET` protocol does not implement fails with `ENOPROTOOPT` or
`EOPNOTSUPP`.

## 12. Verification

12.1. `tests/unix_syscall_smoke.rs` with a C fixture using the musl API, one `PASS`/`FAIL` line
per check, covering each numbered requirement of §§5–10 that can be observed from one boot:
naming, permissions, stream/datagram/sequenced-packet semantics, shutdown, descriptor passing
(including a descriptor sent over its own socket and collected), and every credential interface.

12.2. The existing `udp`, `tcp`, `poll`, `ppoll`, `socketpair`, `ping` and `std` networking
tests MUST pass unchanged, and `wget` over HTTPS MUST still work.

## 13. Open questions

None.
