package dash

import (
	"errors"
	"strings"
	"testing"
)

func TestAppReadShapes(t *testing.T) {
	for _, a := range [][]string{
		{"jobs", "ls", "shop", "--json", "-H", "a"},
		{"requests", "summary", "shop", "--json", "-H", "a", "--since", "7d"},
		{"errors", "shop", "--json", "-H", "a"},
		{"env", "ls", "shop", "--names", "--json", "-H", "a"},
		{"env", "log", "-a", "shop", "--json", "-H", "a"},
		{"alerts", "--json", "-H", "a"},
		{"history", "--json", "-H", "a"},
	} {
		if _, err := Allowed(a); err != nil {
			t.Errorf("%q: %v", a, err)
		}
	}
	for _, a := range [][]string{
		{"env", "ls", "shop", "--json", "-H", "a"}, // values (audited as a reveal): never
		{"env", "ls", "shop", "--names", "--show", "--json", "-H", "a"},
		{"env", "ls", "shop", "--show", "--json", "-H", "a"},
		{"env", "log", "-a", "shop", "--json", "-H", "a", "3"},
		{"jobs", "run", "nightly", "-a", "shop", "-H", "a"},
		{"jobs", "ls", "shop", "-H", "a"},
		{"jobs", "shop", "--json", "-H", "a"},
		{"requests", "summary", "shop", "--json", "-H", "a"},
		{"requests", "summary", "shop", "--json", "-H", "a", "--since", "30d"},
		{"requests", "tail", "shop", "-H", "a", "-f"},
		{"errors", "shop", "--json", "-H", "a", "-n", "500"},
		{"alerts", "--json", "-H", "a", "--watch", "2"},
		{"alerts", "silence", "all", "off", "-H", "a"},
		{"alerts", "disable", "--json", "-H", "a"},
		{"history", "--json", "-H", "a", "-n", "999"},
		{"history", "shop", "--json"},
	} {
		if _, err := Allowed(a); !errors.Is(err, ErrRefused) {
			t.Errorf("not refused: %q", a)
		}
	}
}

func TestAppReads(t *testing.T) {
	e := newEnv(t, nil, nil)
	e.login()
	for _, c := range []struct{ path, argv string }{
		{"/api/jobs?host=a&app=shop", "jobs ls shop --json -H a"},
		{"/api/requests?host=a&app=shop", "requests summary shop --json -H a --since 1h"},
		{"/api/requests?host=a&app=shop&range=7d", "requests summary shop --json -H a --since 7d"},
		{"/api/errors?host=a&app=shop", "errors shop --json -H a"},
		{"/api/envnames?host=a&app=shop", "env ls shop --names --json -H a"},
		{"/api/envlog?host=a&app=shop", "env log -a shop --json -H a"},
		{"/api/alerts?host=a", "alerts --json -H a"},
		{"/api/history?host=a", "history --json -H a"},
	} {
		n := len(e.runs())
		st, m := e.get(c.path)
		d, _ := m["data"].(map[string]any)
		if st != 200 || d == nil || d["argv"] != c.argv || m["cached"] != false || m["host"] != "a" || m["ran_at"] == nil || m["next_poll_s"] == nil {
			t.Fatalf("%s: %d %v", c.path, st, m)
		}
		// cached 60 s: a second ask runs nothing
		if st, m = e.get(c.path); st != 200 || m["cached"] != true || len(e.runs()) != n+1 {
			t.Fatalf("%s: second: %d %v %d", c.path, st, m, len(e.runs())-n)
		}
	}
	for _, q := range []string{"/api/jobs?host=a", "/api/jobs?host=a&app=../x", "/api/requests?host=a&app=shop&range=30d",
		"/api/errors?host=a&app=shop&range=1h", "/api/alerts?host=a&app=shop", "/api/history?host=a;b", "/api/envnames?host=a&app=Shop"} {
		if st, _ := e.get(q); st != 400 {
			t.Errorf("%s: %d", q, st)
		}
	}
	if st, m := e.get("/api/envlog?host=zz&app=shop"); st != 404 || errCode(m) != "no_host" {
		t.Fatal(st, m)
	}
	if st, m := e.get("/api/history?host=fail1"); st != 502 || errCode(m) != "cli" || !strings.Contains(m["error"].(map[string]any)["message"].(string), "Connection refused") {
		t.Fatal(st, m)
	}
	if st, m := e.get("/api/alerts?host=garbage1"); st != 502 || errCode(m) != "bad_output" {
		t.Fatal(st, m)
	}
}
