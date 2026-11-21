package dash

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestAllowlist(t *testing.T) {
	ok := [][]string{
		{"--version"},
		{"help", "snapshot"},
		{"snapshot", "--json", "-H", "web-1"},
		{"snapshot", "-H", "web-1", "--json", "--app", "shop", "--range", "7d"},
		{"snapshot", "--json", "-H", "vps.example_2", "--app", "shop"},
		{"doctor", "web-1", "--json"},
		{"host", "status", "web-1", "--json"},
		{"health", "shop", "--json", "-H", "web-1"},
		{"restart", "shop", "-H", "web-1"},
		{"stop", "shop", "-H", "web-1"},
		{"start", "shop", "-H", "web-1"},
		{"deploy", "-a", "shop", "-H", "web-1"},
		{"rollback", "shop", "-H", "web-1"},
		{"rollback", "shop", "20261113-171442", "-H", "web-1"},
		{"env", "set", "STRIPE_KEY", "-a", "shop", "-H", "web-1"},
		argvSnapshot("a", "web", "24h"), argvDoctor("a"), argvHostStatus("a"),
	}
	for _, a := range ok {
		if _, err := Allowed(a); err != nil {
			t.Errorf("allowed %q: %v", a, err)
		}
	}
	refused := [][]string{
		{"health", "--forget"},
		{"health", "shop", "--forget", "--json", "-H", "a"},
		{"health", "shop", "--json", "-H", "a", "--forget"},
		{"env", "ls"},
		{"env", "ls", "shop", "-H", "a"},
		{"env-ls"},
		{"snapshot", "--json", "-H", "a", "--verbose"},     // unknown flag
		{"snapshot", "--json", "-H", "a", "--app=shop"},    // = form
		{"snapshot", "--json"},                             // -H required
		{"snapshot", "--json", "-H", "a", "--range", "1h"}, // --range needs --app
		{"snapshot", "--json", "-H", "a", "--range", "2h", "--app", "shop"},
		{"snapshot", "--json", "-H", "a", "-H", "b"},
		{"snapshot", "--json", "-H", ".."},
		{"snapshot", "--json", "-H", "a..b"},
		{"snapshot", "--json", "-H", "../etc"},
		{"snapshot", "--json", "-H", "a;b"},
		{"snapshot", "--json", "-H", "a b"},
		{"snapshot", "--json", "-H", "-x"},
		{"snapshot", "--json", "-H", "a", "--app", "../x"},
		{"snapshot", "--json", "-H", "a", "--app", "Shop"},
		{"snapshot", "--json", "-H", "a", "--app", "-shop"},
		{"snapshot", "--json", "-H", "a", "--app", "a"},
		{"snapshot", "--json", "-H", "a", "extra"},
		{"doctor", "--json"},
		{"doctor", "a", "b", "--json"},
		{"doctor", "-x", "--json"},
		{"host", "rm", "a"},
		{"restart", "shop"},
		{"restart", "shop", "-H", "a", "--all"},
		{"deploy"},
		{"deploy", "-a", "shop", "-H", "a", "--force"},
		{"deploy", "-a", "shop", "-H", "a", "--yes"},
		{"deploy", "-a", "shop", "-H", "a", "--dry-run"},
		{"deploy", "-H", "a"},
		{"deploy", "shop", "-H", "a"},
		{"rollback", "shop"},
		{"rollback", "shop", "latest", "-H", "a"},
		{"rollback", "shop", "20261113-171442", "x", "-H", "a"},
		{"rollback", "-H", "a"},
		{"stop", "shop", "-H", "a", "--all"},
		{"start", "-H", "a"},
		{"env", "set", "K=V", "-a", "shop", "-H", "a"}, // a value in argv
		{"env", "set", "K", "V", "-a", "shop", "-H", "a"},
		{"env", "set", "K", "-H", "a"},
		{"env", "set", "K", "-a", "shop", "-H", "a", "--note", "x"},
		{"env", "set", "1K", "-a", "shop", "-H", "a"},
		{"env", "unset", "K", "-a", "shop", "-H", "a"},
		{"env", "import", "-a", "shop", "-H", "a"},
		{"ssh", "a"},
		{"sh", "-c", "id"},
		{"--version", "x"},
		{},
	}
	for _, a := range refused {
		if _, err := Allowed(a); !errors.Is(err, ErrRefused) {
			t.Errorf("not refused: %q", a)
		}
	}
	for _, h := range []string{"", ".", "..", "a..b", "-a", ".a", "a;b", "a b", "a/b", "a$b", "ä", strings.Repeat("a", 65)} {
		if ValidHost(h) {
			t.Errorf("host %q valid", h)
		}
	}
	for _, a := range []string{"a", "1ab", "ab_", "Ab", strings.Repeat("a", 25), "a..b", "ab;"} {
		if ValidApp(a) {
			t.Errorf("app %q valid", a)
		}
	}
}

// the server refuses before any child starts, even with a runner that would run anything
func TestServerAllowlistBeforeRunner(t *testing.T) {
	called := 0
	r := FuncRunner(func(ctx context.Context, q Req) (Result, error) { called++; return Result{Stdout: []byte("{}")}, nil })
	e := newEnv(t, r, nil)
	if _, err := e.srv.run(context.Background(), Req{Argv: []string{"health", "--forget"}}); !errors.Is(err, ErrRefused) {
		t.Fatal(err)
	}
	if called != 0 {
		t.Fatal("runner called")
	}
	// the exec runner checks too
	x, _ := fakeExec(t, e.fake, 1<<20)
	if _, err := x.Run(context.Background(), Req{Argv: []string{"env", "ls"}}); !errors.Is(err, ErrRefused) {
		t.Fatal(err)
	}
	if len(e.runs()) != 0 {
		t.Fatal("a child ran")
	}
	// names in the API are checked before the CLI is reached
	e.login()
	for _, q := range []string{"host=a;b", "host=..", "host=-x", "host=a%20b", "host=a&app=../x", "host=a&app=web&range=2h", "host=a&range=1h"} {
		if st, _ := e.get("/api/snapshot?" + q); st != 400 {
			t.Errorf("%s: %d", q, st)
		}
	}
	if st, m := e.get("/api/snapshot?host=nohost"); st != 404 || errCode(m) != "no_host" {
		t.Errorf("unknown host: %d %v", st, m)
	}
	if called != 0 {
		t.Fatal("runner called for a bad request")
	}
}

func TestSession(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	clock := func() time.Time { return now }
	r := FuncRunner(func(ctx context.Context, q Req) (Result, error) { return Result{Stdout: []byte(`{"x":1}`)}, nil })
	e := newEnv(t, r, func(c *Config) { c.Now = clock })

	// no cookie: 401 "session"
	if st, m := e.get("/api/ping"); st != 401 || errCode(m) != "session" {
		t.Fatalf("no cookie: %d %v", st, m)
	}
	// a code works once
	code := e.srv.NewCode()
	resp, _ := noRedirect.Get(e.ts.URL + "/open?code=" + code)
	resp.Body.Close()
	if resp.StatusCode != 303 || resp.Header.Get("Location") != "/" {
		t.Fatalf("open: %d", resp.StatusCode)
	}
	var ck *http.Cookie
	for _, c := range resp.Cookies() {
		if c.Name == cookieName {
			ck = c
		}
	}
	if ck == nil || !ck.HttpOnly || ck.SameSite != http.SameSiteStrictMode || ck.Path != "/" || ck.MaxAge < 86400 {
		t.Fatalf("cookie: %+v", ck)
	}
	sc := resp.Header.Get("Set-Cookie")
	if !strings.Contains(sc, "HttpOnly") || !strings.Contains(sc, "SameSite=Strict") || !strings.Contains(sc, "Path=/") {
		t.Fatalf("Set-Cookie: %s", sc)
	}
	resp, _ = noRedirect.Get(e.ts.URL + "/open?code=" + code)
	resp.Body.Close()
	if resp.StatusCode != 401 || len(resp.Cookies()) != 0 {
		t.Fatalf("second use: %d", resp.StatusCode)
	}
	// a code expires after 60 s
	old := e.srv.NewCode()
	now = now.Add(61 * time.Second)
	resp, _ = noRedirect.Get(e.ts.URL + "/open?code=" + old)
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("expired code: %d", resp.StatusCode)
	}
	resp, _ = noRedirect.Get(e.ts.URL + "/open?code=nonsense")
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatal("bad code")
	}
	e.cookie = ck
	if st, _ := e.get("/api/ping"); st != 200 {
		t.Fatalf("with cookie: %d", st)
	}
	// a forged cookie
	e.cookie = &http.Cookie{Name: cookieName, Value: strings.Repeat("ab", 32)}
	if st, _ := e.get("/api/ping"); st != 401 {
		t.Fatal("forged cookie")
	}
	e.cookie = ck

	// the session survives a restart (hashes on disk)
	e2, _ := New(Config{Port: e.port, ConfigDir: e.dir, Runner: r, Now: clock}, nil)
	req, _ := http.NewRequest("GET", "/api/ping", nil)
	req.Host = "127.0.0.1:" + itoa(e.port)
	req.AddCookie(ck)
	if !e2.sess.valid(req) {
		t.Fatal("session lost across restart")
	}
	// and ends after 30 days
	now = now.Add(31 * 24 * time.Hour)
	if st, m := e.get("/api/ping"); st != 401 || errCode(m) != "session" {
		t.Fatalf("expired session: %d", st)
	}
}

func itoa(i int) string { return strconv.Itoa(i) }

func TestRequestChecks(t *testing.T) {
	r := FuncRunner(func(ctx context.Context, q Req) (Result, error) { return Result{Stdout: []byte(`{}`)}, nil })
	e := newEnv(t, r, nil)
	e.login()
	p := itoa(e.port)
	host := func(h string) reqOpt { return func(r *http.Request) { r.Host = h } }

	if st, _ := e.get("/api/ping"); st != 200 {
		t.Fatal("baseline")
	}
	if st, _ := e.get("/api/ping", host("localhost:"+p)); st != 200 {
		t.Fatal("localhost")
	}
	for _, h := range []string{"evil.test:" + p, "127.0.0.1", "127.0.0.1:1", "localhost.:" + p, "[::1]:" + p, "127.0.0.2:" + p, "LOCALHOST:" + p} {
		if st, m := e.get("/api/ping", host(h)); st != 403 || errCode(m) != "host" {
			t.Errorf("Host %s: %d", h, st)
		}
	}
	for _, o := range []string{"http://evil.test", "http://127.0.0.1:1", "https://127.0.0.1:" + p, "null"} {
		if st, m := e.get("/api/ping", hdr("Origin", o)); st != 403 || errCode(m) != "origin" {
			t.Errorf("Origin %s: %d", o, st)
		}
	}
	if st, _ := e.get("/api/ping", hdr("Origin", "http://127.0.0.1:"+p)); st != 200 {
		t.Error("same origin refused")
	}
	for _, s := range []string{"cross-site", "same-site"} {
		if st, _ := e.get("/api/ping", hdr("Sec-Fetch-Site", s)); st != 403 {
			t.Errorf("Sec-Fetch-Site %s on the API", s)
		}
		// a page navigation from a link is fine (no data), a subresource is not
		if st, _ := e.get("/", hdr("Sec-Fetch-Site", s), hdr("Sec-Fetch-Mode", "navigate"), hdr("Sec-Fetch-Dest", "document")); st == 403 {
			t.Errorf("navigation from %s refused", s)
		}
		if st, _ := e.get("/index.html", hdr("Sec-Fetch-Site", s), hdr("Sec-Fetch-Mode", "no-cors"), hdr("Sec-Fetch-Dest", "script")); st != 403 {
			t.Errorf("subresource from %s allowed", s)
		}
	}
	// JSON-only POST
	for _, ct := range []string{"", "text/plain", "application/x-www-form-urlencoded", "multipart/form-data"} {
		st, _, _ := e.req(nil, "POST", "/api/confirm", `{}`, func(r *http.Request) {
			if ct == "" {
				r.Header.Del("Content-Type")
			} else {
				r.Header.Set("Content-Type", ct)
			}
		})
		if st != 415 {
			t.Errorf("POST %q: %d", ct, st)
		}
	}
	// no CORS: preflight refused, no ACAO anywhere; the security headers on every answer
	st, _, h := e.req(nil, "OPTIONS", "/api/ping", nil, hdr("Access-Control-Request-Method", "POST"))
	if st != 405 || h.Get("Access-Control-Allow-Origin") != "" {
		t.Errorf("OPTIONS: %d %v", st, h)
	}
	for _, path := range []string{"/api/ping", "/", "/api/nothing"} {
		_, _, h := e.req(nil, "GET", path, nil)
		if h.Get("Content-Security-Policy") != CSP || h.Get("X-Content-Type-Options") != "nosniff" ||
			h.Get("Referrer-Policy") != "no-referrer" || h.Get("Cross-Origin-Opener-Policy") != "same-origin" || h.Get("Access-Control-Allow-Origin") != "" {
			t.Errorf("%s headers: %v", path, h)
		}
	}
	if !strings.Contains(CSP, "require-trusted-types-for 'script'") || !strings.Contains(CSP, "frame-ancestors 'none'") {
		t.Fatal("CSP")
	}
	// bounded body
	big := `{"action":"noop","host":"a","app":"` + strings.Repeat("x", 70<<10) + `"}`
	if st, m := e.post("/api/confirm", big); st != 413 {
		t.Errorf("big body: %d %v", st, m)
	}
	// unknown fields refused
	if st, _ := e.post("/api/confirm", `{"action":"noop","host":"a","app":"web","evil":1}`); st != 400 {
		t.Error("unknown field")
	}
	// newcode: the key of dash.lock, nothing else
	if st, _ := e.post("/api/newcode", `{}`); st != 401 {
		t.Error("newcode without key")
	}
	e.cookie = nil
	st, m := e.post("/api/newcode", `{}`, hdr("X-Tando-Dash-Key", "ctl-key-for-tests"))
	if st != 200 || m["code"] == nil {
		t.Fatalf("newcode: %d %v", st, m)
	}
	resp, _ := noRedirect.Get(e.ts.URL + "/open?code=" + m["code"].(string))
	resp.Body.Close()
	if resp.StatusCode != 303 {
		t.Fatal("newcode's code does not open")
	}
}

func TestPanicRecovery(t *testing.T) {
	r := FuncRunner(func(ctx context.Context, q Req) (Result, error) { panic("boom in a run") })
	e := newEnv(t, r, nil)
	e.srv.static = http.HandlerFunc(func(http.ResponseWriter, *http.Request) { panic("boom in a handler") })
	e.login()
	if st, m := e.get("/api/snapshot?host=a"); st != 500 || errCode(m) != "internal" {
		t.Fatalf("panic in a run: %d %v", st, m)
	}
	if st, m := e.get("/index.html"); st != 500 || errCode(m) != "internal" {
		t.Fatalf("panic in a handler: %d %v", st, m)
	}
	// still serving
	if st, _ := e.get("/api/ping"); st != 200 {
		t.Fatal("not serving after panics")
	}
	// a panicking write ends failed and frees the app
	st, m := e.post("/api/confirm", map[string]string{"action": "noop", "host": "a", "app": "web"})
	if st != 200 {
		t.Fatal(st, m)
	}
	st, m = e.post("/api/action", map[string]string{"action": "noop", "host": "a", "app": "web", "confirm": m["token"].(string)}, hdr("Idempotency-Key", "panic-key-1"))
	if st != 202 {
		t.Fatal(st, m)
	}
	if !until(5*time.Second, func() bool { _, m := e.get("/api/action?key=panic-key-1"); return m["status"] == "failed" }) {
		t.Fatal("write did not end failed")
	}
	if e.srv.WritesRunning() != 0 {
		t.Fatal("app still locked")
	}
}
