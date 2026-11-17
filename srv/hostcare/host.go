// Package hostcare looks after the server itself: it collects facts about the host cheaply and
// safely (files first, a few programs with constant options), judges them into findings (each
// with a state, a one-line detail and the command that fixes it), writes a summary that the
// alert checks read, and, only where the owner turned it on, does the routine maintenance:
// security updates through Ubuntu's own unattended-upgrades, and a reboot in a maintenance
// window with checks before and after. docs/HOSTCARE.md is the owner's view; srv/README.md
// ("hostcare") the layout.
//
// Layer: domain. It imports internal/* only.
package hostcare

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/lock"
	"tando/srv/internal/out"
)

// Host is one server. Every input is explicit: tests build one over a temp tree with a fixed
// clock and a fake runner.
type Host struct {
	Env env.Env
	// FS is prepended to the system paths (/etc, /run, /var, /boot, /home, /root): "" on a
	// server, a temp directory in tests. Env.Root, Env.Lib and Env.Proc are used as they are.
	FS       string
	Loc      *time.Location // the server's time zone (log files carry local times)
	SudoUser string         // who ran it (the admin), for the audit line
	Stderr   io.Writer
	// replaceable for tests
	Statfs   func(path string) (fsinfo.FS, error)
	Adjtimex func() (synced, known bool)
	Sleep    func(time.Duration)
	Probe    Prober
}

// New is the real machine.
func New(e env.Env) *Host {
	return &Host{Env: e, Loc: time.Local, Stderr: os.Stderr, Statfs: fsinfo.Statfs, Adjtimex: adjtimex,
		Sleep: time.Sleep, Probe: httpProber{header: filepath.Join(e.Root, "probe.header")}}
}

// p is a system path under FS.
func (h *Host) p(path string) string {
	if h.FS == "" {
		return path
	}
	return filepath.Join(h.FS, path)
}

func (h *Host) dir() string       { return filepath.Join(h.Env.Lib, "hostcare") }
func (h *Host) confPath() string  { return filepath.Join(h.Env.Root, "hostcare.conf") }
func (h *Host) statePath() string { return filepath.Join(h.dir(), "state") }
func (h *Host) aptPath() string   { return filepath.Join(h.dir(), "apt.json") }

// SummaryPath is the file the alert checks read (docs/HOSTCARE.md "Summary file").
func (h *Host) SummaryPath() string { return filepath.Join(h.dir(), "summary") }
func (h *Host) rebootPath() string  { return filepath.Join(h.dir(), "reboot") }
func (h *Host) bin(n string) string { return filepath.Join(h.Env.Root, "bin", n) }
func (h *Host) now() int64          { return h.Env.Now().Unix() }

func (h *Host) needRoot() error {
	if h.Env.EUID != 0 {
		return errors.New("this needs root (sudo)")
	}
	return nil
}

// mkdir makes the state directory, root 700 (it holds what the server's ports and logins look
// like: not for every user).
func (h *Host) mkdir() error {
	if err := os.MkdirAll(h.dir(), 0o700); err != nil {
		return err
	}
	return os.Chmod(h.dir(), 0o700)
}

// lock serialises the verbs that write (check, set, care, update, reboot).
func (h *Host) lock() (*lock.Lock, error) {
	if err := h.mkdir(); err != nil {
		return nil, err
	}
	l, err := lock.Acquire(filepath.Join(h.dir(), "lock"), 60*time.Second)
	if errors.Is(err, lock.ErrBusy) {
		return nil, errors.New("another tando-host run is busy (an update or a check); try again in a minute")
	}
	return l, err
}

// readFile reads at most max bytes of a regular file without following a FIFO into a hang
// (O_NONBLOCK, then fstat). Missing or unreadable: nil.
func readFile(path string, max int64) []byte {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() {
		return nil
	}
	b, _ := io.ReadAll(io.LimitReader(f, max))
	return b
}

// readTail reads the last max bytes of a regular file (a log), from the start of a line.
func readTail(path string, max int64) []byte {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return nil
	}
	off := int64(0)
	if fi.Size() > max {
		off = fi.Size() - max
	}
	b := make([]byte, fi.Size()-off)
	n, _ := f.ReadAt(b, off)
	b = b[:n]
	if off > 0 {
		for i, c := range b {
			if c == '\n' {
				return b[i+1:]
			}
		}
		return nil
	}
	return b
}

// mtime of a path (0: missing).
func mtime(path string) int64 {
	fi, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return fi.ModTime().Unix()
}

// cleanRule: text from the host (package, unit and process names, log lines) as one safe field:
// controls become "?", bidi overrides go, invalid UTF-8 becomes U+FFFD (notifiers need valid
// UTF-8), cut to max characters.
func clean(s string, max int) string {
	return out.Cleaner{Ctrl: '?', LoneC1: true, ValidUTF8: true, MaxRunes: max}.Clean(s)
}

func errf(format string, a ...any) error { return fmt.Errorf(format, a...) }
