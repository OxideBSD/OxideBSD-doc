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

Default `PATH`: root gets `/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin`; users get
`/bin:/usr/bin:/usr/local/bin`.

## Init system placement

`/sbin/init` (pid 1), `/sbin/rcorder`, `/etc/rc` (the boot script), `/etc/rc.d/*` (one script per
service), `/etc/rc.conf` (settings, `foo_enable="YES"`), `/etc/rc.shutdown`. See the init design
doc once written.

## Where every current binary goes (272 programs)

Today everything except `nano` and `ninja` is seeded flat into `/bin`. This is the target layout;
moving them is follow-up work.

### `/bin` (44)
`ash`, `bash`, `bash_ash`, `cat`, `chmod`, `cp`, `date`, `dd`, `df`, `echo`, `ed`, `egrep`, `expr`, `false`, `fgrep`, `grep`, `gunzip`, `gzip`, `hostname`, `kill`, `link`, `ln`, `ls`, `mkdir`, `mv`, `nproc`, `pgrep`, `pkill`, `pwd`, `realpath`, `rm`, `rmdir`, `sed`, `sh`, `sleep`, `stty`, `sync`, `tar`, `test`, `timeout`, `true`, `unlink`, `vi`, `zcat`

`bash` and `bash_ash` are BusyBox aliases of `ash`, not GNU bash; `sh` is BusyBox `hush`.

### `/sbin` (14)
`dmesg`, `halt`, `hwclock`, `ifconfig`, `lsmod`, `lsoxmod`, `mknod`, `mount`, `ping`, `poweroff`, `route`, `sulogin`, `sysctl`, `umount`

Missing and needed here: `reboot` (only `halt`/`poweroff` are seeded today), `init`, `rcorder`,
`shutdown`, `fsck` (when oxfs gets one).

### `/usr/bin` (159)
`ar`, `arch`, `ascii`, `awk`, `base32`, `base64`, `basename`, `bbconfig`, `bc`, `bmake`, `bunzip2`, `bzcat`, `bzip2`, `cal`, `chat`, `chgrp`, `chown`, `cksum`, `clang`, `clang++`, `clear`, `cmp`, `comm`, `cpio`, `crc32`, `crontab`, `cryptpw`, `cut`, `dc`, `diff`, `dirname`, `dnsdomainname`, `dos2unix`, `dpkg`, `dpkg-deb`, `du`, `env`, `expand`, `factor`, `fallocate`, `find`, `flock`, `fold`, `free`, `fsync`, `ftpget`, `ftpput`, `fuser`, `getopt`, `groups`, `head`, `hexdump`, `hexedit`, `hostid`, `install`, `ipcalc`, `ld.lld`, `less`, `login`, `logname`, `lsof`, `lzcat`, `lzop`, `make`, `makemime`, `man`, `md5sum`, `minips`, `mkpasswd`, `mktemp`, `more`, `mountpoint`, `nano`, `nc`, `netcat`, `netstat`, `nice`, `ninja`, `nl`, `nmeter`, `nohup`, `nslookup`, `od`, `passwd`, `paste`, `patch`, `pidof`, `pipe_progress`, `pmap`, `popmaildir`, `printenv`, `printf`, `pscan`, `pstree`, `pwdx`, `readlink`, `reformime`, `renice`, `reset`, `resize`, `rev`, `rpm`, `rpm2cpio`, `run-parts`, `seq`, `setsid`, `sha1sum`, `sha256sum`, `sha3sum`, `sha512sum`, `shred`, `shuf`, `smemcap`, `sort`, `split`, `ssl_client`, `stat`, `strings`, `su`, `sum`, `tac`, `tail`, `taskset`, `tee`, `telnet`, `time`, `top`, `touch`, `tr`, `traceroute`, `tree`, `truncate`, `ts`, `tsort`, `tty`, `ttysize`, `uname`, `uncompress`, `unexpand`, `uniq`, `unix2dos`, `unlzma`, `unxz`, `unzip`, `uptime`, `usleep`, `uudecode`, `uuencode`, `volname`, `watch`, `wc`, `wget`, `which`, `whoami`, `whois`, `xargs`, `xxd`, `xzcat`, `yes`

### `/usr/sbin` (46)
`addgroup`, `adduser`, `adjtimex`, `arp`, `arping`, `bootchartd`, `chpasswd`, `chroot`, `chrt`, `crond`, `cttyhack`, `delgroup`, `dhcprelay`, `dnsd`, `dumpleases`, `envuidgid`, `fakeidentd`, `ftpd`, `httpd`, `ifdown`, `inetd`, `iostat`, `killall5`, `lpd`, `lpq`, `lpr`, `lspci`, `lsscsi`, `lsusb`, `makedevs`, `mpstat`, `ntpd`, `nuke`, `powertop`, `rdate`, `remove-shell`, `rtcwake`, `sendmail`, `setuidgid`, `softlimit`, `start-stop-daemon`, `tcpsvd`, `telnetd`, `udhcpd`, `udpsvd`, `vconfig`

### `/usr/libexec` (1), `/usr/games` (1)
`getty`; `doom`

### `/usr/tests` (7)
`float-smoke`, `musl`, `smoke`, `std-hello`, `std-hello-oxidebsd`, `std-process-fs-oxidebsd`, `std-thread-net-signal-oxidebsd` -- regression fixtures, currently in `/bin` only because it's the one
directory every smoke test knows.

## Known naming bugs

The BusyBox build derives each applet's installed name by cutting at the first `-`, so four are
seeded under the wrong name, and `dpkg-deb` got an underscore:

| Real name | Seeded today as | Belongs in |
|---|---|---|
| `run-parts` | `/bin/run` | `/usr/bin` |
| `start-stop-daemon` | `/bin/start` | `/usr/sbin` |
| `remove-shell` | `/bin/remove` | `/usr/sbin` |
| `unit-test` | `/bin/unit` | dropped (BusyBox's internal test hook) |
| `dpkg-deb` | `/bin/dpkg_deb` | `/usr/bin` |
