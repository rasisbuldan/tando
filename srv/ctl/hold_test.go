package ctl

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/run"
)

// app.hold / app.release: who may set and lift which reason (the reason in force is read from the
// app's state file), what reaches the agent, and what app.status shows.
func TestHold(t *testing.T) {
	dir := t.TempDir()
	var calls []string
	e := env.Env{Root: filepath.Join(dir, "opt"), Lib: filepath.Join(dir, "lib"), Proc: filepath.Join(dir, "proc"),
		Now: time.Now,
		Run: run.Func(func(_ context.Context, c run.Cmd) ([]byte, error) {
			if c.Argv[0] == "systemctl" {
				return []byte("ActiveState=inactive\n"), nil
			}
			calls = append(calls, strings.Join(c.Argv[1:], "|"))
			return []byte("held=1\nhealthy=1\n"), nil
		})}
	sd := filepath.Join(e.Root, "apps", "shop")
	os.MkdirAll(sd, 0o755)
	os.WriteFile(filepath.Join(sd, "app.conf"), []byte("memory=256M\n"), 0o644)
	state := func(s string) { os.WriteFile(filepath.Join(sd, "state"), []byte("current=20261122-100000\n"+s), 0o644) }
	state("")
	c := New(e)
	n := 0
	serve := func(id Ident, verb, args string) Response {
		n++
		in := `{"v":1,"verb":"` + verb + `","app":"shop","request_id":"hold-` + strings.Repeat("0", 6) + string(rune('a'+n)) + `"`
		if args != "" {
			in += `,"args":` + args
		}
		var b bytes.Buffer
		c.Serve(context.Background(), id, []byte(in+"}"), &b)
		var r Response
		if err := json.Unmarshal(b.Bytes(), &r); err != nil {
			t.Fatalf("not JSON: %q", b.String())
		}
		return r
	}
	w, app, rd := Ident{Mode: ModeWrite}, Ident{Mode: ModeApp, App: "shop"}, Ident{Mode: ModeRead}
	code := func(r Response) string {
		if r.Error == nil {
			return "ok"
		}
		return r.Error.Code
	}
	cases := []struct {
		state, verb, args string
		id                Ident
		want, call        string
	}{
		{"", "app.hold", `{"reason":"suspend"}`, app, "forbidden", ""},
		{"", "app.hold", `{"reason":"pause"}`, rd, "forbidden", ""},
		{"", "app.hold", `{"reason":"stop"}`, w, "bad_request", ""},
		{"", "app.hold", `{}`, w, "bad_request", ""},
		{"", "app.hold", `{"reason":"pause","message":"{env.SECRET}"}`, w, "bad_request", ""},
		{"", "app.hold", `{"reason":"pause","message":"a\" 200\nrespond x"}`, w, "bad_request", ""},
		{"", "app.hold", `{"reason":"pause","message":"` + strings.Repeat("x", 201) + `"}`, w, "bad_request", ""},
		{"", "app.hold", `{"reason":"pause","extra":1}`, w, "bad_request", ""},
		{"", "app.hold", `{"reason":"pause"}`, app, "ok", "hold|shop|pause"},
		{"", "app.hold", `{"reason":"suspend","message":"Abuse report 42, see mail."}`, w, "ok", "hold|shop|suspend|Abuse report 42, see mail."},
		{"hold=pause\n", "app.release", "", app, "ok", "release|shop"},
		{"hold=pause\n", "app.hold", `{"reason":"suspend"}`, app, "forbidden", ""},
		{"hold=suspend\n", "app.release", "", app, "forbidden", ""},
		{"hold=suspend\n", "app.hold", `{"reason":"pause"}`, app, "forbidden", ""},
		{"hold=weird\n", "app.release", "", app, "forbidden", ""},
		{"hold=suspend\n", "app.release", "", rd, "forbidden", ""},
		{"hold=suspend\n", "app.release", "", w, "ok", "release|shop"},
		{"", "app.release", `{"x":1}`, w, "bad_request", ""},
	}
	for _, x := range cases {
		state(x.state)
		calls = nil
		r := serve(x.id, x.verb, x.args)
		got := strings.Join(calls, ",")
		if code(r) != x.want || got != x.call {
			t.Errorf("%s %s %s as %s: %s %+v, agent %q; want %s %q", x.state, x.verb, x.args, x.id.Mode, code(r), r.Error, got, x.want, x.call)
		}
	}
	// app.status shows the reason and since when
	state("hold=suspend\nhold_since=1795000000\nstopped=1\n")
	r := serve(rd, "app.status", "")
	b, _ := json.Marshal(r.Result)
	for _, want := range []string{`"hold":"suspend"`, `"hold_since":1795000000`, `"stopped":true`} {
		if !strings.Contains(string(b), want) {
			t.Errorf("status lacks %s: %s", want, b)
		}
	}
	state("")
	r = serve(rd, "app.status", "")
	if b, _ := json.Marshal(r.Result); strings.Contains(string(b), "hold") {
		t.Errorf("status of an app not held: %s", b)
	}
}
