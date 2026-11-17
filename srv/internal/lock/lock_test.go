package lock

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAcquire(t *testing.T) {
	p := filepath.Join(t.TempDir(), "lock")
	if err := os.WriteFile(p, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	os.Chmod(p, 0o666)
	l, err := Acquire(p, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(p); fi.Mode().Perm() != 0o600 {
		t.Errorf("mode %v, want 0600", fi.Mode().Perm())
	}
	// flock locks belong to the open file description: a second open, even in this process, waits
	t0 := time.Now()
	if _, err := Acquire(p, 120*time.Millisecond); !errors.Is(err, ErrBusy) {
		t.Fatalf("second Acquire = %v, want ErrBusy", err)
	}
	if d := time.Since(t0); d < 100*time.Millisecond {
		t.Errorf("gave up after %v, before the timeout", d)
	}
	go func() {
		time.Sleep(100 * time.Millisecond)
		l.Release()
	}()
	l2, err := Acquire(p, 2*time.Second)
	if err != nil {
		t.Fatalf("Acquire after Release: %v", err)
	}
	l2.Release()
}

func TestAcquireRefuses(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	os.WriteFile(target, nil, 0o600)
	link := filepath.Join(dir, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Acquire(link, time.Second); err == nil {
		t.Error("a symlink was accepted as a lock file")
	}
	if _, err := Acquire(dir, time.Second); err == nil {
		t.Error("a directory was accepted as a lock file")
	}
}
