package studio

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---- the service's front, with in-process helpers over real unix sockets -------------------------

type svcRig struct {
	t       *testing.T
	v       *Service
	now     time.Time
	mu      sync.Mutex
	dbs     map[string]*fakeDB
	spawned []string // app/session of every helper started
	live    map[*Helper]*Studio
}

func newSvc(t *testing.T, apps map[string]bool) *svcRig {
	root := t.TempDir()
	for a, db := range apps {
		os.MkdirAll(filepath.Join(root, "apps", a), 0o755)
		c := "port=4100\n"
		if db {
			c += "database=postgres\n"
		}
		os.WriteFile(filepath.Join(root, "apps", a, "app.conf"), []byte(c), 0o644)
	}
	g := &svcRig{t: t, now: time.Now(), dbs: map[string]*fakeDB{}, live: map[*Helper]*Studio{}}
	for a := range apps {
		g.dbs[a] = newFake(nil)
	}
	g.v = NewService(SvcConfig{Root: root, Run: t.TempDir(), Now: g.clock, Spawn: g.spawn})
	return g
}

func (g *svcRig) clock() time.Time { g.mu.Lock(); defer g.mu.Unlock(); return g.now }
func (g *svcRig) advance(d time.Duration) {
	g.mu.Lock()
	g.now = g.now.Add(d)
	g.mu.Unlock()
}

// spawn: a helper as the real one is, a Studio of the app served on a unix socket of its own
func (g *svcRig) spawn(h *Helper) error {
	g.mu.Lock()
	f := g.dbs[h.App]
	g.spawned = append(g.spawned, h.App+"/"+h.Sess)
	g.mu.Unlock()
	s, err := New(context.Background(), Config{App: h.App, Host: h.Host, Admin: h.Admin, Role: Role(h.App),
		Database: Role(h.App), Password: "pw-" + h.App, Port: h.Port, Idle: time.Hour, StmtLimit: 30 * time.Second,
		Out: io.Discard, Log: io.Discard, Dial: func(context.Context) (DB, error) { return f, nil }})
	if err != nil {
		return err
	}
	dir, _ := os.MkdirTemp("/tmp", "stsvc")
	g.t.Cleanup(func() { os.RemoveAll(dir) })
	ln, err := net.Listen("unix", filepath.Join(dir, "s"))
	if err != nil {
		return err
	}
	pr, pw := io.Pipe()
	done := make(chan struct{})
	go func() { s.Serve(ln, pr, 20*time.Millisecond); close(done) }()
	h.Done, h.Token = done, s.token
	var once sync.Once
	h.Stop = func() { once.Do(func() { pw.Close() }) }
	h.Dial = func(ctx context.Context) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", filepath.Join(dir, "s"))
	}
	g.mu.Lock()
	g.live[h] = s
	g.mu.Unlock()
	g.t.Cleanup(h.Stop)
	return nil
}

const sport = 47200

// req: one request to the front of admin's socket
func (g *svcRig) req(admin, method, path, body, token string, hdr map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Host = fmt.Sprintf("127.0.0.1:%d", sport)
	if body != "" {
		r.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range hdr {
		if k == "Host" {
			r.Host = v
		} else {
			r.Header.Set(k, v)
		}
	}
	w := httptest.NewRecorder()
	g.v.Handler(admin).ServeHTTP(w, r)
	return w
}

// open: a code for app, traded for a token on admin's socket
func (g *svcRig) open(admin, app string) string {
	g.t.Helper()
	code, err := g.v.Mint(admin, app, sport, "prod")
	if err != nil {
		g.t.Fatal(err)
	}
	w := g.req(admin, "POST", "/api/session", `{"code":"`+code+`"}`, "", nil)
	var r struct{ Token, App string }
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &r) != nil || r.Token == "" || r.App != app {
		g.t.Fatalf("session: %d %s", w.Code, w.Body)
	}
	return r.Token
}

func (g *svcRig) helpers() int { g.v.mu.Lock(); defer g.v.mu.Unlock(); return len(g.v.helpers) }

func svcQuery(g *svcRig, tok, path, sql string) (qresp, int) {
	b, _ := json.Marshal(map[string]any{"id": "q1", "sql": sql, "max_rows": 3})
	w := g.req("admin", "POST", path, string(b), tok, nil)
	var q qresp
	json.Unmarshal(w.Body.Bytes(), &q)
	return q, w.Code
}

// A code works once, for a minute, on the socket of the admin it was minted for and with its
// port; the token likewise; a code for an app without a database is not minted.
func TestServiceCodeAndToken(t *testing.T) {
	g := newSvc(t, map[string]bool{"shop": true, "web": false})
	code, _ := g.v.Mint("admin", "shop", sport, "prod")
	if w := g.req("other", "POST", "/api/session", `{"code":"`+code+`"}`, "", nil); w.Code != 401 {
		t.Fatalf("another admin's socket: %d", w.Code)
	}
	code, _ = g.v.Mint("admin", "shop", sport, "prod")
	if w := g.req("admin", "POST", "/api/session", `{"code":"`+code+`"}`, "", map[string]string{"Host": "127.0.0.1:47201"}); w.Code != 401 {
		t.Fatalf("another port: %d", w.Code)
	}
	code, _ = g.v.Mint("admin", "shop", sport, "prod")
	g.advance(CodeTTL + time.Second)
	if w := g.req("admin", "POST", "/api/session", `{"code":"`+code+`"}`, "", nil); w.Code != 401 {
		t.Fatalf("expired: %d", w.Code)
	}
	code, _ = g.v.Mint("admin", "shop", sport, "prod")
	body := `{"code":"` + code + `"}`
	if w := g.req("admin", "POST", "/api/session", body, "", nil); w.Code != 200 {
		t.Fatalf("first use: %d %s", w.Code, w.Body)
	}
	if w := g.req("admin", "POST", "/api/session", body, "", nil); w.Code != 401 {
		t.Fatalf("second use: %d", w.Code)
	}
	if _, err := g.v.Mint("admin", "web", sport, "prod"); err == nil {
		t.Fatal("a code for an app without a database")
	}
	for _, a := range [][3]string{{"ad min", "shop", "prod"}, {"admin", "../shop", "prod"}, {"admin", "shop", "pr od"}} {
		if _, err := g.v.Mint(a[0], a[1], sport, a[2]); err == nil {
			t.Fatalf("minted %v", a)
		}
	}
	tok := g.open("admin", "shop")
	if w := g.req("admin", "GET", "/api/ping", "", tok, nil); w.Code != 200 {
		t.Fatalf("ping: %d", w.Code)
	}
	for name, c := range map[string]struct{ admin, host string }{
		"another admin's socket": {"other", ""}, "another port": {"admin", "127.0.0.1:47201"}} {
		h := map[string]string{}
		if c.host != "" {
			h["Host"] = c.host
		}
		if w := g.req(c.admin, "GET", "/api/ping", "", tok, h); w.Code != 401 {
			t.Errorf("token on %s: %d", name, w.Code)
		}
	}
	g.advance(TokenIdle - time.Minute)
	if w := g.req("admin", "GET", "/api/ping", "", tok, nil); w.Code != 200 {
		t.Fatalf("used within 12 h: %d", w.Code)
	}
	g.advance(TokenIdle + time.Minute)
	if w := g.req("admin", "GET", "/api/ping", "", tok, nil); w.Code != 401 {
		t.Fatalf("12 h unused: %d", w.Code)
	}
}

// Each request goes to the helper of the app it names (the link's app without a name); a helper
// serves one app; an app without a database or a bad name is a 404 and starts nothing.
func TestServiceRoutesPerApp(t *testing.T) {
	g := newSvc(t, map[string]bool{"shop": true, "blog": true, "web": false})
	tok := g.open("admin", "shop")
	if _, code := svcQuery(g, tok, "/api/query", "select 'shop'"); code != 200 {
		t.Fatalf("default app: %d", code)
	}
	if _, code := svcQuery(g, tok, "/api/a/blog/query", "select 'blog'"); code != 200 {
		t.Fatalf("blog: %d", code)
	}
	if c := strings.Join(g.dbs["shop"].Calls(), "|"); !strings.Contains(c, "select 'shop'") || strings.Contains(c, "blog") {
		t.Fatalf("shop's connection: %s", c)
	}
	if c := strings.Join(g.dbs["blog"].Calls(), "|"); !strings.Contains(c, "select 'blog'") || strings.Contains(c, "'shop'") {
		t.Fatalf("blog's connection: %s", c)
	}
	n := g.helpers()
	for _, p := range []string{"/api/a/web/query", "/api/a/nope/query", "/api/a/../query", "/api/a/shop/session", "/api/a/shop/a/blog/query", "/api/a/shop/"} {
		if _, code := svcQuery(g, tok, p, "select 1"); code != 404 {
			t.Errorf("%s: %d", p, code)
		}
	}
	if g.helpers() != n || n != 2 {
		t.Fatalf("helpers: %d, then %d", n, g.helpers())
	}
	// the scope guard and the read-only guard are the helper's, unchanged behind the front
	if q, _ := svcQuery(g, tok, "/api/a/blog/query", "select * from pg_authid"); q.Error == nil || q.Error.SQLState != scopeCode {
		t.Fatalf("scope guard: %+v", q.Error)
	}
	if q, _ := svcQuery(g, tok, "/api/a/blog/query", "delete from t"); q.Error == nil || q.Error.SQLState != "25006" {
		t.Fatalf("read-only guard: %+v", q.Error)
	}
	w := g.req("admin", "GET", "/api/apps", "", tok, nil)
	if !strings.Contains(w.Body.String(), `"apps":["blog","shop"]`) || !strings.Contains(w.Body.String(), `"app":"shop"`) {
		t.Fatalf("apps: %s", w.Body)
	}
	w = g.req("admin", "GET", "/api/a/blog/info", "", tok, nil)
	if !strings.Contains(w.Body.String(), `"app":"blog"`) || w.Header().Get("Content-Security-Policy") != csp || len(w.Header().Values("Content-Security-Policy")) != 1 {
		t.Fatalf("info: %v %s", w.Header(), w.Body)
	}
}

// Every check of the per-app studio's edge holds at the front.
func TestServiceRefusals(t *testing.T) {
	g := newSvc(t, map[string]bool{"shop": true})
	tok := g.open("admin", "shop")
	for name, c := range map[string]struct {
		method, path, body string
		hdr                map[string]string
		code               int
	}{
		"no token":                {"GET", "/api/ping", "", map[string]string{"Authorization": ""}, 401},
		"foreign host":            {"GET", "/api/ping", "", map[string]string{"Host": "evil.example:47200"}, 403},
		"host with a dot":         {"GET", "/api/ping", "", map[string]string{"Host": "localhost.:47200"}, 403},
		"host without a port":     {"GET", "/", "", map[string]string{"Host": "127.0.0.1"}, 403},
		"foreign origin":          {"GET", "/api/ping", "", map[string]string{"Origin": "http://evil.example"}, 403},
		"cross-site fetch":        {"GET", "/api/a/shop/tables", "", map[string]string{"Sec-Fetch-Site": "cross-site"}, 403},
		"cross-site script":       {"GET", "/s.js", "", map[string]string{"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Dest": "script"}, 403},
		"form post":               {"POST", "/api/query", "x", map[string]string{"Content-Type": "application/x-www-form-urlencoded"}, 415},
		"preflight":               {"OPTIONS", "/api/query", "", nil, 405},
		"put":                     {"PUT", "/api/query", "", nil, 405},
		"cross-site link to page": {"GET", "/", "", map[string]string{"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"}, 200},
	} {
		t0 := tok
		if v, ok := c.hdr["Authorization"]; ok && v == "" {
			t0 = ""
			delete(c.hdr, "Authorization")
		}
		w := g.req("admin", c.method, c.path, c.body, t0, c.hdr)
		if w.Code != c.code || w.Header().Get("Content-Security-Policy") != csp || w.Header().Get("X-Frame-Options") != "DENY" {
			t.Errorf("%s: %d, want %d (%s)", name, w.Code, c.code, w.Body)
		}
	}
	if w := g.req("admin", "GET", "/healthz", "", "", nil); w.Body.String() != "tando-studio "+g.v.probe+"\n" {
		t.Fatalf("healthz %q", w.Body)
	}
	if g.helpers() != 0 {
		t.Fatal("a refused request started a helper")
	}
}

// At most HelpersPerApp per app and HelpersAll in all: the one unused longest gives way; a busy
// one never does (429 then).
func TestServiceHelperLimits(t *testing.T) {
	g := newSvc(t, map[string]bool{"a1": true, "a2": true, "a3": true, "a4": true, "a5": true})
	t1, t2, t3 := g.open("admin", "a1"), g.open("admin", "a1"), g.open("admin", "a1")
	for _, tk := range []string{t1, t2, t3} {
		g.advance(time.Second)
		if _, code := svcQuery(g, tk, "/api/query", "select 1"); code != 200 {
			t.Fatalf("query: %d", code)
		}
	}
	if g.helpers() != 2 {
		t.Fatalf("a1 has %d helpers, at most %d", g.helpers(), HelpersPerApp)
	}
	for _, a := range []string{"a2", "a3", "a4", "a5"} {
		g.advance(time.Second)
		if _, code := svcQuery(g, t1, "/api/a/"+a+"/query", "select 1"); code != 200 {
			t.Fatalf("%s: %d", a, code)
		}
	}
	if g.helpers() != HelpersAll {
		t.Fatalf("%d helpers, at most %d", g.helpers(), HelpersAll)
	}
	// all busy: the next is refused, not queued, and nothing is stopped
	g.v.mu.Lock()
	for _, h := range g.v.helpers {
		h.busy++
	}
	g.v.mu.Unlock()
	if _, code := svcQuery(g, t2, "/api/a/a1/query", "select 1"); code != 429 {
		t.Fatalf("all busy: %d", code)
	}
}

// End in the page, Revoke (tando db studio --stop, a restart) and an expired token stop the
// helpers; the helper's own idle end removes it from the front.
func TestServiceEndRevokeAndHelperExit(t *testing.T) {
	g := newSvc(t, map[string]bool{"shop": true, "blog": true})
	tok := g.open("admin", "shop")
	svcQuery(g, tok, "/api/query", "select 1")
	svcQuery(g, tok, "/api/a/blog/query", "select 1")
	if g.v.Ctl("revoke blog") != "revoked=1" {
		t.Fatal("revoke blog")
	}
	if w := g.req("admin", "GET", "/api/ping", "", tok, nil); w.Code != 200 {
		t.Fatal("revoke of one app keeps the tokens")
	}
	if g.v.Ctl("revoke") != "revoked=1" {
		t.Fatal("revoke")
	}
	if w := g.req("admin", "GET", "/api/ping", "", tok, nil); w.Code != 401 {
		t.Fatal("revoke ends every token")
	}
	tok = g.open("admin", "shop")
	svcQuery(g, tok, "/api/query", "select 1")
	var h *Helper
	g.v.mu.Lock()
	h = g.v.helpers[0]
	g.v.mu.Unlock()
	h.Stop() // (as the helper's own idle end: its stdin closes, it exits)
	deadline := time.Now().Add(3 * time.Second)
	for g.helpers() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if g.helpers() != 0 {
		t.Fatal("an ended helper stays listed")
	}
	if _, code := svcQuery(g, tok, "/api/query", "select 1"); code != 200 || g.helpers() != 1 {
		t.Fatalf("a new helper on the next request: %d", code)
	}
	if w := g.req("admin", "POST", "/api/end", "{}", tok, nil); w.Code != 200 {
		t.Fatal("end")
	}
	if w := g.req("admin", "GET", "/api/ping", "", tok, nil); w.Code != 401 || g.helpers() != 0 {
		t.Fatal("end: the token and its helpers are gone")
	}
}

// Cancel reaches the helper that runs the query, through the front.
func TestServiceCancel(t *testing.T) {
	g := newSvc(t, map[string]bool{"shop": true})
	block := make(chan struct{})
	g.dbs["shop"].script = func(string) step { return step{block: block} }
	tok := g.open("admin", "shop")
	done := make(chan qresp)
	go func() { q, _ := svcQuery(g, tok, "/api/a/shop/query", "select pg_sleep(20)"); done <- q }()
	for !strings.Contains(strings.Join(g.dbs["shop"].Calls(), "|"), "exec") {
		time.Sleep(5 * time.Millisecond)
	}
	if w := g.req("admin", "POST", "/api/a/shop/cancel", `{"id":"q1"}`, tok, nil); !strings.Contains(w.Body.String(), "true") {
		t.Fatalf("cancel: %d %s", w.Code, w.Body)
	}
	if q := <-done; q.Error == nil || q.Error.Message != "stopped (cancelled)" {
		t.Fatalf("%+v", q.Error)
	}
}

func TestServiceCtl(t *testing.T) {
	g := newSvc(t, map[string]bool{"shop": true})
	g.v.cfg.Run, _ = os.MkdirTemp("/tmp", "stctl")
	defer os.RemoveAll(g.v.cfg.Run)
	a := g.v.Ctl("code admin shop 47200 prod")
	if !strings.HasPrefix(a, "code=") || !strings.Contains(a, " probe="+g.v.probe+" sock="+g.v.cfg.Run+"/u/admin/s") {
		t.Fatal(a)
	}
	if fi, err := os.Stat(g.v.cfg.Run + "/u/admin/s"); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("the admin's socket: %v %v", fi, err)
	}
	for _, l := range []string{"code admin shop 80 prod", "code admin nope 47200 prod", "code ../x shop 47200 prod", "code admin shop 47200", "revoke ../x", "rm -rf /", ""} {
		if a := g.v.Ctl(l); !strings.HasPrefix(a, "error=") {
			t.Errorf("%q: %s", l, a)
		}
	}
	if a := g.v.Ctl("ls"); a != "tokens=0 helpers=-" {
		t.Fatal(a)
	}
}

func TestParseEnvCred(t *testing.T) {
	var c Config
	env := "A=\"1\"\nDATABASE_URL=\"postgres://tando_my_shop:s3cr\\\"et@127.0.0.1:5432/tando_my_shop\"\n"
	if err := ParseEnvCred([]byte(env), "my-shop", &c); err != nil || c.Role != "tando_my_shop" || c.Database != c.Role || c.Password != `s3cr"et` {
		t.Fatalf("%v %+v", err, c)
	}
	for _, e := range []string{"A=1\n", "DATABASE_URL=\"postgres://tando_other:pw@h/tando_other\"\n", "DATABASE_URL=\"mysql://tando_my_shop:pw@h/x\"\n", "DATABASE_URL=\"postgres://tando_my_shop:@h/x\"\n"} {
		if err := ParseEnvCred([]byte(e), "my-shop", &c); err == nil {
			t.Errorf("accepted %q", e)
		}
	}
	a, err := ParseArgs([]string{"--app", "shop", "--host", "prod", "--admin", "ad", "--port", "47200", "--idle-s", "120", "--fd"})
	if err != nil || !a.FD || a.Env != "/opt/tando/apps/shop/env" || a.Cfg.Heartbeat != 0 {
		t.Fatalf("%v %+v", err, a)
	}
	if _, err := ParseArgs([]string{"--app", "shop", "--host", "prod", "--admin", "ad", "--port", "47200", "--idle-s", "120", "--fd", "--sock", "/run/tando-studio/x/s"}); err == nil {
		t.Fatal("--fd and --sock")
	}
}
