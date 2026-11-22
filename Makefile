# Free Pascal build: `make` produces ./mklist
FPC    ?= fpc
FLAGS  ?= -O2 -XX -CX -Xs -FUbuild
PREFIX ?= /usr/local
DESTDIR ?=

SOURCES = mklist.pas uApp.pas uViewer.pas uScreen.pas uOpts.pas uCP437.pas uSpool.pas uKeys.pas

mklist: $(SOURCES)
	@mkdir -p build
	$(FPC) $(FLAGS) -Fu. -omklist mklist.pas

# make install                     -> /usr/local/bin/mklist (may need sudo)
# make install PREFIX=$$HOME/.local -> ~/.local/bin/mklist
install: mklist
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 mklist $(DESTDIR)$(PREFIX)/bin/mklist

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/mklist

# Behavioural tests on a pseudo-terminal (needs python3 and `pip install pyte`).
# Run them against another build with: LIST_BIN=/path/to/mklist python3 tests/run_tests.py
test: mklist
	LIST_BIN=$(CURDIR)/mklist python3 tests/run_tests.py

clean:
	rm -rf build mklist

.PHONY: install uninstall test clean
