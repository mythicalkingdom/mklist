"""A small pty-based test harness for the `list` file browser.

It starts the program on a pseudo-terminal, feeds it keys, and reads the screen back through a
terminal emulator (pyte), so tests can assert on what a user would actually see.
Works with any implementation of `list` (set LIST_BIN).
"""
import fcntl
import os
import pty
import select
import shutil
import signal
import struct
import tempfile
import termios
import time

try:
    import pyte
except ImportError:  # pragma: no cover
    raise SystemExit("These tests need the 'pyte' package:  pip install pyte")

ROWS, COLS = 25, 80


class Screen(pyte.Screen):
    """pyte chokes on a few private escape sequences that some Video/terminfo drivers emit."""

    def set_margins(self, *a, **kw):
        kw.pop("private", None)
        return super().set_margins(*a, **kw)

    def report_device_attributes(self, *a, **kw):
        pass

    def report_device_status(self, *a, **kw):
        pass


class Session:
    def __init__(self, binary, args, cwd, home, stdin_pipe=False, rows=ROWS, cols=COLS, env=None):
        self.rows, self.cols = rows, cols
        self.pipe_w = None
        r = w = None
        if stdin_pipe:
            r, w = os.pipe()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:                       # child
            os.chdir(cwd)
            if stdin_pipe:
                os.dup2(r, 0)
                os.close(w)
            os.environ.update({"TERM": "xterm-256color", "LANG": "en_US.UTF-8", "HOME": home})
            os.environ.pop("XDG_CONFIG_HOME", None)
            if env:
                os.environ.update(env)
            os.execv(binary, [binary] + list(args))
        if stdin_pipe:
            os.close(r)
            self.pipe_w = w
        self._resize(rows, cols)
        self.screen = Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.status = None
        self.pump(0.6)

    # ---- terminal plumbing
    def _resize(self, rows, cols):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def resize(self, rows, cols):
        self._resize(rows, cols)
        os.kill(self.pid, signal.SIGWINCH)
        self.screen.resize(rows, cols)
        self.rows, self.cols = rows, cols
        self.pump(0.8)

    def pump(self, t=0.2):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.02)
            if r:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    return
                if not data:
                    return
                self.stream.feed(data)

    def send(self, keys, wait=0.25):
        """Send keys (str) and let the program react."""
        os.write(self.fd, keys.encode() if isinstance(keys, str) else keys)
        self.pump(wait)

    def type_chunks(self, keys, chunk=60, wait=0.05):
        """Send a long key sequence in pieces (a pty's input buffer is only ~4 KB)."""
        for i in range(0, len(keys), chunk):
            self.send(keys[i:i + chunk], wait)

    def feed(self, data, wait=0.4):
        """Write to the program's standard input (needs stdin_pipe=True)."""
        os.write(self.pipe_w, data)
        self.pump(wait)

    def close_stdin(self, wait=0.6):
        os.close(self.pipe_w)
        self.pipe_w = None
        self.pump(wait)

    def until(self, pred, timeout=4.0):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.05)
            if pred():
                return True
        return pred()

    # ---- reading the screen
    def row(self, y):
        return "".join(self.screen.buffer[y][x].data for x in range(self.cols)).rstrip()

    def rows_text(self):
        return [self.row(y) for y in range(self.rows)]

    def text(self):
        return "\n".join(self.rows_text())

    def top(self):
        return self.row(0)

    def bottom(self):
        return self.row(self.rows - 1)

    def first_line_no(self):
        """The first number on the top status line (current line / row number)."""
        parts = self.top().split()
        return int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None

    def highlighted(self, y):
        """Characters on row y drawn with a background different from the row's fill colour."""
        bg = self.screen.buffer[y][self.cols - 1].bg
        return "".join(c.data for c in (self.screen.buffer[y][x] for x in range(self.cols)) if c.bg != bg)

    # ---- process state
    def exited(self, timeout=2.0):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.05)
            try:
                pid, _ = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                return True
            if pid:
                self.pid = None
                return True
        return False

    def close(self):
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            self.pid = None
        if self.pipe_w is not None:
            try:
                os.close(self.pipe_w)
            except OSError:
                pass
        try:
            os.close(self.fd)
        except OSError:
            pass


class Env:
    """A throw-away working directory and HOME for one test."""

    def __init__(self, binary):
        self.binary = binary
        self.root = tempfile.mkdtemp(prefix="listtest-")
        self.data = os.path.join(self.root, "data")
        self.home = os.path.join(self.root, "home")
        os.makedirs(self.data)
        os.makedirs(self.home)
        self.sessions = []

    def path(self, name):
        return os.path.join(self.data, name)

    def write(self, name, content):
        mode = "wb" if isinstance(content, bytes) else "w"
        with open(self.path(name), mode) as f:
            f.write(content)
        return self.path(name)

    def start(self, *args, **kw):
        s = Session(self.binary, args, kw.pop("cwd", self.data), self.home, **kw)
        self.sessions.append(s)
        return s

    def config_dir(self):
        return os.path.join(self.home, ".config", "list")

    def cleanup(self):
        for s in self.sessions:
            s.close()
        shutil.rmtree(self.root, ignore_errors=True)
