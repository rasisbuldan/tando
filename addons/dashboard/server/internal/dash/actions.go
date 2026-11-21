package dash

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

// M4: the writes. Each action is an exact argv (allow.go) built here after its checks:
//
//	deploy             tando deploy -a <app> -H <host>, run in the folder tando recorded as where
//	                   the app was last deployed from (the releases verb's origin row, snapshot's
//	                   app.origin: user@machine:path); refused when that is another machine, the
//	                   folder is gone, or it is not a tando project of that app and host
//	rollback [release] tando rollback <app> [<release>] -H <host>
//	stop|start|restart tando <verb> <app> -H <host>
//	env-set            tando env set <KEY> -a <app> -H <host>, the value on stdin (never in argv,
//	                   a record, the output file, a log line or an error)
//
// Every write runs with TANDO_FROM=dashboard: the CLI puts it in front of sudo on the server, so
// the audit line says from=dashboard. Its outcome is read back from the server when the CLI ends
// (snapshot: history for deploy and rollback, waiting out a soak; the app's state for the rest),
// and again after a tando-dash restart, once the CLI it had started is gone.

// actParams: the params of a write request (only those of its action may be given)
type actParams struct {
	Release string  `json:"release,omitempty"`  // rollback
	Key     string  `json:"key,omitempty"`      // env-set
	Value   *string `json:"value,omitempty"`    // env-set; never stored, never hashed into a record
	NewHost string  `json:"new_host,omitempty"` // host-rename
}

// MaxEnvValue: the longest value env set takes from the dashboard
const MaxEnvValue = 32 << 10

// params: the request's params, checked for its action
func (q *writeReq) params() (actParams, *apiError) {
	var p actParams
	if len(q.Params) > 0 && string(q.Params) != "null" {
		d := json.NewDecoder(bytes.NewReader(q.Params))
		d.DisallowUnknownFields()
		if d.Decode(&p) != nil {
			return p, &apiError{Status: 400, Code: "bad_request", Msg: "bad params"}
		}
	}
	bad := func(m string) (actParams, *apiError) { return p, &apiError{Status: 400, Code: "bad_request", Msg: m} }
	if p.NewHost != "" && q.Action != "host-rename" {
		return bad(q.Action + " takes no new_host")
	}
	switch q.Action {
	case "host-rename":
		if p.Release != "" || p.Key != "" || p.Value != nil {
			return bad("host-rename takes only new_host")
		}
		if !ValidHost(p.NewHost) {
			return bad("new_host: letters, digits, . _ - (at most 64, not starting with - or .)")
		}
		if p.NewHost == q.Host {
			return bad(q.Host + " is already called " + p.NewHost)
		}
	case "rollback":
		if p.Key != "" || p.Value != nil {
			return bad("rollback takes only a release")
		}
		if p.Release != "" && !ValidRelease(p.Release) {
			return bad("release: an id such as 20261113-171442 (tando releases)")
		}
	case "env-set":
		if p.Release != "" {
			return bad("env-set takes a key and a value")
		}
		if !ValidEnvKey(p.Key) {
			return bad("key: a letter or _, then letters, digits or _ (at most 128)")
		}
		if p.Value == nil {
			return bad("value: required (it may be empty)")
		}
		// (the CLI reads one line; the agent refuses control characters: refused here first, in
		// words that never repeat the value)
		if len(*p.Value) > MaxEnvValue || !utf8.ValidString(*p.Value) {
			return bad("the value is longer than 32 KB or not UTF-8 text")
		}
		for _, r := range *p.Value {
			if r < 0x20 || r == 0x7f || r >= 0x80 && r < 0xa0 {
				return bad("the value has a line break or another control character; tando takes one line of text")
			}
		}
	default:
		if p != (actParams{}) {
			return bad(q.Action + " takes no params")
		}
	}
	return p, nil
}

// canonParams: the params that count for the idempotency key. env-set's value is not among them:
// nothing derived from it is written to disk (a key reused with another value is caught in
// memory only, by the record's vmac).
func canonParams(action string, p actParams) json.RawMessage {
	c := actParams{Release: p.Release, Key: p.Key, NewHost: p.NewHost}
	if c == (actParams{}) {
		return nil
	}
	b, _ := json.Marshal(c)
	return b
}

// plan: what a write runs
type plan struct {
	argv  []string
	dir   string
	stdin []byte
	base  *histEntry // deploy, rollback: the newest history entry before it
}

// writeEnv: every write's child gets it (the audit line's from)
var writeEnv = []string{"TANDO_FROM=dashboard"}

// prepare: the argv of an admitted write, after the checks that need the server or the disk
func (s *Server) prepare(ctx context.Context, q *writeReq, p actParams) (*plan, *apiError) {
	h, a := q.Host, q.App
	switch q.Action {
	case "noop":
		return &plan{argv: []string{"--version"}}, nil
	case "stop", "start", "restart":
		return &plan{argv: []string{q.Action, a, "-H", h}}, nil
	case "env-set":
		return &plan{argv: []string{"env", "set", p.Key, "-a", a, "-H", h}, stdin: []byte(*p.Value + "\n")}, nil
	case "host-rename":
		if s.knownHost(p.NewHost) {
			return nil, &apiError{Status: 409, Code: "host_exists", Msg: "a host named " + p.NewHost + " exists already; pick another name"}
		}
		// (run in the config dir: the CLI also rewrites a tando.conf in its working folder, and
		// tando-dash's own folder is no project of the user's)
		return &plan{argv: []string{"host", "rename", h, p.NewHost}, dir: s.cfg.ConfigDir}, nil
	case "rollback":
		snap, e := s.readApp(ctx, h, a, true)
		if e != nil {
			return nil, e
		}
		pl := &plan{argv: []string{"rollback", a, "-H", h}, base: snap.newest()}
		if p.Release != "" {
			pl.argv = []string{"rollback", a, p.Release, "-H", h}
		}
		return pl, nil
	case "deploy":
		snap, e := s.readApp(ctx, h, a, true)
		if e != nil {
			return nil, e
		}
		dir, e := deployDir(s.cfg.ConfigDir, snap.Origin, h, a)
		if e != nil {
			return nil, e
		}
		return &plan{argv: []string{"deploy", "-a", a, "-H", h}, dir: dir, base: snap.newest()}, nil
	}
	return nil, &apiError{Status: 400, Code: "bad_request", Msg: "no such action"}
}

// clientName: lib/deploy.sh client_name: `id -un`@`hostname -s`, [A-Za-z0-9_.@-] only, 64 at most
func clientName() string {
	u := ""
	if cu, err := user.Current(); err == nil {
		u = cu.Username
	}
	h, _ := os.Hostname()
	h, _, _ = strings.Cut(h, ".")
	var b strings.Builder
	for _, c := range []byte(u + "@" + h) {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '.' || c == '@' || c == '-' {
			b.WriteByte(c)
		}
	}
	s := b.String()
	if len(s) > 64 {
		s = s[:64]
	}
	return s
}

func folderErr(msg string) *apiError { return &apiError{Status: 422, Code: "deploy_folder", Msg: msg} }

// deployDir: the folder to deploy app to host from, from the server's record of where it was
// last deployed from; every reason to refuse in one line with the way on. A tando.conf that names
// host's old name is fine while the alias tando host rename left (configDir/renamed/<old>:
// alias=<host>) stands: the CLI follows it (lib/common.sh host_use).
func deployDir(configDir string, origin *string, host, app string) (string, *apiError) {
	if origin == nil || *origin == "" {
		return "", folderErr("tando has no record of where " + app + " was deployed from (a server set up by an older tando: tando host setup " + host + "); deploy it once from its folder with tando deploy")
	}
	who, dir, ok := strings.Cut(*origin, ":")
	if me := clientName(); !ok || who != me {
		return "", folderErr(app + " was last deployed from " + who + ", not from this machine (" + me + "): deploy from there, or from its folder here with tando deploy")
	}
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
		return "", folderErr("the recorded folder of " + app + " is not a plain path: " + dir)
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return "", folderErr(app + " was last deployed from " + dir + ", which is not on this machine any more: deploy it from its folder with tando deploy")
	}
	b, err := os.ReadFile(filepath.Join(dir, "tando.conf"))
	if err != nil {
		return "", folderErr(dir + " has no tando.conf: not a tando project any more")
	}
	confApp, confHost := "", ""
	for _, l := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(l, "=")
		if !ok || strings.HasPrefix(strings.TrimSpace(l), "#") {
			continue
		}
		switch strings.TrimSpace(k) {
		case "app":
			confApp = strings.TrimSpace(v)
		case "host":
			confHost = strings.TrimSpace(v)
		}
	}
	if confApp != app {
		return "", folderErr("tando.conf in " + dir + " is for " + orDash(confApp) + ", not " + app + ": deploy from a terminal there")
	}
	if confHost != "" && confHost != host && aliasOf(configDir, confHost) != host {
		return "", folderErr("tando.conf in " + dir + " deploys to " + confHost + ", not " + host + ": deploy from a terminal there")
	}
	// (a tando.conf that names no server: the CLI is given -H)
	return dir, nil
}

// aliasOf: the host old was renamed to (configDir/renamed/<old>: alias=<new>), as lib/common.sh
// host_alias reads it: only while old is no host itself and new is one; "" otherwise
func aliasOf(configDir, old string) string {
	if !ValidHost(old) {
		return ""
	}
	if _, err := os.Stat(filepath.Join(configDir, "hosts", old)); err == nil {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(configDir, "renamed", old))
	if err != nil {
		return ""
	}
	l, _, _ := strings.Cut(string(b), "\n")
	n, ok := strings.CutPrefix(l, "alias=")
	if !ok || !ValidHost(n) {
		return ""
	}
	if fi, err := os.Stat(filepath.Join(configDir, "hosts", n)); err != nil || !fi.Mode().IsRegular() {
		return ""
	}
	return n
}

func orDash(s string) string {
	if s == "" {
		return "no app"
	}
	return s
}

// ---- reading the outcome back from the server ----

type histEntry struct {
	At      int64    `json:"at"`
	Release string   `json:"release"`
	Kind    string   `json:"kind"`
	Result  string   `json:"result"`
	Total   *float64 `json:"total_s,omitempty"`
	Note    string   `json:"note,omitempty"`
}

// appRead: what a snapshot says of one app
type appRead struct {
	State   string      // state_reason: running, static, deploying, stopped, down, failed, not_deployed
	Release string      // the live release
	Origin  *string     // where it was last deployed from (deploy)
	History []histEntry // newest first (with --app)
}

func (a *appRead) newest() *histEntry {
	if a == nil || len(a.History) == 0 {
		return &histEntry{}
	}
	h := a.History[0]
	return &h
}

// after: the newest entry of kind newer than base (base: the newest of any kind before the write)
func (a *appRead) after(base *histEntry, kind string) *histEntry {
	for i := range a.History {
		h := a.History[i]
		if base != nil && (h.At < base.At || h.At == base.At && h.Release == base.Release && h.Kind == base.Kind) {
			break
		}
		if h.Kind == kind {
			return &h
		}
	}
	return nil
}

// readApp: one snapshot of host (with --app: history, origin), never from the cache
func (s *Server) readApp(ctx context.Context, host, app string, full bool) (*appRead, *apiError) {
	ctx, cancel := context.WithTimeout(ctx, s.cfg.ReadTimeout)
	defer cancel()
	a := app
	if !full {
		a = ""
	}
	res, err := s.run(ctx, Req{Argv: argvSnapshot(host, a, ""), Host: host})
	if err != nil {
		e := cliErr(err)
		e.Msg = "could not read " + app + " on " + host + ": " + e.Msg
		return nil, e
	}
	var d struct {
		Reachable *bool  `json:"reachable"`
		Error     string `json:"error"`
		Apps      []struct {
			App         string `json:"app"`
			StateReason string `json:"state_reason"`
			Release     string `json:"release"`
		} `json:"apps"`
		App *struct {
			Origin  *string     `json:"origin"`
			History []histEntry `json:"history"`
		} `json:"app"`
	}
	if json.Unmarshal(res.Stdout, &d) != nil {
		return nil, &apiError{Status: 502, Code: "bad_output", Msg: "could not read " + app + " on " + host + ": tando printed no JSON"}
	}
	if d.Reachable != nil && !*d.Reachable {
		return nil, &apiError{Status: 502, Code: "unreachable", Msg: host + " did not answer: " + firstLine(d.Error)}
	}
	r := &appRead{}
	found := false
	for _, x := range d.Apps {
		if x.App == app {
			r.State, r.Release, found = x.StateReason, x.Release, true
		}
	}
	if !found {
		return nil, &apiError{Status: 404, Code: "no_app", Msg: "no app " + app + " on " + host + " (tando ls -H " + host + ")"}
	}
	if d.App != nil {
		r.Origin, r.History = d.App.Origin, d.App.History
	}
	return r, nil
}

// outcome: what the server says once a write's CLI has ended
type outcome struct {
	CheckedAt string     `json:"checked_at"`
	State     string     `json:"state,omitempty"`   // the app's state_reason
	Release   string     `json:"release,omitempty"` // its live release
	History   *histEntry `json:"history,omitempty"` // deploy, rollback: this operation's entry
	Verdict   string     `json:"verdict"`           // ok, failed, unknown
	Summary   string     `json:"summary"`
}

// readOutcome: the server's word on rec (exit: the CLI's status, -1 when not known). Waits while
// a deploy or rollback still soaks (state deploying), at most OutcomeWait; a host that does not
// answer is asked again until then.
func (s *Server) readOutcome(ctx context.Context, rec *idemRec, exit int) *outcome {
	full := rec.Action == "deploy" || rec.Action == "rollback"
	end := time.Now().Add(s.cfg.OutcomeWait)
	var last *apiError
	for {
		r, e := s.readApp(ctx, rec.Host, rec.App, full)
		if e == nil && !(full && r.State == "deploying" && time.Now().Before(end)) {
			return judge(rec, r, exit, s.cfg.Now())
		}
		last = e
		if time.Now().After(end) || ctx.Err() != nil {
			break
		}
		select {
		case <-time.After(s.cfg.OutcomePoll):
		case <-ctx.Done():
		}
	}
	o := &outcome{CheckedAt: s.cfg.Now().UTC().Format(time.RFC3339), Verdict: "unknown",
		Summary: "the server did not say how it ended; tando status and tando history show it"}
	if last != nil {
		o.Summary = last.Msg + "; tando status and tando history show how it ended"
	}
	return o
}

// judge: the verdict of the server's state for an action
func judge(rec *idemRec, r *appRead, exit int, now time.Time) *outcome {
	o := &outcome{CheckedAt: now.UTC().Format(time.RFC3339), State: r.State, Release: r.Release, Verdict: "unknown"}
	switch rec.Action {
	case "deploy", "rollback":
		o.History = r.after(rec.Base, rec.Action)
		switch {
		case o.History != nil && (o.History.Result == "ok" || o.History.Result == "verified"):
			o.Verdict, o.Summary = "ok", rec.Action+" of "+o.History.Release+": ok; "+rec.App+" is "+r.State
		case o.History != nil:
			o.Verdict, o.Summary = "failed", rec.Action+" of "+o.History.Release+": "+o.History.Result
			if o.History.Note != "" {
				o.Summary += " (" + o.History.Note + ")"
			}
			o.Summary += "; " + rec.App + " is " + r.State
			if r.Release != "" {
				o.Summary += " on " + r.Release
			}
		case exit == 0:
			// (an upload identical to the live release: "already live", no new entry)
			o.Verdict, o.Summary = "ok", "no new "+rec.Action+" on the server; "+rec.App+" is "+r.State
		case exit > 0:
			o.Verdict, o.Summary = "failed", "no "+rec.Action+" was recorded on the server; "+rec.App+" is "+r.State
		default:
			o.Summary = "no " + rec.Action + " was recorded on the server; " + rec.App + " is " + r.State
		}
	case "stop":
		// (a CLI that failed did not do it, whatever the state is now)
		o.Verdict = verdictIf(exit <= 0 && r.State == "stopped")
		o.Summary = rec.App + " is " + r.State
	case "start", "restart":
		o.Verdict = verdictIf(exit <= 0 && (r.State == "running" || r.State == "static"))
		o.Summary = rec.App + " is " + r.State
	default: // env-set, noop: the state says nothing of it; the CLI's status does
		switch {
		case exit == 0:
			o.Verdict = "ok"
		case exit > 0:
			o.Verdict = "failed"
		}
		o.Summary = rec.App + " is " + r.State
		if rec.Action == "env-set" && exit < 0 {
			o.Summary += "; tando env log " + rec.App + " shows whether the change was made"
		}
	}
	return o
}

func verdictIf(ok bool) string {
	if ok {
		return "ok"
	}
	return "failed"
}

// busyRe: the CLI's own words when another operation holds the app (the agent's lock after its
// wait, or another deploy's upload lease)
func busyLine(out string) string {
	sc := bufio.NewScanner(strings.NewReader(out))
	var hit string
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(l, "tando: ") {
			continue
		}
		if strings.Contains(l, " is busy: ") || strings.Contains(l, "is uploading") {
			hit = strings.TrimPrefix(l, "tando: ")
		}
	}
	return hit
}

// lastError: the CLI's last "tando: ..." line (its error), cut at 300 bytes
func lastError(out string) string {
	var hit string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); strings.HasPrefix(l, "tando: ") {
			hit = firstLine(l)
		}
	}
	return hit
}

// ---- reattach after a restart ----

// reattach: a write that was running when tando-dash stopped. Its CLI was not killed (own
// process group): wait until it is gone, then ask the server how it ended.
func (s *Server) reattach(rec *idemRec, lockKey string) {
	defer s.wg.Done()
	defer s.writes.unlock(lockKey)
	deadline := rec.Started.Add(s.cfg.WriteTimeout + time.Minute)
	for rec.Pid > 0 && pidAlive(rec.Pid) && time.Now().Before(deadline) {
		select {
		case <-time.After(s.cfg.OutcomePoll):
		case <-s.base.Done():
			return // still running; the next start reattaches
		}
	}
	exit := -1
	if rec.ChildEnded {
		exit = rec.Exit
	}
	if hostWide(rec.Action) && exit >= 0 { // (the CLI's status is the outcome)
		st := "done"
		if exit > 0 {
			st = "failed"
		}
		s.idem.finish(rec, st, exit, "", lastError(s.idem.tail(rec.Key)), nil)
		return
	}
	if rec.Action == "noop" || hostWide(rec.Action) {
		s.idem.finish(rec, "unknown", exit, "", "tando-dash restarted while this ran; read the outcome from tando (status, history)", nil)
		return
	}
	o := s.readOutcome(s.base, rec, exit)
	if s.base.Err() != nil {
		return
	}
	st, code, msg := verdict(rec, o, exit, s.idem.tail(rec.Key))
	if o.Verdict == "unknown" {
		st = "unknown"
	}
	s.idem.finish(rec, st, exit, code, msg, o)
}

func pidAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// verdict: the record's status, code and message from the outcome, the exit and the output
func verdict(rec *idemRec, o *outcome, exit int, out string) (status, code, msg string) {
	switch {
	case o != nil && o.Verdict == "ok":
		return "done", "", o.Summary
	case exit > 0 || o != nil && o.Verdict == "failed":
		if b := busyLine(out); b != "" {
			return "failed", "busy", "busy: " + b
		}
		m := lastError(out)
		if m == "" && exit > 0 {
			m = fmt.Sprintf("tando %s ended with status %d", rec.Action, exit)
		}
		if o != nil && o.Summary != "" {
			if m != "" {
				m += "; "
			}
			m += o.Summary
		}
		return "failed", "", m
	}
	if o != nil {
		return "unknown", "", o.Summary
	}
	return "unknown", "", ""
}

// ---- progress: Server-Sent Events of a write's output ----

// GET /api/action/stream?key=: the write's output lines from its output file (so a reloaded
// page, a second tab and a tando-dash restart all see the same stream), then its end. Events:
// hello ({key, action, host, app, status, started_at}), line ({n, text}; id: n, so a
// reconnecting EventSource's Last-Event-ID gets only what it missed), end (the record: status,
// exit, code, message, outcome; the last event). A comment every 15 s keeps it open.
func (s *Server) actionStream(w http.ResponseWriter, r *http.Request) {
	key := r.URL.Query().Get("key")
	if !keyRe.MatchString(key) {
		apiErr(w, 400, "bad_request", "key")
		return
	}
	rec := s.idem.lookup(key)
	if rec == nil {
		apiErr(w, 404, "not_found", "no write with this key (records are kept 24 h)")
		return
	}
	if n := s.actStreams.Add(1); n > int64(s.cfg.MaxActionStreams) {
		s.actStreams.Add(-1)
		apiErr(w, 503, "busy", "too many progress streams open; close a tab")
		return
	}
	defer s.actStreams.Add(-1)
	skip, _ := strconv.ParseInt(r.Header.Get("Last-Event-ID"), 10, 64)
	rc := http.NewResponseController(w)
	defer rc.SetWriteDeadline(time.Time{})
	hd := w.Header()
	hd.Set("Content-Type", "text/event-stream")
	hd.Set("Cache-Control", "no-store")
	hd.Set("X-Accel-Buffering", "no")
	w.WriteHeader(200)
	var buf bytes.Buffer
	flush := func() bool {
		_ = rc.SetWriteDeadline(time.Now().Add(sseWriteTimeout))
		_, err := w.Write(buf.Bytes())
		buf.Reset()
		return err == nil && rc.Flush() == nil
	}
	put := func(name string, id int64, v any) {
		b, _ := json.Marshal(v)
		if id > 0 {
			fmt.Fprintf(&buf, "id: %d\n", id)
		}
		fmt.Fprintf(&buf, "event: %s\ndata: %s\n\n", name, b)
	}
	buf.WriteString("retry: 3000\n\n")
	put("hello", 0, map[string]any{"key": rec.Key, "action": rec.Action, "host": rec.Host, "app": rec.App,
		"status": rec.Status, "started_at": rec.Started.UTC().Format(time.RFC3339)})
	if !flush() {
		return
	}
	var off int64
	var n int64
	var part []byte
	read := func(final bool) {
		f, err := os.Open(s.idem.logPath(key))
		if err != nil {
			return
		}
		defer f.Close()
		b, _ := io.ReadAll(io.LimitReader(io.NewSectionReader(f, off, 1<<30), 256<<10))
		off += int64(len(b))
		part = append(part, b...)
		for {
			i := bytes.IndexByte(part, '\n')
			if i < 0 {
				break
			}
			line := part[:i]
			part = part[i+1:]
			n++
			if n > skip {
				put("line", n, map[string]any{"n": n, "text": cleanLine(line)})
			}
		}
		if final && len(part) > 0 {
			n++
			if n > skip {
				put("line", n, map[string]any{"n": n, "text": cleanLine(part)})
			}
			part = nil
		}
	}
	tick := time.NewTicker(s.cfg.ActionPoll)
	defer tick.Stop()
	hb := time.NewTicker(s.hub.cfg.Heartbeat)
	defer hb.Stop()
	for {
		cur := s.idem.lookup(key)
		ended := cur == nil || (cur.Status != "running" && cur.Status != "pending")
		read(ended)
		if ended {
			if cur != nil {
				put("end", 0, cur.view(false, ""))
			} else {
				put("end", 0, map[string]any{"key": key, "status": "unknown", "message": "the record of this write is gone"})
			}
			flush()
			return
		}
		if buf.Len() > 0 && !flush() {
			return
		}
		select {
		case <-tick.C:
		case <-hb.C:
			s.lastUse.Store(s.cfg.Now().UnixNano())
			buf.WriteString(": hb\n\n")
			if !flush() {
				return
			}
		case <-r.Context().Done():
			return
		case <-s.base.Done():
			return
		}
	}
}

// cleanLine: one output line as the page shows it: what a \r redrew last, no other control
// characters, valid UTF-8, 4 KB at most
func cleanLine(b []byte) string {
	if i := bytes.LastIndexByte(bytes.TrimRight(b, "\r"), '\r'); i >= 0 {
		b = b[i+1:]
	}
	b = bytes.TrimRight(b, "\r")
	if len(b) > 4096 {
		b = b[:4096]
	}
	s := strings.ToValidUTF8(string(b), "?")
	return strings.Map(func(r rune) rune {
		if r == '\t' {
			return ' '
		}
		if r < 0x20 || r == 0x7f || r >= 0x80 && r < 0xa0 {
			return -1
		}
		return r
	}, s)
}
