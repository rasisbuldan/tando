package watch

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/lock"
	"tando/srv/internal/out"
	"tando/srv/internal/valid"
)

const confHeader = "# tando alerts settings: tando alerts set key=value (see docs/MONITORING.md)\n"

// lockBusy takes the run's lock for a verb that changes the state ("busy" after 30 s).
func (w Watch) lockBusy() (*heldLock, error) {
	l, err := w.takeLock(30 * time.Second)
	if errors.Is(err, lock.ErrBusy) {
		return nil, errf("busy")
	}
	return l, err
}

// stdinLines reads key=value lines as `while IFS= read -r` does (a last line without a newline
// is not read).
func stdinLines(r io.Reader) ([]string, error) {
	b, err := io.ReadAll(io.LimitReader(r, 1<<20))
	if err != nil {
		return nil, err
	}
	return bashread.Lines(b), nil
}

func hasCtl(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f {
			return true
		}
	}
	return false
}

var (
	nameRe   = regexp.MustCompile(`^[A-Za-z0-9._-]{0,40}$`)
	setNumRe = regexp.MustCompile(`^[0-9]{0,6}$`)
)

// Forget is the verb `forget <app>`: drop the app's alert state now (tando-agent destroy); a run
// would only do it a minute later, possibly after notifying about the app it can no longer find.
func (w Watch) Forget(o *out.Writer, args []string) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	if len(args) == 0 || !valid.App(args[0]) {
		return errf("bad app name")
	}
	a := args[0]
	l, err := w.lockBusy()
	if err != nil {
		return err
	}
	defer l.Release()
	st := newStore(loadQuiet(w.statePath()))
	for _, f := range []string{filepath.Join(w.Dir, "probe", a), filepath.Join(w.Dir, "incidents", a+".tsv"), filepath.Join(w.Dir, "tail", a)} {
		os.Remove(f)
	}
	for _, k := range st.keys() {
		if strings.HasPrefix(k, a+".") {
			st.del(k)
		}
	}
	if st.dirty {
		if err := st.save(w.statePath()); err != nil {
			return err
		}
	}
	if m, err := kvfile.Load(w.vstatePath()); err == nil {
		vs := newStore(m)
		for _, k := range vs.keys() {
			if _, rest, ok := strings.Cut(k, "."); ok && rest == a {
				vs.del(k)
			}
		}
		if vs.dirty {
			vs.save(w.vstatePath())
		}
	}
	o.KV("ok", "1")
	return nil
}

// Set is the verb `set`: key=value lines on stdin; "<app>.<key>" for one app; "<check>=off"
// turns a check off; "key=" goes back to the default.
func (w Watch) Set(o *out.Writer, stdin io.Reader) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	l, err := w.lockBusy()
	if err != nil {
		return err
	}
	defer l.Release()
	f := loadQuiet(w.Conf)
	in, err := stdinLines(stdin)
	if err != nil {
		return err
	}
	for _, kv := range in {
		if kv == "" {
			continue
		}
		k, v, isKV := strings.Cut(kv, "=")
		if !isKV {
			return errf("expected key=value: %s", kv)
		}
		if hasCtl(v) {
			return errf("control characters in %s", k)
		}
		base, app := k, ""
		if i := strings.LastIndexByte(k, '.'); i >= 0 {
			base, app = k[i+1:], k[:i]
		}
		if strings.Contains(k, ".") && !valid.App(app) {
			return errf("bad app name in %s", k)
		}
		_, isSetting := defaultOf(base)
		switch {
		case (slices.Contains(appChecks, base) || slices.Contains(hostChecks, base)) && !isSetting:
			if v != "on" && v != "off" && v != "" {
				return errf("%s must be on or off", k)
			}
			// (disk is an app check too: hog.disk=off turns off only hog's; the shell refused it)
			if app != "" && !slices.Contains(appChecks, base) {
				return errf("%s is a host check: set it without an app", base)
			}
		case isSetting:
			switch base {
			case "name":
				if app != "" || !nameRe.MatchString(v) {
					return errf("bad name")
				}
			case "notify_reboot":
				if app != "" || (v != "yes" && v != "no" && v != "") {
					return errf("notify_reboot must be yes or no")
				}
			case "include_log_lines":
				if app != "" || (v != "on" && v != "off" && v != "") {
					return errf("include_log_lines must be on or off")
				}
			default:
				if !setNumRe.MatchString(v) {
					return errf("%s must be a whole number", k)
				}
				if v != "" {
					v = decimal.Itoa(num(v, 0)) // "08" is 8
				}
			}
		default:
			return errf("unknown setting: %s (see tando alerts set)", k)
		}
		if v == "" {
			delete(f, k)
		} else {
			f[k] = v
		}
	}
	ls := make([]string, 0, len(f))
	for k, v := range f {
		ls = append(ls, k+"="+v)
	}
	sort.Strings(ls) // (sort(1) of the lines, as the shell wrote them)
	data := confHeader
	for _, x := range ls {
		data += x + "\n"
	}
	if err := atomicfile.Write(w.Conf, []byte(data), atomicfile.Mode(0o644)); err != nil {
		return err
	}
	o.KV("ok", "1")
	return nil
}

var (
	notifierNameRe = regexp.MustCompile(`^[a-z][a-z0-9-]{0,19}$`)
	urlRe          = regexp.MustCompile(`^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]]*)?$`)
	tokenRe        = regexp.MustCompile(`^[A-Za-z0-9:_.-]{4,200}$`)
	chatRe         = regexp.MustCompile(`^(-?[0-9]{1,20}|@[A-Za-z0-9_]{4,40})$`)
	addrRe         = regexp.MustCompile(`^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$`)
	heartbeatRe    = regexp.MustCompile(`^url=https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]"\\]*)?$`)
)

// NotifierAdd is the verb `notifier-add <name> <type>`: the fields as key=value lines on stdin
// (secrets: never in argv), stored in $SEC/notify-<name> (root 600 in a root 700 directory).
func (w Watch) NotifierAdd(o *out.Writer, args []string, stdin io.Reader) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	name, typ := arg(args, 0), arg(args, 1)
	if !notifierNameRe.MatchString(name) {
		return errf("bad notifier name (a-z, 0-9, -; up to 20)")
	}
	n := map[string]string{"type": typ}
	in, err := stdinLines(stdin)
	if err != nil {
		return err
	}
	for _, kv := range in {
		if kv == "" {
			continue
		}
		k, v, _ := strings.Cut(kv, "=")
		if hasCtl(v) || strings.ContainsAny(v, `"\ `) {
			return errf("bad characters in %s", k)
		}
		switch k {
		case "url", "api":
			if !urlRe.MatchString(v) {
				return errf("%s must be an http(s) URL", k)
			}
		case "token":
			if !tokenRe.MatchString(v) {
				return errf("bad token")
			}
		case "chat":
			if !chatRe.MatchString(v) {
				return errf("bad chat id")
			}
		case "to", "from":
			if !addrRe.MatchString(v) {
				return errf("bad address in %s", k)
			}
		default:
			return errf("unknown field: %s", k)
		}
		n[k] = v
	}
	switch typ {
	case "webhook", "slack":
		if n["url"] == "" {
			return errf("%s needs url", typ)
		}
	case "ntfy":
		if n["url"] == "" {
			return errf("ntfy needs url (https://ntfy.sh/<topic>)")
		}
	case "telegram":
		if n["token"] == "" || n["chat"] == "" {
			return errf("telegram needs token and chat")
		}
	case "email":
		if n["to"] == "" {
			return errf("email needs to")
		}
		if which("sendmail") == "" && !isExec("/usr/sbin/sendmail") {
			return errf("no sendmail on this host: install and configure an MTA first")
		}
	default:
		return errf("type must be webhook, slack, telegram, ntfy or email")
	}
	for _, d := range []string{w.Sec, filepath.Join(w.Dir, "out"), filepath.Join(w.Dir, "inbox")} {
		mkdir700(d)
	}
	l, err := w.lockBusy()
	if err != nil {
		return err
	}
	defer l.Release()
	if _, err := kvfile.Save(filepath.Join(w.Sec, "notify-"+name), n, atomicfile.Mode(0o600)); err != nil {
		return errf("could not save")
	}
	st := newStore(loadQuiet(w.statePath()))
	for _, k := range st.keys() {
		if strings.HasPrefix(k, "_nf."+name+".") {
			st.del(k)
		}
	}
	if err := st.save(w.statePath()); err != nil {
		return err
	}
	mkdir700(w.queueDir(name))
	o.KV("ok", "1")
	return nil
}

// mkdir700 makes a root-only directory, or makes an existing one root-only (install -d -m 700).
func mkdir700(d string) {
	os.MkdirAll(d, 0o700)
	os.Chmod(d, 0o700)
}

func arg(a []string, i int) string {
	if i < len(a) {
		return a[i]
	}
	return ""
}

// NotifierRm is the verb `notifier-rm <name>`: its secrets, its queue and its state go.
func (w Watch) NotifierRm(o *out.Writer, args []string) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	name := arg(args, 0)
	if !notifierNameRe.MatchString(name) || !fsinfo.RegularFollow(filepath.Join(w.Sec, "notify-"+name)) {
		return errf("no such notifier: %s", name)
	}
	l, err := w.lockBusy()
	if err != nil {
		return err
	}
	defer l.Release()
	os.Remove(filepath.Join(w.Sec, "notify-"+name))
	os.RemoveAll(w.queueDir(name))
	st := newStore(loadQuiet(w.statePath()))
	for _, k := range st.keys() {
		if strings.HasPrefix(k, "_nf."+name+".") {
			st.del(k)
		}
	}
	if err := st.save(w.statePath()); err != nil {
		return err
	}
	o.KV("ok", "1")
	return nil
}

// Heartbeat is the verb `heartbeat`: "url=<url>" on stdin (a secret), or "off".
func (w Watch) Heartbeat(o *out.Writer, stdin io.Reader) error {
	return w.setPingURL(o, stdin, filepath.Join(w.Sec, "heartbeat"), "heartbeat")
}

// Silence is the verb `silence <app|all> <seconds>`; 0 lifts the silence.
func (w Watch) Silence(o *out.Writer, args []string) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	a, s := arg(args, 0), arg(args, 1)
	if a != "all" && !valid.App(a) {
		return errf("bad app")
	}
	secs, ok := valid.Uint(s, 0, 99999999)
	if !ok || len(s) > 8 {
		return errf("bad duration")
	}
	l, err := w.lockBusy()
	if err != nil {
		return err
	}
	defer l.Release()
	st := newStore(loadQuiet(w.statePath()))
	if secs == 0 {
		st.del("_sil." + a)
	} else {
		st.set("_sil."+a, decimal.Itoa(w.now()+secs))
	}
	if err := st.save(w.statePath()); err != nil {
		return err
	}
	o.KV("until", st.or("_sil."+a, "0"))
	return nil
}

// ForgetIncident is the verb `forget-incident <app> <start>`: drop one closed incident from the
// app's record (a false alarm: the monitor was wrong, not the app). Its line leaves
// incidents/<app>.tsv, and the minutes it covers, with the failed probes of the 10 minutes that
// led to it, become "hold": not judged, like a deploy. Uptime is computed from what is left.
func (w Watch) ForgetIncident(o *out.Writer, args []string) error {
	if err := needRoot(w.Env); err != nil {
		return err
	}
	if len(args) < 2 || !valid.App(args[0]) || !decimal.IsDigits(args[1]) {
		return errf("usage: forget-incident <app> <start>")
	}
	a, start := args[0], args[1]
	l, err := w.lockBusy()
	if err != nil {
		return err
	}
	defer l.Release()
	incf := filepath.Join(w.Dir, "incidents", a+".tsv")
	b, _ := os.ReadFile(incf)
	var keep []string
	end := ""
	for _, ln := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		p := strings.Split(ln, "\t")
		if end == "" && len(p) > 1 && p[0] == start {
			if !decimal.IsDigits(p[1]) {
				return errf("that incident is still open: it can be dropped once it has ended")
			}
			end = p[1]
			continue
		}
		if ln != "" {
			keep = append(keep, ln)
		}
	}
	if end == "" {
		return errf("no incident of %s starts at %s (tando health %s --json lists them)", a, start, a)
	}
	from, to := awkNum(start)-600, awkNum(end)
	pf := filepath.Join(w.Dir, "probe", a)
	if pb, err := os.ReadFile(pf); err == nil {
		ls := strings.Split(strings.TrimRight(string(pb), "\n"), "\n")
		n := 0
		for i, ln := range ls {
			ts, rest, _ := strings.Cut(ln, " ")
			cls, _, _ := strings.Cut(rest, " ")
			if t := awkNum(ts); t >= from && t <= to && cls != "ok" && cls != "hold" && cls != "stopped" {
				ls[i] = ts + " hold"
				n++
			}
		}
		if n > 0 {
			if err := atomicfile.Write(pf, []byte(strings.Join(ls, "\n")+"\n"), atomicfile.Mode(0o600)); err != nil {
				return err
			}
		}
		o.KV("minutes", decimal.Itoa(int64(n)))
	}
	body := ""
	if len(keep) > 0 {
		body = strings.Join(keep, "\n") + "\n"
	}
	if err := atomicfile.Write(incf, []byte(body), atomicfile.Mode(0o600)); err != nil {
		return err
	}
	o.KV("ok", "1")
	return nil
}
