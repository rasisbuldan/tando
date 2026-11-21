package logs

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
	"tando/srv/internal/valid"
	"tando/srv/logs/lines"
)

// The audit trail: /var/log/tando/audit.log (root:adm 0640), one line per agent verb that
// changes something or reveals a secret, appended under flock, written when the verb exits:
//
//	<epoch> TAB <who> TAB <from> TAB <verb> TAB <app or -> TAB <result> TAB <note>
//
// Rotated by the writer beyond auditMax to audit.log.1 .. .4.
const (
	auditMax  = 4 << 20
	auditLock = 10 * time.Second
)

var (
	reVerb = regexp.MustCompile(`^[a-z][a-z0-9-]{0,30}$`)
	reWho  = regexp.MustCompile(`^[A-Za-z0-9_.@-]{1,64}$`)
	reAddr = regexp.MustCompile(`^[0-9A-Fa-f.:]{1,45}$`)
	reRC   = regexp.MustCompile(`^[0-9]{1,10}$`)
)

// Origin is who asked and from where: the sudo user and the ssh client address of the calling
// session (found in the environment of an ancestor process); internal runs (timers, boot) are
// "system" from "local", or the requester the agent passes to an activation (TANDO_AUDIT_WHO,
// TANDO_AUDIT_FROM). A request from the tando dashboard says so: its client puts TANDO_FROM=dashboard
// in front of `sudo` in the ssh command, so it is in the environment of the same ancestor as
// SSH_CONNECTION, and from is "dashboard" instead of the address. Only with sudo (SUDO_USER): a
// deploy key's tando-gate refuses such a command and starts the agent without sudo.
func (l *Logs) Origin() (who, from string) {
	getenv := l.Getenv
	if getenv == nil {
		getenv = func(string) string { return "" }
	}
	who = getenv("SUDO_USER")
	ip := ""
	for p := l.PPID; p > 1; {
		if env, err := os.ReadFile(filepath.Join(l.Env.Proc, strconv.Itoa(p), "environ")); err == nil {
			dash := false
			for e := range bytes.SplitSeq(env, []byte{0}) {
				if v, ok := bytes.CutPrefix(e, []byte("SSH_CONNECTION=")); ok {
					ip, _, _ = strings.Cut(string(v), " ")
				}
				dash = dash || string(e) == "TANDO_FROM=dashboard"
			}
			if ip != "" {
				if dash && who != "" {
					ip = "dashboard"
				}
				break
			}
		}
		// "pid (comm) state ppid ...": comm may hold spaces and parentheses
		stat, err := os.ReadFile(filepath.Join(l.Env.Proc, strconv.Itoa(p), "stat"))
		if err != nil {
			break
		}
		i := bytes.LastIndex(stat, []byte(") "))
		if i < 0 {
			break
		}
		f := strings.Fields(string(stat[i+2:]))
		if len(f) < 2 {
			break
		}
		next, err := strconv.Atoi(f[1])
		if err != nil || next == p {
			break
		}
		p = next
	}
	// an activation runs in its own unit: the agent passes the requester along
	if who == "" && ip == "" {
		who, ip = getenv("TANDO_AUDIT_WHO"), getenv("TANDO_AUDIT_FROM")
		if who == "" {
			who = "system"
		}
		if ip == "" {
			ip = "local"
		}
	}
	if !reWho.MatchString(who) {
		who = "unknown"
	}
	if !reAddr.MatchString(ip) && ip != "local" && ip != "dashboard" {
		ip = "unknown"
	}
	return who, ip
}

// AuditOrigin (audit-origin): "<who> <from>", for the agent's activate.
func (l *Logs) AuditOrigin(w *out.Writer) {
	who, from := l.Origin()
	w.Row(who + " " + from)
}

// AuditWrite (audit-write <verb> <app> <rc|result> [note]).
func (l *Logs) AuditWrite(ctx context.Context, args []string) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	arg := func(i int) string {
		if i < len(args) {
			return args[i]
		}
		return ""
	}
	verb, app, rc := arg(0), arg(1), arg(2)
	if !reVerb.MatchString(verb) {
		return errors.New("bad verb")
	}
	if app == "" || (app != "-" && !valid.App(app)) {
		app = "-"
	}
	res := "unknown"
	switch {
	case rc == "0":
		res = "ok"
	case reRC.MatchString(rc):
		res = "fail(" + rc + ")"
	case rc == "ok" || rc == "failed" || rc == "rolledback" || rc == "started":
		res = rc
	}
	note := auditNote(arg(3))
	who, from := l.Origin()
	t := l.Env.Now().Unix()
	ru, rg := l.root()
	if err := ensureDir(l.P.LogDir, 0o755, ru, rg); err != nil {
		return err
	}
	if err := l.createAudit(); err != nil {
		return err
	}
	f, err := l.lockAudit()
	if err != nil {
		return err
	}
	defer f.Close()
	if fi, err := f.Stat(); err == nil && fi.Size() > auditMax {
		if f, err = l.rotateAudit(f); err != nil {
			return err
		}
	}
	shown := note
	if shown == "" {
		shown = "-"
	}
	line := strings.Join([]string{strconv.FormatInt(t, 10), who, from, verb, app, res, shown}, "\t") + "\n"
	if _, err := f.Write([]byte(line)); err != nil { // one write(2): an append is never torn
		return fmt.Errorf("write %s: %w", l.auditFile(), err)
	}
	// a second copy in the main journal, out of reach of a plain edit of the file
	msg := "who=" + who + " from=" + from + " verb=" + verb + " app=" + app + " result=" + res
	if note != "" {
		msg += " note=" + note
	}
	l.Env.Run.Output(ctx, run.Cmd{Argv: []string{"logger", "-t", "tando-audit", "--", msg}, Timeout: 5 * time.Second})
	return nil
}

// auditNote: tabs and newlines become spaces, other control characters go, at most 300 bytes
// (not cutting a UTF-8 character in two).
func auditNote(s string) string {
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\t' || c == '\n':
			b = append(b, ' ')
		case c < 0x20 || c == 0x7f:
		default:
			b = append(b, c)
		}
	}
	if len(b) > 300 {
		b = b[:300]
		for i := 0; i < 3 && len(b) > 0; i++ {
			if r, _ := utf8.DecodeLastRune(b); r != utf8.RuneError {
				break
			}
			if c := b[len(b)-1]; c < 0x80 {
				break
			}
			b = b[:len(b)-1]
		}
	}
	return string(b)
}

// lockAudit opens audit.log for appending and takes its flock (the shell's exec {fd}>> + flock
// -w 10, the same lock). If the file was rotated while waiting, the new one is locked instead.
func (l *Logs) lockAudit() (*os.File, error) {
	deadline := time.Now().Add(auditLock)
	for {
		f, err := os.OpenFile(l.auditFile(), os.O_WRONLY|os.O_APPEND|syscall.O_NOFOLLOW, 0)
		if err != nil {
			return nil, err
		}
		for {
			err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
			if err == nil || (!errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EINTR)) || time.Now().After(deadline) {
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
		if err != nil {
			f.Close()
			return nil, errors.New("audit log busy")
		}
		cur, err1 := f.Stat()
		now, err2 := os.Lstat(l.auditFile())
		if err1 == nil && err2 == nil && os.SameFile(cur, now) {
			return f, nil
		}
		f.Close() // rotated by the writer before us: lock the new file
		if err2 != nil {
			if err := l.createAudit(); err != nil {
				return nil, err
			}
		}
	}
}

// rotateAudit: audit.log.3 -> .4 ... audit.log -> .1, a new audit.log, locked (still holding the
// old one's lock until the new one is held).
func (l *Logs) rotateAudit(old *os.File) (*os.File, error) {
	p := l.auditFile()
	for i := 3; i >= 1; i-- {
		src := p + "." + strconv.Itoa(i)
		if fsinfo.RegularFollow(src) {
			os.Rename(src, p+"."+strconv.Itoa(i+1))
		}
	}
	if err := os.Rename(p, p+".1"); err != nil {
		return old, nil
	}
	if err := l.createAudit(); err != nil {
		return old, nil
	}
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return old, nil
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return old, nil
	}
	old.Close()
	return f, nil
}

// AuditRead (audit-read [app] [n]): the newest n audit rows (of one app), oldest first, across
// the rotated files.
func (l *Logs) AuditRead(name, count string, w *out.Writer) error {
	if err := l.needRoot(); err != nil {
		return err
	}
	if name != "" && name != "-" && !valid.App(name) {
		return errors.New("invalid app name")
	}
	if count == "" {
		count = "50"
	}
	n, ok := decimal.Parse(count, 5)
	if !ok {
		return errors.New("bad count")
	}
	if n == 0 {
		return nil
	}
	ring := make([][]string, n)
	next, total := 0, 0
	p := l.auditFile()
	for _, s := range []string{".4", ".3", ".2", ".1", ""} {
		f, err := os.Open(p + s)
		if err != nil {
			continue
		}
		fi, err := f.Stat()
		if err != nil || !fi.Mode().IsRegular() {
			f.Close()
			continue
		}
		r := lines.NewReader(f, 64<<10)
		for {
			ln, ok := r.Next()
			if !ok {
				break
			}
			fs := strings.Split(string(ln.Text), "\t")
			if len(fs) < 7 || (name != "" && name != "-" && fs[4] != name) {
				continue
			}
			ring[next] = fs
			next = (next + 1) % int(n)
			total++
		}
		f.Close()
	}
	start := 0
	if total >= int(n) {
		start = next
	}
	for i := 0; i < min(total, int(n)); i++ {
		w.Row(append([]string{"audit"}, ring[(start+i)%int(n)]...)...)
	}
	return nil
}
