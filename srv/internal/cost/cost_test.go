package cost

import (
	"testing"
	"time"
)

func TestMeter(t *testing.T) {
	n := int64(0)
	m := New(func() int64 { return n })
	end := m.Start("scan")
	n += 3
	time.Sleep(5 * time.Millisecond)
	end()
	m.Time("scan", func() {})
	if s := m.Snapshot(); len(s.Last) != 0 || len(s.Total) != 1 || s.Total[0].Calls != 2 || s.Total[0].Children != 3 ||
		s.Total[0].Wall < 5*time.Millisecond {
		t.Fatalf("%+v", s)
	}
	m.TickDone()
	m.Time("live loop", func() {})
	s := m.Snapshot()
	if s.Ticks != 1 || len(s.Last) != 1 || s.Last[0].Name != "scan" || s.Last[0].Calls != 2 ||
		len(s.Total) != 2 || s.Total[0].Name != "live loop" {
		t.Fatalf("%+v", s)
	}
	var nilM *Meter // the one-shot: nothing kept, nothing fails
	nilM.Start("x")()
	nilM.Time("x", func() {})
	nilM.TickDone()
	if s := nilM.Snapshot(); s.Ticks != 0 || s.Total != nil {
		t.Fatalf("%+v", s)
	}
}
