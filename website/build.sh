#!/bin/sh
# Builds oxidebsd.org into a directory: the pages, the news pages and their Atom feed.
# Usage: build.sh OUT
#
# A page (pages/NAME.html) or news post (news/YYYY-MM-DD-slug.html) is an HTML fragment whose
# first line is "<!-- title: Its title -->"; it is wrapped in template/head.html and
# template/foot.html.

set -eu

out=${1:?usage: build.sh OUT}
here=$(cd "$(dirname "$0")" && pwd)
site=https://oxidebsd.org/

mkdir -p "$out/news"

. "$here/lib.sh"

# Pages.
for src in "$here"/pages/*.html; do
	name=$(basename "$src")
	body "$src" | page "$(title "$src" | escape)" "" > "$out/$name"
done
cp "$here/style.css" "$out/style.css"
[ -f "$here/CNAME" ] && cp "$here/CNAME" "$out/CNAME"
cp "$here/robots.txt" "$out/robots.txt"
[ -f "$here/favicon.ico" ] && cp "$here/favicon.ico" "$out/favicon.ico"
[ -d "$here/images" ] && cp -R "$here/images" "$out/"

# News posts, newest first.
posts=$(ls "$here"/news/*.html 2>/dev/null | sort -r || true)

{
	echo "<h1>News</h1>"
	if [ -z "$posts" ]; then
		echo "<p>Nothing yet.</p>"
	else
		echo '<ul class="news">'
		for src in $posts; do
			name=$(basename "$src")
			date=$(echo "$name" | cut -c1-10)
			echo "<li><span class=\"date\">$date</span> <a href=\"$name\">$(title "$src" | escape)</a></li>"
		done
		echo "</ul>"
	fi
	echo '<p><a href="atom.xml">Atom feed</a></p>'
} | page "News - OxideBSD" "../" "News from the OxideBSD project." > "$out/news/index.html"

for src in $posts; do
	name=$(basename "$src")
	date=$(echo "$name" | cut -c1-10)
	t=$(title "$src" | escape)
	{
		echo "<h1>$t</h1>"
		echo "<p class=\"date\">$date</p>"
		body "$src"
	} | page "$t - OxideBSD" "../" > "$out/news/$name"
done

# The Atom feed: every post, its whole text.
{
	newest=$(echo "$posts" | head -n 1)
	updated=${newest:+$(basename "$newest" | cut -c1-10)}
	echo '<?xml version="1.0" encoding="utf-8"?>'
	echo '<feed xmlns="http://www.w3.org/2005/Atom">'
	echo '<title>OxideBSD news</title>'
	echo "<link href=\"${site}news/\"/>"
	echo "<link rel=\"self\" href=\"${site}news/atom.xml\"/>"
	echo "<id>${site}news/</id>"
	echo "<updated>${updated:-2026-09-28}T00:00:00Z</updated>"
	echo '<author><name>OxideBSD</name></author>'
	for src in $posts; do
		name=$(basename "$src")
		date=$(echo "$name" | cut -c1-10)
		echo '<entry>'
		echo "<title>$(title "$src" | escape)</title>"
		echo "<link href=\"${site}news/$name\"/>"
		echo "<id>${site}news/$name</id>"
		echo "<updated>${date}T00:00:00Z</updated>"
		echo '<content type="html">'
		body "$src" | escape
		echo '</content>'
		echo '</entry>'
	done
	echo '</feed>'
} > "$out/news/atom.xml"
