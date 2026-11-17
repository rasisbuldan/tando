#!/usr/bin/env python3
"""Drive a full-screen program in a pseudo-terminal for tests (test-only; tando never needs python).

    top-pty.py ROWS COLS SCRIPT -- command args...

SCRIPT is a file of steps, one per line:
    sleep S                 wait S seconds (float), reading output meanwhile
    send TEXT               send TEXT; escapes: \\e \\r \\n \\t \\xNN; "send-raw" sends literally
    wait REGEX [TIMEOUT]    wait until the emulated screen matches REGEX (default 10 s)
    gone REGEX [TIMEOUT]    wait until the screen no longer matches REGEX
    resize ROWS COLS        resize the pty and send SIGWINCH
    signal NAME             send a signal (INT, TERM, ...) to the child
    dump LABEL              print the screen between "=== LABEL" and "=== end"
    check                   fail if any line was written past the right edge so far
    exit [TIMEOUT]          wait for the child to exit (default 10 s)
    # comment

The emulator understands what tando top writes: CSI H/f/J/K/m/?25h/l/?1049h/l, CR, LF, BS and
printable UTF-8. A character written past the last column marks its row; `check` fails when a row of
the frame now on screen is marked (a new frame starts at cursor home). The dashboard never
relies on autowrap. `overflow=N` at the end counts failed checks. On exit it prints the terminal state:
    final: exit=N cursor=visible|hidden altscreen=on|off overflow=N
The tty modes after exit are checked by wrapping the command (e.g. `cmd; stty -a > f`).
Exit status is 0 unless a wait/gone/exit step timed out (then 3).
"""
import os, re, select, signal, struct, sys, termios, fcntl, time, subprocess, codecs


class Screen:
    def __init__(self, rows, cols):
        self.resize(rows, cols)
        self.cursor_visible = True
        self.alt = False
        self.overflow = 0          # failed checks
        self.overflow_lines = []
        self.ovf = {}              # row -> text, for rows of the current frame written past the edge
        self.dec = codecs.getincrementaldecoder("utf-8")("replace")
        self.pending = ""

    def resize(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0

    def text(self):
        return "\n".join("".join(l).rstrip() for l in self.grid)

    def put(self, ch):
        if self.c >= self.cols:
            self.ovf[self.r] = "".join(self.grid[self.r])
            return
        self.grid[self.r][self.c] = ch
        self.c += 1

    def lf(self):
        if self.r < self.rows - 1:
            self.r += 1
        else:
            self.grid.pop(0)
            self.grid.append([" "] * self.cols)

    def feed(self, data):
        s = self.pending + self.dec.decode(data)
        self.pending = ""
        i, n = 0, len(s)
        while i < n:
            ch = s[i]
            if ch == "\x1b":
                if i + 1 >= n:
                    self.pending = s[i:]
                    return
                if s[i + 1] == "[":
                    m = re.match(r"\x1b\[([0-9;?]*)([ -/]*)([@-~])", s[i:])
                    if not m:
                        if n - i < 32:
                            self.pending = s[i:]
                            return
                        i += 2
                        continue
                    self.csi(m.group(1), m.group(3))
                    i += m.end()
                    continue
                if s[i + 1] == "]":  # OSC: skip to BEL or ST
                    j = s.find("\x07", i)
                    k = s.find("\x1b\\", i)
                    ends = [x for x in (j, k) if x >= 0]
                    if not ends:
                        self.pending = s[i:]
                        return
                    e = min(ends)
                    i = e + (1 if e == j else 2)
                    continue
                i += 2
                continue
            if ch == "\r":
                self.c = 0
            elif ch == "\n":
                self.lf()
            elif ch == "\b":
                self.c = max(0, self.c - 1)
            elif ch == "\x07" or ord(ch) < 32:
                pass
            else:
                self.put(ch)
            i += 1

    def csi(self, p, f):
        args = [int(x) if x.isdigit() else 0 for x in p.lstrip("?").split(";")] if p else []
        if f in "Hf":
            if not args or args == [1, 1]:
                self.ovf = {}      # cursor home: a new frame starts
            r = (args[0] if args and args[0] else 1) - 1
            c = (args[1] if len(args) > 1 and args[1] else 1) - 1
            self.r, self.c = min(r, self.rows - 1), min(c, self.cols - 1)
        elif f == "J":
            a = args[0] if args else 0
            if a == 0:
                self.grid[self.r][self.c:] = [" "] * (self.cols - self.c)
                for k in range(self.r + 1, self.rows):
                    self.grid[k] = [" "] * self.cols
            elif a in (2, 3):
                self.grid = [[" "] * self.cols for _ in range(self.rows)]
                self.ovf = {}
        elif f == "K":
            a = args[0] if args else 0
            c = min(self.c, self.cols)
            if a == 0:
                self.grid[self.r][c:] = [" "] * (self.cols - c)
            elif a == 2:
                self.grid[self.r] = [" "] * self.cols
        elif f == "A":
            self.r = max(0, self.r - (args[0] if args and args[0] else 1))
        elif f in "hl" and p.startswith("?"):
            on = f == "h"
            for a in args:
                if a == 25:
                    self.cursor_visible = on
                elif a in (1049, 47, 1047):
                    if self.alt != on:
                        self.grid = [[" "] * self.cols for _ in range(self.rows)]
                    self.alt = on


def unescape(t):
    return codecs.decode(t.replace("\\e", "\\x1b"), "unicode_escape").encode("latin-1")


def main():
    rows, cols, script = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    cmd = sys.argv[sys.argv.index("--") + 1:]
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    attrs = termios.tcgetattr(slave)
    attrs[3] |= termios.ICANON | termios.ECHO | termios.ISIG
    termios.tcsetattr(slave, termios.TCSANOW, attrs)
    env = dict(os.environ, TERM=os.environ.get("TOP_TERM", "xterm-256color"), COLUMNS="", LINES="")
    env.pop("COLUMNS"); env.pop("LINES")
    def child_setup():
        # a terminal program starts with SIGINT and SIGQUIT at their defaults; a suite started in the
        # background (test/all.sh) would otherwise pass "ignored" on, and bash cannot trap a signal
        # that was ignored when it started, so Ctrl-C would do nothing
        signal.signal(signal.SIGINT, signal.SIG_DFL)
        signal.signal(signal.SIGQUIT, signal.SIG_DFL)
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, env=env,
                         preexec_fn=child_setup)
    scr = Screen(rows, cols)
    raw = open(os.environ.get("TOP_RAW", os.devnull), "wb")
    failed = False

    def pump(t):
        end = time.time() + t
        while True:
            left = end - time.time()
            if left <= 0:
                return
            r, _, _ = select.select([master], [], [], min(left, 0.05))
            if r:
                try:
                    d = os.read(master, 65536)
                except OSError:
                    d = b""
                if not d:
                    time.sleep(min(left, 0.05))
                    continue
                raw.write(d)
                scr.feed(d)

    for line in open(script):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cmdw, _, rest = line.strip().partition(" ")
        if cmdw == "sleep":
            pump(float(rest))
        elif cmdw in ("send", "send-raw"):
            try:
                os.write(master, unescape(rest) if cmdw == "send" else rest.encode())
            except OSError:   # the program already exited: say so and show its last screen
                pump(0.2)
                print("GONE before %s %s (exit=%s)" % (cmdw, rest, p.poll()))
                print(scr.text())
                failed = True
                continue
            pump(0.05)
        elif cmdw in ("wait", "gone"):
            m = re.match(r"(.*?)(?:\s+(\d+(?:\.\d+)?))?$", rest)
            rx, to = re.compile(m.group(1)), float(m.group(2) or 10)
            end = time.time() + to
            while time.time() < end:
                hit = bool(rx.search(scr.text()))
                if hit == (cmdw == "wait"):
                    break
                pump(0.1)
            else:
                print("TIMEOUT %s %s" % (cmdw, m.group(1)))
                print(scr.text())
                failed = True
                break
        elif cmdw == "resize":
            r, c = map(int, rest.split())
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", r, c, 0, 0))
            scr.resize(r, c)
            try:
                os.killpg(p.pid, signal.SIGWINCH)
            except OSError:
                pass
            pump(0.1)
        elif cmdw == "signal":
            p.send_signal(getattr(signal, "SIG" + rest.strip()))
            pump(0.1)
        elif cmdw == "dump":
            print("=== " + rest)
            print(scr.text())
            print("=== end")
        elif cmdw == "check":
            # rows of the frame now on screen that were written past the right edge
            if scr.ovf:
                scr.overflow += 1
                print("OVERFLOW rows %s" % sorted(scr.ovf))
                for r in sorted(scr.ovf)[:3]:
                    print("  " + scr.ovf[r].rstrip())
        elif cmdw == "exit":
            to = float(rest or 10)
            end = time.time() + to
            while p.poll() is None and time.time() < end:
                pump(0.1)
            if p.poll() is None:
                print("TIMEOUT exit")
                failed = True
                p.kill()
        else:
            print("bad step: " + line)
            failed = True
    if p.poll() is None:
        p.kill()
        p.wait()
    pump(0.1)
    import resource
    ru = resource.getrusage(resource.RUSAGE_CHILDREN)
    print("rusage: user=%.3f sys=%.3f" % (ru.ru_utime, ru.ru_stime))
    print("final: exit=%s cursor=%s altscreen=%s overflow=%d" % (
        p.returncode, "visible" if scr.cursor_visible else "hidden", "on" if scr.alt else "off",
        scr.overflow))
    sys.exit(3 if failed else 0)


if __name__ == "__main__":
    main()
