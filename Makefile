# Free Pascal build: `make` produces build/mklist
FPC    ?= fpc
FLAGS  ?= -O2 -XX -CX -Xs -FU$(BUILD)
PREFIX ?= /usr/local
DESTDIR ?=

SRC     = src
BUILD   = build
BIN     = $(BUILD)/mklist

SOURCES = $(addprefix $(SRC)/,mklist.pas uApp.pas uViewer.pas uScreen.pas uOpts.pas uCP437.pas uSpool.pas uKeys.pas)

$(BIN): $(SOURCES)
	@mkdir -p $(BUILD)
	$(FPC) $(FLAGS) -Fu$(SRC) -o$(BIN) $(SRC)/mklist.pas

mklist: $(BIN)

# make install                     -> /usr/local/bin/mklist (may need sudo)
# make install PREFIX=$$HOME/.local -> ~/.local/bin/mklist
install: $(BIN)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(BIN) $(DESTDIR)$(PREFIX)/bin/mklist

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/mklist

# Behavioural tests on a pseudo-terminal (needs python3 and `pip install pyte`).
# Run them against another build with: LIST_BIN=/path/to/mklist python3 tests/run_tests.py
test: $(BIN)
	LIST_BIN=$(CURDIR)/$(BIN) python3 tests/run_tests.py

clean:
	rm -rf $(BUILD)

.PHONY: mklist install uninstall test clean
