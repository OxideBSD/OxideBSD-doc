# OxideBSD BusyBox: applet roster

Status: **current** (2026-10-18, `9d80771`). 111 applets.

## 1. Scope

BusyBox is vendored unpatched at `external/gpl2/busybox` (tag `1_38_0`). Each applet is its own
static, fixed-address binary: `build_busybox_applet` configures BusyBox with `allnoconfig` plus
the one applet's Kconfig symbol and asserts `NUM_APPLETS == 1`. The roster is the two tuple
arrays `BUSYBOX_APPLETS` (11 entries) and `BUSYBOX_APPLETS_PASS2` (100 entries) in
`build_busybox.rs`; `distrib/install.mtree` installs each binary at the path listed in §2. Editing `build_busybox.rs`
rebuilds every applet (20 to 40 minutes), so roster changes are batched.

Where every program goes, BusyBox or not: `HIER.md`. Native rewrites still planned:
`INIT_WORKPLAN.md`.

## 2. Current roster

| Directory | Count | Applets |
|-----------|------:|---------|
| `/bin` | 14 | `ash`, `ed`, `egrep`, `expr`, `fgrep`, `grep`, `gunzip`, `gzip`, `pgrep`, `pkill`, `ps`, `sed`, `tar`, `zcat` |
| `/sbin` | 1 | `ping` |
| `/usr/bin` | 94 | `ar`, `arch`, `awk`, `base64`, `basename`, `bc`, `bunzip2`, `bzcat`, `bzip2`, `cal`, `chat`, `chgrp`, `chown`, `cksum`, `cmp`, `comm`, `cpio`, `cut`, `dc`, `diff`, `dirname`, `du`, `env`, `expand`, `find`, `flock`, `fold`, `fsync`, `getopt`, `groups`, `head`, `hexdump`, `id`, `install`, `last`, `logname`, `md5sum`, `mesg`, `mkfifo`, `mktemp`, `nc`, `nice`, `nl`, `nohup`, `od`, `paste`, `patch`, `printenv`, `printf`, `readlink`, `renice`, `rev`, `script`, `seq`, `sha1sum`, `sha256sum`, `sha512sum`, `sort`, `split`, `ssl_client`, `stat`, `strings`, `sum`, `tail`, `tee`, `telnet`, `time`, `tr`, `traceroute`, `truncate`, `tsort`, `tty`, `uname`, `uncompress`, `unexpand`, `uniq`, `unxz`, `unzip`, `uptime`, `users`, `uudecode`, `uuencode`, `uuidgen`, `w`, `wall`, `wc`, `wget`, `which`, `who`, `whoami`, `whois`, `xargs`, `xzcat`, `yes` |
| `/usr/sbin` | 2 | `chroot`, `ntpd` |

`arch` is built from Kconfig symbol `BB_ARCH`. `ash` stays in `/bin` because autoconf
`configure` scripts run under it, and it is `/sbin/emergency`'s fallback shell.

Kept although no BSD base system ships them, as the only tool of their kind until a native one
exists: `wget` and `ssl_client` (the only HTTPS client, until a `fetch`).

The roster is kept small on purpose (2026-10-14: "less applets = more better"): an applet stays
only while it is a BSD base tool nothing else provides.

`who`, `w`, `users`, `wall` and `last` are built with `FEATURE_UTMP` (`last` also `FEATURE_WTMP`)
and read the files musl's utmpx(3) keeps, `/var/run/utmpx` and `/var/log/wtmpx` (`LOGIN.md` §8).

## 3. Removed applets

Every applet that has left the roster, newest first. A replacement path names the program that
now occupies the slot; "dropped" means nothing replaced it.

| Commit | Date | Applets | Replacement or reason |
|--------|------|---------|-----------------------|
| `9d80771` | 2026-10-18 | `date`, `dd`, `df`, `hostname`, `mknod`, `realpath`, `stty`, `timeout` | Native Rust `std` programs, same paths |
| `34b5b55` | 2026-10-15 | `ipcrm` | Native `/usr/bin/ipcrm`, with a native `ipcs`, over the `kern.ipc` tables. |
| `cb10bdf` | 2026-10-14 | `clear`, `reset` | ncurses' own `clear` and `tset` (`reset` is a link to it), with `tput`: what the BSDs ship. |
| `cb10bdf` | 2026-10-14 | `ftpget`, `ftpput`, `nslookup` | Dropped: in no BSD base system (the BSDs have `ftp`/`fetch` and `host`/`drill`). |
| `cb10bdf` | 2026-10-14 | `tac`, `setsid`, `factor` | Dropped: not BSD base (`tail -r` does `tac`'s job; `factor` is a `/usr/games` program). |
| `cb10bdf` | 2026-10-14 | `su` | sudo-rs's `su` (`ea7b74b`); built but not installed since. |
| `cb10bdf` | 2026-10-14 | `minips` | BusyBox's full `ps` (`/bin/ps`), added in the same batch. |
| `cb10bdf` | 2026-10-14 | `netcat` | Dropped: the same applet as `nc`, the only name the BSDs ship. |
| `cb10bdf` | 2026-10-14 | `sha3sum`, `base32`, `pidof`, `xxd`, `hostid`, `resize` | Dropped: in no BSD base system (`pgrep` covers `pidof`). |
| `cb10bdf` | 2026-10-14 | `netstat`, `fuser`, `top` | Dropped: they read Linux's `/proc` layout (`/proc/net/*`, `/proc/<pid>/fd`, ...). Native ones wait for the kernel interfaces. |
| `0f94829` | 2026-10-01 | `mount`, `umount` | Native `/sbin/mount`, `/sbin/umount` over `nmount(2)` (`8a7d30a`). |
| `bc401ba` | 2026-09-30 | `chmod`, `kill`, `link`, `nproc`, `rmdir`, `sleep`, `sync`, `test`, `unlink` | Native Rust programs in `/bin` (`bin/*`). |
| `98cf1fc` | 2026-09-30 | `crond`, `crontab`, `sysctl`, `dmesg`, `halt`, `poweroff` | Native `/usr/sbin/cron`, `/usr/bin/crontab`, `/sbin/sysctl`, `/sbin/dmesg`, `/sbin/reboot` (with `halt` and `poweroff` links). |
| `98cf1fc` | 2026-09-30 | `sh` (hush), `run-parts`, `start-stop-daemon`, `makedevs`, `killall5`, `cttyhack` | Superseded: `/bin/sh` (`lib/libsh`), `periodic(8)`, `rc.subr`, devfs, `/sbin/init`'s shutdown, init giving each session the console. |
| `98cf1fc` | 2026-09-30 | `setuidgid`, `envuidgid`, `softlimit`, `chrt`, `remove-shell`, `cryptpw`, `mkpasswd`, `pscan`, `pipe_progress`, `ttysize`, `volname`, `ipcalc`, `dnsdomainname`, `mountpoint`, `pwdx`, `free`, `usleep`, `ts`, `fallocate` | Dropped: in no BSD base system (Linux, Debian or daemontools tools). |
| `98cf1fc` | 2026-09-30 | `lsof`, `pstree`, `tree`, `watch`, `hexedit`, `dos2unix`, `unix2dos`, `shuf`, `shred`, `crc32`, `ascii`, `lzop`, `lzcat`, `unlzma` | Dropped: ports material, not base on any BSD. |
| `793a75b` | 2026-09-27 | `man`, `more`, `less` | Native `/usr/bin/man`, `/usr/bin/more` (`less` is a link to it), over `liboxdoc`. |
| `093ec0e` | 2026-09-27 | `getty`, `login`, `passwd`, `sulogin` | Native `/usr/libexec/getty`, `/usr/bin/login`, `/usr/bin/passwd` (OpenPAM); single-user mode in `/sbin/init`. |
| `093ec0e` | 2026-09-27 | `adduser`, `addgroup`, `delgroup`, `chpasswd` | Dropped: they edit `/etc/shadow`, which `/etc/master.passwd` and `pwd_mkdb(8)` replaced. |
| `8e4108f` | 2026-09-24 | `cat`, `cp`, `echo`, `false`, `ln`, `ls`, `mkdir`, `mv`, `pwd`, `rm`, `touch`, `true` | Native `/bin` programs (first added in `db81314`). |
| `8e4108f` | 2026-09-24 | `vi` | OpenVi (`bin/vi`) as `/bin/vi`. |
| `8e4108f` | 2026-09-24 | `dpkg`, `dpkg-deb`, `rpm`, `rpm2cpio`, `bash`, `bash_ash`, `bbconfig`, `nuke`, `unit-test`, `bootchartd` | Dropped: foreign package tools, aliases, BusyBox internals. |
| `8e4108f` | 2026-09-24 | `sendmail`, `popmaildir`, `makemime`, `reformime`, `lpd`, `lpq`, `lpr`, `fakeidentd`, `ftpd`, `telnetd`, `httpd`, `inetd`, `tcpsvd`, `udpsvd`, `dnsd`, `dhcprelay`, `udhcpd`, `dumpleases`, `rdate` | Dropped: mail, print and network daemons never verified on OxideBSD. |
| `8e4108f` | 2026-09-24 | `lspci`, `lsusb`, `lsscsi`, `powertop`, `smemcap`, `nmeter`, `mpstat`, `iostat`, `pmap`, `taskset`, `adjtimex`, `hwclock`, `rtcwake`, `vconfig` | Dropped: Linux hardware and `/proc` tools. |
| `8e4108f` | 2026-09-24 | `ifconfig`, `ifdown`, `route`, `arp`, `arping` | Dropped: Linux `SIOC*` network configuration. OxideBSD's own `ifconfig`/`route` wait for interface-configuration ioctls. |
| `dcff2cc` | 2026-08-14 | `resume`, `klogd`, `logger`, `logread`, `syslogd`, `fbset`, `script`, `scriptreplay`, `setserial`, `devfsd`, `microcom`, `modinfo`, `mt`, `rx`, `chvt`, `deallocvt`, `dumpkmap`, `fgconsole`, `loadkmap`, `setconsole`, `setkeycodes`, `setlogcons` | Dropped at the time: no VT, serial, framebuffer or syslog device model. `syslogd` and `logger` now exist natively (`/usr/sbin/syslogd`, `/usr/bin/logger`). |
| `dcff2cc` | 2026-08-14 | `linux32`, `linux64`, `nsenter`, `setarch`, `setpriv`, `unshare` | Dropped: Linux namespaces and personalities. |
| `dcff2cc` | 2026-08-14 | `ipcrm`, `ipcs` | Dropped at the time: no SysV IPC. |
| `dcff2cc` | 2026-08-14 | `chattr`, `fatattr`, `lsattr`, `setfattr` | Dropped: ext2 flag ioctls and extended attributes. |
| `dcff2cc` | 2026-08-14 | `mkfifo`, `runsv`, `runsvdir`, `svlogd`, `svok` | Dropped at the time: oxfs had no FIFO inode kind. |
| `dcff2cc` | 2026-08-14 | `inotifyd`, `mesg` | Dropped: no inotify; no multi-terminal model. |
| `dcff2cc` | 2026-08-14 | `pivot_root`, `switch_root`, `blkid`, `fdformat`, `fdisk`, `findfs`, `fsck`, `fsck_minix`, `mkfs`, `mkswap`, `rdev`, `swapoff`, `devmem`, `eject`, `freeramdisk`, `hd`, `readprofile` | Dropped: partition tables, swap, other on-disk formats, device memory. |

Back in the roster since 2026-10-14, their reasons above gone: `mkfifo` (FIFOs exist), `mesg`
and `script` (ttys and ptys exist; `script` is built with `FEATURE_DEVPTS`, for `/dev/ptmx`).
`ipcrm` came back too, then went native on 2026-10-15 with `ipcs`, whose BusyBox version lists
objects with Linux-only `IPC_INFO`, `SHM_INFO`/`SHM_STAT` (and the `SEM_`, `MSG_` ones):
OxideBSD's read the `kern.ipc` sysctl tables, as the BSDs' do (`SYSCTL.md` §5.2).

Applet names fixed in `8e4108f`: the build had installed `run-parts`, `start-stop-daemon` and
`remove-shell` as `run`, `start` and `remove`.

## 4. Applets never built

The roster came from a build probe (`cd77499`, 2026-07-24, against the BusyBox tree vendored
then, before the `1_38_0` update) that tried every applet BusyBox declares with an `//applet:`
marker (393 candidates) with the single-applet recipe of §1. 287 built and all were added; the
rest are below. The probe has not been rerun against `1_38_0`, and 23 candidates are unaccounted
for in its results.

| Reason | Applets |
|--------|---------|
| Linux `uapi` header musl does not ship (`linux/*.h`, `mtd/*.h`, `asm/unistd.h`) | `ionice`; `fbsplash`; `udhcpc`; `blkdiscard`, `blockdev`, `fsfreeze`, `fstrim`, `mkfs_ext2`, `mkfs_reiser`, `nbdclient`, `partprobe`, `tune2fs`; `hdparm`, `mkfs_vfat`; `i2cdetect`, `i2cdump`, `i2cget`, `i2cset`, `i2ctransfer`; `ether_wake`, `ifenslave`; `tunctl`; `acpid`; `beep`, `conspy`, `kbd_mode`, `loadfont`, `setfont`, `showkey`; `raidautorun`; `ifplugd`, `mdev`, `uevent`; `seedrng`; `rfkill`; `brctl`, `nameif`, `zcip`; `iptunnel`, `slattach`, `tc`, `watchdog`; `losetup`; `init`, `linuxrc`, `openvt`, `vlock`; `flashcp`, `flash_eraseall`, `flash_unlock`, `nanddump`, `nandwrite`, `ubirename`; `ubiupdatevol` |
| Undefined symbol at link | `lzopcat` |
| IPv6 variant enabled by a feature flag, not its own symbol | `ping6`, `traceroute6`, `udhcpc6` |
| Kconfig dependency not met by a single-symbol build | `mim`, `nologin`, `readahead`, `e2label` (needs `TUNE2FS`), `tftp`, `tftpd` (`FEATURE_TFTP_GET`/`PUT`) |
| Needs SELinux | `chcon`, `getenforce`, `getsebool`, `load_policy`, `matchpathcon`, `restorecon`, `runcon`, `selinuxenabled`, `sestatus`, `setenforce`, `setfiles`, `setsebool` |
| Needs BusyBox's utmp/wtmp support | `last`, `runlevel`, `users`, `wall` |
| Not a real applet (documentation example or disabled marker) | `mu`, `ipconfig`, `parse` |
| Missed by the probe; deliberately not built | `lsmod`: parses Linux kernel modules. `/sbin/lsoxmod` (`sbin/lsoxmod`) reads `/proc/modules` instead, and `/sbin/lsmod` is a link to it. |

OxideBSD has its own `/sbin/init` and `/sbin/nologin`.
