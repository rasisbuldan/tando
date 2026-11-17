package daemon

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"tando/srv/daemon/proto"
)

func TestParse(t *testing.T) {
	for _, tt := range []struct {
		in, want string
		ok       bool
	}{
		{"ping", "ping", true}, {"tick", "tick", true}, {"show", "show", true}, {"show 8", "show 8", true},
		{"history 50", "history 50", true}, {"health hog", "health hog", true}, {"brief host", "brief host", true},
		{"status boom-2", "status boom-2", true},
		{"tick now", "", false}, {"show -1", "", false}, {"show 1234567890", "", false}, {"history x", "", false},
		{"health Hog", "", false}, {"health h", "", false}, {"health ../etc", "", false}, {"health hog x", "", false},
		{"show  8", "", false}, {"run", "", false}, {"", "", false}, {"show 8\r", "", false}, {"ping\x00", "", false},
		{"health " + strings.Repeat("a", 27), "", false}, {strings.Repeat("x", proto.MaxRequest), "", false},
	} {
		r, err := proto.Parse(tt.in)
		if (err == nil) != tt.ok || (tt.ok && r.String() != tt.want) {
			t.Errorf("Parse(%q) = %q, %v", tt.in, r.String(), err)
		}
	}
}

// FuzzParse: whatever comes in, a request that passes is one verb and at most one argument of
// safe characters, and prints back as itself.
func FuzzParse(f *testing.F) {
	for _, s := range []string{"ping", "show 8", "health hog", "brief host", "x y z", "\xff\xfe", "health a\x00b"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		r, err := proto.Parse(s)
		if err != nil {
			return
		}
		if r.String() != s || len(s) >= proto.MaxRequest || strings.ContainsAny(s, "\n\r\t\x00/.") {
			t.Fatalf("Parse(%q) passed as %q", s, r.String())
		}
	})
}

// testServer serves h on a socket in a temp dir; uid is what the peer check says.
func testServer(t *testing.T, uid int, h handler) (string, func()) {
	p := filepath.Join(t.TempDir(), "s.sock")
	if len(p) > 100 { // (unix socket paths are short)
		d, _ := os.MkdirTemp("/tmp", "rd")
		t.Cleanup(func() { os.RemoveAll(d) })
		p = filepath.Join(d, "s.sock")
	}
	ln, err := listen(p)
	if err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(p); fi.Mode().Perm() != 0o600 {
		t.Errorf("socket mode %v", fi.Mode())
	}
	s := newServer(ln, h)
	s.peerUID = func(net.Conn) (int, error) { return uid, nil }
	done := make(chan struct{})
	go func() { s.serve(context.Background()); close(done) }()
	return p, func() { ln.Close(); <-done }
}

func echo(ctx context.Context, r proto.Request, w io.Writer) error {
	switch r.Verb {
	case "health":
		return errors.New("no such app: " + r.Arg)
	case "tick":
		select {
		case <-time.After(300 * time.Millisecond):
		case <-ctx.Done():
		}
	}
	io.WriteString(w, "row\t"+r.String()+"\n")
	return nil
}

func TestServer(t *testing.T) {
	p, stop := testServer(t, 0, echo)
	defer stop()
	ctx := context.Background()
	a, err := proto.Call(ctx, p, proto.Request{Verb: "show", Arg: "8"}, 100*time.Millisecond, 5*time.Second)
	if err != nil || !a.OK || string(a.Body) != "row\tshow 8\n" {
		t.Errorf("show: %+v %v", a, err)
	}
	a, err = proto.Call(ctx, p, proto.Request{Verb: "health", Arg: "nope"}, 100*time.Millisecond, 5*time.Second)
	if err != nil || a.OK || a.Err != "no such app: nope" {
		t.Errorf("health: %+v %v", a, err)
	}
	raw := func(send string, wait time.Duration) string {
		c, err := net.Dial("unix", p)
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		io.WriteString(c, send)
		time.Sleep(wait)
		c.SetReadDeadline(time.Now().Add(5 * time.Second))
		b, _ := io.ReadAll(c)
		return string(b)
	}
	for _, tt := range []struct{ send, want string }{
		{"run\n", "err 0 bad request\n"},
		{"show ../x\n", "err 0 bad request\n"},
		{strings.Repeat("a", 1000) + "\n", "err 0 bad request\n"}, // oversized: cut at MaxRequest
		{"show 8", "err 0 bad request\n"},                         // no newline: the read times out
	} {
		if got := raw(tt.send, 0); got != tt.want {
			t.Errorf("%.20q: %q", tt.send, got)
		}
	}
	// a client that sends nothing is dropped after readTimeout, and holds no slot afterwards
	start := time.Now()
	if got := raw("", 0); got != "err 0 bad request\n" || time.Since(start) > readTimeout+time.Second {
		t.Errorf("silent client: %q after %v", got, time.Since(start))
	}
}

// More clients than slots: with every slot taken (handlers held until the test lets them go), the
// next client is told busy at once. Deterministic: it waits until the slots are taken instead of
// hoping that many clients connect within a handler's time.
func TestServerConnectionCap(t *testing.T) {
	release := make(chan struct{})
	in := make(chan struct{}, maxConns)
	p, stop := testServer(t, 0, func(ctx context.Context, r proto.Request, w io.Writer) error {
		in <- struct{}{}
		<-release
		return nil
	})
	defer stop()
	ctx := context.Background()
	var wg sync.WaitGroup
	for range maxConns {
		wg.Add(1)
		go func() {
			defer wg.Done()
			proto.Call(ctx, p, proto.Request{Verb: "ping"}, time.Second, 10*time.Second)
		}()
	}
	for range maxConns {
		select {
		case <-in:
		case <-time.After(5 * time.Second):
			t.Fatal("the slots did not fill")
		}
	}
	a, err := proto.Call(ctx, p, proto.Request{Verb: "ping"}, time.Second, 5*time.Second)
	close(release)
	wg.Wait()
	if err != nil || a.Err != "busy" {
		t.Errorf("one client over %d: %+v %v", maxConns, a, err)
	}
}

func TestServerRefusesNonRoot(t *testing.T) {
	p, stop := testServer(t, 1000, echo)
	defer stop()
	if _, err := proto.Call(context.Background(), p, proto.Request{Verb: "ping"}, 100*time.Millisecond, time.Second); err != proto.ErrNoDaemon {
		t.Errorf("non-root: %v", err)
	}
	if _, err := proto.Call(context.Background(), filepath.Join(t.TempDir(), "none.sock"), proto.Request{Verb: "ping"}, 100*time.Millisecond, time.Second); err != proto.ErrNoDaemon {
		t.Errorf("no daemon: %v", err)
	}
}

func TestFromArgs(t *testing.T) {
	for _, tt := range []struct {
		verb string
		args []string
		ok   bool
	}{{"show", nil, true}, {"show", []string{"8"}, true}, {"health", []string{"nope"}, true}, {"health", []string{""}, false},
		{"history", []string{"x"}, false}, {"brief", []string{"a", "b"}, false}, {"set", nil, false}} {
		if _, err := proto.FromArgs(tt.verb, tt.args); (err == nil) != tt.ok {
			t.Errorf("FromArgs(%s %v): %v", tt.verb, tt.args, err)
		}
	}
}
