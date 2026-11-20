package lock

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestHeld(t *testing.T) {
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
	// two probes at once never see each other as the holder
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
	seen := 0
	for i := 0; i < 20000; i++ {
		if Held(p) {
			seen++
		}
	}
	close(stop)
	wg.Wait()
	if seen > 0 {
		t.Fatalf("a free lock read as held %d times beside another probe", seen)
	}
}
