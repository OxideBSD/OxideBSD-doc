# OxideBSD programs: file placement inventory

Status: **current** (2026-10-15, `c2595d0`).

## 1. Scope

Every program oxfs seeds into the base system (`sys/modules/oxfs/src/lib.rs`, `seed_file`,
`seed_symlink`, `seed_hardlink` and the generated `seed_tree` lists), by directory and by where
its source lives. The placement rules and every directory are in `hier(7)`
(`share/man/man7/hier.7`). Programs in `/bin` and `/sbin` are static PIE. Elsewhere, OxideBSD's
own programs are dynamic PIEs on `/lib/libc.so`; ports linked at a fixed address (BusyBox, bmake
and others) are static.

Source locations: native programs live at the same path in the tree (`bin/`, `sbin/`, `usr.bin/`,
`usr.sbin/`, `libexec/`); BusyBox applets build from `external/gpl2/busybox`
(`BUSYBOX_APPLETS.md`). Links are marked `->` (symbolic) or `=` (hard).

## 2. `/bin` (44 entries)

| Source | Programs |
|--------|----------|
| Native (`bin/`, 23) | `cat`, `chmod`, `cp`, `echo`, `false`, `kill`, `link`, `ln`, `ls`, `mkdir`, `mv`, `nproc`, `pwd`, `rm`, `rmdir`, `sh`, `sleep`, `sync`, `test`, `touch`, `true`, `unlink`, `vi` |
| Links (1) | `[` = `test` |
| BusyBox (21) | `ash`, `date`, `dd`, `df`, `ed`, `egrep`, `expr`, `fgrep`, `grep`, `gunzip`, `gzip`, `hostname`, `pgrep`, `pkill`, `ps`, `realpath`, `sed`, `stty`, `tar`, `timeout`, `zcat` |

`sh` is OxideBSD's own shell (`lib/libsh`). `vi` is OpenVi (`bin/vi`). `ash` remains for autoconf
`configure` scripts and as `/sbin/emergency`'s fallback shell.

## 3. `/sbin` (25 entries)

| Source | Programs |
|--------|----------|
| Native (`sbin/`, 16) | `dmesg`, `emergency`, `fsck`, `fsck_oxfs`, `init`, `init_sh`, `lsoxmod`, `mount`, `newfs_oxfs`, `nologin`, `rcorder`, `reboot`, `shutdown`, `sysctl`, `umount`, `update` |
| Third-party (1) | `zstd` (`external/bsd/zstd`, static, so a set archive unpacks before `/usr` exists; `RAM_FLOOR.md` §4.3.4) |
| Links (6) | `halt` = `reboot`, `poweroff` = `reboot`, `mount_nullfs` = `mount`, `lsmod` -> `lsoxmod`, `unzstd` = `zstd`, `zstdcat` = `zstd` |
| BusyBox (2) | `mknod`, `ping` |

`init_sh` is the non-interactive interpreter for `/etc/rc` and `/etc/rc.d/*` (`INIT_SH.md`).

Not yet present, and expected here: `ifconfig` and `route` (need interface-configuration ioctls).

## 4. `/usr/bin` (127 entries)

| Source | Programs |
|--------|----------|
| Native (`usr.bin/`, 12) | `apropos`, `crontab`, `ipcrm`, `ipcs`, `logger`, `login`, `man`, `mkimg`, `more`, `oxdoc`, `passwd`, `protect` |
| Forks and vendored ports (12) | `bmake` (`usr.bin/make`), `clear`, `tput`, `tset` (and `reset`, a link to it; `lib/ncurses`), `nano` (`usr.bin/nano`), `ninja` (`usr.bin/ninja`), `clang`, `ld.lld` (`external/apache2/llvm`), `openssl` (`external/apache2/openssl`), `zdump` (`external/public-domain/tz`), `sudo` and `su` (`external/mit/sudo-rs`, set-user-ID root, mode 4755) |
| Links (5) | `whatis` -> `apropos`, `less` -> `more`, `make` -> `/usr/bin/bmake`, `clang++` -> `clang`, `sudoedit` -> `sudo` |
| BusyBox (94) | listed in `BUSYBOX_APPLETS.md` §2 |

Clang's resource directory is `/usr/lib/clang/23`.

## 5. `/usr/sbin` (14 entries)

| Source | Programs |
|--------|----------|
| Native (`usr.sbin/`, 10) | `certctl`, `cron`, `fsconf_mkdb`, `makefs`, `makewhatis`, `newsyslog`, `periodic` (a shell script), `pwd_mkdb`, `syslogd`, `tzsetup` |
| Vendored and forks (2) | `zic` (`external/public-domain/tz`), `visudo` (`external/mit/sudo-rs`) |
| BusyBox (2) | `chroot`, `ntpd` |

## 6. Other directories

| Directory | Programs |
|-----------|----------|
| `/usr/libexec` | `getty` (`libexec/getty`) |
| `/usr/games` | `doom` (`external/gpl2/doomgeneric`) |
| `/usr/share/games/doom` | `doom1.wad` (the shareware IWAD; doomgeneric's `FILES_DIR`) |
| `/lib` | `libc.so`, `ld-musl-x86_64.so.1` -> `libc.so`, `libgcc_s.so.1` |
| `/usr/lib` | `libc.so` and `libgcc_s.so` (links into `/lib`) |
| `/usr/tests` | `float-smoke`, `musl`, `smoke`, `std-hello-oxidebsd`, `std-process-fs-oxidebsd`, `std-thread-net-signal-oxidebsd` |
| `/usr/tests/*` | `aslr/pie-aslr-probe`, `at/at-smoke`, `bin/run.sh`, `cred/cred-smoke`, `cron/run.sh`, `devfs/run.sh`, `dynlink/dynlink-smoke`, `dynlink/dynlink-pie-smoke`, `fd/fd-smoke`, `init/init-smoke`, `ipc/sem-open-smoke`, `net/run.sh`, `net/loopback-smoke`, `net/socket-smoke`, `openssl/run.sh`, `openssl/openssl-smoke`, `openssl/openssl-rs-smoke`, `oxfs/hello.txt`, `oxfs/big.txt`, `pagecache/pagecache-smoke`, `poll/ppoll-smoke`, `posix/run.sh` (and the pilot corpus), `pthread/pthread-smoke`, `pthread/pthread-cancel-crash`, `pthread/pshared-cond-crash`, `rc/run.sh`, `sh/run.sh` (and the shell corpus), `syslog/run.sh`, `sysctl/sysctl-smoke`, `tty/tty-smoke`, `tz/run.sh`, `tz/tz-smoke` |
| `/usr/share/examples` | `clang/hello.c`, `clang/hello.cpp`, `ninja/` (a two-file ninja project) |

`/usr/tests` holds regression fixtures, not on any `PATH`. Nothing but the hierarchy's own
directories is seeded in `/`.

## 7. Removed programs

BusyBox applets removed from the base system, with their replacements and reasons:
`BUSYBOX_APPLETS.md` §3.
