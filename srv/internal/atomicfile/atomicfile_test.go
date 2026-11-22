package atomicfile

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWrite(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "state")
	for _, tt := range []struct {
		data string
		mode os.FileMode
	}{{"a=1\n", 0o644}, {"a=2\n", 0o600}, {"", 0o640}} {
		if err := Write(p, []byte(tt.data), Mode(tt.mode)); err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(p)
		if err != nil || string(got) != tt.data {
			t.Fatalf("content %q, %v; want %q", got, err, tt.data)
		}
		if fi, _ := os.Stat(p); fi.Mode().Perm() != tt.mode {
			t.Errorf("mode %v, want %v", fi.Mode().Perm(), tt.mode)
		}
	}
	if left, _ := filepath.Glob(filepath.Join(dir, ".*")); len(left) != 0 {
		t.Errorf("temporary files left: %v", left)
	}
}

func TestWriteFailsCleanly(t *testing.T) {
	dir := t.TempDir()
	// the target is a directory: the rename fails, and the temporary file must go
	target := filepath.Join(dir, "d")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, "x"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Write(target, []byte("x"), Mode(0o644)); err == nil {
		t.Fatal("no error replacing a non-empty directory")
	}
	if left, _ := filepath.Glob(filepath.Join(dir, ".d.tmp*")); len(left) != 0 {
		t.Errorf("temporary files left: %v", left)
	}
	if err := Write(filepath.Join(dir, "missing", "f"), nil, Mode(0o644)); err == nil {
		t.Error("no error writing into a missing directory")
	}
}

func TestWriteIfChanged(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f")
	steps := []struct {
		data    string
		changed bool
	}{{"a\n", true}, {"a\n", false}, {"b\n", true}}
	for i, s := range steps {
		if i == 1 {
			old := time.Now().Add(-time.Hour)
			os.Chtimes(p, old, old)
		}
		before, _ := os.Stat(p)
		changed, err := WriteIfChanged(p, []byte(s.data), Mode(0o644))
		if err != nil || changed != s.changed {
			t.Fatalf("step %d: changed=%v err=%v, want %v", i, changed, err, s.changed)
		}
		if after, _ := os.Stat(p); !s.changed && !after.ModTime().Equal(before.ModTime()) {
			t.Errorf("step %d: an unchanged file was rewritten", i)
		}
	}
}

func TestWriteVolatile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f")
	n := Flushes()
	if err := WriteVolatile(p, []byte("a\n"), Mode(0o640)); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != "a\n" {
		t.Fatalf("%q", b)
	}
	if fi, _ := os.Stat(p); fi.Mode().Perm() != 0o640 {
		t.Errorf("mode %v", fi.Mode())
	}
	if Flushes() != n {
		t.Errorf("WriteVolatile flushed")
	}
	Write(p, []byte("b\n"), Mode(0o640))
	if Flushes() != n+1 {
		t.Errorf("Write did not flush")
	}
}
