package dash

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ---- an SSE viewer ----

type sseEv struct {
	name, id, data string
}

type viewer struct {
	t      *testing.T
	cancel context.CancelFunc
	mu     sync.Mutex
	evs    []sseEv
	hb     int
	closed chan struct{}
}

// watch: GET /api/logs/stream?<q> read by a goroutine into v.evs until the server ends it or
// v.close()
func (e *env) watch(q string, hdrs ...reqOpt) *viewer {
	e.t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	v := &viewer{t: e.t, cancel: cancel, closed: make(chan struct{})}
	r, _ := http.NewRequestWithContext(ctx, "GET", e.ts.URL+"/api/logs/stream?"+q, nil)
	r.AddCookie(e.cookie)
	for _, o := range hdrs {
		o(r)
	}
	resp, err := (&http.Client{}).Do(r)
	if err != nil {
		e.t.Fatal(err)
	}
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		e.t.Fatalf("stream %s: %d %s", q, resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	go func() {
		defer close(v.closed)
		defer resp.Body.Close()
		sc := bufio.NewScanner(resp.Body)
		sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
		var cur sseEv
		for sc.Scan() {
			l := sc.Text()
			switch {
			case l == "":
				if cur.name != "" {
					v.mu.Lock()
					v.evs = append(v.evs, cur)
					v.mu.Unlock()
				}
				cur = sseEv{}
			case strings.HasPrefix(l, ": hb"):
				v.mu.Lock()
				v.hb++
				v.mu.Unlock()
			case strings.HasPrefix(l, "event: "):
				cur.name = l[7:]
			case strings.HasPrefix(l, "id: "):
				cur.id = l[4:]
			case strings.HasPrefix(l, "data: "):
				cur.data = l[6:]
			}
		}
	}()
	return v
}

func (v *viewer) close() { v.cancel(); <-v.closed }

func (v *viewer) events() []sseEv {
	v.mu.Lock()
	defer v.mu.Unlock()
	return append([]sseEv(nil), v.evs...)
}

// lines: the msg of every line event
func (v *viewer) lines() []string {
	var out []string
	for _, e := range v.events() {
		if e.name == "line" {
			var m struct{ Msg string }
			if err := json.Unmarshal([]byte(e.data), &m); err != nil {
				v.t.Errorf("line not JSON: %q", e.data)
			}
			out = append(out, m.Msg)
		}
	}
	return out
}

func (v *viewer) has(name string) *sseEv {
	for _, e := range v.events() {
		if e.name == name {
			return &e
		}
	}
	return nil
}

func (v *viewer) waitLines(n int) bool {
	return until(10*time.Second, func() bool { return len(v.lines()) >= n })
}

func (v *viewer) heartbeats() int {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.hb
}

func (e *env) runsMatching(sub string) int {
	n := 0
	for _, r := range e.runs() {
		if strings.Contains(r, sub) {
			n++
		}
	}
	return n
}

// pids: every fake logs child and grandchild ever started
func (e *env) logPids() []int {
	var ps []int
	b, _ := os.ReadFile(filepath.Join(e.fake, "logs.pids"))
	for _, l := range strings.Fields(string(b)) {
		p, _ := strconv.Atoi(l)
		ps = append(ps, p)
		if g := readPid(filepath.Join(e.fake, "gpid-"+l)); g > 0 {
			ps = append(ps, g)
		}
	}
	return ps
}

func (e *env) noOrphans(t *testing.T) {
	t.Helper()
	if !until(10*time.Second, func() bool { n, _, _ := e.srv.hub.stats(); return n == 0 }) {
		t.Fatal("streams still running")
	}
	for _, p := range e.logPids() {
		if !until(5*time.Second, func() bool { return !alive(p) }) {
			t.Errorf("pid %d still running after its stream ended", p)
		}
	}
}

func logsEnv(t *testing.T, mod func(*LogsConfig)) *env {
	e := newEnv(t, nil, func(c *Config) {
		c.Logs = LogsConfig{Linger: 300 * time.Millisecond, Backoff: 30 * time.Millisecond, BackoffMax: 200 * time.Millisecond,
			SlotWait: 300 * time.Millisecond}
		if mod != nil {
			mod(&c.Logs)
		}
	})
	e.login()
	return e
}

// ---- allowlist ----

func TestLogsAllowlist(t *testing.T) {
	ok := [][]string{
		{"logs", "web", "-H", "a", "--json", "-n", "200"},
		{"logs", "web", "-H", "a", "--json", "-n", "5000", "--since", "2026-11-13 14:30", "--level", "err", "--grep", "GET /x?y=1 'quoted' $(no)", "--worker", "mail", "--release", "20261113-120000"},
		{"logs", "web", "-H", "a", "--json", "-f", "-n", "200", "--since", "@1800000000", "--level", "warning", "--worker", "w-2"},
		argvLogs("a", "web", 1, logFilter{Since: "15m", Grep: "é ünïcode"}),
		argvLogsFollow("a", "web", 200, logFilter{Level: "debug"}),
	}
	for _, a := range ok {
		if _, err := Allowed(a); err != nil {
			t.Errorf("refused %q: %v", a, err)
		}
	}
	bad := [][]string{
		{"logs", "web", "-H", "a", "--json"},                                  // no -n
		{"logs", "web", "-H", "a", "-n", "5"},                                 // no --json
		{"logs", "-H", "a", "--json", "-n", "5"},                              // no app
		{"logs", "web", "api", "-H", "a", "--json", "-n", "5"},                // two apps
		{"logs", "web", "-H", "a", "--json", "-n", "0"},                       // n
		{"logs", "web", "-H", "a", "--json", "-n", "5001"},                    // n
		{"logs", "web", "-H", "a", "--json", "-n", "05"},                      // n
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--grep", "-f"},       // grep read as a flag by tando
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--grep", "a\nb"},     // newline
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--grep", "a\x1b[2J"}, // control
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--grep", strings.Repeat("x", 257)},
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--grep", ""},
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--grep", "x", "--regex"},      // regex: not offered
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--until", "1h"},               // not offered
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--deploy", "20261113-120000"}, // not offered
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--since", "1 day"},
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--since", "$(id)"},
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--level", "loud"},
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--worker", "Mail"},
		{"logs", "web", "-H", "a", "--json", "-n", "5", "--release", "latest"},
		{"logs", "web", "-H", "a", "--json", "-f", "-n", "5", "--grep", "x"}, // follow: level and worker only
		{"logs", "web", "-H", "a", "--json", "-f", "-n", "5", "--release", "20261113-120000"},
		{"logs", "web", "-H", "a", "--json", "-f", "-f", "-n", "5"},
		{"logs", "pull", "/tmp/x", "-a", "web", "-H", "a", "--json", "-n", "5"},
		{"logs", "web", "-H", "-a", "--json", "-n", "5"},
	}
	for _, a := range bad {
		if _, err := Allowed(a); err == nil {
			t.Errorf("allowed %q", a)
		}
	}
}

func TestLogsInvalidFiltersRefused(t *testing.T) {
	e := logsEnv(t, nil)
	for _, q := range []string{
		"host=a", "app=web", "host=a&app=Web", "host=../x&app=web", "host=nosuch&app=web",
		"host=a&app=web&n=0", "host=a&app=web&n=99999", "host=a&app=web&n=abc",
		"host=a&app=web&grep=-f", "host=a&app=web&grep=" + url.QueryEscape("a\nb"), "host=a&app=web&grep=",
		"host=a&app=web&grep=" + strings.Repeat("y", 300), "host=a&app=web&since=yesterday",
		"host=a&app=web&level=loud", "host=a&app=web&worker=-x", "host=a&app=web&release=..%2Fx",
	} {
		st, m := e.get("/api/logs?" + q)
		if st != 400 && st != 404 {
			t.Errorf("tail %s: %d %v", q, st, m)
		}
	}
	for _, q := range []string{"host=a&app=web&grep=x", "host=a&app=web&since=5m", "host=a&app=web&n=5",
		"host=a&app=web&release=20261113-120000", "host=a&app=web&level=nope", "host=a&app=x"} {
		st, m := e.get("/api/logs/stream?" + q)
		if st != 400 {
			t.Errorf("stream %s: %d %v", q, st, m)
		}
	}
	if r := e.runs(); len(r) != 0 {
		t.Errorf("refused requests ran tando: %q", r)
	}
}

func TestLogsTail(t *testing.T) {
	e := logsEnv(t, nil)
	st, m := e.get("/api/logs?host=a&app=web&n=2&level=err&grep=" + url.QueryEscape("GET /a b") + "&since=15m&worker=mail")
	if st != 200 {
		t.Fatalf("tail: %d %v", st, m)
	}
	if ls, _ := m["lines"].([]any); len(ls) != 2 {
		t.Errorf("lines: %v", m["lines"])
	}
	want := "logs web -H a --json -n 2 --since 15m --level err --grep GET /a b --worker mail"
	if r := e.runs(); len(r) != 1 || r[0] != want {
		t.Errorf("argv %q, want %q", r, want)
	}
	st, m = e.get("/api/logs?host=garbage1&app=web")
	if ns, _ := m["notes"].([]any); st != 200 || len(ns) != 1 {
		t.Errorf("notes: %d %v", st, m)
	}
	if st, m = e.get("/api/logs?host=fail1&app=web"); st != 502 || !strings.Contains(fmt.Sprint(m), "Connection refused") {
		t.Errorf("fail: %d %v", st, m)
	}
}

// ---- follow ----

func TestLogsOneChildForManyViewers(t *testing.T) {
	e := logsEnv(t, nil)
	var vs []*viewer
	for i := 0; i < 5; i++ {
		vs = append(vs, e.watch("host=a&app=web"))
	}
	for i, v := range vs {
		if !v.waitLines(10) {
			t.Fatalf("viewer %d: %d lines", i, len(v.lines()))
		}
	}
	if n := e.runsMatching("logs web -H a --json -f"); n != 1 {
		t.Errorf("%d follow children for 5 viewers", n)
	}
	if streams, clients, starts := e.srv.hub.stats(); streams != 1 || clients != 5 || starts != 1 {
		t.Errorf("streams %d clients %d starts %d", streams, clients, starts)
	}
	// another filter set is another stream
	w := e.watch("host=a&app=web&level=err")
	w.waitLines(1)
	if streams, _, _ := e.srv.hub.stats(); streams != 2 {
		t.Errorf("streams %d, want 2", streams)
	}
	for _, v := range append(vs, w) {
		v.close()
	}
	e.noOrphans(t)
}

func TestLogsLateJoinerGetsBuffer(t *testing.T) {
	e := logsEnv(t, func(c *LogsConfig) { c.Ring = 8 })
	v1 := e.watch("host=a&app=web")
	v1.waitLines(20)
	v2 := e.watch("host=a&app=web")
	until(5*time.Second, func() bool { return v2.has("hello") != nil && len(v2.lines()) >= 8 })
	var hello struct{ Buffered int }
	if h := v2.has("hello"); h == nil || json.Unmarshal([]byte(h.data), &hello) != nil || hello.Buffered != 8 {
		t.Fatalf("hello: %+v", h)
	}
	l1, l2 := v1.lines(), v2.lines()
	// v2's first 8 lines are 8 consecutive lines v1 saw, and the newest of them was v1's
	// newest when v2 joined (it continues without a gap)
	start := -1
	for i := range l1 {
		if l1[i] == l2[0] {
			start = i
		}
	}
	if start < 0 || start+8 > len(l1) {
		t.Fatalf("buffer %q not in %q", l2[:8], l1)
	}
	for i := 0; i < 8; i++ {
		if l1[start+i] != l2[i] {
			t.Errorf("buffer line %d: %q, want %q", i, l2[i], l1[start+i])
		}
	}
	// Last-Event-ID: a reconnecting EventSource gets only what it missed
	evs := v2.events()
	var lastID string
	for _, ev := range evs {
		if ev.name == "line" {
			lastID = ev.id
		}
	}
	v3 := e.watch("host=a&app=web", hdr("Last-Event-ID", lastID))
	until(5*time.Second, func() bool { return v3.has("hello") != nil })
	if err := json.Unmarshal([]byte(v3.has("hello").data), &hello); err != nil || hello.Buffered >= 8 {
		t.Errorf("Last-Event-ID %s: buffered %d", lastID, hello.Buffered)
	}
	if n := e.runsMatching("-f"); n != 1 {
		t.Errorf("%d children", n)
	}
	v1.close()
	v2.close()
	v3.close()
}

func TestLogsChildStopsAfterLastViewer(t *testing.T) {
	e := logsEnv(t, func(c *LogsConfig) { c.Linger = 600 * time.Millisecond })
	v := e.watch("host=a&app=web")
	v.waitLines(3)
	v.close()
	// a viewer back within the linger time gets the same child
	time.Sleep(200 * time.Millisecond) // proves the stream is still there: a wait that something did not happen
	v = e.watch("host=a&app=web")
	v.waitLines(len(v.lines()) + 3)
	if _, _, starts := e.srv.hub.stats(); starts != 1 {
		t.Errorf("rejoin within the linger time started %d children", starts)
	}
	v.close()
	left := time.Now()
	pids := e.logPids()
	until(5*time.Second, func() bool { n, _, _ := e.srv.hub.stats(); return n == 0 })
	if d := time.Since(left); d < 550*time.Millisecond {
		t.Errorf("stopped %v after the last viewer, want the linger time (600 ms)", d)
	}
	e.noOrphans(t)
	if len(pids) != 2 {
		t.Errorf("pids %v, want the child and its grandchild", pids)
	}
}

func TestLogsHostCap(t *testing.T) {
	e := logsEnv(t, nil)
	// three reads in flight on host a: a stream gets a clear error, not a hang
	var rels []func()
	for i := 0; i < 3; i++ {
		rel, err := e.lim.Acquire(context.Background(), "a")
		if err != nil {
			t.Fatal(err)
		}
		rels = append(rels, rel)
	}
	t0 := time.Now()
	v := e.watch("host=a&app=web")
	until(5*time.Second, func() bool { return v.has("error") != nil })
	<-v.closed
	if ev := v.has("error"); ev == nil || !strings.Contains(ev.data, `"busy"`) || time.Since(t0) > 3*time.Second {
		t.Fatalf("busy host: %+v after %v", ev, time.Since(t0))
	}
	for _, r := range rels {
		r()
	}
	// two streams per host at most: the third ssh session stays for the reads
	v1, v2 := e.watch("host=a&app=web"), e.watch("host=a&app=web&level=err")
	v1.waitLines(1)
	v2.waitLines(1)
	v3 := e.watch("host=a&app=web&worker=mail")
	select {
	case <-v3.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("a third stream on the host started")
	}
	if ev := v3.has("error"); ev == nil || !strings.Contains(ev.data, "busy") {
		t.Errorf("third stream: %+v", v3.events())
	}
	if st, m := e.get("/api/snapshot?host=a"); st != 200 {
		t.Errorf("a read beside two streams: %d %v", st, m)
	}
	// and the per-host limit holds with reads in flight: never more than 3 children on a
	var maxSeen atomic.Int64
	stop := make(chan struct{})
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
			}
			e.lim.mu.Lock()
			if n := int64(e.lim.per["a"]); n > maxSeen.Load() {
				maxSeen.Store(n)
			}
			e.lim.mu.Unlock()
			time.Sleep(time.Millisecond)
		}
	}()
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			e.get("/api/logs?host=a&app=web&n=" + strconv.Itoa(i+1))
		}(i)
	}
	wg.Wait()
	close(stop)
	if maxSeen.Load() > 3 || maxSeen.Load() < 3 {
		t.Errorf("children on host a at most %d, want 3", maxSeen.Load())
	}
	v1.close()
	v2.close()
	e.noOrphans(t)
}

func TestLogsSlowClientDropped(t *testing.T) {
	e := logsEnv(t, func(c *LogsConfig) { c.ClientBuf = 16 })
	fast := e.watch("host=flood1&app=web")
	fast.waitLines(10)
	// a client that never reads: its TCP buffers fill, then its queue
	conn, err := net.Dial("tcp", e.ts.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "GET /api/logs/stream?host=flood1&app=web HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nCookie: %s=%s\r\n\r\n", e.port, cookieName, e.cookie.Value)
	var st *stream
	until(5*time.Second, func() bool {
		e.srv.hub.mu.Lock()
		defer e.srv.hub.mu.Unlock()
		st = e.srv.hub.streams[streamKey{host: "flood1", app: "web"}]
		return st != nil && e.srv.hub.clients == 2
	})
	nclients := func() int { st.mu.Lock(); defer st.mu.Unlock(); return len(st.clients) }
	if !until(20*time.Second, func() bool { return nclients() == 1 }) {
		t.Fatal("the slow client was not dropped")
	}
	n := len(fast.lines())
	if !fast.waitLines(n + 1000) {
		t.Errorf("the fast viewer stalled at %d lines", len(fast.lines()))
	}
	if fast.has("dropped") != nil || fast.has("error") != nil {
		t.Errorf("the fast viewer was dropped")
	}
	// lines arrive in order, none lost for the fast one
	ls := fast.lines()
	for i := 1; i < len(ls); i++ {
		var a, b int
		fmt.Sscanf(ls[i-1], "web line %d", &a)
		fmt.Sscanf(ls[i], "web line %d", &b)
		if b != a+1 {
			t.Fatalf("fast viewer: %q then %q", ls[i-1], ls[i])
		}
	}
	fast.close()
	conn.Close()
	e.noOrphans(t)
}

func TestLogsReconnectNoDuplicates(t *testing.T) {
	e := logsEnv(t, nil)
	v := e.watch("host=drop1&app=web")
	if !v.waitLines(30) {
		t.Fatalf("%d lines: %+v", len(v.lines()), v.events())
	}
	ls := v.lines()
	for i, l := range ls {
		if want := "web line " + strconv.Itoa(i); l != want {
			t.Fatalf("line %d: %q, want %q (all: %q)", i, l, want, ls)
		}
	}
	if v.has("reconnecting") == nil || v.has("reconnected") == nil {
		t.Errorf("no reconnecting/reconnected event")
	}
	if e.runsMatching("--since @") == 0 {
		t.Errorf("no restart with --since: %q", e.runs())
	}
	v.close()
	e.noOrphans(t)

	// a child that keeps failing: a few retries, then an error event that ends the stream
	f := e.watch("host=fail1&app=web")
	select {
	case <-f.closed:
	case <-time.After(10 * time.Second):
		t.Fatal("a failing stream did not end")
	}
	if ev := f.has("error"); ev == nil || !strings.Contains(ev.data, "Connection refused") {
		t.Errorf("failing stream: %+v", f.events())
	}
	if n := e.runsMatching("logs web -H fail1"); n != 6 {
		t.Errorf("%d runs, want 1 + 5 retries", n)
	}
	e.noOrphans(t)
}

func TestLogsHeartbeat(t *testing.T) {
	e := logsEnv(t, func(c *LogsConfig) { c.Heartbeat = 100 * time.Millisecond })
	os.WriteFile(filepath.Join(e.fake, "logs-every"), []byte("1h"), 0o600) // no lines: only heartbeats
	v := e.watch("host=a&app=web")
	if !until(5*time.Second, func() bool { return v.heartbeats() >= 3 }) {
		t.Errorf("%d heartbeats", v.heartbeats())
	}
	v.close()
	e.noOrphans(t)
}

func TestLogsServerCloseEndsStreams(t *testing.T) {
	e := logsEnv(t, nil)
	v := e.watch("host=a&app=web")
	v.waitLines(2)
	e.srv.Close()
	select {
	case <-v.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("the stream outlived Close")
	}
	e.srv.WaitStreams(5 * time.Second)
	e.noOrphans(t)
}

// goroutines: settle, then count
func goroutines() int {
	prev := -1
	until(10*time.Second, func() bool {
		n := runtime.NumGoroutine()
		same := n == prev
		prev = n
		time.Sleep(100 * time.Millisecond)
		return same
	})
	return runtime.NumGoroutine()
}

func TestLogsNoLeaks(t *testing.T) {
	e := logsEnv(t, func(c *LogsConfig) { c.Linger = 100 * time.Millisecond })
	e.get("/api/ping")
	(&http.Client{}).CloseIdleConnections()
	e.ts.CloseClientConnections()
	g0 := goroutines()
	for round := 0; round < 3; round++ {
		var vs []*viewer
		for _, q := range []string{"host=a&app=web", "host=a&app=web", "host=b&app=api&level=err", "host=drop1&app=web"} {
			vs = append(vs, e.watch(q))
		}
		for _, v := range vs {
			v.waitLines(5)
		}
		for _, v := range vs {
			v.close()
		}
		e.noOrphans(t)
	}
	http.DefaultTransport.(*http.Transport).CloseIdleConnections()
	e.ts.CloseClientConnections()
	if g := goroutines(); g > g0+2 {
		t.Errorf("goroutines %d after the streams ended, %d before", g, g0)
	}
}

// TestLogsSoak: viewers joining and leaving streams (some dropping, some slow, some failing)
// and tails in between, for 2 minutes (TANDO_DASH_SOAK; skipped with -short). In the end no
// stream, no child and no extra goroutine may be left.
func TestLogsSoak(t *testing.T) {
	if testing.Short() {
		t.Skip("soak: not with -short")
	}
	dur := 2 * time.Minute
	if v := os.Getenv("TANDO_DASH_SOAK"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			t.Fatal(err)
		}
		dur = d
	}
	e := logsEnv(t, func(c *LogsConfig) { c.Linger = 150 * time.Millisecond; c.ClientBuf = 64 })
	g0 := goroutines()
	ctx, cancel := context.WithTimeout(context.Background(), dur)
	defer cancel()
	qs := []string{"host=a&app=web", "host=a&app=web&level=err", "host=b&app=api", "host=drop1&app=web",
		"host=flood1&app=web", "host=fail1&app=web", "host=c&app=web&worker=mail"}
	var wg sync.WaitGroup
	var opened, lines atomic.Int64
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			rnd := rand.New(rand.NewSource(int64(w)))
			for ctx.Err() == nil {
				if rnd.Intn(4) == 0 {
					e.get("/api/logs?host=a&app=web&n=50")
					continue
				}
				v := e.watch(qs[rnd.Intn(len(qs))])
				opened.Add(1)
				select {
				case <-time.After(time.Duration(50+rnd.Intn(1500)) * time.Millisecond):
				case <-ctx.Done():
				}
				lines.Add(int64(len(v.lines())))
				v.close()
			}
		}(w)
	}
	wg.Wait()
	e.noOrphans(t)
	http.DefaultTransport.(*http.Transport).CloseIdleConnections()
	noRedirect.CloseIdleConnections()
	e.ts.CloseClientConnections()
	g := goroutines()
	t.Logf("soak %v: %d viewers, %d lines, %d children, goroutines %d -> %d", dur, opened.Load(), lines.Load(), len(e.logPids()), g0, g)
	if g > g0+2 {
		t.Errorf("goroutines %d after the soak, %d before", g, g0)
	}
	if _, clients, _ := e.srv.hub.stats(); clients != 0 {
		t.Errorf("%d clients left", clients)
	}
}
