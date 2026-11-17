package watch

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tando/srv/internal/bashread"
)

func TestClean(t *testing.T) {
	for _, tt := range []struct{ in, want string }{
		{"plain", "plain"},
		{"a\tb\nc\x1bd\x7f", "a b c d "},
		{"c1 \u0085 x", "c1   x"},
		{"bidi ‮evil‬ ⁦x⁩ ‎؜.", "bidi evil x ."},
		{"latin-1 \xe9 replaced", "latin-1 \ufffd replaced"},
		{"8-bit csi \x9b[2J", "8-bit csi  [2J"},
		{strings.Repeat("é", 310), strings.Repeat("é", 300)},
		{strings.Repeat("‮", 5) + strings.Repeat("a", 301), strings.Repeat("a", 300)},
	} {
		if got := clean(tt.in); got != tt.want {
			t.Errorf("clean(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestDur(t *testing.T) {
	for _, tt := range []struct {
		s    int64
		want string
	}{{0, "0s"}, {59, "59s"}, {91, "1m 31s"}, {3600, "1h 00m"}, {7500, "2h 05m"}, {86400, "1d 0h"}, {273600, "3d 4h"}} {
		if got := dur(tt.s); got != tt.want {
			t.Errorf("dur(%d) = %q, want %q", tt.s, got, tt.want)
		}
	}
}

func TestJSONString(t *testing.T) {
	if got, want := jsonString("a\"b\\c\nd\te\x01f\x7fé"), `"a\"b\\c\nd e f é"`; got != want {
		t.Errorf("got %s, want %s", got, want)
	}
}

func TestMask(t *testing.T) {
	for _, tt := range []struct{ in, want string }{
		{"https://hooks.slack.com/services/T0/B0/xyz", "https://hooks.slack.com/…"},
		{"http://user:pw@example.com:8080/x?y", "http://example.com:8080/…"},
		{"", ":///…"},
	} {
		if got := mask(tt.in); got != tt.want {
			t.Errorf("mask(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestFields(t *testing.T) {
	for _, tt := range []struct {
		in   string
		n    int
		want []string
	}{
		{"a\tb\tc", 3, []string{"a", "b", "c"}},
		{"a\t\tb\tc d\te", 3, []string{"a", "b", "c d\te"}}, // empty fields vanish, the rest goes to the last
		{"\ta\tb\t", 3, []string{"a", "b", ""}},
		{"", 2, []string{"", ""}},
	} {
		got := bashread.Fields(tt.in, tt.n)
		if strings.Join(got, "|") != strings.Join(tt.want, "|") {
			t.Errorf("bashread.Fields(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestLinesDropsUnterminated(t *testing.T) {
	if got := bashread.Lines([]byte("a\nb\nc")); strings.Join(got, ",") != "a,b" {
		t.Errorf("got %q", got)
	}
}

func TestSettings(t *testing.T) {
	p := filepath.Join(t.TempDir(), "alerts.conf")
	os.WriteFile(p, []byte("# c=1\nhealth_fails=08\nhog.health_fails=1\nmem_pct=x\nload=off\nhog.memory=off\nname=web1\n"), 0o644)
	s := loadSettings(p)
	for _, tt := range []struct {
		key, app string
		want     int64
	}{{"health_fails", "", 8}, {"health_fails", "hog", 1}, {"health_fails", "other", 8}, {"mem_pct", "", 90}, {"down_after", "", 2}} {
		if got := s.num(tt.key, tt.app); got != tt.want {
			t.Errorf("num(%s, %s) = %d, want %d", tt.key, tt.app, got, tt.want)
		}
	}
	if s.on("load", "") || !s.on("memory", "") || s.on("memory", "hog") || s.str("name") != "web1" {
		t.Errorf("on/str wrong: %v", s)
	}
	if loadSettings(filepath.Join(t.TempDir(), "none")).str("name") != "" {
		t.Error("name default must be empty")
	}
}

func TestLoadStateDropsBadValues(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state")
	os.WriteFile(p, []byte("a.health.st=firing\nb.health.st=weird\na.health.det=any text=ok\n_oomc=1:2:3\n_oomc2=x\na.health.ns=ok\n"+
		"a.health.fl=1,2,3\na.rt=1,x\n_nf.hook.err=HTTP 500\n_out=17,42\n"), 0o600)
	s := loadState(p)
	want := map[string]string{"a.health.st": "firing", "a.health.det": "any text=ok", "_oomc": "1:2:3", "a.health.fl": "1,2,3",
		"_nf.hook.err": "HTTP 500", "_out": "17,42"}
	if len(s.m) != len(want) || !s.dirty {
		t.Fatalf("got %v (dirty %v)", s.m, s.dirty)
	}
	for k, v := range want {
		if s.m[k] != v {
			t.Errorf("%s = %q, want %q", k, s.m[k], v)
		}
	}
}

func TestPctUp(t *testing.T) {
	for _, tt := range []struct {
		used, avail uint64
		want        string
	}{{0, 0, ""}, {1, 99, "1"}, {1, 100, "1"}, {50, 50, "50"}, {901, 99, "91"}} {
		if got := pctUp(tt.used, tt.avail); got != tt.want {
			t.Errorf("pctUp(%d, %d) = %q, want %q", tt.used, tt.avail, got, tt.want)
		}
	}
}

func TestMountOf(t *testing.T) {
	m := []string{"/", "/nx-var", "/nx-var/lib/docker", "/nx-opt"} // (paths that do not exist: no symlinks resolved)
	for _, tt := range []struct{ p, want string }{{"/", "/"}, {"/nx-var", "/nx-var"}, {"/nx-variant", "/"}, {"/nx-opt/tando", "/nx-opt"}} {
		if got := mountOf(tt.p, m); got != tt.want {
			t.Errorf("mountOf(%s) = %s, want %s", tt.p, got, tt.want)
		}
	}
}

func TestCaddyError(t *testing.T) {
	out := `{"level":"info","msg":"using config from file"}` + "\n" +
		`{"level":"error","ts":1,"msg":"adapting config using caddyfile: /etc/caddy/Caddyfile:3: unknown directive"}` + "\n"
	if got := caddyError(out); got != "adapting config using caddyfile: /etc/caddy/Caddyfile:3: unknown directive" {
		t.Errorf("got %q", got)
	}
	if got := caddyError("Error: plain text failure\n"); got != "Error: plain text failure" {
		t.Errorf("got %q", got)
	}
}

// memory counts shmem: anon 100 MB + shmem 400 MB, shmem listed after file (test/e2e-alerts.sh 27b)
func TestMemstat(t *testing.T) {
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, "memory.stat"), []byte("anon 100000000\nfile 5000\nkernel 1\nshmem 400000000\nfile_mapped 3\n"), 0o644)
	if got := memstat(d); got != 500000000 {
		t.Errorf("memstat = %d, want 500000000", got)
	}
	if got := memstat(filepath.Join(d, "none")); got != 0 {
		t.Errorf("missing file: %d", got)
	}
}
