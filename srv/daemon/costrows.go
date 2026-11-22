package daemon

import (
	"time"

	"tando/srv/internal/cost"
	"tando/srv/internal/decimal"
	"tando/srv/internal/out"
)

// costRows writes the `cost` verb's answer (tando-status cost): tandod's own cost by section.
//
//	costs <seconds running> <ticks> <cpu ms> <children's cpu ms>        the whole process so far
//	cost last|total <calls> <wall ms> <cpu ms> <children's cpu ms> <programs> <section>
//
// "last" is the last minute: from the end of one tick to the end of the next (the tick's
// checks, and the live loop's passes and socket verbs in between); "total" since the start.
// A section's cpu is the process's while it ran (srv/internal/cost).
func costRows(o *out.Writer, s cost.Snapshot) {
	o.Row("costs", decimal.Itoa(int64(s.Since/time.Second)), decimal.Itoa(s.Ticks), ms(s.CPU), ms(s.ChildCPU))
	for _, part := range []struct {
		scope string
		rows  []cost.Row
	}{{"last", s.Last}, {"total", s.Total}} {
		for _, r := range part.rows {
			o.Row("cost", part.scope, decimal.Itoa(r.Calls), ms(r.Wall), ms(r.CPU), ms(r.ChildCPU), decimal.Itoa(r.Children), r.Name)
		}
	}
}

func ms(d time.Duration) string { return decimal.Itoa(int64(d / time.Millisecond)) }
