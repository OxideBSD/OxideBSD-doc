# Helpers shared by build.sh and man.sh; $here must name the website directory.

# The title on a fragment's first line.
title() {
	sed -n '1s/^<!-- title: \(.*\) -->$/\1/p' "$1"
}

# A fragment without its title line.
body() {
	sed 1d "$1"
}

# Text escaped for HTML and XML.
escape() {
	sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# The template with @TITLE@, @ROOT@ and @EXTRA@ replaced (literally: no escapes in the
# values are interpreted).
fill() {
	TITLE=$1 ROOT=$2 EXTRA=$3 awk '
		function sub_all(s, from, to,    i, r) {
			r = ""
			while ((i = index(s, from)) > 0) {
				r = r substr(s, 1, i - 1) to
				s = substr(s, i + length(from))
			}
			return r s
		}
		{
			s = sub_all($0, "@TITLE@", ENVIRON["TITLE"])
			s = sub_all(s, "@ROOT@", ENVIRON["ROOT"])
			s = sub_all(s, "@EXTRA@", ENVIRON["EXTRA"])
			print s
		}' "$4"
}

# The first paragraph of a body, as plain text, cut to about 160 characters (at the end of a
# sentence if one ends there, else at a word): what search results show under a page's title
# when it gives no description of its own.
first_paragraph() {
	tr '\n' ' ' | awk '{
		i = index($0, "<p>"); if (i == 0) exit
		s = substr($0, i + 3); j = index(s, "</p>"); if (j > 0) s = substr(s, 1, j - 1)
		gsub(/<[^>]*>/, "", s); gsub(/  +/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
		if (length(s) > 160) {
			s = substr(s, 1, 160)
			if (match(s, /^.*[.!?] /)) s = substr(s, 1, RLENGTH - 1)
			else { sub(/ [^ ]*$/, "", s); s = s "..." }
		}
		print s
	}'
}

# page TITLE ROOT [DESCRIPTION] < BODY > OUT: a whole page around a body. The description
# (escaped here) defaults to the body's first paragraph.
page() {
	body=$(cat)
	desc=${3-}
	[ -n "$desc" ] || desc=$(printf '%s\n' "$body" | first_paragraph)
	extra=
	if [ -n "$desc" ]; then
		desc=$(printf '%s' "$desc" | escape | sed 's/"/\&quot;/g')
		extra="<meta name=\"description\" content=\"$desc\">
"
	fi
	fill "$1" "$2" "$extra" "$here/template/head.html"
	printf '%s\n' "$body"
	fill "$1" "$2" "" "$here/template/foot.html"
}
