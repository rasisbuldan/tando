package cgroup

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAppDir(t *testing.T) {
	root := t.TempDir()
	if got, want := AppDir(root, "hello-2"), filepath.Join(root, "system.slice/tando-hello-2.service"); got != want {
		t.Errorf("without a slice: %s, want %s", got, want)
	}
	d := filepath.Join(root, `tando.slice/tando-hello\x2d2.slice/tando-hello-2.service`)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := AppDir(root, "hello-2"); got != d {
		t.Errorf("with its slice: %s, want %s", got, d)
	}
}

func TestValue(t *testing.T) {
	f := filepath.Join(t.TempDir(), "memory.stat")
	os.WriteFile(f, []byte("anon 1234\nfile 99\nanon_thp 0\nshmem 7\nbad x\n"), 0o644)
	tests := []struct {
		key  string
		want int64
		ok   bool
	}{{"anon", 1234, true}, {"shmem", 7, true}, {"anon_thp", 0, true}, {"missing", 0, false}, {"bad", 0, false}}
	for _, tt := range tests {
		if got, ok := Value(f, tt.key); got != tt.want || ok != tt.ok {
			t.Errorf("Value(%s) = %d, %v", tt.key, got, ok)
		}
	}
	if _, ok := Value(f+".missing", "anon"); ok {
		t.Error("a missing file has a value")
	}
}
