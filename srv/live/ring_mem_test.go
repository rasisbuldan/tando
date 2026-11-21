package live

import (
	"fmt"
	"runtime"
	"testing"
)

// fillRing puts Keep points of n apps in a ring the way Sample does, names reused as the daemon does.
func fillRing(n int) *Live {
	l := &Live{}
	names := make([]string, n)
	for i := range names {
		names[i] = fmt.Sprintf("app-number-%03d", i)
	}
	for k := 0; k < Keep; k++ {
		p := Point{At: int64(k * 5), Host: Host{Load: "0.52"}}
		for i := 0; i < n; i++ {
			p.Apps = append(p.Apps, App{Name: names[i], Active: "active", Sub: "running", Restarts: 1, MainPID: 4242,
				Mem: int64(100<<20 + k), CPU: int64(k % 900), Tasks: 7, usageUsec: int64(k) * 1000})
		}
		l.add(p)
	}
	return l
}

func heapAfterGC() uint64 {
	runtime.GC()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return m.HeapAlloc
}

// TestRingBytesPerAppPoint: the hour of points costs at most 24 bytes per app per point.
func TestRingBytesPerAppPoint(t *testing.T) {
	for _, n := range []int{25, 100, 200} {
		before := heapAfterGC()
		l := fillRing(n)
		after := heapAfterGC()
		per := float64(after-before) / float64(n*Keep)
		runtime.KeepAlive(l)
		t.Logf("%d apps: %.1f B per app per point, %.1f MiB", n, per, float64(after-before)/(1<<20))
		if per > 24 {
			t.Errorf("%d apps: %.1f B per app per point, want <= 24", n, per)
		}
	}
}

func BenchmarkRing(b *testing.B) {
	for _, n := range []int{25, 100, 200} {
		b.Run(fmt.Sprint(n, "apps"), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				before := heapAfterGC()
				l := fillRing(n)
				after := heapAfterGC()
				runtime.KeepAlive(l)
				b.ReportMetric(float64(after-before)/(1<<20), "MiB")
				b.ReportMetric(float64(after-before)/float64(n*Keep), "B/app-point")
			}
		})
	}
}
