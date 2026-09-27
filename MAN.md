# OxideBSD manual pages: oxdoc, man and apropos — design specification

Status: **accepted design, not yet implemented.** Target release: v0.3.0.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be interpreted as described in
RFC 2119. Interfaces will be documented in the manual pages `oxdoc(1)`, `man(1)`, `apropos(1)`,
`more(1)`, `man.conf(5)`, `makewhatis(8)` and the language references `roff(7)`, `mdoc(7)`,
`man(7)`, `tbl(7)` and `eqn(7)`; this document records the design. Where FreeBSD, NetBSD and
OpenBSD agree it follows them; all three use mandoc, so mandoc's observable behavior is the
reference, and §10 lists where OxideBSD departs from it.

## 1. Scope

Formatting and reading manual pages on OxideBSD: a roff formatter for the `mdoc` and `man` macro
languages and the `tbl` and `eqn` preprocessors (`oxdoc`); the programs that find, display and
search pages (`man`, `apropos`, `whatis`); the index those searches read (`makewhatis`); and a
pager (`more`).

Everything is written from scratch in Rust. No code is taken from mandoc or groff.

**Rationale.** OxideBSD documents its interfaces as mdoc pages, and ported software ships `man`
pages, some using `tbl`; without a formatter none of them can be read on the system itself.

## 2. Components

| Path | Role | Source |
|---|---|---|
| `liboxdoc` | Parser, document tree, validator and renderers; linked into every program below | Rust library, `lib/liboxdoc` |
| `/usr/bin/oxdoc` | Formats or checks pages given as files: `oxdoc [-T device] [-W level] file ...` | Rust, `usr.bin/oxdoc` |
| `/usr/bin/man` | Finds a page by name and section, formats it, runs the pager | Rust, `usr.bin/man` |
| `/usr/bin/apropos`, `/usr/bin/whatis` | Search the index; one program, selected by name | Rust, `usr.bin/apropos` |
| `/usr/sbin/makewhatis` | Builds and updates the index | Rust, `usr.sbin/makewhatis` |
| `/usr/bin/more`, `/usr/bin/less` | The pager (§8.6); `less` is a symbolic link to `more` | Rust, `usr.bin/more` |
| `/etc/man.conf` | Manual paths and output options (`man.conf(5)`) | `etc/man.conf` |
| `<manpath>/oxdoc.db` | The search index of one manual tree (§7) | written by `makewhatis` |

BusyBox's `man`, `more` and `less` MUST NOT be installed once these programs exist.

## 3. Architecture

3.1. **Pipeline.** `liboxdoc` processes a page in four stages:
1. **roff** — reads the input, expands escapes, strings, number registers, conditionals and
   user macros, and hands each resulting line to the language parser as a request, a macro call
   or text;
2. **parse** — the `mdoc`, `man`, `tbl` or `eqn` parser builds a **document tree**, a single
   node type shared by all languages (sections, blocks, lists, inline styles, tables, equations);
3. **validate** — checks the tree against the language's rules, reporting diagnostics (§6) and
   repairing what it can, as mandoc does, so a broken page still renders;
4. **render** — an output device (§5) walks the tree.

3.2. The language is detected per file: a first macro of `.Dd` selects `mdoc`, anything else
`man`. `tbl` regions (`.TS`/`.TE`) and `eqn` regions (`.EQ`/`.EN`) are recognized inside
either.

3.3. **No dependence on the platform.** `liboxdoc` MUST NOT use libc directly and MUST NOT
depend on the host being Linux; it uses only Rust `std`. The programs are built for
`x86_64-unknown-oxidebsd` only. The library keeps host unit tests (§9).

3.4. Input is UTF-8. Invalid bytes are replaced and reported. roff special-character escapes
(`\(xx`, `\[name]`, `\C'name'`, `\[uXXXX]`) map to Unicode code points; each device supplies an
ASCII fallback for characters it cannot show.

## 4. Languages

4.1. **roff core.** The requests and escapes that `mdoc` and `man` pages actually use: comments,
`.de`/`.am`/`.ds`/`.as`/`.rm`/`.rn`, `.nr` and `\n`, `.if`/`.ie`/`.el`, `.so` (restricted to the
manual tree, §8.3), `.ig`, `.br`, `.sp`, `.nf`/`.fi`, `.ft`, `.in`, `.ti`, `.ce`, `.ta`, `.tr`,
`.cc`/`.ec`/`.eo`, `.ll`, `.ne`, `.bp` (ignored), and the font, size, width, spacing and
character escapes. It is not a general typesetter: page layout, diversions, traps and
environments are out of scope, as in mandoc.

4.2. **mdoc.** The full macro set documented by mandoc's `mdoc(7)`, including every `.Bl` list
type, `.Bd` display types, `.Rs` references and `.St`/`.Lb`/`.At`/`.Bx` family expansions.

4.3. **man.** The `man(7)` macros plus the common GNU extensions (`.SY`/`.YS`, `.OP`, `.EX`/`.EE`,
`.UR`/`.UE`, `.MT`/`.ME`, `.TQ`, `.MR`).

4.4. **tbl.** Options, layout lines, data, spans, horizontal and vertical lines, and `T{`/`T}`
text blocks.

4.5. **eqn.** Rendered as linear text in terminal and Markdown output and as MathML in HTML, as
mandoc does.

## 5. Output devices

`-T` selects the device; `-O` passes device options.

| Device | Output |
|---|---|
| `utf8` | Terminal text in UTF-8 (default when the locale or `LANG` names UTF-8) |
| `ascii` | Terminal text in ASCII |
| `html` | A standalone HTML5 document; `-O style=`, `-O man=` (link template), `-O fragment` |
| `markdown` | CommonMark |
| `lint` | Diagnostics only (§6) |
| `tree` | The document tree, for debugging |

5.1. **Terminal styles.** Bold and underline are emitted as SGR escape sequences (`ESC[1m`,
`ESC[4m`) when the output is a terminal or `more`, and not at all otherwise. `-O overstrike`
selects classic backspace overstrike (`b\bb`, `_\bb`) for other pagers and for `col -b`.

5.2. **Width.** `-O width=` sets the line length; by default it is the terminal's width, capped at
80 columns less two, and 78 when the output is not a terminal.

5.3. The terminal device's plain-text output (with `-O overstrike` and no styles) SHOULD match
mandoc's `-T ascii` output byte for byte for well-formed pages, since that is the reference
the BSDs share (§9.2).

## 6. Diagnostics

6.1. Diagnostics use mandoc's levels: `style`, `warning`, `error` and `unsupported`, and the
format `oxdoc: file:line:column: LEVEL: message: detail`.

6.2. `-W level` reports diagnostics at `level` and above; `-W stop` stops after the first. `oxdoc
-T lint` defaults to `-W style` and exits 1 if anything at `warning` or above was reported.

6.3. Cross-references (`.Xr`) are checked against the index when one exists, as mandoc does, and
are reported at `style` level.

6.4. **Rationale.** OxideBSD's own pages are checked with `oxdoc -T lint` on OxideBSD itself; the
levels match mandoc's so that the same pages lint the same way on either.

## 7. The index

7.1. `makewhatis` writes one file per manual tree, `<manpath>/oxdoc.db`. `makewhatis` with no
arguments rebuilds every tree in `man.conf`; `-d dir file ...` updates entries; `-u dir file ...`
removes them; `-t` checks the index against the tree.

7.2. **Format.** A single file, read by memory mapping or one read: a header (magic `OXDOCDB`,
version, offsets), a string table, a page table (file, sections, architectures, names and the
one-line description from `.Nd` or the `NAME` section), and a key table of `(macro class,
value, page)` entries sorted for binary search. The macro classes are mandoc's (`Nm`, `Nd`,
`Xr`, `Fn`, `Ev`, `Pa`, `Er`, `Cd`, `In`, `Va`, `Sh`, `Ss`, ...), so `apropos Xr=getty` and
`apropos -s 8 Nm~^pwd` work as on OpenBSD.

7.3. **Full text.** The key table also holds every word of each page's text under the class
`Tx`: words are split at non-alphanumeric characters, lower-cased, and stored once per page.
`apropos Tx=password` and `apropos Tx~^passw` search it, and `apropos -t word ...` is
shorthand for `Tx=word`. A plain `apropos word` keeps its traditional meaning, a search of
names and descriptions.

7.4. The format is versioned; a program finding an unknown version MUST ignore the file and SHOULD
say so, rather than guess.

7.5. `whatis name` is `apropos -f`: exact matches on page names only.

## 8. man

8.1. `man [-acfhklw] [-C file] [-M path] [-m path] [-S subsection] [[-s] section] name ...`, as
in OpenBSD. With `-k`, `man` is `apropos`; with `-f`, `whatis`.

8.2. **Search.** The manual path is `-M`, else `MANPATH`, else the `manpath` lines of `man.conf`,
else `/usr/share/man:/usr/local/share/man`; `-m` adds to it. Sections are searched in the
order `1 8 6 2 3 5 7 4 9`, then any other. Within a section, `man` looks for `manN/name.N`,
then architecture subdirectories; the index is used when present and the file system otherwise.

8.3. `.so` includes are resolved relative to the manual tree root and MUST NOT leave it.

8.4. Output goes through `MANPAGER`, else `PAGER`, else `/usr/bin/more`, when standard output is
a terminal, and straight to standard output otherwise.

8.5. `man.conf(5)` uses mandoc's format: `manpath dir` and `output option value` lines.

8.6. **The pager.** `more` implements POSIX `more(1)` and, from `less`, backward scrolling,
backward search and the `-R` handling of SGR sequences; it also renders backspace overstrike as
bold and underline. Invoked as `less`, it behaves identically. It pages any input, not only
manual pages.

## 9. Verification

9.1. Host unit tests in `liboxdoc` for each stage.

9.2. **Differential tests against mandoc** on the host, as `lib/libsh` is tested against dash: a
corpus of pages (OxideBSD's own, the pages of every ported program, and a pinned set of OpenBSD
base pages) formatted with `oxdoc -T ascii -O overstrike` and `mandoc -T ascii`; output must match
exactly, and `-T lint` diagnostics must match in level and position. Known, intended differences
are listed in the corpus.

9.3. On-target tests: `man` finds and formats a page from each section, `apropos` and `whatis`
answer from a freshly built index, and `oxdoc -T lint` passes on every page OxideBSD installs.

## 10. Departures from mandoc

1. Terminal styles default to SGR sequences rather than backspace overstrike (§5.1), since the
   console and `more` both understand them.
2. The index is `oxdoc.db` in OxideBSD's own format, not `mandoc.db`; neither can read the other.
3. There is no `catN` preformatted-page support.
4. `apropos` searches the full text of pages (§7.3).

## 11. Implementation order

1. roff core, `mdoc`, the terminal device, `oxdoc`, `man` and `more` — enough to read OxideBSD's
   own pages.

Each language's manual page (`roff(7)`, `mdoc(7)`, `man(7)`, `tbl(7)`, `eqn(7)`) is written with
its parser, in the same step.
2. `man` language and lint.
3. `tbl`.
4. The index, `makewhatis`, `apropos` and `whatis`.
5. `eqn`, HTML and Markdown.

## 12. Resolved questions

1. The pager is `/usr/bin/more`, with `/usr/bin/less` a symbolic link to it (§8.6). POSIX
   specifies `more` and not `less`.
2. `apropos` searches full text, unlike mandoc's (§7.3).
3. Each language reference is written alongside its parser (§11).
