package dash

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// ---- the fake CLI's writes ----
//
// Files in FAKE_TANDO_DIR, per host and app (<h>-<a>): state-<h>-<a> (the state_reason),
// hist-<h>-<a> (history lines "at TAB release TAB kind TAB result", oldest first; at counts up),
// origin-<h>-<a> (where it was last deployed from), env-<h>-<a>-<KEY>.sha256 (the SHA-256 of the
// value env set got on stdin: the value itself is never written). Every write appends
// "<argv> |from=<TANDO_FROM> |cwd=<dir>" to writes.log. Modes by host: busy* refuses as the CLI
// does when another operation holds the app; slow* takes 1.5 s; flop* fails (a deploy records a
// failed history line); cut* (deploy) records ok, then SIGKILLs itself; soak* (deploy) leaves
// the app deploying until the second snapshot after it.

func fakeFlag(args []string, f string) string {
	for i, a := range args {
		if a == f && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func fakeAppend(path, line string) {
	if f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600); err == nil {
		fmt.Fprintln(f, line)
		f.Close()
	}
}

func fakeHist(dir, pfx string) [][]string {
	b, _ := os.ReadFile(filepath.Join(dir, "hist-"+pfx))
	var h [][]string
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if f := strings.Split(l, "\t"); len(f) == 4 {
			h = append(h, f)
		}
	}
	return h
}

func fakeAddHist(dir, pfx, id, kind, result string) {
	n := len(fakeHist(dir, pfx))
	fakeAppend(filepath.Join(dir, "hist-"+pfx), fmt.Sprintf("%d\t%s\t%s\t%s", 1_800_000_000+n+1, id, kind, result))
}

func fakeSetState(dir, pfx, st string) {
	_ = os.WriteFile(filepath.Join(dir, "state-"+pfx), []byte(st), 0o600)
}

func fakeWrite(dir, host, mode string, args []string) (int, bool) {
	verb, app := args[0], ""
	switch verb {
	case "deploy":
		app = fakeFlag(args, "-a")
	case "env":
		if len(args) < 3 || args[1] != "set" {
			return 0, false
		}
		app = fakeFlag(args, "-a")
	case "rollback", "stop", "start", "restart":
		app = args[1]
	default:
		return 0, false
	}
	cwd, _ := os.Getwd()
	fakeAppend(filepath.Join(dir, "writes.log"), strings.Join(args, " ")+" |from="+os.Getenv("TANDO_FROM")+" |cwd="+cwd)
	pfx := host + "-" + app
	switch mode {
	case "busy":
		fmt.Println("waiting for " + app + "...")
		fmt.Fprintln(os.Stderr, "tando: "+app+" is busy: a deploy by alice (pid 4242) holds it (tando status shows it)")
		return 1, true
	case "slow":
		time.Sleep(1500 * time.Millisecond)
	}
	if mode == "flop" {
		if verb == "deploy" {
			fakeAddHist(dir, pfx, fmt.Sprintf("20261121-1000%02d", len(fakeHist(dir, pfx))), "deploy", "failed")
		}
		fmt.Println("step 1 of " + verb)
		fmt.Fprintln(os.Stderr, "tando: "+verb+" of "+app+" failed: the new release did not pass its health check")
		return 1, true
	}
	switch verb {
	case "deploy":
		if _, err := os.Stat("tando.conf"); err != nil {
			fmt.Fprintln(os.Stderr, "tando: no tando.conf here")
			return 1, true
		}
		id := fmt.Sprintf("20261121-1000%02d", len(fakeHist(dir, pfx)))
		fmt.Println("building " + app)
		fmt.Println("uploading\r50%\r100%")
		switch mode {
		case "cut":
			fakeAddHist(dir, pfx, id, "deploy", "ok")
			fmt.Println("live: " + id)
			_ = syscall.Kill(os.Getpid(), syscall.SIGKILL)
		case "soak":
			fakeSetState(dir, pfx, "deploying")
			_ = os.WriteFile(filepath.Join(dir, "soak-"+pfx), []byte(id), 0o600)
			fmt.Println("live: " + id + " (soaking)")
			return 0, true
		}
		fakeAddHist(dir, pfx, id, "deploy", "ok")
		fakeSetState(dir, pfx, "running")
		fmt.Println("live: " + id)
	case "rollback":
		id := "20261120-000000"
		if len(args) == 5 {
			id = args[2]
		}
		fakeAddHist(dir, pfx, id, "rollback", "ok")
		fakeSetState(dir, pfx, "running")
		fmt.Println("rolled back to " + id)
	case "stop":
		fakeSetState(dir, pfx, "stopped")
		fmt.Println(app + " stopped")
	case "start", "restart":
		fakeSetState(dir, pfx, "running")
		fmt.Println(app + " " + verb + "ed")
	case "env":
		b, _ := io.ReadAll(os.Stdin)
		v, ok := strings.CutSuffix(string(b), "\n")
		if !ok || strings.Contains(v, "\n") {
			fmt.Fprintln(os.Stderr, "tando: not one line on stdin")
			return 1, true
		}
		sum := sha256.Sum256([]byte(v))
		_ = os.WriteFile(filepath.Join(dir, "env-"+pfx+"-"+args[2]+".sha256"), []byte(hex.EncodeToString(sum[:])), 0o600)
		fmt.Println("env updated (1 set), " + app + " restarted")
	}
	return 0, true
}

// fakeSnapApps: `,"apps":[...]` of the host's fake apps and, with --app, `,"app":{...}`
func fakeSnapApps(dir, host string, args []string) string {
	if args[0] != "snapshot" {
		return ""
	}
	ms, _ := filepath.Glob(filepath.Join(dir, "state-"+host+"-*"))
	if len(ms) == 0 {
		return ""
	}
	type row struct {
		App   string `json:"app"`
		State string `json:"state_reason"`
		Rel   string `json:"release"`
	}
	var apps []row
	for _, m := range ms {
		a := strings.TrimPrefix(filepath.Base(m), "state-"+host+"-")
		pfx := host + "-" + a
		if id, err := os.ReadFile(filepath.Join(dir, "soak-"+pfx)); err == nil {
			if readPid(filepath.Join(dir, "soak-reads-"+pfx)) >= 1 { // the soak is over
				fakeAddHist(dir, pfx, string(id), "deploy", "ok")
				fakeSetState(dir, pfx, "running")
				os.Remove(filepath.Join(dir, "soak-"+pfx))
			} else {
				_ = os.WriteFile(filepath.Join(dir, "soak-reads-"+pfx), []byte("1"), 0o600)
			}
		}
		st, _ := os.ReadFile(m)
		rel := ""
		if h := fakeHist(dir, pfx); len(h) > 0 {
			rel = h[len(h)-1][1]
		}
		apps = append(apps, row{a, string(st), rel})
	}
	b, _ := json.Marshal(apps)
	out := `,"apps":` + string(b)
	if a := fakeFlag(args, "--app"); a != "" {
		pfx := host + "-" + a
		app := map[string]any{"name": a, "origin": nil}
		if o, err := os.ReadFile(filepath.Join(dir, "origin-"+pfx)); err == nil {
			app["origin"] = string(o)
		}
		hist := []map[string]any{}
		h := fakeHist(dir, pfx)
		for i := len(h) - 1; i >= 0; i-- {
			at, _ := strconv.Atoi(h[i][0])
			hist = append(hist, map[string]any{"at": at, "app": a, "release": h[i][1], "kind": h[i][2], "result": h[i][3], "total_s": 12.5, "deployer": "me"})
		}
		app["history"] = hist
		b, _ := json.Marshal(app)
		out += `,"app":` + string(b)
	}
	return out
}

// ---- helpers ----

func actEnv(t *testing.T) *env {
	e := newEnv(t, nil, func(c *Config) {
		c.OutcomePoll, c.OutcomeWait, c.ActionPoll = 50*time.Millisecond, 5*time.Second, 20*time.Millisecond
	})
	e.login()
	return e
}

func (e *env) fakeApp(host, app, state string) {
	fakeSetState(e.fake, host+"-"+app, state)
}

// project: a folder with tando.conf for app (and host), recorded as its origin on host
func (e *env) project(host, app, conf string) string {
	d := e.t.TempDir()
	os.WriteFile(filepath.Join(d, "tando.conf"), []byte(conf), 0o600)
	os.WriteFile(filepath.Join(e.fake, "origin-"+host+"-"+app), []byte(clientName()+":"+d), 0o600)
	return d
}

func (e *env) write(key, action, host, app string, params any) (int, map[string]any) {
	e.t.Helper()
	body := map[string]any{"action": action, "host": host, "app": app, "confirm": e.confirmTok(action, host, app)}
	if params != nil {
		body["params"] = params
	}
	st, m, _ := e.req(nil, "POST", "/api/action", body, hdr("Idempotency-Key", key))
	return st, m
}

// waitEnd: the record once it ended
func (e *env) waitEnd(key string) map[string]any {
	e.t.Helper()
	var m map[string]any
	if !until(10*time.Second, func() bool {
		_, m = e.get("/api/action?key=" + key)
		s, _ := m["status"].(string)
		return s != "" && s != "running"
	}) {
		e.t.Fatalf("%s did not end: %v", key, m)
	}
	return m
}

func (e *env) writes() []string {
	b, _ := os.ReadFile(filepath.Join(e.fake, "writes.log"))
	s := strings.TrimSpace(string(b))
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

type sse struct {
	name, id, data string
}

// stream: the events of /api/action/stream until the end event (or 10 s)
func (e *env) stream(key, lastID string) []sse {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	r, _ := http.NewRequestWithContext(ctx, "GET", e.ts.URL+"/api/action/stream?key="+key, nil)
	r.AddCookie(e.cookie)
	if lastID != "" {
		r.Header.Set("Last-Event-ID", lastID)
	}
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "text/event-stream" {
		e.t.Fatalf("stream: %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	var evs []sse
	var cur sse
	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		l := sc.Text()
		switch {
		case l == "":
			if cur.name != "" {
				evs = append(evs, cur)
				if cur.name == "end" {
					return evs
				}
			}
			cur = sse{}
		case strings.HasPrefix(l, "event: "):
			cur.name = l[7:]
		case strings.HasPrefix(l, "id: "):
			cur.id = l[4:]
		case strings.HasPrefix(l, "data: "):
			cur.data = l[6:]
		}
	}
	e.t.Fatalf("no end event: %v", evs)
	return nil
}

func lineTexts(evs []sse) []string {
	var o []string
	for _, ev := range evs {
		if ev.name == "line" {
			var m map[string]any
			json.Unmarshal([]byte(ev.data), &m)
			o = append(o, m["text"].(string))
		}
	}
	return o
}

func outcomeOf(m map[string]any) map[string]any {
	o, _ := m["outcome"].(map[string]any)
	return o
}

// ---- tests ----

func TestWriteActionsArgv(t *testing.T) {
	e := actEnv(t)
	e.fakeApp("a", "web", "running")
	// (its $PWD: the logical path, as the origin records it)
	real := e.project("a", "web", "app = web\nhost = a\n# a comment = x\n")
	type c struct {
		action string
		params any
		argv   string
		state  string
	}
	for i, x := range []c{
		{"deploy", nil, "deploy -a web -H a", "running"},
		{"stop", nil, "stop web -H a", "stopped"},
		{"start", nil, "start web -H a", "running"},
		{"restart", nil, "restart web -H a", "running"},
		{"rollback", nil, "rollback web -H a", "running"},
		{"rollback", map[string]string{"release": "20261113-171442"}, "rollback web 20261113-171442 -H a", "running"},
		{"env-set", map[string]string{"key": "STRIPE_KEY", "value": "v"}, "env set STRIPE_KEY -a web -H a", "running"},
	} {
		key := fmt.Sprintf("argv-key-%04d", i)
		if st, m := e.write(key, x.action, "a", "web", x.params); st != 202 {
			t.Fatalf("%s: %d %v", x.action, st, m)
		}
		m := e.waitEnd(key)
		o := outcomeOf(m)
		if m["status"] != "done" || o == nil || o["verdict"] != "ok" || o["state"] != x.state {
			t.Fatalf("%s: %v", x.action, m)
		}
		if x.action == "deploy" || x.action == "rollback" {
			h, _ := o["history"].(map[string]any)
			if h == nil || h["kind"] != x.action || h["result"] != "ok" {
				t.Fatalf("%s: outcome history %v", x.action, o)
			}
		}
		w := e.writes()
		got := w[len(w)-1]
		want := x.argv + " |from=dashboard |cwd="
		if !strings.HasPrefix(got, want) {
			t.Fatalf("%s: %q, want %q", x.action, got, want)
		}
		if x.action == "deploy" && got != want+real {
			t.Fatalf("deploy ran in %q, not the project %q", got, real)
		}
		if x.action != "deploy" && strings.HasSuffix(got, real) {
			t.Fatalf("%s ran in the project", x.action)
		}
	}
	if n := len(e.writes()); n != 7 {
		t.Fatalf("%d writes", n)
	}
}

// the value of env set: on stdin only; never in argv, a record, an output file, a log or an error
func TestEnvValueNeverWritten(t *testing.T) {
	logs := &bytes.Buffer{}
	e := newEnv(t, nil, func(c *Config) {
		c.OutcomePoll, c.OutcomeWait, c.ActionPoll = 50*time.Millisecond, 5*time.Second, 20*time.Millisecond
		c.Log = &lockedBuf{b: logs}
	})
	e.login()
	e.fakeApp("a", "web", "running")
	e.fakeApp("flop1", "web", "running")
	const marker = "dash-env-test-marker with spaces"
	if st, m := e.write("env-key-00001", "env-set", "a", "web", map[string]string{"key": "API_TOKEN", "value": marker}); st != 202 {
		t.Fatal(st, m)
	}
	m := e.waitEnd("env-key-00001")
	sum := sha256.Sum256([]byte(marker))
	if b, _ := os.ReadFile(filepath.Join(e.fake, "env-a-web-API_TOKEN.sha256")); string(b) != hex.EncodeToString(sum[:]) || m["status"] != "done" {
		t.Fatalf("the CLI did not get the value on stdin: %q %v", b, m)
	}
	// replay: same key, same value: the record; same key, another value: refused (in memory)
	if st, m := e.write("env-key-00001", "env-set", "a", "web", map[string]string{"key": "API_TOKEN", "value": marker}); st != 200 || m["replay"] != true {
		t.Fatal(st, m)
	}
	if st, m := e.write("env-key-00001", "env-set", "a", "web", map[string]string{"key": "API_TOKEN", "value": marker + "x"}); st != 422 || errCode(m) != "key_reused" {
		t.Fatal(st, m)
	}
	// a failing env set: its error does not carry the value either
	e.write("env-key-00002", "env-set", "flop1", "web", map[string]string{"key": "API_TOKEN", "value": marker})
	if m := e.waitEnd("env-key-00002"); m["status"] != "failed" || !strings.Contains(m["message"].(string), "failed") {
		t.Fatal(m)
	}
	// values the CLI cannot take: refused before anything, without the value in the answer
	for _, v := range []string{marker + "\nX=1", marker + "\r", marker + "\x1b[31m", strings.Repeat("v", MaxEnvValue+1)} {
		st, m := e.post("/api/action", map[string]any{"action": "env-set", "host": "a", "app": "web", "confirm": e.confirmTok("env-set", "a", "web"),
			"params": map[string]string{"key": "API_TOKEN", "value": v}}, hdr("Idempotency-Key", "env-key-00003"))
		if b, _ := json.Marshal(m); st != 400 || bytes.Contains(b, []byte(marker)) || bytes.Contains(b, []byte("vvvv")) {
			t.Fatalf("%d %s", st, b)
		}
	}
	for _, p := range []map[string]any{{"key": "1BAD", "value": "x"}, {"key": "A-B", "value": "x"}, {"key": "OK"}, {"key": "OK", "value": "x", "release": "20261113-171442"}, {"value": "x"}} {
		st, _ := e.post("/api/action", map[string]any{"action": "env-set", "host": "a", "app": "web", "confirm": "x", "params": p}, hdr("Idempotency-Key", "env-key-00004"))
		if st != 400 {
			t.Fatalf("%v: %d", p, st)
		}
	}
	// the streams of both
	for _, k := range []string{"env-key-00001", "env-key-00002"} {
		for _, ev := range e.stream(k, "") {
			if strings.Contains(ev.data, marker) {
				t.Fatalf("stream: %v", ev)
			}
		}
	}
	// nothing on disk holds it: the config dir (records, op output), the fake CLI's files (its
	// argv log), tando-dash's log
	for _, d := range []string{e.dir, e.fake} {
		filepath.WalkDir(d, func(p string, de fs.DirEntry, err error) error {
			if err == nil && !de.IsDir() {
				if b, _ := os.ReadFile(p); bytes.Contains(b, []byte(marker)) || bytes.Contains(b, []byte("dash-env-test-marker")) {
					t.Errorf("the value is in %s", p)
				}
			}
			return nil
		})
	}
	if strings.Contains(logs.String(), "dash-env-test-marker") {
		t.Error("the value is in the log")
	}
	if w := strings.Join(e.writes(), "\n"); !strings.Contains(w, "env set API_TOKEN -a web -H a |from=dashboard") {
		t.Fatalf("argv: %s", w)
	}
}

type lockedBuf struct {
	mu chanMutex
	b  *bytes.Buffer
}

type chanMutex struct{ c chan struct{} }

func (l *lockedBuf) Write(p []byte) (int, error) {
	if l.mu.c == nil {
		l.mu.c = make(chan struct{}, 1)
	}
	l.mu.c <- struct{}{}
	defer func() { <-l.mu.c }()
	return l.b.Write(p)
}

func TestDeployFolderRefused(t *testing.T) {
	e := actEnv(t)
	e.fakeApp("a", "web", "running")
	try := func(name, want string) {
		t.Helper()
		st, m := e.write("fold-key-"+name, "deploy", "a", "web", nil)
		msg, _ := m["error"].(map[string]any)["message"].(string)
		if st != 422 || errCode(m) != "deploy_folder" || !strings.Contains(msg, want) {
			t.Fatalf("%s: %d %v", name, st, m)
		}
	}
	try("none", "no record of where web was deployed from")
	os.WriteFile(filepath.Join(e.fake, "origin-a-web"), []byte("someone@other-mac:/src/web"), 0o600)
	try("foreign", "last deployed from someone@other-mac, not from this machine")
	os.WriteFile(filepath.Join(e.fake, "origin-a-web"), []byte(clientName()+":/nonexistent/src/web"), 0o600)
	try("missing", "not on this machine any more")
	os.WriteFile(filepath.Join(e.fake, "origin-a-web"), []byte(clientName()+":relative/web"), 0o600)
	try("relative", "not a plain path")
	d := e.project("a", "web", "app = web\n")
	os.Remove(filepath.Join(d, "tando.conf"))
	try("noconf", "has no tando.conf")
	e.project("a", "web", "app = shop\nhost = a\n")
	try("otherapp", "is for shop, not web")
	e.project("a", "web", "app = web\nhost = b\n")
	try("otherhost", "deploys to b, not a")
	if w := e.writes(); len(w) != 0 {
		t.Fatalf("a deploy ran: %v", w)
	}
	// unknown app on the host: 404; a host that does not answer: 502
	if st, m := e.write("fold-key-noapp", "deploy", "a", "nope", nil); st != 404 || errCode(m) != "no_app" {
		t.Fatal(st, m)
	}
	if st, m := e.write("fold-key-down", "deploy", "fail1", "web", nil); st != 502 {
		t.Fatal(st, m)
	}
	// the folder is fine (no host in tando.conf: -H is given): it runs
	e.project("a", "web", "app = web\n")
	if st, m := e.write("fold-key-good", "deploy", "a", "web", nil); st != 202 {
		t.Fatal(st, m)
	}
	if m := e.waitEnd("fold-key-good"); m["status"] != "done" {
		t.Fatal(m)
	}
}

// same key twice: one run, the same record and the same stream, for every action
func TestActionsReplay(t *testing.T) {
	e := actEnv(t)
	e.fakeApp("a", "web", "running")
	e.project("a", "web", "app = web\nhost = a\n")
	for i, x := range []struct {
		action string
		params any
	}{{"deploy", nil}, {"rollback", nil}, {"stop", nil}, {"start", nil}, {"restart", nil}, {"env-set", map[string]string{"key": "K", "value": "v"}}} {
		key := fmt.Sprintf("replay-key-%03d", i)
		n := len(e.writes())
		if st, m := e.write(key, x.action, "a", "web", x.params); st != 202 {
			t.Fatal(x.action, st, m)
		}
		st, m := e.write(key, x.action, "a", "web", x.params)
		if (st != 202 && st != 200) || m["replay"] != true || m["key"] != key {
			t.Fatal(x.action, st, m)
		}
		e.waitEnd(key)
		if st, m = e.write(key, x.action, "a", "web", x.params); st != 200 || m["replay"] != true || m["status"] != "done" {
			t.Fatal(x.action, st, m)
		}
		if got := len(e.writes()) - n; got != 1 {
			t.Fatalf("%s: %d runs", x.action, got)
		}
		s1, s2 := e.stream(key, ""), e.stream(key, "")
		if fmt.Sprint(s1) != fmt.Sprint(s2) || len(lineTexts(s1)) == 0 {
			t.Fatalf("%s: streams differ or empty:\n%v\n%v", x.action, s1, s2)
		}
	}
}

func TestActionStream(t *testing.T) {
	e := actEnv(t)
	e.fakeApp("slow1", "web", "running")
	e.project("slow1", "web", "app = web\nhost = slow1\n")
	if st, m := e.write("stream-key-01", "deploy", "slow1", "web", nil); st != 202 {
		t.Fatal(st, m)
	}
	// joined while it runs: hello, the lines as they come, then the end with the server's word
	evs := e.stream("stream-key-01", "")
	if evs[0].name != "hello" || !strings.Contains(evs[0].data, `"action":"deploy"`) || !strings.Contains(evs[0].data, `"status":"running"`) {
		t.Fatalf("hello: %v", evs[0])
	}
	lines := lineTexts(evs)
	if strings.Join(lines, "|") != "building web|100%|live: 20261121-100000" {
		t.Fatalf("lines: %q", lines)
	}
	end := evs[len(evs)-1]
	var m map[string]any
	json.Unmarshal([]byte(end.data), &m)
	if m["status"] != "done" || outcomeOf(m)["verdict"] != "ok" || m["exit"] != 0.0 {
		t.Fatalf("end: %v", m)
	}
	// numbered lines; a reconnect with Last-Event-ID gets only what it missed
	if evs[1].id != "1" || evs[3].id != "3" {
		t.Fatalf("ids: %v", evs)
	}
	re := e.stream("stream-key-01", "2")
	if l := lineTexts(re); len(l) != 1 || l[0] != "live: 20261121-100000" || re[1].id != "3" || re[len(re)-1].name != "end" {
		t.Fatalf("resume: %v", re)
	}
	if st, _ := e.get("/api/action/stream?key=nope-key-0001"); st != 404 {
		t.Fatal(st)
	}
	if st, _ := e.get("/api/action/stream?key=bad"); st != 400 {
		t.Fatal(st)
	}
}

// the outcome is the server's: a CLI killed after the server finished is done; a soak is waited
// out; a failure says what the CLI said and how the app is
func TestActionOutcome(t *testing.T) {
	e := actEnv(t)
	for _, h := range []string{"cut1", "soak1", "flop1", "busy1"} {
		e.fakeApp(h, "web", "running")
		e.project(h, "web", "app = web\nhost = "+h+"\n")
	}
	e.write("out-key-cut001", "deploy", "cut1", "web", nil)
	m := e.waitEnd("out-key-cut001")
	if m["status"] != "done" || m["exit"] == 0.0 || outcomeOf(m)["verdict"] != "ok" {
		t.Fatalf("midkill: %v", m)
	}
	e.write("out-key-soak01", "deploy", "soak1", "web", nil)
	m = e.waitEnd("out-key-soak01")
	if o := outcomeOf(m); m["status"] != "done" || o["state"] != "running" || o["history"] == nil {
		t.Fatalf("soak: %v", m)
	}
	e.write("out-key-fail01", "deploy", "flop1", "web", nil)
	m = e.waitEnd("out-key-fail01")
	msg, _ := m["message"].(string)
	if m["status"] != "failed" || m["exit"] != 1.0 || !strings.Contains(msg, "did not pass its health check") || !strings.Contains(msg, "deploy of 20261121-100000: failed") {
		t.Fatalf("fail: %v", m)
	}
	// another operation holds the app (a deploy from a terminal): the CLI's own words, at once
	for i, a := range []string{"restart", "deploy"} {
		k := fmt.Sprintf("out-key-busy%02d", i)
		e.write(k, a, "busy1", "web", nil)
		m = e.waitEnd(k)
		if m["status"] != "failed" || m["code"] != "busy" || m["message"] != "busy: web is busy: a deploy by alice (pid 4242) holds it (tando status shows it)" {
			t.Fatalf("busy %s: %v", a, m)
		}
	}
	// a stop that did not stop it: failed, from the state
	e.fakeApp("a", "web", "running")
	os.WriteFile(filepath.Join(e.fake, "state-a-web"), []byte("running"), 0o600)
}

func TestActionConflict(t *testing.T) {
	e := actEnv(t)
	e.fakeApp("slow1", "web", "running")
	e.fakeApp("slow1", "shop", "running")
	if st, _ := e.write("conf-key-0001", "restart", "slow1", "web", nil); st != 202 {
		t.Fatal(st)
	}
	st, m := e.write("conf-key-0002", "env-set", "slow1", "web", map[string]string{"key": "K", "value": "v"})
	msg, _ := m["error"].(map[string]any)["message"].(string)
	if st != 409 || errCode(m) != "running" || !strings.Contains(msg, "a restart of web is running, started ") {
		t.Fatalf("%d %v", st, m)
	}
	if st, _ := e.write("conf-key-0003", "stop", "slow1", "shop", nil); st != 202 {
		t.Fatal("another app is free", st)
	}
	e.waitEnd("conf-key-0001")
	e.waitEnd("conf-key-0003")
	if st, _ := e.write("conf-key-0002", "env-set", "slow1", "web", map[string]string{"key": "K", "value": "v"}); st != 202 {
		t.Fatal("after the first", st)
	}
	e.waitEnd("conf-key-0002")
}

// for every action: neither the client going away nor tando-dash stopping kills the CLI
func TestActionsSurviveShutdown(t *testing.T) {
	for _, x := range []struct {
		action string
		params any
	}{{"deploy", nil}, {"rollback", nil}, {"stop", nil}, {"start", nil}, {"restart", nil}, {"env-set", map[string]string{"key": "K", "value": "v"}}} {
		e := actEnv(t)
		e.fakeApp("slow1", "web", "running")
		e.project("slow1", "web", "app = web\nhost = slow1\n")
		ctx, cancel := context.WithCancel(context.Background())
		body := map[string]any{"action": x.action, "host": "slow1", "app": "web", "confirm": e.confirmTok(x.action, "slow1", "web")}
		if x.params != nil {
			body["params"] = x.params
		}
		st, _, _ := e.req(ctx, "POST", "/api/action", body, hdr("Idempotency-Key", "surv-key-0001"))
		cancel()
		if st != 202 {
			t.Fatal(x.action, st)
		}
		var pid int
		if !until(5*time.Second, func() bool { r := e.srv.idem.lookup("surv-key-0001"); pid = r.Pid; return pid > 0 }) {
			t.Fatal(x.action, "no pid")
		}
		e.srv.Close()
		if !alive(pid) {
			t.Fatalf("%s: the CLI was killed", x.action)
		}
		if !until(5*time.Second, func() bool { return len(e.writes()) == 1 && !alive(pid) }) {
			t.Fatalf("%s: did not finish", x.action)
		}
	}
}

// a tando-dash restart while a write ran: once its CLI is gone, the server says how it ended
func TestReattach(t *testing.T) {
	dir := t.TempDir()
	fake := t.TempDir()
	// a pid that is gone
	c := exec.Command("true")
	c.Run()
	dead := c.Process.Pid
	// a deploy (the server recorded it after the base), a stop (the app is stopped), a restart
	// whose CLI still runs (a process of ours), an env set (the state says nothing of it)
	sleeper := exec.Command(os.Args[0])
	sleeper.Env = append(os.Environ(), "FAKE_TANDO=sleep", "FAKE_PIDFILE="+filepath.Join(fake, "sleeper.pid"))
	if err := sleeper.Start(); err != nil {
		t.Fatal(err)
	}
	defer sleeper.Process.Kill()
	now := time.Now()
	recs := []*idemRec{
		{Key: "reat-key-deploy", Hash: "h", Action: "deploy", Host: "a", App: "web", Status: "running", Pid: dead, Started: now, Base: &histEntry{At: 1_800_000_001, Release: "20261121-100000", Kind: "deploy"}},
		{Key: "reat-key-stop01", Hash: "h", Action: "stop", Host: "a", App: "shop", Status: "running", Pid: dead, Started: now},
		{Key: "reat-key-rstrt1", Hash: "h", Action: "restart", Host: "b", App: "web", Status: "running", Pid: sleeper.Process.Pid, Started: now},
		{Key: "reat-key-env001", Hash: "h", Action: "env-set", Host: "b", App: "api", Status: "running", Pid: dead, Started: now},
	}
	b, _ := json.Marshal(idemFile{Secret: strings.Repeat("ab", 32), Records: recs})
	os.MkdirAll(filepath.Join(dir, "cache", "dash-ops"), 0o700)
	os.MkdirAll(filepath.Join(dir, "hosts"), 0o700)
	for _, h := range []string{"a", "b"} {
		os.WriteFile(filepath.Join(dir, "hosts", h), []byte("x"), 0o600)
	}
	os.WriteFile(filepath.Join(dir, "cache", "dash-idem.json"), b, 0o600)
	os.WriteFile(filepath.Join(dir, "cache", "dash-ops", hashHex("reat-key-deploy")[:32]+".log"), []byte("building web\nlive: 20261121-100001\n"), 0o600)
	fakeAddHist(fake, "a-web", "20261121-100000", "deploy", "ok")
	fakeAddHist(fake, "a-web", "20261121-100001", "deploy", "ok")
	fakeSetState(fake, "a-web", "running")
	fakeSetState(fake, "a-shop", "stopped")
	fakeSetState(fake, "b-web", "running")
	fakeSetState(fake, "b-api", "running")

	r, _ := fakeExec(t, fake, 1<<20)
	e := newEnv(t, r, func(c *Config) {
		c.ConfigDir = dir
		c.OutcomePoll, c.OutcomeWait, c.ActionPoll = 50*time.Millisecond, 5*time.Second, 20*time.Millisecond
	})
	e.dir, e.fake = dir, fake
	e.login()
	m := e.waitEnd("reat-key-deploy")
	if o := outcomeOf(m); m["status"] != "done" || o["verdict"] != "ok" || o["history"].(map[string]any)["release"] != "20261121-100001" {
		t.Fatalf("deploy: %v", m)
	}
	evs := e.stream("reat-key-deploy", "")
	if l := lineTexts(evs); len(l) != 2 || evs[len(evs)-1].name != "end" {
		t.Fatalf("stream: %v", evs)
	}
	if m = e.waitEnd("reat-key-stop01"); m["status"] != "done" || outcomeOf(m)["state"] != "stopped" {
		t.Fatalf("stop: %v", m)
	}
	if m = e.waitEnd("reat-key-env001"); m["status"] != "unknown" || !strings.Contains(m["message"].(string), "tando env log api") {
		t.Fatalf("env: %v", m)
	}
	// the restart's CLI runs on: still running, and its app taken
	time.Sleep(300 * time.Millisecond) // (proves it did NOT end while the CLI lives)
	if _, m = e.get("/api/action?key=reat-key-rstrt1"); m["status"] != "running" {
		t.Fatalf("restart ended while its CLI ran: %v", m)
	}
	if st, m := e.write("reat-key-other", "stop", "b", "web", nil); st != 409 {
		t.Fatal(st, m)
	}
	sleeper.Process.Kill()
	sleeper.Wait()
	if m = e.waitEnd("reat-key-rstrt1"); m["status"] != "done" || outcomeOf(m)["state"] != "running" {
		t.Fatalf("restart: %v", m)
	}
}
