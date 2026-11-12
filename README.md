# list (Free Pascal)

A Free Pascal port of the Rust `list` text-mode file browser (itself modelled on Vernon Buerg's DOS
LIST): same keys, text and hex modes, status lines top and bottom, memory-windowed reading of big
files, stdin as a pager, follow/tail, command history, remembered positions, bytes search.
**Regex search is not included** (`r` / `re` just say so).

    make            # needs fpc 3.2+; produces ./list (about 400 KB)
    ./list [-x] [-m SIZE] [- | file | wildcard | directory]...
    some-command | ./list

Press F1 for the key list; the README of the Rust version describes the commands. The configuration
(`list.cfg`, `history.txt`, `positions.txt`) lives in the same folder as the Rust version
(`~/.config/list/`, `%APPDATA%\list\` on Windows), so the two share settings.

## How it differs from the Rust version

* **Terminal layer:** FPC's `Video` and `Keyboard` units. Cells hold CP437 bytes, so UTF-8 text is
  mapped to CP437 for display: accented Latin letters and box drawing show correctly, but characters with
  no CP437 equivalent (CJK, emoji, ...) appear as `?`. Files that are not UTF-8 are shown as CP437, as before.
* **Colours:** the 16 standard terminal colours (so exact shades depend on the terminal theme), and only 8
  background colours (0-7). Find highlight defaults to black on brown.
* **Esc must be pressed twice** to act (quit / cancel the command line): the `Keyboard` unit cannot tell a
  lone Esc from the start of an Alt-key sequence. F10, Alt-X and Ctrl-C quit at once.
* A paste of more than ~256 bytes at once can stall until the next keypress (a bug in the unit's input ring).
* Alt-E (25/43 rows) is not supported. Resizing the terminal works on Unix.
* No threads: piped input is read with non-blocking reads from the main loop.
* **Untested:** everything was developed and tested on Linux only. The Windows branches (stdin pipe via
  `PeekNamedPipe`, `PRN` printing, `%APPDATA%`) have not been compiled or run.
