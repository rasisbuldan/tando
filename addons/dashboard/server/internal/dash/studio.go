package dash

import (
	"bufio"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The database studio from the dashboard (docs/SPEC.md "Database studio"). tando-dash starts
// `tando db studio <app> -H <host> --json` as a long-running child and hands the page the
// studio's one-time link, which the page opens in a window of its own. The studio's own page,
// key and Stop stay exactly as in the terminal; nothing of the studio passes through tando-dash.
//
//   - a confirmed action: a confirm token (kind "studio") for exactly this host and app, every time;
//   - an Idempotency-Key: the same key again returns the first answer (in memory only: the link
//     is never written to disk or logged) and starts nothing;
//   - at most 1 dashboard studio per host (the server allows 2: the other stays free for the
//     terminal) and 4 in all, counted apart from the reads' and log streams' limiter (the studio
//     opens its own ssh connection);
//   - the child's stdin is a pipe tando-dash holds: when tando-dash dies, the CLI sees EOF and ends
//     its session (lib/studio.sh --json). Its process group gets SIGTERM on Stop and on Close;
//     its pid is in cache/dash-studios.json (0600) so a tando-dash started after a crash stops
//     what is left (the pid's command line checked first).

const (
	studioPerHost   = 1
	studioMax       = 4
	studioMaxKeys   = 128
	studioKeyTTL    = 10 * time.Minute
	studioReadyWait = 45 * time.Second
	studioStopWait  = 8 * time.Second
)

var studioURLRe = regexp.MustCompile(`^http://127\.0\.0\.1:[0-9]{1,5}/#c=[A-Za-z0-9_-]{8,128}$`)

func argvStudio(host, app string) []string {
	return []string{"db", "studio", app, "-H", host, "--json"}
}

type studioChild struct {
	Host  string    `json:"host"`
	App   string    `json:"app"`
	Since time.Time `json:"since"`
	Pid   int       `json:"pid"`

	starting bool
	stdin    *os.File
	done     chan struct{}
}

// studioAnswer: an open's answer, kept for its Idempotency-Key (memory only)
type studioAnswer struct {
	what   string // host/app
	done   chan struct{}
	status int
	body   map[string]any
	at     time.Time
}

type studios struct {
	mu     sync.Mutex
	byHost map[string]*studioChild
	keys   map[string]*studioAnswer
	file   string
	path   func() string
	env    []string
	now    func() time.Time
	wg     sync.WaitGroup
	logf   func(string, ...any)
}

func newStudios(file string, path func() string, env []string, now func() time.Time, logf func(string, ...any)) *studios {
	st := &studios{byHost: map[string]*studioChild{}, keys: map[string]*studioAnswer{}, file: file, path: path, env: env, now: now, logf: logf}
	st.cleanLeftovers()
	return st
}

// cleanLeftovers: children a crashed tando-dash left (their pids in the file): each one whose
// command line is still that studio's gets SIGTERM to its group; then the file is emptied
func (st *studios) cleanLeftovers() {
	b, err := os.ReadFile(st.file)
	if err != nil {
		return
	}
	var old []studioChild
	_ = json.Unmarshal(b, &old)
	for _, c := range old {
		if c.Pid <= 1 || !ValidHost(c.Host) || !ValidApp(c.App) {
			continue
		}
		if isStudioChild(c.Pid, c.Host, c.App) {
			_ = syscall.Kill(-c.Pid, syscall.SIGTERM)
			st.logf("stopped a database studio of %s on %s left by an earlier tando-dash (pid %d)", c.App, c.Host, c.Pid)
		}
	}
	_ = writeFileAtomic(st.file, []byte("[]\n"), 0o600)
}

// isStudioChild: pid leads its own process group and runs `... db studio <app> -H <host> --json`
func isStudioChild(pid int, host, app string) bool {
	out, err := exec.Command("ps", "-o", "pgid=", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return false
	}
	f := strings.Fields(string(out))
	if len(f) < 2 || f[0] != strconv.Itoa(pid) {
		return false
	}
	return strings.HasSuffix(strings.Join(f[1:], " "), " "+strings.Join(argvStudio(host, app), " "))
}

// saveLocked: the pids of the running children (0600)
func (st *studios) saveLocked() {
	l := []studioChild{}
	for _, c := range st.byHost {
		if c.Pid > 0 {
			l = append(l, *c)
		}
	}
	b, _ := json.Marshal(l)
	if err := writeFileAtomic(st.file, b, 0o600); err != nil {
		st.logf("could not write %s: %v", st.file, err)
	}
}

// list: the dashboard's studios now (the overview carries it)
func (st *studios) list() []map[string]any {
	st.mu.Lock()
	defer st.mu.Unlock()
	l := []map[string]any{}
	for _, c := range st.byHost {
		state := "open"
		if c.starting {
			state = "starting"
		}
		l = append(l, map[string]any{"host": c.Host, "app": c.App, "since": c.Since.UTC().Format(time.RFC3339), "state": state})
	}
	sort.Slice(l, func(i, j int) bool { return l[i]["host"].(string) < l[j]["host"].(string) })
	return l
}

type studioReq struct {
	Host    string `json:"host"`
	App     string `json:"app"`
	Confirm string `json:"confirm,omitempty"`
}

func (q *studioReq) check() *apiError {
	if !ValidHost(q.Host) {
		return &apiError{Status: 400, Code: "bad_request", Msg: "host: letters, digits, . _ -"}
	}
	if !ValidApp(q.App) {
		return &apiError{Status: 400, Code: "bad_request", Msg: "app: a-z, 0-9, -; 2-24 characters"}
	}
	return nil
}

// POST /api/studio/open {host, app, confirm} with Idempotency-Key -> {url, host, app, since}
func (s *Server) studioOpen(w http.ResponseWriter, r *http.Request) {
	st := s.studios
	key := r.Header.Get("Idempotency-Key")
	if !keyRe.MatchString(key) {
		apiErr(w, 400, "idempotency_key", "an Idempotency-Key header (8-128 letters, digits, -) is required")
		return
	}
	var q studioReq
	if _, ok := decode(w, r, &q); !ok {
		return
	}
	if e := q.check(); e != nil {
		writeErr(w, e)
		return
	}
	if !s.knownHost(q.Host) {
		apiErr(w, 404, "no_host", "no host named "+q.Host+" (tando host ls)")
		return
	}
	what := q.Host + "/" + q.App
	st.mu.Lock()
	if a := st.keys[key]; a != nil {
		st.mu.Unlock()
		if a.what != what {
			apiErr(w, 422, "key_reused", "this Idempotency-Key was used for another request")
			return
		}
		select {
		case <-a.done:
		case <-r.Context().Done():
			return
		}
		body := map[string]any{"replay": true}
		for k, v := range a.body {
			body[k] = v
		}
		writeJSON(w, a.status, body)
		return
	}
	now := st.now()
	for k, a := range st.keys {
		select {
		case <-a.done:
			if now.Sub(a.at) > studioKeyTTL {
				delete(st.keys, k)
			}
		default:
		}
	}
	if len(st.keys) >= studioMaxKeys {
		st.mu.Unlock()
		apiErr(w, 503, "busy", "too many studio requests remembered; retry later")
		return
	}
	if c := st.byHost[q.Host]; c != nil {
		st.mu.Unlock()
		msg := "the dashboard's studio on " + q.Host + " is open for " + c.App + ": it is in the window it opened; Stop it to start a new one"
		if c.App == q.App {
			msg = "the studio of " + q.App + " is open in another window (its link works once); Stop it to start a new one"
		}
		writeErr(w, &apiError{Status: 409, Code: "studio_open", Msg: msg,
			Extra: map[string]any{"app": c.App, "since": c.Since.UTC().Format(time.RFC3339)}})
		return
	}
	if len(st.byHost) >= studioMax {
		st.mu.Unlock()
		apiErr(w, 503, "busy", "the dashboard has 4 studios open already; Stop one first")
		return
	}
	c := &studioChild{Host: q.Host, App: q.App, Since: now, starting: true, done: make(chan struct{})}
	st.byHost[q.Host] = c
	a := &studioAnswer{what: what, done: make(chan struct{}), at: now}
	st.keys[key] = a
	st.mu.Unlock()

	fail := func(e *apiError) {
		st.mu.Lock()
		if st.byHost[q.Host] == c {
			delete(st.byHost, q.Host)
		}
		delete(st.keys, key) // a refusal or a failed start is not remembered: the key can be used again
		st.mu.Unlock()
		a.status, a.body = e.Status, map[string]any{"error": e}
		close(a.done)
		writeErr(w, e)
	}
	if !s.confirms.use(q.Confirm, "studio", q.Host, q.App) {
		fail(&apiError{Status: 403, Code: "confirm", Msg: "this confirmation has expired or was for something else; confirm again"})
		return
	}
	url, e := st.start(c, argvStudio(q.Host, q.App))
	if e != nil {
		fail(e)
		return
	}
	a.status, a.body = 200, map[string]any{"url": url, "host": q.Host, "app": q.App, "since": c.Since.UTC().Format(time.RFC3339)}
	close(a.done)
	writeJSON(w, 200, a.body)
}

// start: the child, until its ready line (the link) or its end. c is reserved in byHost.
func (st *studios) start(c *studioChild, argv []string) (string, *apiError) {
	if _, err := Allowed(argv); err != nil {
		return "", cliErr(err)
	}
	path := st.path()
	if path == "" {
		return "", &apiError{Status: 502, Code: "start", Msg: "tando not found (install tando, or start tando-dash with --tando PATH)"}
	}
	inR, inW, err := os.Pipe()
	if err != nil {
		return "", &apiError{Status: 502, Code: "start", Msg: "could not run tando: " + err.Error()}
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		inR.Close()
		inW.Close()
		return "", &apiError{Status: 502, Code: "start", Msg: "could not run tando: " + err.Error()}
	}
	errw := &lockedCap{c: capWriter{max: stderrKeep}}
	cmd := exec.Command(path, argv...)
	cmd.Env = append(append(append(os.Environ(), st.env...), writeEnv...), "TANDO_COLOR=never")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = inR, outW, errw
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = 2 * time.Second
	err = cmd.Start()
	inR.Close()
	outW.Close()
	if err != nil {
		inW.Close()
		outR.Close()
		return "", &apiError{Status: 502, Code: "start", Msg: "could not run " + path + ": " + err.Error()}
	}
	pid := cmd.Process.Pid
	st.mu.Lock()
	c.Pid, c.stdin = pid, inW
	st.saveLocked()
	st.mu.Unlock()

	ready := make(chan string, 1)
	go func() { // the ready line, then the rest is read and dropped (the CLI must never block on it)
		defer outR.Close()
		sc := bufio.NewScanner(outR)
		sent := false
		for sc.Scan() {
			if sent {
				continue
			}
			var m struct {
				URL string `json:"url"`
			}
			if json.Unmarshal(sc.Bytes(), &m) == nil && studioURLRe.MatchString(m.URL) {
				ready <- m.URL
				sent = true
			}
		}
	}()
	st.wg.Add(1)
	go func() {
		defer st.wg.Done()
		_ = cmd.Wait()
		_ = syscall.Kill(-pid, syscall.SIGKILL) // what it left in its group (its stdin watcher, an ssh)
		inW.Close()
		st.mu.Lock()
		if st.byHost[c.Host] == c {
			delete(st.byHost, c.Host)
		}
		st.saveLocked()
		st.mu.Unlock()
		close(c.done)
	}()
	t := time.NewTimer(studioReadyWait)
	defer t.Stop()
	select {
	case url := <-ready:
		st.mu.Lock()
		c.starting = false
		st.mu.Unlock()
		return url, nil
	case <-c.done:
		msg := firstLine(errw.String())
		if msg == "" {
			msg = "tando db studio ended before the studio answered"
		}
		return "", &apiError{Status: 502, Code: "cli", Msg: msg}
	case <-t.C:
		_ = syscall.Kill(-pid, syscall.SIGTERM)
		return "", &apiError{Status: 504, Code: "timeout", Msg: "the studio did not start within 45 s"}
	}
}

// stopChild: SIGTERM to the group (the CLI ends its session, as Ctrl-C does), SIGKILL if it
// takes longer than studioStopWait; returns when it has ended
func (st *studios) stopChild(c *studioChild) {
	_ = syscall.Kill(-c.Pid, syscall.SIGTERM)
	select {
	case <-c.done:
		return
	case <-time.After(studioStopWait):
	}
	_ = syscall.Kill(-c.Pid, syscall.SIGKILL)
	select {
	case <-c.done:
	case <-time.After(3 * time.Second):
	}
}

// closeAll: tando-dash stops: every child's group gets SIGTERM and its stdin is closed
func (st *studios) closeAll() {
	st.mu.Lock()
	defer st.mu.Unlock()
	for _, c := range st.byHost {
		if c.Pid > 0 {
			_ = syscall.Kill(-c.Pid, syscall.SIGTERM)
		}
	}
}

// POST /api/studio/stop {host, app} -> {stopped}
func (s *Server) studioStop(w http.ResponseWriter, r *http.Request) {
	var q studioReq
	if _, ok := decode(w, r, &q); !ok {
		return
	}
	if e := q.check(); e != nil {
		writeErr(w, e)
		return
	}
	st := s.studios
	st.mu.Lock()
	c := st.byHost[q.Host]
	if c == nil || c.App != q.App {
		st.mu.Unlock()
		writeJSON(w, 200, map[string]any{"stopped": false, "studios": st.list()})
		return
	}
	if c.starting || c.Pid <= 0 {
		st.mu.Unlock()
		apiErr(w, 409, "starting", "the studio is still starting; Stop again in a moment")
		return
	}
	st.mu.Unlock()
	st.stopChild(c)
	writeJSON(w, 200, map[string]any{"stopped": true, "studios": st.list()})
}

// lockedCap: a capWriter the exec copier writes while the handler may read it
type lockedCap struct {
	mu sync.Mutex
	c  capWriter
}

func (l *lockedCap) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.c.Write(p)
}

func (l *lockedCap) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.c.b.String()
}

// studioPath: the tando CLI and its environment, from the ExecRunner (tests: the fake)
func studioPath(r Runner) (func() string, []string) {
	if x, ok := r.(*ExecRunner); ok {
		return x.Path, x.Env
	}
	return func() string { return "" }, nil
}
