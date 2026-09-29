# OxideBSD getty, login and PAM: design specification

Status: **accepted design, partly implemented** (not yet: the serial-terminal tests of §9.2, which need `tty01`; init's boot and shutdown records, §8.2; `who`). Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interfaces are documented in the manual pages `getty(8)`, `gettytab(5)`, `login(1)`,
`login.conf(5)`, `pam.conf(5)`, `pam_unix(8)`, `pam_nologin(8)`, `pam_securetty(8)` and
`utmpx(3)`; this document records the design. Where FreeBSD, NetBSD and OpenBSD agree it follows them; where they
differ, the majority. It depends on `TTY.md` (terminal devices) and
`INIT.md` (who starts getty).

## 1. Scope

The path from a terminal to a user's shell: init starts `getty` on each terminal in `/etc/ttys`;
getty prepares the line and reads a user name; `login` authenticates through PAM, applies the
user's login class, records the session, and starts the user's shell.

## 2. Components

| Path | Role | Source |
|---|---|---|
| `/usr/libexec/getty` | Terminal setup and login prompt | Rust, `libexec/getty` |
| `/etc/gettytab` | getty's terminal descriptions (`gettytab(5)`) | `etc/gettytab` |
| `/usr/bin/login` | Authentication and session start | Rust, `usr.bin/login` |
| `/etc/login.conf` | Login classes (`login.conf(5)`) | `etc/login.conf` |
| `/etc/pam.d/` | PAM policies: `system`, `login`, `other` | `etc/pam.d/` |
| `/usr/lib/libpam.a` | OpenPAM, static, with OxideBSD's modules | `external/bsd/openpam` + `lib/libpam/modules` |
| `/etc/motd` | Message of the day | `etc/motd` |
| `/etc/master.passwd`, `/etc/passwd`, `/usr/sbin/pwd_mkdb` | Accounts (`passwd(5)`, `pwd_mkdb(8)`) | `etc/master.passwd`, Rust `usr.sbin/pwd_mkdb` |
| `/var/run/utmpx`, `/var/log/wtmpx`, `/var/log/lastlogx` | Session records (`utmpx(3)`) | musl |
| `/etc/nologin` | Refuses logins while it exists | written by `shutdown(8)` |

getty and login MUST NOT reuse BusyBox's; BusyBox `getty` and `login` stop being installed.

## 3. Capability databases

3.1. `gettytab(5)` and `login.conf(5)` use the same termcap-style format as the BSDs' `getcap(3)`:
records of `name|alias:cap:cap:...`, continued with `\`, capabilities `name` (boolean),
`name#number`, `name=string` (with `\` and `^` escapes), `name@` (cancels), and `tc=name`
(inherits another record).

3.2. One Rust parser implements this format for both files (`lib/libgetcap`). Unlike the BSDs,
OxideBSD reads the text files directly; there is no `cap_mkdb` database.

**Rationale.** A second, compiled copy of each file is a source of stale configuration; the files
are small.

## 4. getty

4.1. init runs `getty <type> <tty>`, `<type>` naming a `gettytab` record (default `default`) and
`<tty>` a device under `/dev`.

4.2. getty MUST open the device, become a session leader, make the terminal its controlling
terminal, and use it as standard input, output and error. It MUST then configure the line from the
record: speed (`sp`, and the `nx` chain for speed cycling on a serial line), parity (`ep`, `op`,
`np`, `8b`), control characters (`er`, `kl`, `in`, `qu`, `ec`, `eo`...), and output processing.

4.3. getty prints the `if` file or `im` banner, expanding the BSDs' `%` escapes (`%h` host name,
`%t` terminal, `%s` system name, `%m` machine, `%r` release, `%v` version, `%d` date), then the
`lm` prompt (default `login: `), and reads a name. A name typed in upper case only sets the
terminal to upper-case mode, as in the BSDs. With `to`, getty exits after that many idle seconds.

4.4. getty then executes `lo` (default `/usr/bin/login`) as `login -p <name>`; with `al`
(autologin) it runs `login -f <user>` without prompting.

4.5. Capabilities getty does not implement MUST be parsed and ignored, not rejected.

## 5. login

5.1. `login [-fp] [-h host] [user]`: `-f` skips authentication (only when run by root, as by
getty's autologin); `-p` preserves the environment getty passed; `-h` names the remote host.

5.2. **Authentication** MUST go through PAM, service name `login`: `pam_start`,
`pam_authenticate`, `pam_acct_mgmt` (which covers nologin and secure terminals, §6), then
`pam_setcred` and `pam_open_session`. A failed attempt MUST NOT say whether the user exists.

5.3. **Retries.** After a failure login prompts again. The number of attempts and the delay
between them come from the login class: `login-retries` (default 10) and `login-backoff`
(default 3, after which each further attempt waits five seconds more), as in FreeBSD and NetBSD. OxideBSD
adds `login-timeout` (default 300 seconds), after which login exits.

5.4. **Session setup.** login MUST, in order: change the terminal's owner to the user, its group
to `tty`, and its mode to 0620; record the session (§8); apply the user's login class (§7); set
the group list (`initgroups`), group ID and user ID, dropping root; set `HOME`, `SHELL`, `USER`,
`LOGNAME`, `PATH`, `TERM` and `MAIL`; change to the home directory (to `/` if it is missing,
unless the class sets `requirehome`); print `/etc/motd` unless `~/.hushlogin` exists (the last-login line comes from `pam_lastlog`, as
in FreeBSD and NetBSD); and execute
the user's shell as a login shell (`argv[0]` starting with `-`).

5.5. **Logout.** login stays as the shell's parent: when the shell exits it closes the PAM session,
records the logout, and returns the terminal to root with mode 0600.

**Rationale.** The BSDs' login also waits for the shell, so that the session can be closed and
recorded; PAM session modules require it.

## 6. PAM

6.1. OpenPAM (release 2025-05-31) is vendored as a plain source tree under
`external/bsd/openpam` and built by `build.rs` into a static `libpam.a` with musl; no autotools.

6.2. OxideBSD has no `dlopen`. Modules are linked into the programs that use PAM. OpenPAM's
static-module lookup (`openpam_static.c`) is changed to walk a NULL-terminated table,
`openpam_static_modules[]`, that the modules library defines, in place of the GNU linker sets
upstream uses. The change is local to the vendored tree and SHOULD be offered upstream.

6.3. The modules are written in Rust (`lib/libpam/modules`), exporting OpenPAM's `struct
pam_module` for each:

| Module | Functions | Behavior |
|---|---|---|
| `pam_unix` | auth, account, password | Checks the password against `/etc/master.passwd` with `crypt(3)`; account checks the expire and change fields and locked (`!`, `*`) entries; password changes it |
| `pam_nologin` | account | If `/etc/nologin` exists, prints it and refuses everyone but root |
| `pam_securetty` | account | Refuses root on a terminal not marked `secure` in `/etc/ttys` |
| `pam_lastlog` | session | Prints the user's last login, and records this one, in `lastlogx` |
| `pam_permit`, `pam_deny` | all | Always succeed / always fail |

6.4. Policies follow FreeBSD's and NetBSD's layout: `/etc/pam.d/system` holds the common stack, and
`/etc/pam.d/login` includes it and adds `pam_nologin` and `pam_securetty` to its account stack.
`/etc/pam.d/other` denies everything.

6.5. A C program that uses PAM links `libpam.a` and the modules' static library; a Rust program
depends on the modules crate directly (linking both would duplicate Rust's runtime).

## 7. Login classes

7.1. `/etc/login.conf` follows `login.conf(5)`, which all three BSDs share. A user's class is the
fifth field of `/etc/master.passwd` (§7.4); an empty class means `default`, and root's is `root`.

7.2. login MUST apply: `path`, `setenv`, `umask`, `priority`, `lang`, `charset`, `timezone`,
`shell`, `welcome` (motd file), `hushlogin`, `nologin`, `requirehome`, `login-retries`,
`login-backoff`, `login-timeout`, and the resource limits (`cputime`, `filesize`, `datasize`,
`stacksize`, `coredumpsize`, `memoryuse`, `memorylocked`, `maxproc`, `openfiles`, `vmemoryuse`),
each with `-cur` and `-max` forms.

7.3. Resource limits are set with `setrlimit`, whether or not the kernel enforces each one yet.

7.4. **Accounts** move to the layout all three BSDs use: `/etc/master.passwd` (mode 0600) holds
every field, `name:password:uid:gid:class:change:expire:gecos:home:shell`; `pwd_mkdb(8)` generates
the public `/etc/passwd` from it, with the password replaced by `*` and the class, change and
expire fields removed. `/etc/shadow` is removed. musl's `getspnam(3)` is changed to read
`/etc/master.passwd`, mapping the password, change and expire fields into `struct spwd`, so
existing callers keep working. Unlike the BSDs, `pwd_mkdb` writes no `.db` files; libc reads the
text files.

## 8. Session records

8.1. musl's `utmpx(3)` functions, stubs today, are implemented in OxideBSD's musl fork using
NetBSD's files, whose names OpenBSD's `utmp` files share: `/var/run/utmpx` (current sessions),
`/var/log/wtmpx` (history) and `/var/log/lastlogx` (each user's last login). Records are musl's
`struct utmpx`, written whole.

8.2. login writes a `USER_PROCESS` record at login and a `DEAD_PROCESS` record at logout;
`/sbin/init` writes `BOOT_TIME` and `SHUTDOWN_TIME` (INIT.md).

8.3. `utmpx` does not survive a reboot: `rc.d/cleanvar` empties `/var/run`, so no session
appears active after a crash.

## 9. Verification

9.1. Host unit tests for the capability-database parser, gettytab `%` expansion, and login.conf
value parsing.

9.2. On-target tests: getty on the serial terminal (`TTY.md`) driven through a pty on the host:
the banner and prompt appear; a name reaches login; `user`/`user` logs in and gets a shell with
the right uid, environment, home and umask; a wrong password is refused and delayed; root is
refused on an insecure terminal; `/etc/nologin` refuses `user`; `who` shows the session and
logout removes it.

## 10. Open questions

1. Whether `login-timeout` should be proposed upstream, or stay OxideBSD's.
2. Account tools: `vipw`, `chpass`, `passwd` and `pw`/`adduser` replacing BusyBox's, which edit
   `/etc/shadow`.
