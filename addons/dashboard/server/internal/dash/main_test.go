package dash

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The fake tando CLI: this test binary, run again with FAKE_TANDO=1. What it does depends on the
// host name it is given (fault injection), so parallel tests need no shared mode:
//
//	ok*, a, b, c   a snapshot JSON (with unknown fields)   slow*   the same after 1.5 s
//	hang*          sleeps (and starts a grandchild that sleeps), pids in FAKE_TANDO_DIR
//	garbage*       not JSON          fail*   "ssh: ... refused" on stderr, exit 1
//	midkill*       half a JSON document, then SIGKILL itself     big*   4 MB of JSON
//
// Every run appends its argv to FAKE_TANDO_DIR/runs.log. Files in FAKE_TANDO_DIR change
// --version: version (its text), noop-sleep (a duration), no-snapshot (help snapshot fails).
func TestMain(m *testing.M) {
	switch os.Getenv("FAKE_TANDO") {
	case "1":
		os.Exit(fakeTando(os.Args[1:]))
	case "sleep":
		_ = os.WriteFile(os.Getenv("FAKE_PIDFILE"), []byte(strconv.Itoa(os.Getpid())), 0o600)
		time.Sleep(300 * time.Second)
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func fakeTando(args []string) int {
	dir := os.Getenv("FAKE_TANDO_DIR")
	if f, err := os.OpenFile(filepath.Join(dir, "runs.log"), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600); err == nil {
		fmt.Fprintln(f, strings.Join(args, " "))
		f.Close()
	}
	if len(args) == 1 && args[0] == "--version" {
		if b, err := os.ReadFile(filepath.Join(dir, "noop-sleep")); err == nil {
			d, _ := time.ParseDuration(strings.TrimSpace(string(b)))
			time.Sleep(d)
		}
		v := "tando 0.2.2"
		if b, err := os.ReadFile(filepath.Join(dir, "version")); err == nil {
			v = strings.TrimSpace(string(b))
		}
		fmt.Println(v)
		return 0
	}
	if len(args) == 2 && args[0] == "help" {
		if _, err := os.Stat(filepath.Join(dir, "no-snapshot")); err == nil {
			fmt.Fprintln(os.Stderr, `tando: unknown command "snapshot".`)
			return 2
		}
		fmt.Println("usage: tando snapshot --json [-H host]")
		return 0
	}
	host := ""
	for i, a := range args {
		if a == "-H" && i+1 < len(args) {
			host = args[i+1]
		}
	}
	if host == "" && len(args) >= 2 {
		host = args[len(args)-2] // doctor <host> --json, host status <host> --json
	}
	mode := strings.TrimRight(host, "0123456789")
	switch mode {
	case "slow":
		time.Sleep(1500 * time.Millisecond)
	case "hang":
		_ = os.WriteFile(filepath.Join(dir, host+".pid"), []byte(strconv.Itoa(os.Getpid())), 0o600)
		self, _ := os.Executable()
		c := exec.Command(self)
		c.Env = append(os.Environ(), "FAKE_TANDO=sleep", "FAKE_PIDFILE="+filepath.Join(dir, host+".gpid"))
		_ = c.Start()
		time.Sleep(300 * time.Second)
		return 0
	case "garbage":
		fmt.Println("<html>not json{")
		return 0
	case "fail":
		fmt.Fprintln(os.Stderr, "tando: ssh: connect to host "+host+" port 22: Connection refused")
		fmt.Fprintln(os.Stderr, "second line")
		return 1
	case "midkill":
		fmt.Print(`{"host":"` + host + `","status":{"apps":[`)
		_ = syscall.Kill(os.Getpid(), syscall.SIGKILL)
	case "big":
		fmt.Print(`{"pad":"` + strings.Repeat("x", 4<<20) + `"}`)
		return 0
	}
	if args[0] == "doctor" || args[0] == "host" {
		fmt.Printf(`{"host":%q,"checks":[{"name":"ssh","ok":true}]}`+"\n", host)
		return 0
	}
	fmt.Printf(`{"host":%q,"future_field":{"x":1},"status":{"apps":[{"app":"web","state":"running","link":"http://web.example.test","cpu":1.5},{"name":"api","state":"down"}],"alerts":[{"app":"api","check":"down","state":"firing"}]},"argv":%q}`+"\n",
		host, strings.Join(args, " "))
	return 0
}

// ---- test server ----

type env struct {
	t      *testing.T
	srv    *Server
	ts     *httptest.Server
	dir    string // ConfigDir
	fake   string // FAKE_TANDO_DIR
	port   int
	cookie *http.Cookie
	lim    *Limiter
}

// fakeExec: the real ExecRunner on the fake CLI
func fakeExec(t *testing.T, fakeDir string, maxOut int) (*ExecRunner, *Limiter) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	lim := NewLimiter(8, 3, 64)
	return &ExecRunner{Path: func() string { return self }, MaxOut: maxOut, Lim: lim,
		Env: []string{"FAKE_TANDO=1", "FAKE_TANDO_DIR=" + fakeDir}}, lim
}

func newEnv(t *testing.T, runner Runner, mod func(*Config)) *env {
	t.Helper()
	e := &env{t: t, dir: t.TempDir(), fake: t.TempDir()}
	if err := os.MkdirAll(filepath.Join(e.dir, "hosts"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, h := range []string{"a", "b", "c", "ok1", "slow1", "hang1", "garbage1", "fail1", "midkill1", "big1"} {
		os.WriteFile(filepath.Join(e.dir, "hosts", h), []byte("x"), 0o600)
	}
	if runner == nil {
		var r *ExecRunner
		r, e.lim = fakeExec(t, e.fake, 1<<20)
		runner = r
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	e.port = ln.Addr().(*net.TCPAddr).Port
	cfg := Config{Port: e.port, ConfigDir: e.dir, Runner: runner, Log: io.Discard, CtlKey: "ctl-key-for-tests"}
	if mod != nil {
		mod(&cfg)
	}
	e.srv, err = New(cfg, http.NotFoundHandler())
	if err != nil {
		t.Fatal(err)
	}
	e.ts = httptest.NewUnstartedServer(e.srv)
	e.ts.Listener = ln
	e.ts.Start()
	t.Cleanup(func() { e.ts.Close(); e.srv.Close(); e.srv.wg.Wait() })
	return e
}

var noRedirect = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }, Timeout: 30 * time.Second}

// login: a code for the cookie
func (e *env) login() {
	e.t.Helper()
	resp, err := noRedirect.Get(e.ts.URL + "/open?code=" + e.srv.NewCode())
	if err != nil {
		e.t.Fatal(err)
	}
	resp.Body.Close()
	for _, c := range resp.Cookies() {
		if c.Name == cookieName {
			e.cookie = c
		}
	}
	if resp.StatusCode != 303 || e.cookie == nil {
		e.t.Fatalf("login: %d, cookie %v", resp.StatusCode, e.cookie)
	}
}

type reqOpt func(*http.Request)

func hdr(k, v string) reqOpt { return func(r *http.Request) { r.Header.Set(k, v) } }

func (e *env) req(ctx context.Context, method, path string, body any, opts ...reqOpt) (int, map[string]any, http.Header) {
	e.t.Helper()
	var rd io.Reader
	if body != nil {
		switch b := body.(type) {
		case string:
			rd = strings.NewReader(b)
		default:
			j, _ := json.Marshal(b)
			rd = bytes.NewReader(j)
		}
	}
	if ctx == nil {
		ctx = context.Background()
	}
	r, _ := http.NewRequestWithContext(ctx, method, e.ts.URL+path, rd)
	if body != nil {
		r.Header.Set("Content-Type", "application/json")
	}
	if e.cookie != nil {
		r.AddCookie(e.cookie)
	}
	for _, o := range opts {
		o(r)
	}
	resp, err := noRedirect.Do(r)
	if err != nil {
		return -1, nil, nil
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	if m == nil {
		m = map[string]any{"_raw": string(b)}
	}
	return resp.StatusCode, m, resp.Header
}

func (e *env) get(path string, opts ...reqOpt) (int, map[string]any) {
	st, m, _ := e.req(nil, "GET", path, nil, opts...)
	return st, m
}

func (e *env) post(path string, body any, opts ...reqOpt) (int, map[string]any) {
	st, m, _ := e.req(nil, "POST", path, body, opts...)
	return st, m
}

func errCode(m map[string]any) string {
	if e, ok := m["error"].(map[string]any); ok {
		s, _ := e["code"].(string)
		return s
	}
	return ""
}

func (e *env) runs() []string {
	b, _ := os.ReadFile(filepath.Join(e.fake, "runs.log"))
	s := strings.TrimSpace(string(b))
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

// until: poll cond for up to d
func until(d time.Duration, cond func() bool) bool {
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		if cond() {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return cond()
}

// alive: the process exists and is not a zombie we could still see
func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	if err != nil {
		return false
	}
	out, _ := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(pid)).Output()
	st := strings.TrimSpace(string(out))
	return st != "" && !strings.HasPrefix(st, "Z")
}

func readPid(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}
