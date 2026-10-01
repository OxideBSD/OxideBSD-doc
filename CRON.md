# OxideBSD cron and periodic: design specification

Status: **accepted design, implemented** (2026-09-30; see §11). Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interfaces are documented in the manual pages `cron(8)`, `crontab(1)`, `crontab(5)`,
`periodic(8)` and `periodic.conf(5)`; this document records the design. It follows FreeBSD, whose
cron derives from Paul Vixie's, as do NetBSD's and OpenBSD's. It depends on `SYSLOG.md` (where job
output goes), `TIMEZONE.md` (tables are in local time) and `INIT.md` (`rc.d/cron`).

## 1. Scope

The daemon that runs scheduled commands, the tables it reads, the utility that edits them, and
the daily, weekly and monthly maintenance run.

## 2. Components

| Path | Role | Source |
|---|---|---|
| `/usr/sbin/cron` | The daemon | Rust, `usr.sbin/cron` |
| `/usr/bin/crontab` | Installs, lists, edits and removes user tables | Rust, `usr.bin/crontab` |
| `/etc/crontab` | The system table | `etc/crontab` |
| `/etc/cron.d/`, `/usr/local/etc/cron.d/` | More system tables | — |
| `/var/cron/tabs/<user>` | User tables | written by `crontab` |
| `/var/cron/allow`, `/var/cron/deny` | Who may use `crontab` | local |
| `/usr/sbin/periodic` | Runs the maintenance scripts | `sh` script, `usr.sbin/periodic` |
| `/etc/periodic/{daily,weekly,monthly}/` | Maintenance scripts | `etc/periodic` |
| `/etc/defaults/periodic.conf`, `/etc/periodic.conf` | Their settings | `etc/defaults/periodic.conf` |
| `/etc/pam.d/cron` | Account checks before a job runs | `etc/pam.d/cron` |
| `/etc/rc.d/cron` | Start-up | `etc/rc.d/cron` |

BusyBox's `crond` and `crontab` stop being installed.

## 3. Table format (`crontab(5)`)

3.1. A table is lines of three kinds: blank lines and `#` comments; environment settings
`name = value` (the value MAY be quoted); and job lines.

3.2. A job line is five time fields and a command: minute (0–59), hour (0–23), day of month
(1–31), month (1–12 or `jan`–`dec`), day of week (0–7, 0 and 7 both Sunday, or `sun`–`sat`). A
field is `*`, a number, a range `a-b`, a list `a,b,c`, or any of these with a step `/n`. When both
the day of month and the day of week are restricted, a job runs when either matches.

3.3. In the system tables (`/etc/crontab` and the `cron.d` directories), a user name follows the
time fields; the job runs as that user.

3.4. The time fields may be replaced by one of `@reboot` (once, when cron starts after boot),
`@yearly`/`@annually`, `@monthly`, `@weekly`, `@daily`/`@midnight`, `@hourly`, `@every_minute`
and `@every_second`.

3.5. In the command, an unescaped `%` ends the command; the text after it, with each further `%`
turned into a newline, is the job's standard input.

3.6. A job's environment is `SHELL=/bin/sh`, `PATH=/usr/bin:/bin`, `HOME` from the password file,
`LOGNAME` and `USER`, then the table's own settings, which MAY override all but `LOGNAME` and
`USER`.

## 4. `cron`

4.1. Job times are local time (`TIMEZONE.md`). `cron` runs as root, reads every table at start,
and wakes once a minute, on the minute (once a second while any `@every_second` job exists). It reloads a table whose modification time has
changed, and rescans `/var/cron/tabs` when that directory's modification time has changed.

4.2. **Running a job.** For each job due, `cron` MUST fork, set the user's group, user ID and
login class (`login.conf(5)`: umask, resource limits, environment), SHOULD run the PAM account
stack of service `cron` (a job whose account check fails is not run, and the failure is logged),
and run the command with `$SHELL -c`. Each start is logged as `(user) CMD (command)` at
`cron.info`.

4.3. **Output.** A job's standard output and standard error are collected. OxideBSD has no mail
system, so the output is logged, one line per `syslog(3)` message, as `(user) CMDOUT (line)` at
`cron.notice`, instead of being mailed. `MAILTO=""` discards it. When a mailer exists, `MAILTO`
and `-m` MUST send mail as in FreeBSD, and logging stops being the default.

4.4. **`@reboot`.** `cron` runs `@reboot` jobs when it starts and `/var/run/cron.reboot` does not
exist, and then creates that file. `rc.d/cleanvar` empties `/var/run` at boot, so a restarted
`cron` does not run them again.

4.5. **Clock changes.** If the clock moves forward by up to three hours, jobs with a fixed time
that were skipped run once; if it moves backward by up to three hours, jobs are not run twice.
Larger changes restart scheduling from the new time. This is Vixie cron's behavior.

4.6. **Options.** FreeBSD's: `-j jitter` and `-J rootjitter` (a random delay of up to that many
seconds before each job, for non-root and root jobs), `-m address` (default for `MAILTO`), `-n`
(stay in the foreground), `-s` and `-o` (enable or disable FreeBSD's special handling of
daylight-saving changes: with `-s`, a job whose time is skipped runs once after the change, and a
job whose time repeats runs once).

4.7. The process ID is written to `/var/run/cron.pid`.

## 5. `crontab`

5.1. `crontab [-u user] file`, `crontab [-u user] -l`, `crontab [-u user] -e`, `crontab [-u user]
-r [-f]`: install a table from a file (or `-` for standard input), list it, edit it with
`$VISUAL` or `$EDITOR` (default `vi`), or remove it (after confirmation, unless `-f`). `-u` is for
root only.

5.2. A table MUST be checked before it is installed; an invalid one is rejected with the line
number and reason, and under `-e` the user is offered to edit it again.

5.3. Tables are written to `/var/cron/tabs/<user>`, owned by root, mode `0600`, in a directory of
mode `0700`; `crontab` then updates the directory's modification time so that `cron` rescans it.

5.4. **Access.** Root may always use `crontab`. Otherwise, if `/var/cron/allow` exists, only the
users listed in it may; else if `/var/cron/deny` exists, everyone except those listed may; else
everyone may.

5.5. In the BSDs `crontab` is set-user-ID root. Until OxideBSD can execute set-user-ID programs
(`SUDO.md`), `crontab` works for root only and tells other users so, as `passwd(1)` does today.

## 6. `/etc/crontab`

```
SHELL=/bin/sh
PATH=/etc:/bin:/sbin:/usr/bin:/usr/sbin
#
#minute	hour	mday	month	wday	who	command
#
0	*	*	*	*	root	newsyslog
1	3	*	*	*	root	periodic daily
15	4	*	*	6	root	periodic weekly
30	5	1	*	*	root	periodic monthly
```

## 7. `periodic`

7.1. `periodic directory ...` runs, for each argument, every executable file in
`/etc/periodic/<directory>` and then `/usr/local/etc/periodic/<directory>`, in name order. An
argument that is an absolute path names the directory itself. It is a shell script, as in FreeBSD.

7.2. Each script reads `/etc/defaults/periodic.conf` and then `/etc/periodic.conf` (through
`periodic.conf`'s own `source_periodic_confs`) and exits with FreeBSD's codes: 0 nothing notable,
1 notable output, 2 invalid configuration, higher an error. `<directory>_show_success`,
`_show_info` and `_show_badconfig` decide which scripts' output is kept.

7.3. **Output.** `<directory>_output` names where the kept output goes: a file path (appended),
or a user name (mailed, once a mailer exists; logged with `syslog(3)` until then). The default is
`/var/log/daily.log`, `/var/log/weekly.log` and `/var/log/monthly.log`, rotated by `newsyslog`.

7.4. **Initial scripts.**

| Script | Enabled by default | Does |
|---|---|---|
| `daily/110.clean-tmps` | no | Removes files in `/tmp` untouched for `daily_clean_tmps_days` (3) days |
| `daily/200.backup-passwd` | yes | Reports changes to `master.passwd` and `group` since the last run and copies them to `/var/backups` |
| `daily/400.status-disks` | yes | `df` output |
| `daily/430.status-uptime` | yes | `uptime` output |
| `daily/999.local` | yes | Runs `/etc/daily.local` if it exists |
| `weekly/999.local` | yes | Runs `/etc/weekly.local` if it exists |
| `monthly/999.local` | yes | Runs `/etc/monthly.local` if it exists |

## 8. Start-up

`rc.d/cron` (`REQUIRE: LOGIN FILESYSTEMS`, `KEYWORD: shutdown`) starts `cron $cron_flags`. In
`/etc/defaults/rc.conf`: `cron_enable="YES"`, `cron_flags=""`.

## 9. Verification

9.1. Host tests: the table parser (every field form, names, steps, `@` forms, `%`, errors with
line numbers) and the scheduler, against an injected clock, including the day-of-month/day-of-week
rule and §4.5's clock changes.

9.2. `tests/cron_syscall_smoke.rs`: on target, `cron -n` with an `@reboot` job and an
`@every_second` job, both of which write a file and produce output; the files appear, the output
is in the `cron` log, `crontab -l` round-trips an installed table, and an invalid table is refused.

## 10. Open questions

1. `at(1)`, `batch(1)` and `atrun(8)`: not planned yet.
2. FreeBSD's `periodic security` run (`/etc/periodic/security`): deferred until there is something
   for it to check, such as set-user-ID files.

## 11. Implementation notes

Settled in the code (`lib/libcron`, `usr.sbin/cron`, `usr.bin/crontab`, `usr.sbin/periodic`,
`etc/periodic`), and documented in the manual pages:

1. **§4.6 `-s`/`-o`.** `-o` is the default, as in FreeBSD. Both are one mechanism: cron counts
   minutes in UTC (`-o`) or in local time (`-s`), and §4.5's clock-change rules apply to the
   count, so under `-s` a daylight-saving change is a clock change.
2. **§3.2.** A field that *begins* with `*` counts as unrestricted for the day rule (Vixie
   cron's behavior), so `0 0 */2 * 5` means odd days that are Fridays. `n/step` means
   `n-max/step`. Bad lines are skipped and logged by cron; crontab refuses the whole table.
3. **Tables** must be regular files owned by root and not group- or world-writable, or they are
   skipped; `cron.d` file names are filtered as the BSDs' `not_a_crontab` does. A change is
   noticed by modification time, of each table and of the three directories, at each wake.
4. **Jobs** run in a runner process per job (jitter, PAM `cron` with `pam_nologin` and
   `pam_unix`, `setusercontext` from `lib/liblogincap`, `$SHELL -c` in the home directory).
5. **crontab** writes through a rename and moves `/var/cron/tabs`'s time. It writes no header
   comment, so `-l` gives back exactly what was installed.
6. **periodic** runs `/etc/periodic/<dir>` then `/usr/local/etc/periodic/<dir>`, each in name
   order (not merged). Output for a user is logged at `daemon.notice` with `logger`.
7. **Verification**: `lib/libcron` host tests (13, with spring-forward and fall-back in both
   modes), `usr.sbin/cron` and `usr.bin/crontab` host tests, and `cron_syscall_smoke`.
