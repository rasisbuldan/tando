package reqlog

import (
	"bytes"
	"strconv"
	"testing"
)

const caddyLine = `{"level":"info","ts":1794756159.183189,"logger":"http.log.access.log0","msg":"handled request","request":{"remote_ip":"10.0.24.19","remote_port":"54847","proto":"HTTP/1.1","method":"POST","host":"perf.example.com","uri":"/api/fail/19773"},"bytes_read":0,"user_id":"","duration":0.002472146,"size":33255,"status":200}`

func sameRequest(a, b *Request) bool {
	eq := func(x, y []byte) bool { return (x == nil) == (y == nil) && bytes.Equal(x, y) }
	return a.Ts == b.Ts && a.Duration == b.Duration && a.Status == b.Status && a.Size == b.Size &&
		eq(a.Method, b.Method) && eq(a.URI, b.URI) && eq(a.ClientIP, b.ClientIP) && eq(a.RemoteIP, b.RemoteIP)
}

func TestFastShapes(t *testing.T) {
	p := NewParser()
	for _, l := range []string{caddyLine, `{}`, `{"request":{}}`, `{"request":"x","request":{"method":"GET"}}`,
		`{"ts":1,"ts":2,"status":"500","status":404}`, `{"a":[1,{"b":[true,false,null]}],"size":-0.5e-3}`,
		`{"request":{"uri":"/\u00e9\"\\\/\b\f\n\r\t","method":"","headers":{"X":["a"]}},"status":0}`} {
		var f, d Request
		if !fastParse([]byte(l), &f) {
			t.Errorf("not read fast: %s", l)
			continue
		}
		if !p.Decode([]byte(l), &d) || !sameRequest(&f, &d) {
			t.Errorf("%s:\nfast %+v\n dec %+v", l, f, d)
		}
	}
	for _, l := range []string{`{ "ts":1}`, `{"ts":01}`, `{"ts":1.}`, `{"a":"\ud83d"}`, `{"a":"x` + "\x01" + `"}`, `{"a":1}x`, `[1]`,
		`{"a":tru}`, `{"a":1,}`} {
		var f Request
		if fastParse([]byte(l), &f) {
			t.Errorf("read fast: %s", l)
		}
	}
}

// the fast scanner never disagrees with the decoder: when it reads a line, the decoder reads the
// same fields from it
func FuzzFast(f *testing.F) {
	f.Add([]byte(caddyLine))
	f.Add([]byte(`{"level":"info","ts":1,"request":{"method":"GET","uri":"/\u001b","client_ip":"1"},"status":500,"status":200}`))
	f.Add([]byte(`{"request":{"uri":"a","uri":"b"},"request":{"uri":"c"},"x":[{"y":null}]}`))
	f.Fuzz(func(t *testing.T, line []byte) {
		var dr Request
		dec := NewParser().Decode(line, &dr)
		for _, fast := range []func([]byte, *Request) bool{caddyParse, fastParse} {
			var fr Request
			if fast(line, &fr) && (!dec || !sameRequest(&fr, &dr)) {
				t.Fatalf("%q:\nfast %+v\n dec %v %+v", line, fr, dec, dr)
			}
		}
	})
}

func TestCaddyLayout(t *testing.T) {
	var r Request
	for _, l := range []string{caddyLine,
		`{"level":"info","ts":1794587950.1234567,"logger":"http.log.access.log0","msg":"handled request","request":{"remote_ip":"127.0.0.1","remote_port":"41234","client_ip":"127.0.0.1","proto":"HTTP/2.0","method":"GET","host":"a.localhost","uri":"/x?-"},"bytes_read":0,"duration":0.000123456,"size":3,"status":503}`} {
		if !caddyParse([]byte(l), &r) {
			t.Errorf("not read by the layout: %s", l)
		}
	}
	for v, want := range map[string]float64{"0": 0, "-0": 0, "1794756159.183189": 1794756159.183189, "0.002472146": 0.002472146,
		"12.5": 12.5, "1e3": 1000, "123456789012345678": 123456789012345678, "0.1234567890123456789": 0.1234567890123456789} {
		if got := decimal([]byte(v)); got != want {
			t.Errorf("decimal(%s) = %v", v, got)
		}
	}
}

// decimal agrees with strconv on every number the grammar allows
func FuzzDecimal(f *testing.F) {
	f.Add("1794756159.183189")
	f.Add("-0.000000000000001")
	f.Fuzz(func(t *testing.T, v string) {
		s := scanner{b: []byte(v)}
		if _, e, ok := s.num(); !ok || e != len(v) {
			return
		}
		want, _ := strconv.ParseFloat(v, 64)
		if got := decimal([]byte(v)); got != want && !(got != got && want != want) {
			t.Fatalf("%s: %v, strconv %v", v, got, want)
		}
	})
}

func TestNoAllocations(t *testing.T) {
	p := NewParser()
	var r Request
	s := NewSummary(86400, 1794760000, 60)
	line := []byte(caddyLine)
	p.Parse(line, &r)
	s.Add(&r)
	if n := testing.AllocsPerRun(1000, func() { p.Parse(line, &r) }); n != 0 {
		t.Fatalf("Parse: %v allocations per line", n)
	}
	if n := testing.AllocsPerRun(1000, func() { p.Parse(line, &r); s.Add(&r) }); n != 0 {
		t.Fatalf("Parse + Summary.Add of a known path: %v allocations per line", n)
	}
	f := RowFilter{From: 1794760000, MinStatus: 500}
	if n := testing.AllocsPerRun(1000, func() { f.Skips(line) }); n != 0 {
		t.Fatalf("Skips: %v allocations", n)
	}
}

func BenchmarkParseFast(b *testing.B) {
	p := NewParser()
	var r Request
	line := []byte(caddyLine)
	b.SetBytes(int64(len(line)))
	b.ReportAllocs()
	for b.Loop() {
		p.Parse(line, &r)
	}
}

func BenchmarkParseDecoder(b *testing.B) {
	p := NewParser()
	var r Request
	line := []byte(caddyLine)
	b.SetBytes(int64(len(line)))
	b.ReportAllocs()
	for b.Loop() {
		p.Decode(line, &r)
	}
}

func BenchmarkSummaryAdd(b *testing.B) {
	p := NewParser()
	var r Request
	s := NewSummary(86400, 1794760000, 60)
	line := []byte(caddyLine)
	b.ReportAllocs()
	for b.Loop() {
		p.Parse(line, &r)
		s.Add(&r)
	}
}

func BenchmarkSkips(b *testing.B) {
	f := RowFilter{From: 1794760000, MinStatus: 500}
	line := []byte(caddyLine)
	b.ReportAllocs()
	for b.Loop() {
		f.Skips(line)
	}
}

func TestDict(t *testing.T) {
	d := NewDict(Keys{})
	for i := 0; i < 5000; i++ {
		k := []byte("GET /p/" + strconv.Itoa(i%3000))
		id, ok := d.ID(k, 1<<20)
		if !ok || string(d.Key(id)) != string(k) || int(id) != i%3000 {
			t.Fatalf("%d: id %d", i, id)
		}
	}
	k, ok := ParseKeys(d.Unsaved())
	if !ok || k.Len() != 3000 || string(k.Key(2999)) != "GET /p/2999" {
		t.Fatal("dictionary file round trip")
	}
	d2 := NewDict(k)
	if id, ok := d2.ID([]byte("GET /p/17"), 1<<20); !ok || id != 17 || len(d2.Unsaved()) != 0 {
		t.Fatal("a continued dictionary finds its keys")
	}
	if _, ok := d2.ID([]byte("GET /new"), d2.size+5); ok {
		t.Fatal("over its byte cap")
	}
	if _, ok := ParseKeys([]byte{5, 0, 'a'}); ok {
		t.Fatal("a cut file")
	}
}

func TestLoadKeysAllocations(t *testing.T) {
	d := NewDict(Keys{})
	for i := 0; i < 20000; i++ {
		d.ID([]byte("GET /p/"+strconv.Itoa(i)), 1<<30)
	}
	file := d.Unsaved()
	if n := testing.AllocsPerRun(5, func() { ParseKeys(file) }); n > 50 {
		t.Fatalf("loading 20,000 keys: %v allocations (chunks and the index only)", n)
	}
}
