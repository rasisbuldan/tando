package reqlog

import (
	"strings"
	"testing"
)

func TestAppendClean(t *testing.T) {
	for raw, want := range map[string]string{
		"/plain": "/plain", `/a\/b`: "/a/b", `/n\nr\rt\tb\bf\f`: `/n\nr\rt\tb\bf\f`, `\u001b[2J`: "^[[2J",
		`\u0009`: "^I", `\u0085`: `\x85`, `\uZZZZ`: "?", `\u12`: "^R", `\ud83d`: "?", `x\`: "x",
		"caf\u00e9": "café", "c1 \u0085 raw": "c1 ? raw", "ctl \x01\x7f": "ctl ??", `\"q\"`: `"q"`, `\\`: `\`,
	} {
		if got := string(AppendClean(nil, []byte(raw))); got != want {
			t.Errorf("AppendClean(%q) = %q, want %q", raw, got, want)
		}
	}
}

func TestAppendPath(t *testing.T) {
	for u, want := range map[string]string{
		"": "/", "/": "/", "nopath": "/", "a/b": "/b", "/users/123/orders/9f86d081884c7d65": "/users/:n/orders/:id",
		"/x?-": "/x", "/q/1?a=b/c": "/q/:n", "//double": "//double", "/trail/": "/trail/", "/h/9f86d081884c7d6": "/h/9f86d081884c7d6",
		"/u/550e8400-e29b-41d4-a716-446655440000": "/u/:id", "/v/1.2": "/v/1.2", "/" + strings.Repeat("z", 100): "/" + strings.Repeat("z", 78) + "~", "/" + strings.Repeat("a", 100): "/:id",
	} {
		if got := string(AppendPath(nil, []byte(u))); got != want {
			t.Errorf("AppendPath(%q) = %q, want %q", u, got, want)
		}
	}
}

func TestParse(t *testing.T) {
	p := NewParser()
	var r Request
	line := `{"level":"info","ts":1794587950.5,"request":{"remote_ip":"10.0.0.1","method":"GET","uri":"/x","client_ip":"1.2.3.4"},"duration":0.25,"size":12,"status":503,"status":200}`
	if !p.Parse([]byte(line), &r) || r.Ts != 1794587950.5 || r.Status != 503 || string(r.Method) != "GET" ||
		string(r.Addr()) != "1.2.3.4" || string(r.RemoteIP) != "10.0.0.1" || r.Duration != 0.25 {
		t.Fatalf("%+v", r)
	}
	long := `{"ts":1,"request":{"uri":"` + strings.Repeat("u", 5000) + `","method":""},"status":0}`
	if !p.Parse([]byte(long), &r) || r.URI != nil || r.Method == nil || len(r.Method) != 0 || r.Counted() {
		t.Fatalf("a path over 4095 bytes reads as none; an empty method is no method: %q %v", r.Method, r.Counted())
	}
	for _, bad := range []string{"", "x", "{", `{"ts":"1"`, `{"request":[1]}`, strings.Repeat("{", 100000)} {
		p.Parse([]byte(bad), &r)
	}
}

func TestHist(t *testing.T) {
	var h Hist
	for i := 0; i < 100; i++ {
		h.Add(0.1) // 100 ms
	}
	h.Add(1e300)
	h.Add(-1)
	if v, _ := h.Percentile(0.5); v < 97.5 || v > 102.5 {
		t.Fatalf("p50 %v not within 2.5%% of 100 ms", v)
	}
}

func FuzzRequest(f *testing.F) {
	f.Add([]byte(`{"level":"info","ts":1794587950.1,"request":{"remote_ip":"1.1.1.1","method":"GET","uri":"/a/1?-"},"duration":0.1,"size":3,"status":500}`))
	f.Fuzz(func(t *testing.T, line []byte) {
		p := NewParser()
		var r Request
		if !p.Parse(line, &r) {
			return
		}
		s := NewSummary(3600, 1794590000, 60)
		s.Add(&r)
		var c Chunk
		c.Add(&r)
		c.Tops(3)
		row, ok := RowFilter{}.Make(&r)
		if !ok {
			return
		}
		for _, f := range row {
			if strings.ContainsAny(f, "\t\n\r\x1b") {
				t.Fatalf("a control character in a field: %q", f)
			}
		}
		if p := string(AppendPath(nil, AppendClean(nil, r.URI))); len(p) > 80 {
			t.Fatalf("path of %d bytes", len(p))
		}
	})
}

func TestQuick(t *testing.T) {
	ok := `{"level":"info","ts":1794587950.5,"logger":"x","request":{"uri":"/\"status\":1}"},"size":1,"status":503}`
	if ts, st, q := Quick([]byte(ok)); !q || ts != 1794587950.5 || st != 503 {
		t.Fatal(ts, st, q)
	}
	for _, l := range []string{`{"ts":1,"status":500}`, `{"level":"info","ts":1,"status":5000}`, `{"level":"info","ts":1,"a":{"status":500}}`,
		`{"level":"info","ts":1,"status":500,"status":200}`, `{"level":"info","ts":1e3,"status":500}`} {
		if _, _, q := Quick([]byte(l)); q {
			t.Errorf("%s: read without decoding", l)
		}
	}
}

// whatever Quick reads, the decoder reads the same
func FuzzQuick(f *testing.F) {
	f.Add([]byte(`{"level":"info","ts":1794587950.1,"request":{"method":"GET","uri":"/"},"duration":0.1,"size":3,"status":500}`))
	f.Add([]byte(`{"level":"info","ts":1,"x":{"status":2},"status":500}`))
	f.Fuzz(func(t *testing.T, line []byte) {
		ts, okT := QuickTS(line)
		st, okS := QuickStatus(line)
		var r Request
		if !NewParser().Parse(line, &r) {
			return
		}
		if okT && r.Ts != ts || okS && r.Status != st {
			t.Fatalf("quick %v %v (%v %v), decoded %v %v", ts, st, okT, okS, r.Ts, r.Status)
		}
	})
}
