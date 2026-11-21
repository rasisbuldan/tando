package dash

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// fakeStudio: `tando db studio <app> -H <host> --json` of the fake CLI. Its pid goes to
// studio.pids, its TANDO_FROM to studio.from, every line of its stdin to studio-in-<pid>; it leaves
// a grandchild that holds its stdout (like ssh; pid in studio-gpid-<pid>), prints a line of noise,
// then the ready line (the code is "code<pid>"), and answers each "mint <app>" line with a fresh
// link ("code<pid>m<n>"; the app "nomint" gets the CLI's {"error"} line): the end of stdin ends it
// ("eof" in studio-end-<pid>), so does SIGTERM ("term"). Modes by host: fail* refuses as the CLI
// does when the server has no studio; hang* never answers.
func fakeStudio(dir, mode string, args []string) int {
	pid := os.Getpid()
	fakeAppend(filepath.Join(dir, "studio.pids"), strconv.Itoa(pid))
	fakeAppend(filepath.Join(dir, "studio.from"), os.Getenv("TANDO_FROM"))
	switch mode {
	case "fail":
		fmt.Fprintln(os.Stderr, "tando: the studio on fail1 gave no code (tando doctor fail1)")
		return 1
	case "hang":
		time.Sleep(300 * time.Second)
		return 0
	}
	end := func(why string) {
		_ = os.WriteFile(filepath.Join(dir, "studio-end-"+strconv.Itoa(pid)), []byte(why), 0o600)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM)
	go func() { <-sig; end("term"); os.Exit(143) }()
	self, _ := os.Executable()
	c := exec.Command(self)
	c.Stdout = os.Stdout
	c.Env = append(os.Environ(), "FAKE_TANDO=sleep", "FAKE_PIDFILE="+filepath.Join(dir, "studio-gpid-"+strconv.Itoa(pid)))
	_ = c.Start()
	fmt.Println("checking the studio on the server")
	app := args[2]
	fmt.Printf(`{"url":"http://127.0.0.1:47123/#c=code%d&app=%s","port":47123,"sid":"0123456789ab"}`+"\n", pid, app)
	sc := bufio.NewScanner(os.Stdin)
	n := 0
	for sc.Scan() {
		fakeAppend(filepath.Join(dir, "studio-in-"+strconv.Itoa(pid)), sc.Text())
		a, ok := strings.CutPrefix(sc.Text(), "mint ")
		if !ok {
			continue
		}
		if a == "nomint" {
			fmt.Println(`{"error":"the studio on a gave no code"}`)
			continue
		}
		n++
		fmt.Printf(`{"url":"http://127.0.0.1:47123/#c=code%dm%d&app=%s","port":47123,"sid":"0123456789ab"}`+"\n", pid, n, a)
	}
	end("eof")
	return 0
}

func studioPidsIn(dir string) []int {
	b, _ := os.ReadFile(filepath.Join(dir, "studio.pids"))
	var l []int
	for _, f := range strings.Fields(string(b)) {
		n, _ := strconv.Atoi(f)
		l = append(l, n)
	}
	return l
}

// studioGpid: the grandchild of a fake studio child (its pid file is written once it runs)
func studioGpid(fake string, pid int) int {
	f := filepath.Join(fake, "studio-gpid-"+strconv.Itoa(pid))
	until(5*time.Second, func() bool { return readPid(f) > 0 })
	return readPid(f)
}

func (e *env) studioOpen(host, app string) (int, map[string]any) {
	e.t.Helper()
	return e.post("/api/studio/open", map[string]any{"host": host, "app": app})
}

var testStudioURL = regexp.MustCompile(`^http://127\.0\.0\.1:47123/#c=code[0-9]+(m[0-9]+)?&app=[a-z0-9-]+$`)

func TestStudioAllowlist(t *testing.T) {
	if _, err := Allowed(argvStudio("a", "web")); err != nil {
		t.Fatal(err)
	}
	for _, bad := range [][]string{
		{"db", "studio", "web", "-H", "a"},                     // no --json: it would open a browser and print a box
		{"db", "studio", "web", "-H", "a", "--json", "--stop"}, // --stop ends the terminal's studios too
		{"db", "studio", "web", "-H", "a", "--json", "--idle", "240"},
		{"db", "studio", "-H", "a", "--json"}, // no app: the CLI would ask
		{"db", "psql", "web", "-H", "a"},
	} {
		if _, err := Allowed(bad); err == nil {
			t.Errorf("allowed %v", bad)
		}
	}
}

// the first click starts ONE child per host (no confirmation, no key); every later click on the
// host, for any app, is a "mint" line on that child's stdin: a fresh link, no second child
func TestStudioOneTunnelPerHost(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	if n := len(studioPidsIn(e.fake)); n != 0 {
		t.Fatalf("%d children before a click", n)
	}
	st, m := e.studioOpen("a", "web")
	url1, _ := m["url"].(string)
	if st != 200 || !testStudioURL.MatchString(url1) || !strings.HasSuffix(url1, "&app=web") {
		t.Fatalf("first click: %d %v", st, m)
	}
	if b, _ := os.ReadFile(filepath.Join(e.fake, "studio.from")); strings.TrimSpace(string(b)) != "dashboard" {
		t.Errorf("TANDO_FROM %q", b)
	}
	st, m = e.studioOpen("a", "api") // another app, same host
	url2, _ := m["url"].(string)
	if st != 200 || !testStudioURL.MatchString(url2) || !strings.HasSuffix(url2, "&app=api") || url2 == url1 {
		t.Fatalf("second click: %d %v", st, m)
	}
	st, m = e.studioOpen("a", "web") // the same app again: a fresh code, never the old link
	url3, _ := m["url"].(string)
	if st != 200 || url3 == url1 || url3 == url2 {
		t.Fatalf("third click: %d %v (%s %s)", st, m, url1, url2)
	}
	pids := studioPidsIn(e.fake)
	if len(pids) != 1 {
		t.Fatalf("children after three clicks: %v", pids)
	}
	if b, _ := os.ReadFile(filepath.Join(e.fake, "studio-in-"+strconv.Itoa(pids[0]))); strings.TrimSpace(string(b)) != "mint api\nmint web" {
		t.Fatalf("stdin lines %q", b)
	}
	// another host has its own
	if st, m := e.studioOpen("b", "api"); st != 200 {
		t.Fatalf("host b: %d %v", st, m)
	}
	if len(studioPidsIn(e.fake)) != 2 {
		t.Fatalf("children %v", studioPidsIn(e.fake))
	}
	// the pid file has both (0600) and never a link
	fi, err := os.Stat(filepath.Join(e.dir, "cache", "dash-studios.json"))
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("pid file: %v %v", fi, err)
	}
	if b, _ := os.ReadFile(filepath.Join(e.dir, "cache", "dash-studios.json")); strings.Contains(string(b), "#c=") || strings.Count(string(b), `"pid"`) != 2 {
		t.Fatalf("pid file %s", b)
	}
	// no confirm token, no Idempotency-Key and no stop endpoint any more
	if st, _ := e.post("/api/studio/stop", map[string]any{"host": "a", "app": "web"}); st != 404 {
		t.Fatalf("stop endpoint: %d", st)
	}
	if st, m := e.post("/api/confirm", map[string]any{"action": "studio", "host": "a", "app": "web"}); st == 200 {
		t.Fatalf("a studio confirm token was issued: %v", m)
	}
}

// concurrent first clicks on one host start one child, and each gets its own code
func TestStudioConcurrentClicks(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	var wg sync.WaitGroup
	urls := make([]string, 6)
	for i := range urls {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if st, m := e.studioOpen("a", "web"); st == 200 {
				urls[i], _ = m["url"].(string)
			}
		}(i)
	}
	wg.Wait()
	seen := map[string]bool{}
	for _, u := range urls {
		if !testStudioURL.MatchString(u) || seen[u] {
			t.Fatalf("urls %v", urls)
		}
		seen[u] = true
	}
	if n := len(studioPidsIn(e.fake)); n != 1 {
		t.Fatalf("%d children", n)
	}
}

// after 30 min (here: a short idle) without a click the forward closes: the group is killed, a
// click after that starts a new one; a click in between keeps it open
func TestStudioIdleCloses(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.srv.studios.idle = 700 * time.Millisecond
	e.login()
	if st, m := e.studioOpen("a", "web"); st != 200 {
		t.Fatalf("open: %d %v", st, m)
	}
	pid := studioPidsIn(e.fake)[0]
	gpid := studioGpid(e.fake, pid)
	for i := 0; i < 3; i++ { // clicks keep it open past the idle time
		time.Sleep(400 * time.Millisecond)
		if st, m := e.studioOpen("a", "web"); st != 200 {
			t.Fatalf("click %d: %d %v", i, st, m)
		}
	}
	if len(studioPidsIn(e.fake)) != 1 || !alive(pid) {
		t.Fatal("closed while clicks kept coming")
	}
	if !until(8*time.Second, func() bool { return !alive(pid) && !alive(gpid) }) {
		t.Fatal("not closed after the idle time")
	}
	if b, _ := os.ReadFile(filepath.Join(e.fake, "studio-end-"+strconv.Itoa(pid))); string(b) != "term" {
		t.Errorf("ended by %q", b)
	}
	if !until(5*time.Second, func() bool {
		e.srv.studios.mu.Lock()
		defer e.srv.studios.mu.Unlock()
		return len(e.srv.studios.byHost) == 0
	}) {
		t.Fatal("still listed")
	}
	if st, m := e.studioOpen("a", "web"); st != 200 || len(studioPidsIn(e.fake)) != 2 {
		t.Fatalf("after close: %d %v, children %v", st, m, studioPidsIn(e.fake))
	}
}

// a child that ends on its own (a lost ssh, a sleep) is noticed: the next click starts a new one
func TestStudioChildExitNoticed(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	if st, m := e.studioOpen("a", "web"); st != 200 {
		t.Fatalf("open: %d %v", st, m)
	}
	pid := studioPidsIn(e.fake)[0]
	gpid := studioGpid(e.fake, pid)
	_ = syscall.Kill(pid, syscall.SIGKILL)
	if !until(5*time.Second, func() bool { return !alive(gpid) }) {
		t.Fatal("the grandchild was left")
	}
	if st, m := e.studioOpen("a", "web"); st != 200 || len(studioPidsIn(e.fake)) != 2 {
		t.Fatalf("after the end: %d %v, children %v", st, m, studioPidsIn(e.fake))
	}
}

// the CLI's refusal is the answer's message; nothing stays reserved. A mint the CLI refuses is
// an error line, and the forward stays for the next click.
func TestStudioCLIRefusal(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	st, m := e.studioOpen("fail1", "web")
	if st != 502 || !strings.HasPrefix(m["error"].(map[string]any)["message"].(string), "the studio on fail1 gave no code") {
		t.Fatalf("%d %v", st, m)
	}
	e.srv.studios.mu.Lock()
	n := len(e.srv.studios.byHost)
	e.srv.studios.mu.Unlock()
	if n != 0 {
		t.Fatalf("still reserved: %d", n)
	}
	if st, m := e.studioOpen("a", "web"); st != 200 {
		t.Fatalf("open: %d %v", st, m)
	}
	before := len(studioPidsIn(e.fake)) // (the refused start's child counts)
	st, m = e.studioOpen("a", "nomint")
	if st != 502 || !strings.Contains(m["error"].(map[string]any)["message"].(string), "gave no code") {
		t.Fatalf("refused mint: %d %v", st, m)
	}
	if st, m := e.studioOpen("a", "web"); st != 200 || len(studioPidsIn(e.fake)) != before {
		t.Fatalf("after a refused mint: %d %v, children %v", st, m, studioPidsIn(e.fake))
	}
}

// bad names never reach the child; an unknown host is refused
func TestStudioBadRequests(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	for _, q := range []map[string]any{{"host": "a", "app": "web; rm"}, {"host": "a", "app": "A"}, {"host": "a b", "app": "web"}, {"host": "a"}} {
		if st, _ := e.post("/api/studio/open", q); st != 400 {
			t.Errorf("%v: %d", q, st)
		}
	}
	if st, _ := e.studioOpen("nohost", "web"); st != 404 {
		t.Errorf("unknown host: %d", st)
	}
	if len(studioPidsIn(e.fake)) != 0 {
		t.Fatal("a refused click started a child")
	}
}

// tando-dash stopping leaves no child: Close stops every group
func TestStudioCloseLeavesNone(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	for _, h := range []string{"a", "b"} {
		if st, m := e.studioOpen(h, "web"); st != 200 {
			t.Fatalf("open: %d %v", st, m)
		}
	}
	var all []int
	for _, p := range studioPidsIn(e.fake) {
		all = append(all, p, studioGpid(e.fake, p))
	}
	e.srv.Close()
	e.srv.WaitStreams(10 * time.Second)
	for _, p := range all {
		if p == 0 || alive(p) {
			t.Fatalf("left running: %d of %v", p, all)
		}
	}
}

// a tando-dash that crashed left a child: the next one stops it (its command line checked),
// and leaves alone a pid whose command line is something else
func TestStudioLeftoverCleaned(t *testing.T) {
	dir, fake := t.TempDir(), t.TempDir()
	self, _ := os.Executable()
	start := func(env string, args ...string) *exec.Cmd {
		c := exec.Command(self, args...)
		c.Env = append(os.Environ(), env, "FAKE_TANDO_DIR="+fake, "FAKE_PIDFILE="+filepath.Join(fake, "decoy.pid"))
		c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		c.Stdout = io.Discard
		if _, err := c.StdinPipe(); err != nil { // held open: the stdin EOF is not what ends it
			t.Fatal(err)
		}
		if err := c.Start(); err != nil {
			t.Fatal(err)
		}
		go c.Wait()
		return c
	}
	child := start("FAKE_TANDO=1", argvStudio("a", "web")...)
	decoy := start("FAKE_TANDO=sleep")
	t.Cleanup(func() {
		syscall.Kill(-child.Process.Pid, syscall.SIGKILL)
		syscall.Kill(-decoy.Process.Pid, syscall.SIGKILL)
	})
	if !until(5*time.Second, func() bool { return readPid(filepath.Join(fake, "studio-gpid-"+strconv.Itoa(child.Process.Pid))) > 0 }) {
		t.Fatal("the leftover did not start")
	}
	gpid := readPid(filepath.Join(fake, "studio-gpid-"+strconv.Itoa(child.Process.Pid)))
	l, _ := json.Marshal([]studioRec{{Host: "a", App: "web", Pid: child.Process.Pid}, {Host: "a", App: "web", Pid: decoy.Process.Pid}})
	os.MkdirAll(filepath.Join(dir, "cache"), 0o700)
	os.WriteFile(filepath.Join(dir, "cache", "dash-studios.json"), l, 0o600)
	r, _ := fakeExec(t, fake, 1<<20)
	srv, err := New(Config{Port: 1, ConfigDir: dir, Runner: r, Log: io.Discard}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	if !until(5*time.Second, func() bool { return !alive(child.Process.Pid) && !alive(gpid) }) {
		t.Fatal("the leftover studio is still running")
	}
	if !alive(decoy.Process.Pid) {
		t.Fatal("a process that is not a studio was killed")
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "cache", "dash-studios.json")); strings.TrimSpace(string(b)) != "[]" {
		t.Fatalf("pid file %q", b)
	}
}
