package proto

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWatchVerb(t *testing.T) {
	for verb, want := range map[string]delegated{
		"run": {}, "show": {"show", 35 * time.Second}, "history": {"history", 35 * time.Second},
		"health": {"health", 35 * time.Second}, "brief": {"brief", 35 * time.Second},
		"set": {}, "status": {}, "tick": {}, "": {},
	} {
		got, ok := watchVerb(verb)
		if got != want || ok != (want.Verb != "") {
			t.Errorf("%q: %+v %v", verb, got, ok)
		}
	}
}

// Requests the protocol does not carry are never sent (so nothing needs to listen here).
func TestNotAsked(t *testing.T) {
	ctx := context.Background()
	for _, args := range [][]string{nil, {"x"}, {""}, {"a", "b"}} {
		if _, ok := AskWatch(ctx, "run", args); ok {
			t.Errorf("run %q asked (it goes through RunTick)", args)
		}
	}
	if _, ok := AskWatch(ctx, "set", nil); ok {
		t.Error("set asked")
	}
	if _, ok := AskStatus(ctx, "Bad"); ok {
		t.Error("a bad app name asked")
	}
}

// sockPath is a unix socket path short enough for every OS.
func sockPath(t *testing.T) string {
	d, err := os.MkdirTemp("/tmp", "pt")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return filepath.Join(d, "s")
}

// serve answers every connection with fn (after reading the request line).
func serve(t *testing.T, path string, fn func(c net.Conn)) {
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				bufio.NewReader(c).ReadString('\n')
				fn(c)
			}()
		}
	}()
}

// A daemon that accepts and never answers: the run here gets what is left of the budget, not a
// whole tick on top of the wait (which would overrun the unit's TimeoutStartSec).
func TestRunTickBudget(t *testing.T) {
	p := sockPath(t)
	serve(t, p, func(c net.Conn) { time.Sleep(5 * time.Second) })
	var got time.Duration
	start := time.Now()
	err := runTick(context.Background(), p, 600*time.Millisecond, 400*time.Millisecond, time.Hour, func(ctx context.Context) error {
		dl, _ := ctx.Deadline()
		got = time.Until(dl)
		return nil
	})
	if err != nil || got > 250*time.Millisecond || got < 50*time.Millisecond {
		t.Errorf("local run got %v of the budget (want about 200 ms), err %v", got, err)
	}
	if time.Since(start) > 700*time.Millisecond {
		t.Errorf("took %v", time.Since(start))
	}
	// the wait used the whole budget: no local run, an error
	called := false
	err = runTick(context.Background(), p, 300*time.Millisecond, time.Second, time.Hour, func(context.Context) error { called = true; return nil })
	if err == nil || called {
		t.Errorf("no time left: err %v, ran %v", err, called)
	}
	// no daemon at all: the local run, at most maxLocal
	err = runTick(context.Background(), sockPath(t), time.Hour, time.Hour, 50*time.Millisecond, func(ctx context.Context) error {
		dl, _ := ctx.Deadline()
		got = time.Until(dl)
		return nil
	})
	if err != nil || got > 50*time.Millisecond {
		t.Errorf("no daemon: %v, %v", got, err)
	}
	// tandod answered: its answer, nothing local
	p2 := sockPath(t)
	serve(t, p2, func(c net.Conn) { io.WriteString(c, Header(errors.New("another run holds the lock"), 0)) })
	err = runTick(context.Background(), p2, time.Second, time.Second, time.Hour, func(context.Context) error { called = true; return nil })
	if err == nil || err.Error() != "another run holds the lock" || called {
		t.Errorf("answered: %v, ran %v", err, called)
	}
}

func TestReadAnswer(t *testing.T) {
	for _, tt := range []struct {
		in   string
		want Answer
		ok   bool
	}{
		{"ok 3\nab\n", Answer{OK: true, Body: []byte("ab\n")}, true},
		{"ok 0\n", Answer{OK: true, Body: []byte{}}, true},
		{"err 4 no such app: x\nrow\n", Answer{Err: "no such app: x", Body: []byte("row\n")}, true},
		{"ok 10\nshort\n", Answer{}, false}, // the daemon died while writing
		{"ok\nrows\n", Answer{}, false},     // unframed
		{"ok x\n", Answer{}, false},
		{"ok 1 extra\nx", Answer{}, false},
		{"what 1\nx", Answer{}, false},
		{"", Answer{}, false},
		{"ok 3", Answer{}, false},
	} {
		a, err := ReadAnswer(strings.NewReader(tt.in))
		if (err == nil) != tt.ok || (tt.ok && (a.OK != tt.want.OK || a.Err != tt.want.Err || string(a.Body) != string(tt.want.Body))) {
			t.Errorf("%q: %+v %v", tt.in, a, err)
		}
	}
	// what Header frames, ReadAnswer reads back
	for _, e := range []error{nil, errors.New("bad\nmessage")} {
		a, err := ReadAnswer(strings.NewReader(Header(e, 4) + "abcd"))
		if err != nil || string(a.Body) != "abcd" {
			t.Errorf("round trip %v: %+v %v", e, a, err)
		}
	}
}

// FuzzReadAnswer: any input is read or refused, never more than it said, never a panic.
func FuzzReadAnswer(f *testing.F) {
	for _, s := range []string{"ok 3\nabc", "err 0 x\n", "ok 99999999999\n", "ok -1\n", "\n", "err 2\nab"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		a, err := ReadAnswer(strings.NewReader(s))
		if err != nil {
			if err != ErrNoDaemon {
				t.Fatalf("%q: %v", s, err)
			}
			return
		}
		head, _, _ := strings.Cut(s, "\n")
		if !strings.HasPrefix(head, "ok ") && !strings.HasPrefix(head, "err ") || len(a.Body) > len(s) {
			t.Fatalf("%q read as %+v", s, a)
		}
	})
}
