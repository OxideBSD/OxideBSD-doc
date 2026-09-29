# oxidebsd.org. `make` builds the site into _site/; `make man` adds the manual pages, rendered
# with oxdoc(1) from OxideBSD's share/man (OXDOC and MANDIR say where those are); `make doc` adds
# the design specifications from this repository's root, rendered with lowdown(1); `make sitemap`
# (last) lists every page for search engines.

OUT ?=		_site
OXDOC ?=	oxdoc
MANDIR ?=	../../OxideBSD/share/man
LOWDOWN ?=	lowdown
SPECDIR ?=	..

all: site

site:
	sh build.sh ${OUT}

man:
	sh man.sh ${OXDOC} ${MANDIR} ${OUT}

doc:
	sh doc.sh ${LOWDOWN} ${SPECDIR} ${OUT}

# Last: lists every page built so far.
sitemap:
	sh sitemap.sh ${OUT}

# Text still to be written: the WRITE: comments in the pages and posts.
todo:
	@grep -n 'WRITE:' pages/*.html news/*.html 2>/dev/null || true

clean:
	rm -rf ${OUT}

.PHONY: all site man doc sitemap todo clean
