# list (Free Pascal)

A Free Pascal port of the Rust `list` text-mode file browser (itself modelled on Vernon Buerg's DOS
LIST): same keys, text and hex modes, status lines top and bottom, memory-windowed reading of big
files, stdin as a pager, follow/tail, command history, remembered positions, bytes search, and regex search.

    make                              # needs fpc 3.2+; produces ./list (about 420 KB)
    make install                      # /usr/local/bin/list (may need sudo)
    make install PREFIX=$HOME/.local  # ~/.local/bin/list
    make test                         # behavioural tests (python3 + `pip install pyte`)
    ./list [-x] [-m SIZE] [- | file | wildcard | directory]...
    some-command | ./list

Press F1 for the key list; the README of the Rust version describes the commands. The configuration
(`list.cfg`, `history.txt`, `positions.txt`) lives in the same folder as the Rust version
(`~/.config/list/`, `%APPDATA%\list\` on Windows), so the two share settings.

## Regex search

`r` or `re PATTERN` (any case) / `rex PATTERN` (exact case), using FPC's `RegExpr` (TRegExpr): Perl-like syntax
with `\d \w \s`, classes, groups, `|`, `{n,m}`, lazy quantifiers. Matching is byte-wise and per line (`^`/`$` are
line anchors, `.` does not cross a newline), non-overlapping, and highlighted on screen. Case-insensitive matching
is ASCII only, and `.` matches one byte, so it takes two to match an accented letter. In hex mode only the last hit
is highlighted, and in windowed (big) files a match longer than 4 KB that straddles a 1 MB chunk boundary can be missed.

## How it differs from the Rust version

* **Terminal layer:** FPC's `Video` and `Keyboard` units. Cells hold CP437 bytes, so UTF-8 text is
  mapped to CP437 for display: accented Latin letters and box drawing show correctly, but characters with
  no CP437 equivalent (CJK, emoji, ...) appear as `?`. Files that are not UTF-8 are shown as CP437, as before.
* **Colours:** the 16 standard terminal colours (so exact shades depend on the terminal theme), and only 8
  background colours (0-7). Find highlight defaults to black on brown.
* **Keyboard:** on Unix the program has its own key decoder (`uKeys.pas`) instead of FPC's `Keyboard` unit,
  which waits for a second key after Esc (freezing the program until then) and stalls on input bursts of more
  than 256 bytes. A lone Esc is delivered after 40 ms, long pastes work, and UTF-8 can be typed on the command
  line. Other platforms use the `Keyboard` unit (build with `-dFORCEKBD` to use it on Unix too).
* Alt-E (25/43 rows) is not supported. Resizing the terminal works on Unix.
* No threads: piped input is read with non-blocking reads from the main loop.
* **Untested:** everything was developed and tested on Linux only. The Windows branches (stdin pipe via
  `PeekNamedPipe`, `PRN` printing, `%APPDATA%`) have not been compiled or run.

## Tests

`tests/run_tests.py` drives the program through a pseudo-terminal and reads the screen back with a terminal
emulator (`pyte`), so it checks what a user would see: views, search and regex, big-file windowing and line
numbers, stdin, follow/tail, Esc handling, key bursts, history, remembered positions, windows, copy, resize, etc.
The same suite passes for the Rust version (`LIST_BIN=/path/to/list python3 tests/run_tests.py`), which keeps the
two implementations in agreement. `-k NAME` selects tests and `-v` prints tracebacks.
