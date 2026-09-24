# OxideBSD filesystem hierarchy (`hier`)

OxideBSD's equivalent of FreeBSD's `hier(7)`: where programs live, and why. The rules follow the
BSD convention (FreeBSD/NetBSD/OpenBSD agree on the core of it); where OxideBSD deviates, it says
so. The source tree mirrors this: `bin/*` builds programs for `/bin`, `usr.bin/*` for `/usr/bin`,
`sbin/*` for `/sbin`, `usr.sbin/*` for `/usr/sbin`.

## The four main directories

| Directory | What goes there | Test |
|---|---|---|
| `/bin` | Essential **user** commands | Needed in single-user mode, with only the root filesystem, to use and repair the system |
| `/sbin` | Essential **system administration** commands | Needed to boot, mount, configure the network, or shut down -- usually root-only |
| `/usr/bin` | All other **user** commands | Everything a user runs that isn't essential |
| `/usr/sbin` | All other **administration** commands and **daemons** | Services, user management, diagnostics, anything root-only and non-essential |

Deciding questions, in order: *Does single-user repair need it?* (yes: `/bin` or `/sbin`)
*Is it for administering the system rather than using it?* (yes: an `sbin`).

Deliberate deviations from FreeBSD, each so single-user repair has what it actually needs:
`vi` lives in `/bin` (FreeBSD and OpenBSD ship `/usr/bin/vi`), and so do `grep`, `sed`, `tar` and
`gzip`/`gunzip`/`zcat` (all `/usr/bin` on FreeBSD).

## Other program locations

| Directory | Purpose |
|---|---|
| `/usr/libexec` | Helpers other programs run, not users: `getty`, later the rc/init helpers |
| `/usr/games` | Games: `doom` |
| `/usr/tests` | Test programs (FreeBSD's convention) -- not on anyone's `PATH` |
| `/usr/local/bin`, `/usr/local/sbin` | Third-party software installed later (ports/packages), never base |

Default `PATH`: root gets `/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/games`; users get
`/bin:/usr/bin:/usr/local/bin:/usr/games` (`/usr/games` last, as on OpenBSD).

## Init system placement

`/sbin/init` (pid 1), `/sbin/rcorder`, `/etc/rc` (the boot script), `/etc/rc.d/*` (one script per
service), `/etc/rc.conf` (settings, `foo_enable="YES"`), `/etc/rc.shutdown`. See the init design
doc once written.

## Where every current binary goes (227 programs)

This is the seeded layout (2026-09-23). The source tree mirrors it, except for the BusyBox
applets, which all build from `external/gpl2/busybox`.

### `/bin` (44)
`ash`, `cat`, `chmod`, `cp`, `date`, `dd`, `df`, `echo`, `ed`, `egrep`, `expr`, `false`, `fgrep`, `grep`, `gunzip`, `gzip`, `hostname`, `hush`, `kill`, `link`, `ln`, `ls`, `mkdir`, `mv`, `nproc`, `pgrep`, `pkill`, `pwd`, `realpath`, `rm`, `rmdir`, `sed`, `sh`, `sleep`, `stty`, `sync`, `tar`, `test`, `timeout`, `touch`, `true`, `unlink`, `vi`, `zcat`

`sh` is OxideBSD's own shell (`lib/libsh`); `hush` is BusyBox's, still pid 1 and the interactive
shell until `sh` has an interactive mode. `touch` is here (not `/usr/bin` as on FreeBSD) because
it's one of the native `bin/` utilities.

### `/sbin` (12)
`dmesg`, `halt`, `init_sh`, `lsmod`, `lsoxmod`, `mknod`, `mount`, `ping`, `poweroff`, `sulogin`, `sysctl`, `umount`

Missing and needed here: `reboot`, `init`, `rcorder`, `shutdown`, `ifconfig`/`route` (OxideBSD's
own, once the kernel has interface-configuration ioctls), `fsck` (when oxfs gets one).

### `/usr/bin` (146)
`ar`, `arch`, `ascii`, `awk`, `base32`, `base64`, `basename`, `bc`, `bmake`, `bunzip2`, `bzcat`, `bzip2`, `cal`, `chat`, `chgrp`, `chown`, `cksum`, `clang`, `clang++`, `clear`, `cmp`, `comm`, `cpio`, `crc32`, `crontab`, `cryptpw`, `cut`, `dc`, `diff`, `dirname`, `dnsdomainname`, `dos2unix`, `du`, `env`, `expand`, `factor`, `fallocate`, `find`, `flock`, `fold`, `free`, `fsync`, `ftpget`, `ftpput`, `fuser`, `getopt`, `groups`, `head`, `hexdump`, `hexedit`, `hostid`, `install`, `ipcalc`, `ld.lld`, `less`, `login`, `logname`, `lsof`, `lzcat`, `lzop`, `make`, `man`, `md5sum`, `minips`, `mkpasswd`, `mktemp`, `more`, `mountpoint`, `nano`, `nc`, `netcat`, `netstat`, `nice`, `ninja`, `nl`, `nohup`, `nslookup`, `od`, `passwd`, `paste`, `patch`, `pidof`, `pipe_progress`, `printenv`, `printf`, `pscan`, `pstree`, `pwdx`, `readlink`, `renice`, `reset`, `resize`, `rev`, `run-parts`, `seq`, `setsid`, `sha1sum`, `sha256sum`, `sha3sum`, `sha512sum`, `shred`, `shuf`, `sort`, `split`, `ssl_client`, `stat`, `strings`, `su`, `sum`, `tac`, `tail`, `tee`, `telnet`, `time`, `top`, `tr`, `traceroute`, `tree`, `truncate`, `ts`, `tsort`, `tty`, `ttysize`, `uname`, `uncompress`, `unexpand`, `uniq`, `unix2dos`, `unlzma`, `unxz`, `unzip`, `uptime`, `usleep`, `uudecode`, `uuencode`, `volname`, `watch`, `wc`, `wget`, `which`, `whoami`, `whois`, `xargs`, `xxd`, `xzcat`, `yes`

Clang's resource directory moved with it: `/usr/lib/clang/23`.

### `/usr/sbin` (16)
`addgroup`, `adduser`, `chpasswd`, `chroot`, `chrt`, `crond`, `cttyhack`, `delgroup`, `envuidgid`, `killall5`, `makedevs`, `ntpd`, `remove-shell`, `setuidgid`, `softlimit`, `start-stop-daemon`

### `/usr/libexec` (1), `/usr/games` (1)
`getty`; `doom`

### `/usr/tests` (7)
`float-smoke`, `musl`, `smoke`, `std-hello`, `std-hello-oxidebsd`, `std-process-fs-oxidebsd`, `std-thread-net-signal-oxidebsd` -- regression fixtures.

## Removed 2026-09-23

48 BusyBox applets that don't belong in a BSD base system or can't work on this kernel:

- Foreign or decorative: `dpkg`, `dpkg-deb`, `rpm`, `rpm2cpio`, `bash`/`bash_ash` (aliases for
  hush/ash), `bbconfig`, `nuke`, `unit-test`, `bootchartd`.
- Mail, print and network daemons, never verified here: `sendmail`, `popmaildir`, `makemime`,
  `reformime`, `lpd`, `lpq`, `lpr`, `fakeidentd`, `ftpd`, `telnetd`, `httpd`, `inetd`, `tcpsvd`,
  `udpsvd`, `dnsd`, `dhcprelay`, `udhcpd`, `dumpleases`, `rdate`.
- Linux hardware and `/proc` tools: `lspci`, `lsusb`, `lsscsi`, `powertop`, `smemcap`, `nmeter`,
  `mpstat`, `iostat`, `pmap`, `taskset`, `adjtimex`, `hwclock`, `rtcwake`, `vconfig`.
- Linux network configuration (Linux `SIOC*` ioctls): `ifconfig`, `ifdown`, `route`, `arp`,
  `arping`.

The naming bugs listed here before (`run`, `start`, `remove`, `unit`, `dpkg_deb`) are fixed or
gone: the build now names applets `run-parts`, `start-stop-daemon` and `remove-shell`.
