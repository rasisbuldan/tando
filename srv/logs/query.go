package logs

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"tando/srv/internal/fsinfo"
	"tando/srv/internal/valid"
	"tando/srv/logs/journal"
	"tando/srv/logs/lines"
)

// maxEntry bounds a journalctl JSON line read (a message over 4096 bytes is null in -o json;
// escapes and byte arrays make a line a few times longer at most).
const maxEntry = 1 << 20

// queryCPU: a runaway query is stopped by a CPU limit (follow mode reads only new lines).
const queryCPU = 120

var specCheck = map[string]func(string) bool{
	"n":         regexp.MustCompile(`^([0-9]{1,7}|all)$`).MatchString,
	"since":     reTime.MatchString,
	"until":     reTime.MatchString,
	"grep":      func(v string) bool { n := utf8.RuneCountInString(v); return n >= 1 && n <= 256 },
	"grep_mode": regexp.MustCompile(`^(fixed|ifixed|regex|iregex)$`).MatchString,
	"level":     regexp.MustCompile(`^[0-7]$`).MatchString,
	"release":   valid.ID,
	"deploy":    valid.ID,
	"format":    func(v string) bool { return v == "text" || v == "json" },
	"follow":    func(v string) bool { return v == "1" || v == "0" },
	"cursor":    func(v string) bool { return v == "1" || v == "0" },
	"after":     regexp.MustCompile(`^[a-z]=[0-9a-f]{1,64}(;[a-z]=[0-9a-f]{1,64}){1,9}$`).MatchString,
	"tz":        regexp.MustCompile(`^[+-][0-9]{4}$`).MatchString,
}

var (
	reTime   = regexp.MustCompile(`^(@[0-9]{1,11}|-[0-9]{1,10})$`)
	reCount7 = regexp.MustCompile(`^[0-9]{1,7}$`)
)

// readSpec reads the query (key=value lines) from stdin: at most 30 lines, whitelisted keys,
// every value checked against a strict pattern. Anything else fails closed, before journalctl
// runs. As bash's read, a last line without its newline is not read.
func readSpec(r io.Reader, q map[string]string) error {
	lr := lines.NewReader(r, 4096)
	for n := 1; ; n++ {
		ln, ok := lr.Next()
		if !ok || !ln.EOL {
			return nil
		}
		if n > 30 {
			return errors.New("spec too long")
		}
		line := string(ln.Text)
		k, v, has := strings.Cut(line, "=")
		if !has {
			return errors.New("bad spec line")
		}
		if hasControl(v) {
			return fmt.Errorf("control characters in %s", k)
		}
		check, known := specCheck[k]
		if !known {
			return fmt.Errorf("unknown spec key: %s", k)
		}
		if ln.Len != len(ln.Text) || !check(v) {
			return fmt.Errorf("bad value for %s", k)
		}
		q[k] = v
	}
}

// hasControl: C0, DEL or a C1 control (U+0080-U+009F).
func hasControl(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x20 || c == 0x7f || (c == 0xc2 && i+1 < len(s) && s[i+1] >= 0x80 && s[i+1] <= 0x9f) {
			return true
		}
	}
	return false
}

// Query is the logs verb: `logs <app> spec` with the query on stdin, or the old form
// `logs <app> [n] [follow]`. It writes text (or JSON) lines to w; in follow mode it flushes every
// line and runs until the client goes away.
func (l *Logs) Query(ctx context.Context, name string, args []string, stdin io.Reader, w *bufio.Writer) error {
	a, err := l.app(name)
	if err != nil {
		return err
	}
	q, err := readQuery(args, stdin)
	if err != nil {
		return err
	}
	all := q["n"] == "all"
	n, _ := strconv.ParseInt(q["n"], 10, 64)
	follow := q["follow"] == "1"
	if !all && n == 0 && !follow {
		return nil // -n 0: nothing (journalctl alone would print everything)
	}
	p, err := a.planQuery(q, l.Env.Now().Unix())
	if err != nil {
		return err
	}
	if !follow && l.LimitCPU != nil {
		l.LimitCPU(queryCPU)
	}
	for _, h := range p.header {
		w.WriteString(h)
		w.WriteByte('\n')
	}
	jc := append([]string{"journalctl", "--no-pager", "-q", "-o", "json", "--output-fields=MESSAGE,PRIORITY,_SYSTEMD_UNIT,UNIT,_PID"}, p.args...)
	if follow {
		return l.follow(ctx, jc, p.f, q, n, all, w)
	}
	return l.printQuery(ctx, a, p, jc, n, all, w)
}

// readQuery is the query of `logs`: the key=value lines of the spec form (readSpec), or the
// words of the old form `logs <app> [n] [follow]`, over the defaults.
func readQuery(args []string, stdin io.Reader) (map[string]string, error) {
	q := map[string]string{"n": "100", "format": "text", "follow": "0", "cursor": "0"}
	if len(args) > 0 && args[0] == "spec" {
		if err := readSpec(stdin, q); err != nil {
			return nil, err
		}
		return q, nil
	}
	if len(args) > 0 && args[0] != "" {
		if !reCount7.MatchString(args[0]) {
			return nil, errors.New("bad count")
		}
		q["n"] = args[0]
	}
	if len(args) > 1 && args[1] == "follow" {
		q["follow"] = "1"
	}
	return q, nil
}

// queryPlan is a checked query turned into what runs: journalctl's arguments, the filter of its
// lines, the header lines (text only) and what printQuery needs to add its note.
type queryPlan struct {
	args   []string // journalctl's arguments after its fixed ones (Query)
	f      *journal.Filter
	header []string
	until  string // the end of the window ("" none), for the note on suppressed lines
	track  bool   // the oldest line shown is tracked for that note (text, not a deploy's log)
}

// planQuery turns the query into journalctl's arguments and the line filter. Every error (a bad
// regular expression, an unknown release) comes before anything runs or is printed.
func (a *app) planQuery(q map[string]string, now int64) (*queryPlan, error) {
	text := q["format"] == "text"
	f := &journal.Filter{JSON: !text, Level: -1, Cursor: q["cursor"] == "1"}
	if v := q["level"]; v != "" {
		f.Level, _ = strconv.Atoi(v)
	}
	if pat := q["grep"]; pat != "" {
		var err error
		if f.Match, err = matcher(pat, q["grep_mode"]); err != nil {
			return nil, err
		}
	}
	p := &queryPlan{f: f}
	if fsinfo.RegularFollow(a.nsConf()) {
		p.args = append(p.args, "--namespace=+"+a.ns())
	}
	// a release that never went live (it failed its pre-flight, or was rolled back before it
	// verified...) has no live period: show what its deploy logged instead, which is what a
	// failure box points to
	release, deploy, neverLive := q["release"], q["deploy"], false
	if release != "" {
		f.Ranges = a.releaseRanges(release, now)
		if f.Ranges == nil {
			deploy, release, neverLive = release, "", true
		}
	}
	var units [][2]string
	if deploy != "" {
		if !a.knownRelease(deploy) {
			return nil, fmt.Errorf("no such release: %s", deploy)
		}
		units = [][2]string{{"tando-" + a.name + "-act-" + deploy + ".service", "act"},
			{"tando-" + a.name + "-venv-" + deploy + ".service", "venv"}, {"tando-" + a.name + "-pre-" + deploy + ".service", "pre"}}
		if text {
			if neverLive {
				p.header = append(p.header, "# release "+deploy+" was never live: its deploy log (activation, build, pre-flight)")
			}
			p.header = append(p.header, a.deployHeader(deploy)...)
		}
	} else {
		units = a.units()
	}
	f.Roles = map[string]string{}
	for _, u := range units {
		f.Roles[u[0]] = u[1]
		p.args = append(p.args, "-u", u[0])
	}
	since, until := "", ""
	if release != "" {
		since = strconv.FormatInt(int64(f.Ranges[0][0])/1000000, 10)
		until = strconv.FormatInt(int64(f.Ranges[len(f.Ranges)-1][1])/1000000, 10)
		if text {
			var b strings.Builder
			for _, r := range f.Ranges {
				b.WriteString(localTime(int64(r[0])/1000000) + ".." + localTime(int64(r[1])/1000000) + " ")
			}
			p.header = append(p.header, "# release "+release+" was live: "+b.String()+"(server time)")
		}
	}
	if v := q["since"]; v != "" {
		since = tsec(v, now)
	}
	if v := q["until"]; v != "" {
		until = tsec(v, now)
	}
	if since != "" {
		p.args = append(p.args, "--since=@"+since)
	}
	if until != "" && q["follow"] != "1" {
		p.args = append(p.args, "--until=@"+until)
	}
	f.TZOff, f.TZS = tzOffset(q["tz"])
	p.args = append(p.args, grepArgs(q["grep"], q["grep_mode"])...)
	p.until, p.track = until, text && deploy == ""
	return p, nil
}

// tzOffset: the client's zone, +hhmm or -hhmm ("": +0000), as seconds and as +hh:mm.
func tzOffset(tz string) (int64, string) {
	if tz == "" {
		tz = "+0000"
	}
	hh, _ := strconv.Atoi(tz[1:3])
	mm, _ := strconv.Atoi(tz[3:5])
	off := int64(hh*3600 + mm*60)
	if tz[0] == '-' {
		off = -off
	}
	return off, tz[:3] + ":" + tz[3:5]
}

// grepArgs: a fixed string is also handed to journalctl -g as an escaped literal: it skips the
// JSON formatting of lines that cannot match (measured 2.0 s -> 0.2 s for a scan of 100k
// entries). The filter still makes the exact decision. Not when the pattern could match the ^X /
// \xHH / ? notation of neutralised bytes.
func grepArgs(pat, mode string) []string {
	if pat == "" || (mode != "" && mode != "fixed" && mode != "ifixed") {
		return nil
	}
	lit, ok := grepLiteral(pat)
	if !ok {
		return nil
	}
	cs := "yes"
	if mode == "ifixed" {
		cs = "no"
	}
	return []string{"--grep=" + lit, "--case-sensitive=" + cs}
}

// printQuery runs the query without follow: every matching line (all), or the newest n of them
// read newest first (-r) and printed oldest first; then the note on lines journald dropped.
func (l *Logs) printQuery(ctx context.Context, a *app, p *queryPlan, jc []string, n int64, all bool, w *bufio.Writer) error {
	var oldest float64
	parser := journal.NewParser()
	var e journal.Entry
	var buf []byte
	emit := func(ln lines.Line, out func([]byte)) bool {
		if !parser.Parse(ln.Text, &e) {
			return true
		}
		var us float64
		var ok bool
		if buf, us, ok = p.f.Line(buf[:0], &e); ok {
			out(buf)
			if p.track && (oldest == 0 || us < oldest) {
				oldest = us
			}
			return true
		}
		return true
	}
	var err error
	if all {
		err = l.stream(ctx, jc, time.Hour, maxEntry, func(ln lines.Line) bool {
			return emit(ln, func(b []byte) { w.Write(b); w.WriteByte('\n') })
		})
	} else {
		var st lines.Stack
		count := int64(0)
		err = l.stream(ctx, append(jc, "-r"), time.Hour, maxEntry, func(ln lines.Line) bool {
			emit(ln, func(b []byte) { st.Push(b); count++ })
			return count < n
		})
		if werr := st.WriteReversed(w); werr != nil {
			return werr
		}
	}
	l.commandFailed(err)
	if p.track && oldest > 0 {
		a.suppressedNote(ctx, int64(oldest)/1000000, p.until, w)
	}
	return w.Flush()
}

// follow: the newest n lines (unless the client resumes after a cursor), then every new line as
// it comes. Every streamed line carries its cursor when asked (the client resumes after it).
func (l *Logs) follow(ctx context.Context, jc []string, f *journal.Filter, q map[string]string, n int64, all bool, w *bufio.Writer) error {
	p := journal.NewParser()
	var e journal.Entry
	var buf []byte
	cursor := q["after"]
	if cursor == "" && (all || n != 0) {
		var st lines.Stack
		count := int64(0)
		first := true
		l.stream(ctx, append(jc, "-r"), time.Hour, maxEntry, func(ln lines.Line) bool {
			if !p.Parse(ln.Text, &e) {
				return true
			}
			if first { // the newest entry, matching or not: following resumes after it
				cursor, first = string(journal.Str(e.Cursor)), false
			}
			var ok bool
			if buf, _, ok = f.Line(buf[:0], &e); ok {
				st.Push(buf)
				count++
			}
			return all || count < n
		})
		if err := st.WriteReversed(w); err != nil {
			return err
		}
	}
	if err := w.Flush(); err != nil {
		return err
	}
	if cursor != "" {
		jc = append(jc, "-f", "--lines=all", "--after-cursor="+cursor)
	} else {
		jc = append(jc, "-f", "-n", "0")
	}
	var werr error
	err := l.stream(ctx, jc, forever, maxEntry, func(ln lines.Line) bool {
		if !p.Parse(ln.Text, &e) {
			return true
		}
		var ok bool
		if buf, _, ok = f.Line(buf[:0], &e); ok {
			buf = append(buf, '\n')
			if _, werr = w.Write(buf); werr == nil {
				werr = w.Flush()
			}
		}
		return werr == nil
	})
	if werr != nil {
		return werr
	}
	l.commandFailed(err)
	return nil
}

// units: the exact units of the app: the service, its journald instance (its "Suppressed N
// messages" notices) and its jobs. Globs are never used: another app's name could match them.
func (a *app) units() [][2]string {
	u := [][2]string{{"tando-" + a.name + ".service", "app"}, {"systemd-journald@tando-" + a.name + ".service", "journald"}}
	var jobs []string
	for k := range a.conf {
		if j, ok := strings.CutPrefix(k, "job."); ok && reJob.MatchString(j) {
			jobs = append(jobs, j)
		}
	}
	slices.Sort(jobs)
	for _, j := range jobs {
		u = append(u, [2]string{"tando-" + a.name + "-job-" + j + ".service", "job:" + j})
	}
	return u
}

// reJob: a job name as the agent accepts it.
var reJob = regexp.MustCompile(`^[a-z][a-z0-9-]{0,20}$`)

// tsec: @epoch or -seconds (ago) as epoch seconds.
func tsec(v string, now int64) string {
	n, _ := strconv.ParseInt(v[1:], 10, 64)
	if v[0] == '-' {
		n = now - n
	}
	return strconv.FormatInt(n, 10)
}

// localTime: date -d @t '+%F %T' in the server's zone.
func localTime(t int64) string { return time.Unix(t, 0).Format("2006-01-02 15:04:05") }

// matcher: the --grep test on a displayed message. fixed and ifixed are substrings (ifixed:
// ASCII case folded, as awk's tolower in the C locale); regex is RE2 syntax (a superset of the
// POSIX ERE the shell version used with mawk, without back-references), iregex the same with
// (?i). An invalid regex is refused before any output.
func matcher(pat, mode string) (func([]byte) bool, error) {
	switch mode {
	case "", "fixed":
		p := []byte(pat)
		return func(m []byte) bool { return bytes.Contains(m, p) }, nil
	case "ifixed":
		p := asciiLower(nil, []byte(pat))
		var buf []byte
		return func(m []byte) bool { buf = asciiLower(buf[:0], m); return bytes.Contains(buf, p) }, nil
	}
	if mode == "iregex" {
		pat = "(?i)" + pat
	}
	re, err := regexp.Compile(pat)
	if err != nil {
		return nil, errors.New("bad regular expression")
	}
	return re.Match, nil
}

func asciiLower(dst, b []byte) []byte {
	for _, c := range b {
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		dst = append(dst, c)
	}
	return dst
}

var reHexish = regexp.MustCompile(`[xX][0-9a-fA-F]`)

// grepLiteral: the pattern as a PCRE literal for journalctl -g (every character but letters and
// digits escaped), when it is printable ASCII that cannot match the ^X, \xHH and ? notation.
func grepLiteral(pat string) (string, bool) {
	for i := 0; i < len(pat); i++ {
		if c := pat[i]; c < ' ' || c > '~' || c == '^' || c == '\\' || c == '[' || c == '?' {
			return "", false
		}
	}
	if reHexish.MatchString(pat) {
		return "", false
	}
	var b strings.Builder
	for i := 0; i < len(pat); i++ {
		c := pat[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			b.WriteByte('\\')
		}
		b.WriteByte(c)
	}
	return b.String(), true
}

// suppressedNote: "# note" after the lines shown when journald dropped lines of the app (its
// rate limit, log_rate) between the oldest line shown and the end of the window: those lines are
// gone for good.
func (a *app) suppressedNote(ctx context.Context, from int64, until string, w *bufio.Writer) {
	jc := []string{"journalctl", "--no-pager", "-q", "-o", "cat", "--namespace=" + a.ns(), "-u",
		"systemd-journald@" + a.ns() + ".service", "--since=@" + strconv.FormatInt(from, 10), "-g", "^Suppressed [0-9]+ messages"}
	if until != "" {
		jc = append(jc, "--until=@"+until)
	}
	var total float64
	read := 0
	var fs [3][]byte
	a.l.stream(ctx, jc, time.Minute, 4096, func(ln lines.Line) bool {
		if k := lines.Fields(ln.Text, fs[:]); k >= 2 {
			total += lines.Num(fs[1])
		}
		read++
		return read < 10000
	})
	if total > 0 {
		fmt.Fprintf(w, "# note: journald dropped %s lines in this window (over log_rate %s)\n",
			strconv.FormatFloat(total, 'f', -1, 64), a.setting("log_rate"))
	}
}
