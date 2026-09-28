# oxidebsd.org. `make` builds the site into _site/; `make man` adds the manual pages, rendered
# with oxdoc(1) from OxideBSD's share/man (OXDOC and MANDIR say where those are).

OUT ?=		_site
OXDOC ?=	oxdoc
MANDIR ?=	../../OxideBSD/share/man

all: site

site:
	sh build.sh ${OUT}

man:
	sh man.sh ${OXDOC} ${MANDIR} ${OUT}

# Text still to be written: the WRITE: comments in the pages and posts.
todo:
	@grep -n 'WRITE:' pages/*.html news/*.html 2>/dev/null || true

clean:
	rm -rf ${OUT}

.PHONY: all site man todo clean
