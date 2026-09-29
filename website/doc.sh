#!/bin/sh
# Renders the design specifications (the Markdown files in the repository root whose title ends in
# "design specification") into the site with lowdown(1): doc/NAME.html for each, and
# doc/index.html listing them with their status.
# Usage: doc.sh LOWDOWN SRCDIR OUT   (SRCDIR holds the .md files: this repository's root)

set -eu

lowdown=${1:?usage: doc.sh LOWDOWN SRCDIR OUT}
srcdir=${2:?usage: doc.sh LOWDOWN SRCDIR OUT}
out=${3:?usage: doc.sh LOWDOWN SRCDIR OUT}
here=$(cd "$(dirname "$0")" && pwd)

. "$here/lib.sh"

mkdir -p "$out/doc"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The page a spec's file becomes: INIT_SH.md -> init-sh.html.
htmlname() {
	basename "$1" .md | tr 'A-Z_' 'a-z-' | sed 's/$/.html/'
}

for src in "$srcdir"/*.md; do
	head -n 1 "$src" | grep -q 'design specification$' || continue
	file=$(basename "$src")
	echo "$file" >> "$tmp/list"
	"$lowdown" -Thtml --html-head-ids "$src" > "$tmp/$file.html"
done
[ -f "$tmp/list" ] || { echo "doc.sh: no design specifications in $srcdir" >&2; exit 1; }

# Mentions of another spec by file name ("`UNIX.md`") link to its page.
sedscript=$tmp/links.sed
while read -r file; do
	echo "s|<code>$file</code>|<a href=\"$(htmlname "$file")\"><code>$file</code></a>|g"
done < "$tmp/list" > "$sedscript"

while read -r file; do
	name=$(htmlname "$file")
	# "# OxideBSD sockets and local sockets: design specification" -> "sockets and local sockets"
	# (Left in lower case: several begin with a command's name.)
	subject=$(head -n 1 "$srcdir/$file" | sed 's/^# OxideBSD //; s/:* *—* *design specification$//')
	status=$(sed -n 's/^Status: \*\*\(.*\)\*\*.*/\1/p' "$srcdir/$file" | head -n 1 | sed 's/\.$//; s/,$//')
	printf '%s\t%s\t%s\n' "$name" "$subject" "$status" >> "$tmp/index"
	{
		echo '<div class="spec">'
		sed -f "$sedscript" "$tmp/$file.html"
		echo "<p class=\"date\">Source: <a href=\"https://github.com/OxideBSD/OxideBSD-doc/blob/master/$file\">$file</a></p>"
		echo '</div>'
	} | page "$(printf '%s' "$subject" | escape) - OxideBSD design" "../" "OxideBSD design specification: $subject. $status." > "$out/doc/$name"
done < "$tmp/list"

{
	echo "<h1>Design specifications</h1>"
	echo "<p>How parts of OxideBSD are meant to work, and why. The interfaces themselves are"
	echo "documented in the <a href=\"../man/\">manual pages</a>.</p>"
	echo "<dl>"
	sort -t "$(printf '\t')" -k2 "$tmp/index" | while IFS="$(printf '\t')" read -r name subject status; do
		echo "<dt><a href=\"$name\">$(printf '%s' "$subject" | escape)</a></dt>"
		echo "<dd>$(printf '%s' "$status" | escape)</dd>"
	done
	echo "</dl>"
} | page "Design specifications - OxideBSD" "../" > "$out/doc/index.html"
