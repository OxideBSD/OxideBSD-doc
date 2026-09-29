#!/bin/sh
# Renders OxideBSD's manual pages into the site with oxdoc(1): man/NAME.SECTION.html for each
# page, and man/index.html listing them by section.
# Usage: man.sh OXDOC MANDIR OUT   (MANDIR holds man1/, man5/, ...: OxideBSD's share/man)

set -eu

oxdoc=${1:?usage: man.sh OXDOC MANDIR OUT}
mandir=${2:?usage: man.sh OXDOC MANDIR OUT}
out=${3:?usage: man.sh OXDOC MANDIR OUT}
here=$(cd "$(dirname "$0")" && pwd)

. "$here/lib.sh"

mkdir -p "$out/man"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Render each page. Cross-references link to NAME.SECTION.html next to it.
for src in "$mandir"/man*/*.[1-9]; do
	[ -f "$src" ] || continue
	file=$(basename "$src")
	name=${file%.*}
	sec=${file##*.}
	"$oxdoc" -T html -O fragment,man=%N.%S.html "$src" > "$tmp/$name.$sec.html"
	# The one-line description, for the index.
	tr '\n' ' ' < "$tmp/$name.$sec.html" |
		sed -n 's/.*<span class="Nd">\(.*\)/\1/p' |
		sed 's/<\/span>.*//; s/  */ /g' > "$tmp/$name.$sec.nd"
	echo "$sec $name" >> "$tmp/list"
done

# A reference to a page the site doesn't have is left unlinked.
for f in "$tmp"/*.html; do
	for target in $(grep -o 'class="Xr" href="[^"]*"' "$f" | sed 's/.*href="//; s/"$//' | sort -u); do
		if [ ! -f "$tmp/$target" ]; then
			t=$target sed "s|<a class=\"Xr\" href=\"$target\">|<a class=\"Xr\">|g" "$f" > "$f.new"
			mv "$f.new" "$f"
		fi
	done
done

for f in "$tmp"/*.html; do
	page=$(basename "$f" .html)
	name=${page%.*}
	sec=${page##*.}
	{
		echo '<div class="manual">'
		cat "$f"
		echo '</div>'
	} | page "$name($sec) - OxideBSD" "../" "$name($sec): $(cat "$tmp/$name.$sec.nd")" > "$out/man/$page.html"
done

# The index.
section_name() {
	case $1 in
	1) echo "General commands" ;;
	2) echo "System calls" ;;
	3) echo "Library functions" ;;
	4) echo "Device drivers" ;;
	5) echo "File formats" ;;
	6) echo "Games" ;;
	7) echo "Miscellaneous" ;;
	8) echo "System administration" ;;
	9) echo "Kernel internals" ;;
	esac
}

{
	echo "<h1>Manual pages</h1>"
	for sec in 1 2 3 4 5 6 7 8 9; do
		grep -q "^$sec " "$tmp/list" || continue
		echo "<h2>Section $sec: $(section_name "$sec")</h2>"
		echo "<dl>"
		grep "^$sec " "$tmp/list" | sort -k2 | while read -r s name; do
			echo "<dt><a href=\"$name.$s.html\">$name($s)</a></dt>"
			echo "<dd>$(cat "$tmp/$name.$s.nd")</dd>"
		done
		echo "</dl>"
	done
} | page "Manual pages - OxideBSD" "../" "OxideBSD's manual pages: commands, system calls, library functions, file formats and system administration." > "$out/man/index.html"
