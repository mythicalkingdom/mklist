# Free Pascal build: `make` produces ./list
FPC    ?= fpc
FLAGS  ?= -O2 -XX -CX -Xs -FUbuild
PREFIX ?= /usr/local
DESTDIR ?=

SOURCES = list.pas uApp.pas uViewer.pas uScreen.pas uOpts.pas uCP437.pas uSpool.pas uKeys.pas

list: $(SOURCES)
	@mkdir -p build
	$(FPC) $(FLAGS) -Fu. -olist list.pas

# make install                     -> /usr/local/bin/list (may need sudo)
# make install PREFIX=$$HOME/.local -> ~/.local/bin/list
install: list
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 list $(DESTDIR)$(PREFIX)/bin/list

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/list

# Behavioural tests on a pseudo-terminal (needs python3 and `pip install pyte`).
# Run them against another build with: LIST_BIN=/path/to/list python3 tests/run_tests.py
test: list
	LIST_BIN=$(CURDIR)/list python3 tests/run_tests.py

clean:
	rm -rf build list

.PHONY: install uninstall test clean
