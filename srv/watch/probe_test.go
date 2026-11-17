package watch

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestProbe(t *testing.T) {
	var mu sync.Mutex // (the probes run in parallel)
	var gotUA, gotProbe, gotHost, gotEnc string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			mu.Lock()
			gotUA, gotProbe, gotHost, gotEnc = r.UserAgent(), r.Header.Get("X-Tando-Probe"), r.Host, r.Header.Get("Accept-Encoding")
			mu.Unlock()
		}
		switch r.URL.Path {
		case "/redirect":
			http.Redirect(w, r, "/elsewhere", http.StatusFound)
		case "/slow":
			time.Sleep(1500 * time.Millisecond)
		case "/big":
			w.Write([]byte(strings.Repeat("x", 10000)))
		default:
			w.Write([]byte("ok\n"))
		}
	}))
	defer srv.Close()
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	hdr := filepath.Join(t.TempDir(), "probe.header")
	os.WriteFile(hdr, []byte("X-Tando-Probe: 0123abcd\n"), 0o600)
	p := httpProber{header: hdr, loopback: "127.0.0.1"}
	base := "http://hog.example.test:" + port // the name does not resolve: the connection goes to the loopback address
	res := p.Probe(context.Background(), []probeReq{{base + "/health"}, {base + "/redirect"}, {base + "/slow"}, {base + "/big"}}, time.Second)
	if res[0].code != 200 || res[0].exit != 0 || res[0].body != "ok\n" {
		t.Errorf("health: %+v", res[0])
	}
	mu.Lock()
	defer mu.Unlock()
	if gotUA != "tando-probe" || gotHost != "hog.example.test:"+port || gotEnc != "" {
		t.Errorf("request: UA %q host %q accept-encoding %q", gotUA, gotHost, gotEnc)
	}
	if gotProbe != "0123abcd" {
		t.Errorf("probe header %q", gotProbe)
	}
	if res[1].code != 302 {
		t.Errorf("redirect followed: %+v", res[1])
	}
	if res[2].exit != 28 {
		t.Errorf("slow: %+v", res[2])
	}
	if len(res[3].body) != 4096 {
		t.Errorf("body kept: %d bytes", len(res[3].body))
	}
	// nothing listens: refused
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := l.Addr().String()
	l.Close()
	_, free, _ := net.SplitHostPort(addr)
	if r := p.Probe(context.Background(), []probeReq{{"http://x.test:" + free + "/"}}, time.Second); r[0].exit != 7 || r[0].code != 0 {
		t.Errorf("refused: %+v", r[0])
	}
	if c := p.Direct(context.Background(), srv.URL+"/redirect"); c != 302 {
		t.Errorf("direct: %d", c)
	}
}

func TestSenderKeepsSecretsOutOfErrors(t *testing.T) {
	var mu sync.Mutex
	var body, ctype string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b := make([]byte, 100)
		n, _ := r.Body.Read(b)
		mu.Lock()
		body, ctype = string(b[:n]), r.Header.Get("Content-Type")
		mu.Unlock()
		if strings.Contains(r.URL.Path, "moved") {
			http.Redirect(w, r, "/x", http.StatusMovedPermanently)
		}
	}))
	defer srv.Close()
	s := httpSender{}
	code, err := s.Post(context.Background(), srv.URL+"/hook/S3CR3T", [][2]string{{"Content-Type", "application/json"}}, []byte(`{"a":1}`))
	mu.Lock()
	gb, gc := body, ctype
	mu.Unlock()
	if err != nil || code != 200 || gb != `{"a":1}` || gc != "application/json" {
		t.Errorf("post: %d %v %q %q", code, err, body, ctype)
	}
	if code, _ := s.Post(context.Background(), srv.URL+"/moved/S3CR3T", nil, nil); code != 301 {
		t.Errorf("redirect followed: %d", code)
	}
	u, _ := url.Parse(srv.URL)
	srv.Close()
	for _, target := range []string{"http://" + u.Host + "/hook/S3CR3T", "http://S3CR3T.invalid./x", "not a url S3CR3T"} {
		_, err := s.Post(context.Background(), target, nil, []byte("x"))
		if err == nil || strings.Contains(errText(err), "S3CR3T") || strings.Contains(err.Error(), "S3CR3T") {
			t.Errorf("%s: %v", target, err)
		}
	}
	if _, err := s.Post(context.Background(), "http://"+u.Host+"/x", nil, []byte("x")); errText(err) != "connection refused" {
		t.Errorf("refused: %q", errText(err))
	}
	if err := s.Ping(context.Background(), "http://"+u.Host+"/hb/S3CR3T"); err == nil || strings.Contains(err.Error(), "S3CR3T") {
		t.Errorf("ping: %v", err)
	}
}
