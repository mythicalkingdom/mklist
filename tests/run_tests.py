#!/usr/bin/env python3
"""Behavioural tests for `list`, run against a real terminal session.

    python3 tests/run_tests.py                 # tests ./list (the Free Pascal build)
    LIST_BIN=/path/to/list python3 tests/run_tests.py
    python3 tests/run_tests.py -k regex -v     # only tests whose name contains 'regex'

Needs:  pip install pyte
The same tests are meant to pass for every implementation (Rust and Free Pascal).
"""
import glob
import os
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import Env  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.abspath(os.environ.get("LIST_BIN", os.path.join(HERE, "..", "list")))

TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


# ---------------------------------------------------------------- fixtures
UP, DOWN, RIGHT, LEFT = "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D"
PGUP, PGDN, HOME, END, DEL = "\x1b[5~", "\x1b[6~", "\x1b[H", "\x1b[F", "\x1b[3~"
F1, F3, F5, F9, F10 = "\x1bOP", "\x1bOR", "\x1b[15~", "\x1b[20~", "\x1b[21~"
ESC = "\x1b"


def alt(c):
    return ESC + c


def big(env):
    """300 lines of varying length, with tabs."""
    lines = ["line %d some text\twith tab and a long tail %s\n" % (i, "x" * (i % 7 * 20)) for i in range(1, 301)]
    return env.write("big.txt", "".join(lines)), lines


HUGE_LINES = 100000


def huge(env):
    """~3.5 MB, so that a 64K memory limit forces many buffer reloads."""
    env.write("huge.txt", "".join("line %07d the quick brown fox é\n" % i for i in range(1, HUGE_LINES + 1)))
    return env.path("huge.txt")


def expect(cond, msg=""):
    if not cond:
        raise AssertionError(msg)


def eq(a, b, msg=""):
    if a != b:
        raise AssertionError("%s: expected %r, got %r" % (msg, b, a))


# ---------------------------------------------------------------- basic views
@test
def text_view(env):
    big(env)
    s = env.start("big.txt")
    expect(s.top().startswith("LIST"), s.top())
    expect("big.txt" in s.top())
    eq(s.first_line_no(), 1, "first line")
    expect(s.row(1).startswith("line 1 some text"), s.row(1))
    expect(s.bottom().startswith("Command"), s.bottom())
    expect(s.top().rstrip().endswith("%"), "percent on the status line: " + s.top())


@test
def hex_view(env):
    env.write("a.txt", "10 FORI=1TO3:PRINTI;:NEXTI\r\n20 OPEN\r\n")
    s = env.start("a.txt")
    s.send(alt("h"))
    expect(s.row(1).startswith("000000"), s.row(1))
    expect("31 30 20 46 4F 52 49 3D-31 54 4F 33 3A 50 52 49" in s.row(1), s.row(1))
    expect(s.row(1).endswith("10 FORI=1TO3:PRI"), s.row(1))
    expect("♪◙" in s.row(2), "CR/LF drawn as glyphs: " + s.row(2))      # the DOS look: ♪◙
    s.send(alt("h"))
    expect(s.row(1).startswith("10 FORI"), "back to text mode")


@test
def help_pages(env):
    big(env)
    s = env.start("big.txt")
    s.send(F1)
    expect("FUNCTION KEYS" in s.text() and "ALT- KEYS" in s.text(), "page 1")
    expect("a-Z" in s.text() and "a-A" in s.text(), "all alt keys on page 1")
    s.send("x")
    expect("NAVIGATION AND COMMAND LINE" in s.text(), "page 2")
    s.send("x")
    expect(s.top().startswith("LIST"), "closes after the last page")


@test
def end_of_file_message(env):
    env.write("small.txt", "one\ntwo\nthree\n")
    s = env.start("small.txt")
    expect("End-of-file" in s.bottom(), s.bottom())
    eq(s.first_line_no(), 1)


# ---------------------------------------------------------------- search
@test
def find_literal_highlight(env):
    big(env)
    s = env.start("big.txt")
    s.send("/LINE 150\r")
    eq(s.first_line_no(), 150, "jumped to the match")
    eq(s.highlighted(1), "line 150", "any-case match is highlighted as in the file")


@test
def find_exact_case(env):
    big(env)
    s = env.start("big.txt")
    s.send("\\LINE 150\r")
    expect("not found" in s.bottom().lower(), s.bottom())
    s.send("\\line 150\r")
    eq(s.first_line_no(), 150)


@test
def find_next_prev_wrap(env):
    big(env)
    s = env.start("big.txt")
    s.send("/line 1\r")                        # first hit is on screen already
    s.send(F3)
    first = s.first_line_no()
    s.send(F9)
    expect(s.first_line_no() is not None)
    s.send("/line 300\r")
    s.send(F3)                                 # only one match: it wraps to itself
    expect("wrapped" in s.bottom().lower(), s.bottom())


@test
def regex_basic(env):
    big(env)
    s = env.start("big.txt")
    s.send("r")                                # prefills "re "
    s.send("line 1[0-9]5 S\r")                 # any case
    eq(s.first_line_no(), 105)
    eq(s.highlighted(1), "line 105 s")
    s.send("\r")
    s.send("re ^line 2\\d{2} so\r")
    eq(s.first_line_no(), 200, "anchor and repetition")
    s.send("\r")
    s.send("re (tab|tail) and\r")           # searches on from the current line (200)
    eq(s.first_line_no(), 200)
    eq(s.highlighted(1), "tab and", "alternation")


@test
def regex_exact_case_and_errors(env):
    big(env)
    s = env.start("big.txt")
    s.send("\r")
    s.send("rex line 1[0-9]5 S\r")
    expect("not found" in s.bottom().lower(), s.bottom())
    s.send("\r")
    s.send("rex line 1[0-9]5 s\r")
    eq(s.first_line_no(), 105)
    s.send("\r")
    s.send("re (unclosed\r")
    expect("regex" in s.bottom().lower(), s.bottom())
    s.send("\r")
    s.send("re text.line\r")                   # . does not cross a newline
    expect("not found" in s.bottom().lower(), s.bottom())


@test
def bytes_search(env):
    env.write("b.bin", b"AB\x00CD\r\nplain\n")
    s = env.start("b.bin")                     # NUL byte: starts in hex mode
    s.send("\r")
    s.send("bytes 43 44\r")
    expect("4344" in s.highlighted(1).replace(" ", ""), repr(s.highlighted(1)))
    s.send("\r")
    s.send("bytes 4z\r")
    expect("hex" in s.bottom().lower(), s.bottom())


# ---------------------------------------------------------------- navigation and display
@test
def goto_and_percent(env):
    big(env)
    s = env.start("big.txt")
    s.send("#200\r")
    eq(s.first_line_no(), 200)
    expect(s.row(1).startswith("line 200 "), s.row(1))
    expect(" 6" in s.top() or " 7" in s.top(), "percent shown: " + s.top())
    s.send(END)
    eq(s.first_line_no(), 278, "last page")
    expect("End-of-file" in s.bottom())
    s.send(HOME)
    eq(s.first_line_no(), 1)
    s.send("+40\r")
    eq(s.first_line_no(), 41)
    s.send("-10\r")
    eq(s.first_line_no(), 31)


@test
def sideways_scroll_wrap_ruler(env):
    big(env)
    s = env.start("big.txt")
    s.send(RIGHT * 2)
    expect("Col 17" in s.top(), s.top())
    s.send(LEFT * 2)
    expect("Col" not in s.top(), s.top())
    s.send("w")                                # wrap long lines
    expect(any(r.startswith("xxxx") for r in s.rows_text()[1:24]), "wrapped continuation rows")
    s.send("w")
    s.send(alt("r"))                           # ruler
    expect("+" in s.row(1) and "1" in s.row(1) and s.row(1)[0] in "─-", repr(s.row(1)))


@test
def utf8_and_cp437_display(env):
    env.write("u8.txt", "café 日本 ☺ ok\ttab\nsecond ── box\n")
    s = env.start("u8.txt")
    expect("café" in s.row(1) and "☺" in s.row(1), s.row(1))
    expect("── box" in s.row(2), s.row(2))
    s.send(alt("t"))                           # tabs off: a tab is drawn as a glyph
    expect("ok○tab" in s.row(1), s.row(1))
    env.write("cp.txt", b"dos \xc9\xcd\xbb \x01\x02 bytes \xe9 here\r\n")
    s2 = env.start("cp.txt")
    expect("╔═╗" in s2.row(1) and "θ" not in s2.row(1) and "Θ" in s2.row(1), s2.row(1))


@test
def colour_keys_and_toggles(env):
    big(env)
    s = env.start("big.txt")
    before = s.screen.buffer[3][5].bg
    s.send(F5)
    expect(s.screen.buffer[3][5].bg != before, "F5 changes the text background")
    s.send(alt("z"))
    expect("Toggles" in s.text(), "Alt-Z shows the toggles")


@test
def resize(env):
    big(env)
    s = env.start("big.txt")
    s.resize(30, 100)
    expect(s.row(29).startswith("Command"), s.row(29))
    expect(s.top().rstrip().endswith("%") and len(s.top().rstrip()) > 90, "status line spans the new width")
    s.resize(12, 50)
    expect(s.row(11).startswith("Command"), s.row(11))


# ---------------------------------------------------------------- big files / memory windowing
@test
def windowed_navigation(env):
    path = huge(env)
    s = env.start("-m", "64K", path)
    expect("@" in s.top(), "byte offsets shown when windowed: " + s.top())
    eq(s.first_line_no(), 1)
    s.send(END)
    eq(s.first_line_no(), HUGE_LINES - 22, "End")
    expect(s.row(1).startswith("line %07d" % (HUGE_LINES - 22)), s.row(1))
    expect("End-of-file" in s.bottom())
    s.send(HOME)
    eq(s.first_line_no(), 1, "Home")
    s.send("#50000\r")
    eq(s.first_line_no(), 50000, "goto")
    expect(s.row(1).startswith("line 0050000"), s.row(1))
    s.send("/line 0070000\r")
    eq(s.first_line_no(), 70000, "search far")
    expect(s.row(1).startswith("line 0070000"), s.row(1))
    s.send("\\line 0000030\r")
    eq(s.first_line_no(), 30, "search backwards across many reloads (wraps)")


@test
def windowed_scrolling_keeps_line_numbers(env):
    path = huge(env)
    s = env.start("-m", "64K", path)
    s.send("#50000\r")
    s.type_chunks(UP * 3000, chunk=90, wait=0.08)           # far more than one 64K window
    eq(s.first_line_no(), 47000, "3000 Up presses")
    expect(s.row(1).startswith("line 0047000"), s.row(1))
    s.type_chunks(PGDN * 200, chunk=80, wait=0.08)           # 200 pages of 23 lines
    eq(s.first_line_no(), 47000 + 200 * 23, "200 PgDn presses")
    expect(s.row(1).startswith("line %07d" % (47000 + 200 * 23)), s.row(1))


@test
def windowed_hex_offsets(env):
    path = huge(env)
    s = env.start("-m", "64K", path)
    s.send(alt("h"))
    s.send("$100000\r")
    expect(s.row(1).startswith("100000"), "hex offset column shows real file offsets: " + s.row(1))


@test
def mem_command(env):
    big(env)
    s = env.start("big.txt")
    s.send("\r")
    s.send("mem 2M\r")
    expect("2M" in s.bottom(), s.bottom())
    s.send("\r")
    s.send("mem 1x\r")
    expect("bad" in s.bottom().lower(), s.bottom())


# ---------------------------------------------------------------- stdin, follow, tail
@test
def stdin_pager(env):
    env_vars = {"TMPDIR": env.root}
    s = env.start(stdin_pipe=True, env=env_vars)
    expect("(stdin)" in s.top(), s.top())
    s.feed(b"first line\nsecond line\npartial")
    expect(s.row(1).startswith("first line") and s.row(3).startswith("partial"), s.text())
    expect("waiting" in s.bottom().lower(), "input still pending: " + s.bottom())
    s.feed(b" now complete\n" + b"".join(b"row %d\n" % i for i in range(3, 60)))
    expect(s.row(3).startswith("partial now complete"), s.row(3))
    s.send(END)
    expect(s.row(1).startswith("row 37") or s.row(1).startswith("row 38"), s.row(1))
    s.close_stdin()
    s.send(END)
    expect("end-of-file" in s.bottom().lower(), "input finished: " + s.bottom())
    expect(glob.glob(os.path.join(env.root, "list-*.tmp")), "spool file exists while running")
    s.send("q")
    expect(s.exited(), "q quits")
    eq(glob.glob(os.path.join(env.root, "list-*.tmp")), [], "spool file removed on exit")


@test
def follow_and_tail(env):
    log = env.write("grow.log", "".join("entry %d\n" % i for i in range(1, 31)))
    s = env.start("grow.log")
    eq(s.first_line_no(), 1)
    with open(log, "a") as f:
        f.write("".join("entry %d\n" % i for i in range(31, 41)))
    before = s.top()
    expect(s.until(lambda: s.top() != before, 4), "the percentage changes as the file grows")
    eq(s.first_line_no(), 1, "not following: the view stays put")
    s.send("f")
    expect("follow" in s.bottom().lower(), s.bottom())
    eq(s.first_line_no(), 18, "follow jumps to the end")
    with open(log, "a") as f:
        f.write("".join("entry %d\n" % i for i in range(41, 51)))
    expect(s.until(lambda: s.first_line_no() == 28, 4), "follow keeps up: " + s.top())
    s.send(UP)
    with open(log, "a") as f:
        f.write("entry 51\n")
    s.pump(1.0)
    expect(s.first_line_no() == 27, "Up stops following: " + s.top())
    with open(log, "w") as f:                  # truncation: start over
        f.write("fresh start\n")
    expect(s.until(lambda: s.row(1).startswith("fresh start"), 4), s.text())


# ---------------------------------------------------------------- keyboard
@test
def lone_esc_quits(env):
    big(env)
    s = env.start("big.txt")
    s.send(ESC)
    expect(s.exited(1.5), "a single Esc quits")


@test
def esc_cancels_input_without_freezing(env):
    log = env.write("grow2.log", "one\ntwo\n")
    s = env.start("grow2.log")
    s.send("\r")
    s.send("abc")
    expect("abc" in s.bottom(), s.bottom())
    s.send(ESC)
    expect("abc" not in s.bottom(), "Esc cancels the command line: " + s.bottom())
    with open(log, "a") as f:
        f.write("three\n")
    expect(s.until(lambda: s.row(3) == "three", 3), "the display still refreshes after Esc")
    s.send("f")                                 # a plain key, not read as Alt-F
    expect("follow" in s.bottom().lower(), s.bottom())
    expect(not s.exited(0.3), "still running")


@test
def exit_keys(env):
    big(env)
    for name, key in (("F10", F10), ("Alt-X", alt("x")), ("Ctrl-C", "\x03"), ("q", "q"), ("x", "x")):
        s = env.start("big.txt")
        s.send(key)
        expect(s.exited(1.5), name + " quits")


@test
def alt_and_function_keys(env):
    big(env)
    s = env.start("big.txt")
    s.send(alt("h"))
    expect(s.row(1).startswith("000000"), "Alt-H")
    s.send(alt("h"))
    s.send(F1)
    expect("FUNCTION KEYS" in s.text(), "F1")
    s.send("x")
    s.send("x")
    s.send("\x1b[11~")                          # F1 in the other common encoding
    expect("FUNCTION KEYS" in s.text(), "F1 (CSI form)")
    s.send("x")
    s.send("x")
    s.send(PGDN)
    eq(s.first_line_no(), 24, "PgDn")
    s.send(PGUP)
    eq(s.first_line_no(), 1, "PgUp")


@test
def key_bursts_are_not_lost(env):
    big(env)
    s = env.start("big.txt")
    s.send(DOWN * 300, 1.2)                     # 900 bytes in one write
    eq(s.first_line_no(), 278, "300 Down presses")
    s.send("#290\r")
    s.send(UP * 100, 1.2)
    eq(s.first_line_no(), 178, "100 Up presses")


@test
def typed_utf8_in_command_line(env):
    big(env)
    s = env.start("big.txt")
    s.send("\r")
    s.send("café")
    expect("café" in s.bottom(), s.bottom())


# ---------------------------------------------------------------- persistence
@test
def history_recall_and_persist(env):
    big(env)
    s = env.start("big.txt")
    s.send("\r")
    s.send("goto 77\r")
    s.send("\r")
    s.send("/tail\r")
    s.send("q")
    expect(s.exited(), "quit")
    hist = open(os.path.join(env.config_dir(), "history.txt")).read().split("\n")
    expect("goto 77" in hist and "/tail" in hist, repr(hist))
    s2 = env.start("big.txt")
    s2.send("\r")
    s2.send(UP)
    expect("/tail" in s2.bottom(), s2.bottom())
    s2.send(UP)
    expect("goto 77" in s2.bottom(), s2.bottom())
    s2.send(DOWN)
    expect("/tail" in s2.bottom(), s2.bottom())
    s3 = env.start("big.txt")
    s3.send("\r")
    s3.send("g")                                # prefix filter: only entries starting with "g"
    s3.send(UP)
    expect("goto 77" in s3.bottom(), s3.bottom())


@test
def remembered_position(env):
    big(env)
    s = env.start("big.txt")
    s.send("#150\r")
    s.send("q")
    expect(s.exited(), "quit")
    s2 = env.start("big.txt")
    eq(s2.first_line_no(), 150, "reopened where we left off")
    s2.send("\r")
    s2.send("remember\r")                       # turn it off and check the toggle message
    expect("off" in s2.bottom().lower(), s2.bottom())


@test
def binary_file_opens_in_hex(env):
    env.write("n.bin", b"AB\x00CD\r\nplain\n")
    s = env.start("n.bin")
    expect(s.row(1).startswith("000000   41 42 00 43 44 0D 0A"), s.row(1))
    expect("binary" in s.bottom().lower(), s.bottom())
    s.send(alt("h"))
    expect(s.row(1).startswith("AB"), "Alt-H goes to text mode")


# ---------------------------------------------------------------- windows, blocks, menu
@test
def split_windows(env):
    big(env)
    s = env.start("big.txt")
    s.send(alt("w"))
    expect(s.row(0).startswith("LIST") and s.row(12).startswith("LIST"), "two status lines")
    s.send("q")
    expect(s.row(12) == "" or not s.row(12).startswith("LIST"), "Q closes one window")
    expect(not s.exited(0.3), "program keeps running")


@test
def copy_marked_block(env):
    path, lines = big(env)
    s = env.start("big.txt")
    s.send(alt("m"))                            # mark the top line
    s.send(PGDN)
    s.send(alt("b"))                            # mark the bottom line of the next page
    s.send(alt("d"))
    s.send("blk.out\r")
    expect("copied" in s.bottom(), s.bottom())
    eq(open(env.path("blk.out")).read(), "".join(lines[:46]), "block contents")
    s.send(alt("d"))
    s.send("blk.out\r")
    expect("exists" in s.bottom(), "refuses to overwrite: " + s.bottom())
    s.send(alt("o"))
    s.send("blk.out\r")
    expect("appended" in s.bottom(), s.bottom())
    eq(len(open(env.path("blk.out")).read()), 2 * len("".join(lines[:46])), "append doubles the file")


@test
def file_menu(env):
    big(env)
    env.write("zzz.txt", "last\n")
    s = env.start()
    expect("Select file" in s.text() and "big.txt" in s.text(), s.text())
    s.send("b")                                  # type-ahead jump to the first name starting with b
    s.send("\r")
    expect("big.txt" in s.top(), s.top())


@test
def open_command_and_wildcards(env):
    big(env)
    env.write("a1.txt", "alpha\n")
    env.write("a2.txt", "beta\n")
    s = env.start("big.txt")
    s.send("\r")
    s.send("open a*.txt\r")
    expect("a1.txt" in s.top() and s.row(1).startswith("alpha"), s.text())
    s.send("q")                                  # next file in the list
    expect("a2.txt" in s.top() and s.row(1).startswith("beta"), s.text())
    s.send("1")                                  # back to the first
    expect("a1.txt" in s.top(), s.top())


# ---------------------------------------------------------------- command-line behaviour
@test
def cat_mode_and_options(env):
    path, _ = big(env)
    content = open(path, "rb").read()
    r = subprocess.run([BIN, path], capture_output=True)
    eq(r.stdout, content, "output redirected: the file is copied through")
    r = subprocess.run("echo piped | " + BIN + " | cat", shell=True, capture_output=True)
    eq(r.stdout, b"piped\n", "stdin piped through to a non-terminal")
    r = subprocess.run([BIN, "-s", "-X", path], capture_output=True)
    eq(r.stdout, content, "unknown options are ignored")
    r = subprocess.run([BIN, "--version"], capture_output=True, text=True)
    expect(r.stdout.startswith("list "), r.stdout)
    r = subprocess.run([BIN, "--help"], capture_output=True, text=True)
    expect("usage" in r.stdout.lower(), r.stdout)
    r = subprocess.run([BIN, "-m", "bogus", path], capture_output=True, text=True)
    expect(r.returncode != 0, "bad --mem size is an error")


# ---------------------------------------------------------------- ANSI / overstrike formatting
def cell(s, y, x):
    return s.screen.buffer[y][x]


@test
def ansi_sequences_are_interpreted(env):
    env.write("a.txt", "plain \x1b[1mbold\x1b[0m \x1b[4mul\x1b[24m \x1b[31mred\x1b[0m \x1b[7mrv\x1b[0m "
              "\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\ \x1b[38;5;82mgn\x1b[0m\x1b[2K\n")
    s = env.start("a.txt")
    s.pump()
    line = s.row(1)
    eq(line, "plain bold ul red rv link gn", "escape sequences are not displayed")
    base = cell(s, 1, 0)
    bold, ul, red, rv, gn = cell(s, 1, 6), cell(s, 1, 11), cell(s, 1, 14), cell(s, 1, 18), cell(s, 1, 26)
    expect(bold.fg != base.fg, "bold looks different")
    expect(ul.fg != base.fg and ul.fg != bold.fg, "underline looks different from bold")
    eq(red.fg, "red", "red")
    eq(rv.fg, base.bg, "reverse swaps colours")
    eq(gn.fg, "brightgreen", "256-colour mapped to the 16-colour palette")
    eq(cell(s, 1, 5).fg, base.fg, "reset ends the style")


@test
def ansi_toggle(env):
    env.write("a.txt", "x \x1b[1mbold\x1b[0m\n")
    s = env.start("a.txt")
    s.pump()
    eq(s.row(1), "x bold")
    s.send(alt("q"))
    expect("[1mbold" in s.row(1), "raw escapes shown: " + s.row(1))
    s.send(alt("q"))
    eq(s.row(1), "x bold")


@test
def markdown_rendering(env):
    src = ("# Title\n- item **bold** and *it*\n1. `code` [site](http://x.y) \\*lit\\*\n> quote\n"
           "snake_case_name 2 * 3 * 4\n---\n")
    env.write("d.md", src)
    env.write("d.txt", src)
    s = env.start("d.md")
    s.pump()
    eq(s.row(1), "Title")
    eq(s.row(2), "\u2022 item bold and it")
    eq(s.row(3), "1. code site *lit*")
    eq(s.row(4), "quote")
    eq(s.row(5), "snake_case_name 2 * 3 * 4", "no false emphasis")
    expect(set(s.row(6)) == {"\u2500"}, "rule drawn: " + s.row(6))
    base = cell(s, 5, 0)
    expect(cell(s, 1, 0).fg != base.fg, "heading coloured")
    expect(cell(s, 2, 7).fg not in (base.fg,), "bold coloured")
    expect(cell(s, 3, 3).bg != base.bg, "code has its own background")
    s.send(":md\r")
    expect(s.row(1) == "# Title", "raw when off: " + s.row(1))
    s.close()
    s = env.start("d.txt")
    s.pump()
    eq(s.row(1), "# Title", "only .md files are formatted")


@test
def backspace_overstrike(env):
    env.write("m.txt", "N\bNA\bAM\bME\bE  _\bu_\bn_\bd x\n")
    s = env.start("m.txt")
    s.pump()
    eq(s.row(1), "NAME  und x")
    base = cell(s, 1, 10)
    expect(cell(s, 1, 0).fg != base.fg, "doubled characters are bold")
    expect(cell(s, 1, 6).fg != base.fg, "_ backspace char is underlined")
    eq(cell(s, 1, 10).fg, base.fg, "plain text unaffected")


# ---------------------------------------------------------------- runner
def main(argv):
    pattern = None
    verbose = "-v" in argv
    if "-k" in argv:
        pattern = argv[argv.index("-k") + 1]
    if "--list" in argv:
        print("\n".join(t.__name__ for t in TESTS))
        return 0
    if not (os.path.isfile(BIN) and os.access(BIN, os.X_OK)):
        print("binary not found: %s (build it, or set LIST_BIN)" % BIN)
        return 2
    selected = [t for t in TESTS if pattern is None or pattern in t.__name__]
    print("testing %s (%d tests)" % (BIN, len(selected)))
    failed = []
    t0 = time.time()
    for t in selected:
        env = Env(BIN)
        start = time.time()
        try:
            t(env)
            status = "ok"
        except Exception as e:  # noqa: BLE001
            status = "FAIL"
            failed.append((t.__name__, e, traceback.format_exc() if verbose else ""))
        finally:
            env.cleanup()
        print("  %-4s %-40s %.1fs" % (status, t.__name__, time.time() - start))
    print()
    for name, err, tb in failed:
        print("FAILED %s: %s" % (name, err))
        if tb:
            print(tb)
    print("%d passed, %d failed in %.0fs" % (len(selected) - len(failed), len(failed), time.time() - t0))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
