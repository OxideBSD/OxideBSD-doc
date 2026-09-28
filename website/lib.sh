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

# page TITLE ROOT < BODY > OUT: a whole page around a body.
page() {
	fill "$1" "$2" "" "$here/template/head.html"
	cat
	fill "$1" "$2" "" "$here/template/foot.html"
}
