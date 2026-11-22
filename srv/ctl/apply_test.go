package ctl

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/run"
)

func TestCheckGeneration(t *testing.T) {
	cases := []struct {
		s    Spec
		gen  int64
		code string
	}{
		{Spec{}, 1, ""},
		{Spec{}, 0, "bad_request"},
		{Spec{}, -3, "bad_request"},
		{Spec{Generation: 5, Attempted: 5}, 4, "conflict"}, // older
		{Spec{Generation: 5, Attempted: 5}, 5, "conflict"}, // applied already
		{Spec{Generation: 5, Attempted: 5}, 6, ""},
		{Spec{Generation: 5, Attempted: 7, Failed: "deploy"}, 7, ""},         // a retry of the failed one
		{Spec{Generation: 5, Attempted: 7, Failed: "deploy"}, 6, "conflict"}, // older than one sent
		{Spec{Generation: 5, Attempted: 7, Failed: "deploy"}, 9, ""},
	}
	for _, c := range cases {
		e := CheckGeneration(c.s, c.gen)
		got := ""
		if e != nil {
			got = e.Code
		}
		if got != c.code {
			t.Errorf("%+v gen %d: %q, want %q", c.s, c.gen, got, c.code)
		}
	}
}

// ctlHarness: a node with the app shop; the agent answers as fail says (verb -> reason).
func ctlHarness(t *testing.T, fail map[string]string) (*Ctl, *[]string, func(Ident, string) Response) {
	t.Helper()
	dir := t.TempDir()
	var calls []string
	e := env.Env{Root: filepath.Join(dir, "opt"), Lib: filepath.Join(dir, "lib"), Proc: filepath.Join(dir, "proc"), Now: time.Now,
		Run: run.Func(func(_ context.Context, c run.Cmd) ([]byte, error) {
			calls = append(calls, strings.Join(c.Argv[1:], " "))
			if why, ok := fail[c.Argv[1]]; ok {
				c.Stderr.Write([]byte("tando-agent: " + why + "\n"))
				return nil, errors.New("exit status 1")
			}
			return []byte("healthy=1\n"), nil
		})}
	os.MkdirAll(filepath.Join(e.Root, "apps", "shop"), 0o755)
	os.WriteFile(filepath.Join(e.Root, "apps", "shop", "app.conf"), []byte("memory=512M\nstart=node s.js\ndomains=shop.example.com|redirect\n"), 0o644)
	os.WriteFile(filepath.Join(e.Root, "apps", "shop", "state"), []byte("current=20261122-100000\n"), 0o644)
	os.WriteFile(filepath.Join(e.Root, "apps", "shop", "env"), []byte("TOKEN=\"s3\\\"cret\"\nA=\"1\"\n"), 0o640)
	c := New(e)
	serve := func(id Ident, s string) Response {
		var b bytes.Buffer
		c.Serve(context.Background(), id, []byte(s), &b)
		var r Response
		if err := json.Unmarshal(b.Bytes(), &r); err != nil {
			t.Fatalf("not JSON: %q", b.String())
		}
		return r
	}
	return c, &calls, serve
}

var (
	wr  = Ident{Mode: ModeWrite}
	rd  = Ident{Mode: ModeRead}
	shp = Ident{Mode: ModeApp, App: "shop"}
)

func TestApplyGenerationAndSteps(t *testing.T) {
	c, calls, serve := ctlHarness(t, map[string]string{"env-unset": "could not write the env file"})
	// env only: no deploy step
	r := serve(wr, `{"v":1,"verb":"apply","app":"shop","request_id":"apply-0001","args":{"generation":3,"env":{"set":{"K":"v"}}}}`)
	if !r.OK || len(*calls) != 1 || (*calls)[0] != "env-set shop" {
		t.Fatalf("env apply: %+v %q", r, *calls)
	}
	if s, _ := c.LoadSpec("shop"); s.Generation != 3 || s.Attempted != 3 {
		t.Fatalf("spec %+v", s)
	}
	for _, g := range []string{"2", "3"} {
		r = serve(wr, `{"v":1,"verb":"apply","app":"shop","request_id":"apply-old-`+g+`","args":{"generation":`+g+`,"env":{"set":{"K":"w"}}}}`)
		if r.Error == nil || r.Error.Code != "conflict" || len(*calls) != 1 {
			t.Fatalf("generation %s: %+v", g, r)
		}
	}
	// a failing step: named; the steps before it are reported as kept; the generation not recorded
	r = serve(wr, `{"v":1,"verb":"apply","app":"shop","request_id":"apply-0004","args":{"generation":4,"env":{"set":{"K":"x"},"unset":["OLD"]}}}`)
	if r.Error == nil || !strings.Contains(r.Error.Message, "step env.unset failed") || !strings.Contains(r.Error.Message, "kept: env.set") {
		t.Fatalf("failed step: %+v", r)
	}
	if s, _ := c.LoadSpec("shop"); s.Generation != 3 || s.Attempted != 4 || s.Failed != "env.unset" {
		t.Fatalf("spec after a failure %+v", s)
	}
	// settings need an artifact (none applied before): refused before any step
	n := len(*calls)
	r = serve(wr, `{"v":1,"verb":"apply","app":"shop","request_id":"apply-0005","args":{"generation":5,"settings":{"memory":"1G"}}}`)
	if r.Error == nil || r.Error.Code != "bad_request" || len(*calls) != n {
		t.Fatalf("settings without artifact: %+v", r)
	}
	// a code setting is not the spec's
	r = serve(wr, `{"v":1,"verb":"apply","app":"shop","request_id":"apply-0006","args":{"generation":6,"settings":{"start":"sh -c x"}}}`)
	if r.Error == nil || r.Error.Code != "bad_request" {
		t.Fatalf("code setting in spec: %+v", r)
	}
	// apply and import are the write principal's
	r = serve(shp, `{"v":1,"verb":"apply","app":"shop","request_id":"apply-0007","args":{"generation":7}}`)
	if r.Error == nil || r.Error.Code != "forbidden" {
		t.Fatalf("app principal apply: %+v", r)
	}
	r = serve(wr, `{"v":1,"verb":"app.import","app":"shop","request_id":"import-001","args":{"generation":1}}`)
	if r.Error == nil || r.Error.Code != "conflict" {
		t.Fatalf("import over an existing app: %+v", r)
	}
}

func TestExportAndDrain(t *testing.T) {
	c, calls, serve := ctlHarness(t, nil)
	r := serve(rd, `{"v":1,"verb":"app.export","app":"shop"}`)
	b, _ := json.Marshal(r.Result)
	if !r.OK || strings.Contains(string(b), "cret") || !strings.Contains(string(b), `"env_names":["A","TOKEN"]`) ||
		!strings.Contains(string(b), `"domains":["shop.example.com"]`) || !strings.Contains(string(b), `"memory":"512M"`) {
		t.Fatalf("export: %s", b)
	}
	if r = serve(rd, `{"v":1,"verb":"app.export","app":"shop","args":{"values":true}}`); r.Error == nil || r.Error.Code != "forbidden" {
		t.Fatalf("values to read: %+v", r)
	}
	if r = serve(shp, `{"v":1,"verb":"app.export","app":"shop","args":{"values":true}}`); r.Error == nil || r.Error.Code != "forbidden" {
		t.Fatalf("values to the app: %+v", r)
	}
	r = serve(wr, `{"v":1,"verb":"app.export","app":"shop","args":{"values":true}}`)
	b, _ = json.Marshal(r.Result)
	if !r.OK || !strings.Contains(string(b), `"TOKEN":"s3\"cret"`) {
		t.Fatalf("values: %s", b)
	}
	// export is not kept by the request store (no value on the node's disk)
	if out, _ := grepTree(c.Dir, "cret"); out {
		t.Fatal("an env value was written under the store")
	}
	// drain: new apps refused, the existing one deployed to as before
	if r = serve(shp, `{"v":1,"verb":"node.drain","request_id":"drain-0001"}`); r.Error == nil || r.Error.Code != "forbidden" {
		t.Fatalf("drain by app: %+v", r)
	}
	r = serve(wr, `{"v":1,"verb":"node.drain","request_id":"drain-0002","args":{"stop_apps":true,"stop_order":["shop"]}}`)
	if !r.OK || !c.draining() || (*calls)[len(*calls)-1] != "stop shop" {
		t.Fatalf("drain: %+v %q", r, *calls)
	}
	r = serve(wr, `{"v":1,"verb":"app.deploy","app":"new","request_id":"deploy-0001","args":{"url":"https://a.example.com/x.tar.gz","sha256":"`+strings.Repeat("a", 64)+`","size":10}}`)
	if r.Error == nil || r.Error.Code != "forbidden" || !strings.Contains(r.Error.Message, "draining") {
		t.Fatalf("new app while draining: %+v", r)
	}
	r = serve(wr, `{"v":1,"verb":"inventory"}`)
	b, _ = json.Marshal(r.Result)
	if !strings.Contains(string(b), `"draining":true`) {
		t.Fatalf("inventory: %s", b)
	}
	if r = serve(wr, `{"v":1,"verb":"node.drain","request_id":"drain-0003","args":{"off":true}}`); !r.OK || c.draining() {
		t.Fatalf("undrain: %+v", r)
	}
}

// grepTree: whether any file under dir contains s.
func grepTree(dir, s string) (bool, error) {
	found := false
	err := filepath.Walk(dir, func(p string, fi os.FileInfo, err error) error {
		if err == nil && fi.Mode().IsRegular() {
			if b, _ := os.ReadFile(p); bytes.Contains(b, []byte(s)) {
				found = true
			}
		}
		return nil
	})
	return found, err
}
