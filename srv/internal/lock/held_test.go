package lock

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
)

func TestHeld(t *testing.T) {
	if _, err := os.Stat("/proc/locks"); err != nil {
		t.Skip("no /proc/locks here (test/go.sh runs this in a Linux container)")
	}
	p := filepath.Join(t.TempDir(), "lock")
	if Held(p) {
		t.Fatal("a missing file is held")
	}
	if err := os.WriteFile(p, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if Held(p) {
		t.Fatal("a free file is held")
	}
	l, err := Acquire(p, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !Held(p) {
		t.Fatal("a held lock reads as free")
	}
	l.Release()
	if Held(p) {
		t.Fatal("a released lock reads as held")
	}
	// the probe never takes the lock: a verb's own try beside a busy probe always succeeds
	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var wg sync.WaitGroup
	stop := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
				Held(p)
			}
		}
	}()
	busy := 0
	for i := 0; i < 20000; i++ {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if errors.Is(err, syscall.EWOULDBLOCK) {
			busy++
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	}
	close(stop)
	wg.Wait()
	if busy > 0 {
		t.Fatalf("the lock was taken %d times by the probe beside a verb's try", busy)
	}
}
