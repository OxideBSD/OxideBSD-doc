# OxideBSD init_sh: design specification

Status: **accepted (reviewed 2026-09-23).** Items marked *(proposal)* were accepted as written. Target release:
v0.3.0. Companion to `INIT.md`.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119.

## 1. Scope

`/sbin/init_sh` is the interpreter for OxideBSD's boot and service scripts: `/etc/rc`,
`/etc/rc.shutdown` and every script in `/etc/rc.d`. It accepts the full POSIX shell language plus
an init-specific dialect (§4).

## 2. Structure

2.1. The shell is implemented once, as a Rust library (the *core*), and built into separate
binaries:

| Binary | Language | Status |
|---|---|---|
| `/sbin/init_sh` | POSIX sh + init dialect | this specification |
| `/bin/sh` | POSIX sh + interactive features | future; replaces BusyBox `hush` |

2.2. The init dialect MUST NOT be present in `/bin/sh`. A script that uses the dialect is an
`init_sh` program and MUST begin with `#!/sbin/init_sh`.

2.3. Both binaries are Rust `std` programs for `x86_64-unknown-oxidebsd`. The core MUST also build
for the development host, so that it can be tested there (§8).

## 3. POSIX language

3.1. `init_sh` MUST implement the Shell Command Language of POSIX.1-2017 (XCU chapter 2) for
non-interactive use: lexical conventions and quoting, all parameter and word expansions, field
splitting, pathname expansion, redirection including here-documents, pipelines and lists, all
compound commands, function definitions, and the special built-in utilities.

3.2. Interactive features are out of scope: line editing, history, job control and the `-i`
option. `init_sh` exits with an error if asked to read commands interactively.

3.3. Extensions to POSIX, available in both binaries: `local` (function-scoped variables, as in
`dash` and FreeBSD `sh`, used throughout `rc.subr`-style scripts).

3.4. Regular built-ins: at least `cd`, `echo`, `printf`, `test`/`[`, `read`, `getopts`, `umask`,
`kill`, `wait`, `command`, `type`, `true`, `false`, `pwd`.

## 4. Init dialect

### 4.1. Service blocks

A service script declares exactly one service:

```sh
#!/sbin/init_sh
service cron {
    desc     "Daemon to execute scheduled commands"
    provide  cron
    require  LOGIN FILESYSTEMS
    before   securelevel
    keyword  shutdown
    command  /usr/sbin/cron
    pidfile  /var/run/cron.pid

    start_pre {
        mkdir -p /var/cron/tabs
    }
}
```

Grammar (EBNF; `WORD` and `compound_list` as in POSIX):

```
service_block = "service" NAME "{" { field | hook } "}" ;
field         = FIELD_NAME WORD { WORD } NEWLINE ;
hook          = HOOK_NAME "{" compound_list "}" ;
```

### 4.2. Fields *(proposal)*

| Field | Meaning | Default |
|---|---|---|
| `desc` | One-line description | none |
| `provide` | Names this service provides to `rcorder` | the service name |
| `require` | Names that must start first | none |
| `before` | Names that must start after this one | none |
| `keyword` | `rcorder` keywords (`shutdown`, `nojail`, ...) | none |
| `command` | Program to run | none (a service without one only runs hooks) |
| `args` | Arguments to `command` | `${<name>_flags}` from `rc.conf` |
| `pidfile` | File holding the running process's pid | none (status falls back to process name) |
| `user`, `group` | Credentials to run `command` with | root |
| `env` | `NAME=value` pairs added to `command`'s environment | none |
| `chdir` | Working directory for `command` | `/` |
| `stop_signal` | Signal sent to stop the service | `SIGTERM` |
| `stop_timeout` | Seconds to wait before `SIGKILL` | 10 |
| `foreground` | `command` stays in the foreground (does not daemonize itself) | no |

4.2.1. `provide`, `require`, `before` and `keyword` MUST be literal words: no expansions and no
command substitution. **Rationale:** `rcorder` reads them without executing the script.

4.2.2. Other fields MAY contain parameter expansions; they are evaluated after `rc.conf` has been
loaded.

### 4.3. Hooks *(proposal)*

| Hook | Runs |
|---|---|
| `start_pre`, `start_post` | Before / after starting `command` |
| `stop_pre`, `stop_post` | Before / after stopping it |
| `status` | Replaces the default status check |
| `command <name> { ... }` | Defines an extra action, e.g. `command reload { kill -HUP $pid }` |

A non-zero exit from `start_pre` MUST abort the start.

### 4.4. Actions and initconf

4.4.1. Services are controlled and configured with `/sbin/initconf`, a separate program:

```
initconf <action> <script>
initconf list
```

`<script>` is a service name, looked up as `/etc/rc.d/<script>` and then
`/usr/local/etc/rc.d/<script>`; an argument containing `/` is used as a path.

4.4.2. **Runtime actions**: `start`, `stop`, `restart`, `status`, and any defined with
`command <name>` (§4.3). The prefixes `force` (ignore `<name>_enable`), `one` (run once even if
disabled) and `quiet` apply as in FreeBSD's `rc.subr`, e.g. `initconf onestart cron`. `initconf`
performs a runtime action by running the script with `init_sh`.

4.4.3. **Configuration actions**, performed by `initconf` itself on `/etc/rc.conf`:

| Action | Effect |
|---|---|
| `enable` / `disable` | Set `<name>_enable` to `YES` / `NO` |
| `rcvar` | Print the service's `rc.conf` variables and their current values |
| `list` (no script) | Print every service with its enabled state |

4.4.4. A service script MAY also be run directly, `/etc/rc.d/<name> <action>`, for runtime
actions; its `#!/sbin/init_sh` line makes this equivalent to `initconf <action> <name>`.

4.4.5. The argument order (action first) differs deliberately from FreeBSD's `service(8)`
(`service cron start`).

### 4.5. Enabling and restarts

4.5.1. A service named `foo` is enabled by `foo_enable="YES"` in `rc.conf`. `start` on a disabled
service MUST do nothing and exit successfully.

4.5.2. `foo_restart="YES"` runs `command` under `/usr/sbin/daemon -r` (see `INIT.md` §8).

### 4.6. rc.conf handling *(proposal)*

4.6.1. `init_sh` loads `/etc/defaults/rc.conf` and then `/etc/rc.conf` natively. Both MUST remain
valid POSIX shell (assignments and comments only), so that ordinary shells can still read them.

4.6.2. Values of `*_enable` and `*_restart` variables MUST be one of `YES`, `NO`, `TRUE`, `FALSE`,
`ON`, `OFF`, `1` or `0` (any case). Any other value MUST produce a warning naming the file, line
and variable, and is treated as `NO`.

4.6.3. An `rc.conf` line that is not an assignment or comment MUST produce a warning and be
ignored.

### 4.7. rc.subr built-ins

These are native built-ins, so that scripts written for FreeBSD's `rc.subr` run unchanged:
`load_rc_config`, `run_rc_command`, `checkyesno`, `check_pidfile`, `check_process`,
`wait_for_pids`, `force_depend`, `info`, `warn`, `err`, `debug`. `. /etc/rc.subr` MUST be
accepted and has no effect.

### 4.8. Init and kernel built-ins *(proposal)*

| Built-in | Purpose |
|---|---|
| `sysctl name[=value]` | Read or set a kernel parameter without spawning a process |
| `init_report <service> <state>` | Tell init that a service started, stopped or failed (for recovery mode, `INIT.md` §9.3) |
| `init_mode` | Print init's current state (`runcom`, `multi-user`, `recovery`, ...) |

## 5. /etc/rc

`/etc/rc` is itself an `init_sh` program. It loads `rc.conf`, obtains the order from `rcorder`,
and runs `start` on each service, reporting failures and continuing (`INIT.md` §4.6). It runs
services **in-process** through the core's service machinery, not by invoking `initconf` for each
one; `/etc/rc.shutdown` does the same with `stop`. The behavior of an action MUST be identical by
either path.

## 6. rcorder

`/sbin/rcorder` MUST accept both service blocks (§4.1) and classic `# PROVIDE:` / `# REQUIRE:` /
`# BEFORE:` / `# KEYWORD:` comment headers, and order a mixed set of scripts together.

## 7. Errors

7.1. Syntax errors MUST be reported with the file, line and column, and the script MUST NOT run.

7.2. Exit statuses follow POSIX: 0 success, 1–125 failure, 126 command not executable, 127 not
found, 128+n killed by signal n.

## 8. Verification

8.1. **Differential testing.** A corpus of POSIX scripts is run on the development host through
both the core's host build and `dash`; standard output, standard error and exit status MUST match.
Known, intended differences are listed explicitly in the test suite.

8.2. **Unit tests** for the lexer, parser and each expansion.

8.3. **On-target tests** boot OxideBSD and run the real `/etc/rc`.

## 9. Open questions

1. The field and hook lists in §4.2–4.3.
2. Whether `rcorder` itself should become an `init_sh` built-in.
3. The init/kernel built-in set in §4.8.
4. How strictly `rc.conf` validation should treat unknown variables.
