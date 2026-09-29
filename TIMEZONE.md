# OxideBSD time zones: design specification

Status: **draft for review.** Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interfaces are documented in the manual pages `tzfile(5)`, `zic(8)`, `zdump(8)`,
`tzsetup(8)` and `localtime(3)`; this document records the design. It follows the BSDs, all of
which ship the IANA time zone database. `SYSLOG.md` and `CRON.md` depend on it.

## 1. Scope

The time zone database, where it is installed, how the local zone is chosen, and how programs find
it.

## 2. Components

| Path | Role | Source |
|---|---|---|
| `external/public-domain/tz` | IANA `tzdata` and `tzcode`, one pinned release | vendored tree, public domain |
| `/usr/share/zoneinfo/` | Compiled zones (`tzfile(5)`), `zone1970.tab`, `zone.tab`, `iso3166.tab`, `tzdata.zi` | built by `zic` at build time |
| `/etc/localtime` | The local zone | symbolic link, written by `tzsetup` |
| `/usr/sbin/zic` | Zone compiler | `tzcode`, C |
| `/usr/bin/zdump` | Prints a zone's transitions | `tzcode`, C |
| `/usr/sbin/tzsetup` | Chooses the local zone | Rust, `usr.sbin/tzsetup` |

## 3. Database

3.1. The release is vendored as a plain tree, like `bmake` and `ncurses`: IANA publishes versioned
tarballs, not a canonical repository to fork. Updating means replacing the tree with a newer
release.

3.2. The build compiles the database with a host build of the vendored `zic`, not the host's own,
so that the output does not depend on the build machine, and seeds it under `/usr/share/zoneinfo`
with every zone and the `backward` links. The `right/` (leap-second) variants are not installed:
the kernel's clock does not count leap seconds.

3.3. Files are compiled with `zic -b slim` (64-bit data only, `zic`'s default), which musl's
`localtime(3)` reads.

## 4. The local zone

4.1. `/etc/localtime` is a symbolic link to a file under `/usr/share/zoneinfo`, as in NetBSD and
OpenBSD. Without it, local time is UTC.

4.2. The `TZ` environment variable overrides it for a process, with POSIX syntax (`TZ=EST5EDT`) or
a zone name (`TZ=Europe/Berlin`), which musl looks up under `/usr/share/zoneinfo`.

4.3. The hardware clock keeps UTC, the BSDs' default. A hardware clock set to local time (another
operating system's convention, FreeBSD's `/etc/wall_cmos_clock`) is not supported.

4.4. No zone is chosen by default; a new system runs in UTC until `tzsetup` is run.

## 5. `tzsetup`

5.1. `tzsetup zone` links `/etc/localtime` to that zone after checking that it exists and is a
valid `tzfile(5)`.

5.2. `tzsetup` without an argument asks for a region, then a zone within it, from
`zone1970.tab`, as numbered menus on the terminal, and offers UTC.

5.3. `tzsetup -r` re-reads the zone name from the current link and refreshes it (after a
database update); `-n` shows what would be done without doing it.

5.4. Running programs keep the zone they started with; `syslogd` and `cron` MUST re-read the local
zone on `SIGHUP`.

## 6. Verification

6.1. `tests/tz_syscall_smoke.rs` with a C fixture: `localtime(3)` and `mktime(3)` round-trip a set
of instants across a daylight-saving transition in a zone with one and a zone without; `TZ`
overrides `/etc/localtime`; with no `/etc/localtime`, local time is UTC; `zdump -v` on a zone
lists its transitions; `tzsetup` on an invalid name fails and leaves the link unchanged.

## 7. Open questions

None.
