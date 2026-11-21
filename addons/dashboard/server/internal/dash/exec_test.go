package dash

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func stringsReader(s string) *strings.Reader { return strings.NewReader(s) }

// faults of the fake CLI, through the real exec runner and the API
func TestFaults(t *testing.T) {
	e := newEnv(t, nil, func(c *Config) { c.ReadTimeout = 3 * time.Second })
	e.login()
	cases := []struct {
		host, code string
		status     int
	}{
		{"ok1", "", 200},
		{"slow1", "", 200},
		{"garbage1", "bad_output", 502},
		{"fail1", "cli", 502},
		{"midkill1", "cli", 502},
		{"big1", "too_large", 502},
	}
	for _, c := range cases {
		st, m := e.get("/api/snapshot?host=" + c.host)
		if st != c.status || errCode(m) != c.code {
			t.Errorf("%s: %d %v", c.host, st, m)
		}
		if c.code != "" && m["next_poll_s"] == nil {
			t.Errorf("%s: no poll hint on an error", c.host)
		}
	}
	// the stderr's first line is the message
	_, m := e.get("/api/snapshot?host=fail1")
	if msg := m["error"].(map[string]any)["message"].(string); msg != "ssh: connect to host fail1 port 22: Connection refused" {
		t.Errorf("message %q", msg)
	}
	// the fake saw exactly the argv shapes of the allowlist
	for _, l := range e.runs() {
		if _, err := Allowed(strings.Fields(l)); err != nil {
			t.Errorf("ran %q: %v", l, err)
		}
	}
}

// a hanging child (and its grandchild) is killed at the timeout: nothing is left
func TestChildKilledOnTimeout(t *testing.T) {
	e := newEnv(t, nil, func(c *Config) { c.ReadTimeout = 1 * time.Second })
	e.login()
	t0 := time.Now()
	st, m := e.get("/api/snapshot?host=hang1")
	if st != 504 || errCode(m) != "timeout" || time.Since(t0) > 6*time.Second {
		t.Fatalf("%d %v after %v", st, m, time.Since(t0))
	}
	checkGone(t, e.fake, "hang1")
}

// a client that goes away kills its child (it was the only waiter)
func TestChildKilledOnDisconnect(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { e.req(ctx, "GET", "/api/snapshot?host=hang1", nil); close(done) }()
	if !until(5*time.Second, func() bool {
		return readPid(filepath.Join(e.fake, "hang1.pid")) > 0 && readPid(filepath.Join(e.fake, "hang1.gpid")) > 0
	}) {
		t.Fatal("child did not start")
	}
	cancel()
	<-done
	checkGone(t, e.fake, "hang1")
	if !until(3*time.Second, func() bool { return e.lim.Running() == 0 }) {
		t.Fatal("slot not given back")
	}
}

func checkGone(t *testing.T, dir, host string) {
	t.Helper()
	pid, gpid := readPid(filepath.Join(dir, host+".pid")), readPid(filepath.Join(dir, host+".gpid"))
	if pid == 0 {
		t.Fatal("no pid recorded")
	}
	if !until(5*time.Second, func() bool { return !alive(pid) && (gpid == 0 || !alive(gpid)) }) {
		t.Fatalf("left running: child %d alive=%v, grandchild %d alive=%v", pid, alive(pid), gpid, alive(gpid))
	}
	if gpid == 0 {
		t.Log("grandchild had not started when the group was killed")
	}
}

// many requests at once: children stay within the caps, the rest wait or get 503 busy, and
// nothing is left afterwards
func TestBoundedUnderLoad(t *testing.T) {
	self, _ := os.Executable()
	e := newEnv(t, nil, func(c *Config) { c.MaxInflight = 40; c.ReadTimeout = 10 * time.Second })
	lim := NewLimiter(4, 2, 6)
	e.srv.cfg.Runner = &ExecRunner{Path: func() string { return self }, MaxOut: 1 << 20, Lim: lim,
		Env: []string{"FAKE_TANDO=1", "FAKE_TANDO_DIR=" + e.fake}}
	for i := 0; i < 30; i++ {
		os.WriteFile(filepath.Join(e.dir, "hosts", "slow"+itoa(10+i)), []byte("x"), 0o600)
	}
	e.login()
	var mu sync.Mutex
	maxRun := 0
	stop := make(chan struct{})
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
			}
			if n := lim.Running(); n > 0 {
				mu.Lock()
				if n > maxRun {
					maxRun = n
				}
				mu.Unlock()
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()
	var wg sync.WaitGroup
	codes := make([]int, 60)
	for i := range codes {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes[i], _ = e.get("/api/snapshot?host=slow" + itoa(10+i%30))
		}()
	}
	wg.Wait()
	close(stop)
	ok, busy := 0, 0
	for _, c := range codes {
		switch c {
		case 200:
			ok++
		case 503:
			busy++
		default:
			t.Errorf("status %d", c)
		}
	}
	if maxRun > 4 {
		t.Fatalf("%d children at once (cap 4)", maxRun)
	}
	if ok == 0 || busy == 0 {
		t.Fatalf("ok %d busy %d: expected both", ok, busy)
	}
	if lim.Running() != 0 || e.srv.inflight.Load() != 0 {
		t.Fatalf("left: %d children, %d requests", lim.Running(), e.srv.inflight.Load())
	}
	// per host: at most 2 at once for one host
	l2 := NewLimiter(10, 2, 10)
	r1, _ := l2.Acquire(context.Background(), "h")
	r2, _ := l2.Acquire(context.Background(), "h")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if _, err := l2.Acquire(ctx, "h"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("third slot for one host")
	}
	if r3, err := l2.Acquire(context.Background(), "other"); err != nil {
		t.Fatal("other host blocked")
	} else {
		r3()
	}
	r1()
	r2()
}

func TestVersionGuard(t *testing.T) {
	fake := t.TempDir()
	x, _ := fakeExec(t, fake, 1<<20)
	stamp := "v1"
	var mu sync.Mutex
	g := &Guard{Min: "0.2.2", Run: func(ctx context.Context, argv []string) (Result, error) { return x.Run(ctx, Req{Argv: argv}) },
		Stamp: func() string { mu.Lock(); defer mu.Unlock(); return stamp }}
	if err := g.Check(context.Background()); err != nil || g.Version() != "0.2.2" {
		t.Fatalf("0.2.2: %v %q", err, g.Version())
	}
	// cached while the file does not change
	os.WriteFile(filepath.Join(fake, "version"), []byte("tando 0.1.9"), 0o600)
	if err := g.Check(context.Background()); err != nil {
		t.Fatal("re-checked without a change")
	}
	// the CLI changed on disk: checked again, refused
	mu.Lock()
	stamp = "v2"
	mu.Unlock()
	err := g.Check(context.Background())
	if err == nil || !strings.HasPrefix(err.Error(), "update tando:") || !strings.Contains(err.Error(), "0.1.9") {
		t.Fatalf("old: %v", err)
	}
	// new enough but no snapshot
	os.WriteFile(filepath.Join(fake, "version"), []byte("tando 0.3.0"), 0o600)
	os.WriteFile(filepath.Join(fake, "no-snapshot"), nil, 0o600)
	mu.Lock()
	stamp = "v3"
	mu.Unlock()
	if err := g.Check(context.Background()); err == nil || !strings.Contains(err.Error(), "snapshot") {
		t.Fatalf("no snapshot: %v", err)
	}
	// garbage version
	os.Remove(filepath.Join(fake, "no-snapshot"))
	os.WriteFile(filepath.Join(fake, "version"), []byte("hello"), 0o600)
	mu.Lock()
	stamp = "v4"
	mu.Unlock()
	if err := g.Check(context.Background()); err == nil {
		t.Fatal("garbage version accepted")
	}
	for _, c := range [][2]string{{"0.2.1", "0.2.2"}, {"0.9.9", "0.10.0"}, {"1.0.0", "1.0.1"}} {
		if !older(c[0], c[1]) || older(c[1], c[0]) {
			t.Errorf("older %v", c)
		}
	}

	// through the API: 503 update_tando, and fine again after an upgrade
	os.WriteFile(filepath.Join(fake, "version"), []byte("tando 0.1.0"), 0o600)
	mu.Lock()
	stamp = "v5"
	mu.Unlock()
	e := newEnv(t, FuncRunner(func(ctx context.Context, q Req) (Result, error) { return Result{Stdout: []byte(`{}`)}, nil }),
		func(c *Config) { c.Version = g })
	e.login()
	if st, m := e.get("/api/snapshot?host=a"); st != 503 || errCode(m) != "update_tando" {
		t.Fatalf("old CLI: %d %v", st, m)
	}
	os.WriteFile(filepath.Join(fake, "version"), []byte("tando 0.3.0"), 0o600)
	mu.Lock()
	stamp = "v6"
	mu.Unlock()
	if st, m := e.get("/api/snapshot?host=a"); st != 200 {
		t.Fatalf("after upgrade: %d %v", st, m)
	}
	// FileStamp changes with the file
	p := filepath.Join(t.TempDir(), "tando")
	os.WriteFile(p, []byte("a"), 0o700)
	s1 := FileStamp(p)
	os.WriteFile(p, []byte("bb"), 0o700)
	if s1 == "" || s1 == FileStamp(p) {
		t.Fatal("FileStamp")
	}
}

// graceful shutdown: reads' children killed, a write's child left running
func TestShutdownLeavesWrites(t *testing.T) {
	e := newEnv(t, nil, nil)
	os.WriteFile(filepath.Join(e.fake, "noop-sleep"), []byte("2s"), 0o600)
	e.login()
	b := map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": e.confirmTok("noop", "a", "web")}
	if st, m := e.act("shut-key-0001", b); st != 202 {
		t.Fatal(st, m)
	}
	var pid int
	if !until(3*time.Second, func() bool { pid = e.srv.idem.lookup("shut-key-0001").Pid; return pid > 0 }) {
		t.Fatal("no pid")
	}
	go e.req(nil, "GET", "/api/snapshot?host=hang1", nil)
	until(5*time.Second, func() bool { return readPid(filepath.Join(e.fake, "hang1.pid")) > 0 })
	e.srv.Close()
	checkGone(t, e.fake, "hang1")
	if !alive(pid) {
		t.Fatal("the write's child was killed by shutdown")
	}
	// it ends on its own; its record says so
	if !until(5*time.Second, func() bool { return e.srv.idem.lookup("shut-key-0001").Status == "done" }) {
		t.Fatal("write did not finish")
	}
	// a restart while a write ran: the record is handed over to be reattached (TestReattach)
	st, _ := openIdem(filepath.Join(e.dir, "x.json"), filepath.Join(e.dir, "ops"), 10, time.Hour, time.Now)
	r, _, _ := st.begin(context.Background(), "run-key-00001", "h", "", writeReq{Action: "noop", Host: "a", App: "web"})
	st.start(r, nil)
	st2, _ := openIdem(filepath.Join(e.dir, "x.json"), filepath.Join(e.dir, "ops"), 10, time.Hour, time.Now)
	if got := st2.lookup("run-key-00001"); got == nil || got.Status != "running" || len(st2.reattach) != 1 {
		t.Fatalf("after restart: %+v", got)
	}
	_ = syscall.Getpid
}

func TestLockFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "cfg", "dash.lock")
	l, other, err := AcquireLock(p)
	if err != nil || other != nil {
		t.Fatal(err, other)
	}
	if err := l.Write(LockInfo{Pid: 1, Port: 4567, URL: "http://127.0.0.1:4567/", Key: "k"}); err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(p)
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode())
	}
	// flock is per open file description: a second open in this process is refused like
	// another process would be
	l2, other, err := AcquireLock(p)
	if err != nil || l2 != nil || other == nil || other.Port != 4567 || other.Key != "k" {
		t.Fatalf("second: %v %v %v", l2, other, err)
	}
	l.Release()
	l3, other, err := AcquireLock(p)
	if err != nil || l3 == nil || other != nil {
		t.Fatalf("after release: %v %v", other, err)
	}
	l3.Release()
}
