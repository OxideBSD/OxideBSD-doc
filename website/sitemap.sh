#!/bin/sh
# Lists every page of the built site in sitemap.xml, for search engines (robots.txt names it).
# Run last, after the site, manual pages and specifications are built.
# Usage: sitemap.sh OUT

set -eu

out=${1:?usage: sitemap.sh OUT}
site=https://oxidebsd.org/

{
	echo '<?xml version="1.0" encoding="UTF-8"?>'
	echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
	(cd "$out" && find . -name '*.html' | sed 's|^\./||' | sort) | while read -r path; do
		# A directory's index.html is served as the directory itself.
		case $path in
		index.html) path= ;;
		*/index.html) path=${path%index.html} ;;
		esac
		echo "<url><loc>$site$path</loc></url>"
	done
	echo '</urlset>'
} > "$out/sitemap.xml"
