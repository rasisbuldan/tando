package dash

import (
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
	"syscall"
	"testing"
	"time"
)

// fakeStudio: `tando db studio <app> -H <host> --json` of the fake CLI. Its pid goes to
// studio.pids and its TANDO_FROM to studio.from; it leaves a grandchild that holds its stdout
// (like ssh; pid in studio-gpid-<pid>), prints a line of noise, then the ready line, and waits:
// the end of stdin ends it ("eof" in studio-end-<pid>), so does SIGTERM ("term"). Modes by
// host: fail* refuses as the CLI does when the server has 2 studios open; hang* never answers.
func fakeStudio(dir, mode string, args []string) int {
	pid := os.Getpid()
	fakeAppend(filepath.Join(dir, "studio.pids"), strconv.Itoa(pid))
	fakeAppend(filepath.Join(dir, "studio.from"), os.Getenv("TANDO_FROM"))
	switch mode {
	case "fail":
		fmt.Fprintln(os.Stderr, "tando: 2 studios are open on fail1 already (shop (admin), other (admin)): stop one first")
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
	fmt.Printf(`{"url":"http://127.0.0.1:47123/#c=code%d","port":47123,"sid":"0123456789ab"}`+"\n", pid)
	_, _ = io.Copy(io.Discard, os.Stdin)
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

func (e *env) studioToken(action, host, app string) string {
	e.t.Helper()
	st, m := e.post("/api/confirm", map[string]any{"action": action, "host": host, "app": app})
	tok, _ := m["token"].(string)
	if st != 200 || tok == "" {
		e.t.Fatalf("confirm: %d %v", st, m)
	}
	return tok
}

func (e *env) studioOpen(key, host, app, tok string) (int, map[string]any) {
	e.t.Helper()
	return e.post("/api/studio/open", map[string]any{"host": host, "app": app, "confirm": tok}, hdr("Idempotency-Key", key))
}

var testStudioURL = regexp.MustCompile(`^http://127\.0\.0\.1:47123/#c=code[0-9]+$`)

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

// open: a confirm token for exactly this, an Idempotency-Key; the same key again: the same link
// and no second child; another app on the host: 409 naming the one open; Stop ends the group
func TestStudioOpen(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	if st, m := e.studioOpen("key-studio-0", "a", "web", ""); st != 403 || errCode(m) != "confirm" {
		t.Fatalf("no token: %d %v", st, m)
	}
	if st, m := e.studioOpen("key-studio-0", "a", "web", e.studioToken("restart", "a", "web")); st != 403 {
		t.Fatalf("a restart's token: %d %v", st, m)
	}
	if st, m := e.post("/api/studio/open", map[string]any{"host": "a", "app": "web", "confirm": e.studioToken("studio", "a", "web")}); st != 400 || errCode(m) != "idempotency_key" {
		t.Fatalf("no key: %d %v", st, m)
	}
	if n := len(studioPidsIn(e.fake)); n != 0 {
		t.Fatalf("%d children before a confirmed open", n)
	}
	st, m := e.studioOpen("key-studio-1", "a", "web", e.studioToken("studio", "a", "web"))
	url, _ := m["url"].(string)
	if st != 200 || !testStudioURL.MatchString(url) {
		t.Fatalf("open: %d %v", st, m)
	}
	if b, _ := os.ReadFile(filepath.Join(e.fake, "studio.from")); strings.TrimSpace(string(b)) != "dashboard" {
		t.Errorf("TANDO_FROM %q", b)
	}
	// the same key: the same answer, nothing started (no token needed: it is a replay)
	st, m = e.studioOpen("key-studio-1", "a", "web", "")
	if st != 200 || m["url"] != url || m["replay"] != true || len(studioPidsIn(e.fake)) != 1 {
		t.Fatalf("replay: %d %v, children %v", st, m, studioPidsIn(e.fake))
	}
	if st, m := e.studioOpen("key-studio-1", "a", "api", ""); st != 422 {
		t.Fatalf("key reused: %d %v", st, m)
	}
	// one per host: another app (and the same app again) is refused with what is open
	st, m = e.studioOpen("key-studio-2", "a", "api", e.studioToken("studio", "a", "api"))
	if st != 409 || errCode(m) != "studio_open" || m["error"].(map[string]any)["running"].(map[string]any)["app"] != "web" {
		t.Fatalf("second on the host: %d %v", st, m)
	}
	if len(studioPidsIn(e.fake)) != 1 {
		t.Fatal("a refused open started a child")
	}
	// another host has its own
	if st, m := e.studioOpen("key-studio-3", "b", "api", e.studioToken("studio", "b", "api")); st != 200 {
		t.Fatalf("host b: %d %v", st, m)
	}
	if l := e.srv.studios.list(); len(l) != 2 || l[0]["app"] != "web" || l[0]["state"] != "open" || l[1]["app"] != "api" {
		t.Fatalf("list %v", l)
	}
	// the pid file has both (0600)
	fi, err := os.Stat(filepath.Join(e.dir, "cache", "dash-studios.json"))
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("pid file: %v %v", fi, err)
	}
	if b, _ := os.ReadFile(filepath.Join(e.dir, "cache", "dash-studios.json")); strings.Contains(string(b), "#c=") {
		t.Fatal("the link was written to disk")
	}
	// Stop: SIGTERM to the group; the child and its grandchild are gone when it answers
	pid := studioPidsIn(e.fake)[0]
	gpid := studioGpid(e.fake, pid)
	st, m = e.post("/api/studio/stop", map[string]any{"host": "a", "app": "web"})
	if st != 200 || m["stopped"] != true {
		t.Fatalf("stop: %d %v", st, m)
	}
	if alive(pid) || alive(gpid) || gpid == 0 {
		t.Fatalf("after Stop: pid %d alive %v, grandchild %d alive %v", pid, alive(pid), gpid, alive(gpid))
	}
	if b, _ := os.ReadFile(filepath.Join(e.fake, "studio-end-"+strconv.Itoa(pid))); string(b) != "term" {
		t.Errorf("ended by %q", b)
	}
	if l := e.srv.studios.list(); len(l) != 1 || l[0]["host"] != "b" {
		t.Fatalf("after stop: %v", l)
	}
	// the host is free again
	if st, m := e.studioOpen("key-studio-4", "a", "api", e.studioToken("studio", "a", "api")); st != 200 {
		t.Fatalf("after stop: %d %v", st, m)
	}
}

// a child that ends on its own (Stop in the page, idle, a lost heartbeat) is noticed: the entry
// closes, what it left in its group is killed, the overview says so
func TestStudioChildExitNoticed(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	if st, m := e.studioOpen("key-studio-1", "a", "web", e.studioToken("studio", "a", "web")); st != 200 {
		t.Fatalf("open: %d %v", st, m)
	}
	ents, _ := os.ReadDir(filepath.Join(e.dir, "hosts"))
	for _, f := range ents {
		if f.Name() != "a" {
			os.Remove(filepath.Join(e.dir, "hosts", f.Name()))
		}
	}
	_, m := e.get("/api/overview")
	if l, _ := m["studios"].([]any); len(l) != 1 || l[0].(map[string]any)["app"] != "web" {
		t.Fatalf("overview studios: %v", m["studios"])
	}
	pid := studioPidsIn(e.fake)[0]
	gpid := studioGpid(e.fake, pid)
	_ = syscall.Kill(pid, syscall.SIGKILL)
	if !until(5*time.Second, func() bool { return len(e.srv.studios.list()) == 0 }) {
		t.Fatal("the child's end was not noticed")
	}
	if !until(5*time.Second, func() bool { return !alive(gpid) }) {
		t.Fatal("the grandchild was left")
	}
	_, m = e.get("/api/overview")
	if l, _ := m["studios"].([]any); len(l) != 0 {
		t.Fatalf("overview studios after the end: %v", m["studios"])
	}
}

// the CLI's refusal (2 open on the server) is the answer's message; nothing stays reserved
func TestStudioCLIRefusal(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	st, m := e.studioOpen("key-studio-1", "fail1", "web", e.studioToken("studio", "fail1", "web"))
	if st != 502 || !strings.HasPrefix(m["error"].(map[string]any)["message"].(string), "2 studios are open on fail1 already") {
		t.Fatalf("%d %v", st, m)
	}
	if l := e.srv.studios.list(); len(l) != 0 {
		t.Fatalf("still reserved: %v", l)
	}
}

// tando-dash stopping leaves no child: Close stops every group
func TestStudioCloseLeavesNone(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	for i, h := range []string{"a", "b"} {
		if st, m := e.studioOpen(fmt.Sprintf("key-studio-%d", i), h, "web", e.studioToken("studio", h, "web")); st != 200 {
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
	l, _ := json.Marshal([]studioChild{{Host: "a", App: "web", Pid: child.Process.Pid}, {Host: "a", App: "web", Pid: decoy.Process.Pid}})
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
