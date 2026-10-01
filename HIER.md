# OxideBSD program inventory

Where each program in the base system is installed, and the BusyBox applets taken out of it. A
working list, not a specification: the rules for where things go, and every directory, are in
`hier(7)` (`share/man/man7/hier.7` in the OxideBSD tree, and on the website's manual pages).

## Where every current binary goes (227 programs)

This is the seeded layout (2026-09-23). The source tree mirrors it, except for the BusyBox
applets, which all build from `external/gpl2/busybox`. Added since, among others: `/usr/bin/openssl`
and `/usr/sbin/certctl` (2026-09-30).

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

## Removed 2026-09-30

45 more BusyBox applets, listed with the reasons in `BUSYBOX_APPLETS.md` ("Third cut"),
including `/bin/hush`, `/usr/sbin/crond` and BusyBox's `/usr/bin/crontab` (now native).
`/sbin` gained `init`, `nologin`, `reboot` (+ `halt`, `poweroff`), `rcorder`, `shutdown` and
`emergency` since the list below was made; `/usr/sbin` gained `cron`, `periodic` and `syslogd`.

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
