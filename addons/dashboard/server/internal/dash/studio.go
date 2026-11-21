package dash

import (
	"bufio"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The database studio from the dashboard (docs/SPEC.md "Database studio"). The server's studio is
// always on (docs/STUDIO.md); what tando-dash holds is ONE ssh forward per host to it, started by
// the first click and closed after 30 min without one:
//
//   - the forward is `tando db studio <app> -H <host> --json` (the CLI; exact argv in the
//     allowlist), a long-running child whose first stdout line is {"url","port","sid"};
//   - every click after that writes "mint <app>" on the child's stdin and reads one more such line:
//     a fresh one-time code on the same port. No confirmation, no stop: the page opens the link
//     in a new tab at once. The link is never stored, logged or written to disk;
//   - at most 4 forwards in all, counted apart from the reads' and log streams' limiter (the
//     forward is its own ssh connection);
//   - the child's stdin is a pipe tando-dash holds: when tando-dash dies, the CLI sees EOF and ends
//     its forward. Its process group gets SIGTERM on idle and on Close; its pid is in
//     cache/dash-studios.json (0600) so a tando-dash started after a crash stops what is left
//     (the pid's command line checked first).

const (
	studioMax       = 4
	studioIdle      = 30 * time.Minute
	studioReadyWait = 45 * time.Second
	studioStopWait  = 8 * time.Second
)

// the link as the CLI prints it: the code works once; &app= names the app the studio opens
var studioURLRe = regexp.MustCompile(`^http://127\.0\.0\.1:[0-9]{1,5}/#c=[A-Za-z0-9_-]{8,128}(&app=[a-z0-9-]{2,24})?$`)

func argvStudio(host, app string) []string {
	return []string{"db", "studio", app, "-H", host, "--json"}
}

// studioLine: one line of the child's stdout that carries a link or the CLI's refusal
type studioLine struct {
	URL string
	Err string
}

// studioRec: a child as cache/dash-studios.json keeps it
type studioRec struct {
	Host  string    `json:"host"`
	App   string    `json:"app"` // the app of the first click (the child's argv)
	Since time.Time `json:"since"`
	Pid   int       `json:"pid"`
}

type tunnel struct {
	studioRec

	mu    sync.Mutex // one click at a time per host
	up    bool       // started: Pid, stdin and lines are set
	dead  bool       // ended or failed to start: a click gets a new one
	stdin *os.File
	lines chan studioLine
	done  chan struct{}
	timer *time.Timer
	last  time.Time
}

type studios struct {
	mu     sync.Mutex
	byHost map[string]*tunnel
	file   string
	path   func() string
	env    []string
	now    func() time.Time
	idle   time.Duration
	wg     sync.WaitGroup
	logf   func(string, ...any)
}

func newStudios(file string, path func() string, env []string, now func() time.Time, logf func(string, ...any)) *studios {
	st := &studios{byHost: map[string]*tunnel{}, file: file, path: path, env: env, now: now, idle: studioIdle, logf: logf}
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
	var old []studioRec
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
	l := []studioRec{}
	for _, t := range st.byHost {
		if t.Pid > 0 {
			l = append(l, t.studioRec)
		}
	}
	b, _ := json.Marshal(l)
	if err := writeFileAtomic(st.file, b, 0o600); err != nil {
		st.logf("could not write %s: %v", st.file, err)
	}
}

type studioReq struct {
	Host string `json:"host"`
	App  string `json:"app"`
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

// POST /api/studio/open {host, app} -> {url, host, app}: a fresh one-time link to the server's
// studio, through the host's forward (started when there is none)
func (s *Server) studioOpen(w http.ResponseWriter, r *http.Request) {
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
	url, e := s.studios.open(q.Host, q.App)
	if e != nil {
		writeErr(w, e)
		return
	}
	writeJSON(w, 200, map[string]any{"url": url, "host": q.Host, "app": q.App})
}

// open: the host's forward (started by this first click), then one code for app
func (st *studios) open(host, app string) (string, *apiError) {
	for try := 0; try < 2; try++ {
		st.mu.Lock()
		t := st.byHost[host]
		if t == nil {
			if len(st.byHost) >= studioMax {
				st.mu.Unlock()
				return "", &apiError{Status: 503, Code: "busy", Msg: "the dashboard has 4 database forwards open already; they close after 30 min unused"}
			}
			t = &tunnel{studioRec: studioRec{Host: host, App: app, Since: st.now()}}
			st.byHost[host] = t
		}
		st.mu.Unlock()
		t.mu.Lock()
		if t.dead {
			t.mu.Unlock()
			continue
		}
		url, e, retry := st.click(t, app)
		t.mu.Unlock()
		if retry && try == 0 {
			continue
		}
		return url, e
	}
	return "", &apiError{Status: 502, Code: "cli", Msg: "the database forward on " + host + " ended; click again"}
}

// click (t.mu held): start the child when this is the first click, else ask it for a code.
// retry: the forward was found ended, a new one may be started.
func (st *studios) click(t *tunnel, app string) (string, *apiError, bool) {
	if !t.up {
		url, e := st.start(t, argvStudio(t.Host, t.App), app)
		if e != nil {
			st.drop(t)
			return "", e, false
		}
		st.armIdle(t)
		return url, nil, false
	}
	select {
	case <-t.done:
		return "", nil, true
	default:
	}
	for len(t.lines) > 0 { // (a late line of an earlier timed-out ask)
		<-t.lines
	}
	if _, err := t.stdin.WriteString("mint " + app + "\n"); err != nil {
		return "", nil, true
	}
	timer := time.NewTimer(studioReadyWait)
	defer timer.Stop()
	select {
	case l := <-t.lines:
		if l.Err != "" {
			return "", &apiError{Status: 502, Code: "cli", Msg: l.Err}, false
		}
		st.armIdle(t)
		return l.URL, nil, false
	case <-t.done:
		return "", nil, true
	case <-timer.C:
		_ = syscall.Kill(-t.Pid, syscall.SIGTERM)
		return "", &apiError{Status: 504, Code: "timeout", Msg: "the studio did not answer within 45 s"}, false
	}
}

// drop: t is gone (failed start or ended)
func (st *studios) drop(t *tunnel) {
	st.mu.Lock()
	if st.byHost[t.Host] == t {
		delete(st.byHost, t.Host)
	}
	st.saveLocked()
	st.mu.Unlock()
	t.dead = true
}

// armIdle (t.mu held): the forward closes after st.idle without a click
func (st *studios) armIdle(t *tunnel) {
	st.mu.Lock()
	defer st.mu.Unlock()
	t.last = st.now()
	if t.timer != nil {
		t.timer.Reset(st.idle)
		return
	}
	t.timer = time.AfterFunc(st.idle, func() {
		st.mu.Lock()
		cur := st.byHost[t.Host] == t
		st.mu.Unlock()
		if cur {
			st.logf("closed the database forward to %s: no click for %s", t.Host, st.idle)
			st.stopChild(t)
		}
	})
}

// start: the child, until its first line (the link) or its end. t is reserved in byHost.
func (st *studios) start(t *tunnel, argv []string, app string) (string, *apiError) {
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
	t.lines = make(chan studioLine, 8)
	t.done = make(chan struct{})
	st.mu.Lock()
	t.Pid, t.stdin, t.up = pid, inW, true
	st.saveLocked()
	st.mu.Unlock()

	go func() { // the child's lines that carry a link or an error; the rest is read and dropped (the CLI must never block on it)
		defer outR.Close()
		sc := bufio.NewScanner(outR)
		for sc.Scan() {
			var m struct {
				URL   string `json:"url"`
				Error string `json:"error"`
			}
			if json.Unmarshal(sc.Bytes(), &m) != nil {
				continue
			}
			switch {
			case m.URL != "" && studioURLRe.MatchString(m.URL):
				select {
				case t.lines <- studioLine{URL: m.URL}:
				default:
				}
			case m.Error != "":
				select {
				case t.lines <- studioLine{Err: oneLineErr(m.Error)}:
				default:
				}
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
		if st.byHost[t.Host] == t {
			delete(st.byHost, t.Host)
		}
		if t.timer != nil {
			t.timer.Stop()
		}
		st.saveLocked()
		st.mu.Unlock()
		close(t.done)
	}()
	timer := time.NewTimer(studioReadyWait)
	defer timer.Stop()
	select {
	case l := <-t.lines:
		if l.Err != "" {
			return "", &apiError{Status: 502, Code: "cli", Msg: l.Err}
		}
		return l.URL, nil
	case <-t.done:
		msg := firstLine(errw.String())
		if msg == "" {
			msg = "tando db studio ended before the studio answered"
		}
		return "", &apiError{Status: 502, Code: "cli", Msg: msg}
	case <-timer.C:
		_ = syscall.Kill(-pid, syscall.SIGTERM)
		return "", &apiError{Status: 504, Code: "timeout", Msg: "the studio did not start within 45 s"}
	}
}

func oneLineErr(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

// stopChild: SIGTERM to the group (the CLI ends its forward, as Ctrl-C does), SIGKILL if it
// takes longer than studioStopWait; returns when it has ended
func (st *studios) stopChild(t *tunnel) {
	if t.Pid <= 0 || t.done == nil {
		return
	}
	_ = syscall.Kill(-t.Pid, syscall.SIGTERM)
	select {
	case <-t.done:
		return
	case <-time.After(studioStopWait):
	}
	_ = syscall.Kill(-t.Pid, syscall.SIGKILL)
	select {
	case <-t.done:
	case <-time.After(3 * time.Second):
	}
}

// closeAll: tando-dash stops: every child's group gets SIGTERM and its idle timer stops
func (st *studios) closeAll() {
	st.mu.Lock()
	defer st.mu.Unlock()
	for _, t := range st.byHost {
		if t.timer != nil {
			t.timer.Stop()
		}
		if t.Pid > 0 {
			_ = syscall.Kill(-t.Pid, syscall.SIGTERM)
		}
	}
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
