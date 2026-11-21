package watch

import (
	"strings"
	"testing"
	"time"

	"tando/srv/internal/decimal"
)

// costData writes tandod.x: days of minutes at cpu ms (no reader), then the last hour at
// lastCPU, with req requests in every last-hour minute
func (f *fakeHost) costData(days int64, cpu, lastCPU, req int64) {
	var b strings.Builder
	now := f.now.Unix()
	for t := now - days*86400; t <= now; t += 60 {
		c, r := cpu, int64(0)
		if t > now-3600 {
			c, r = lastCPU, req
		}
		b.WriteString(decimal.Itoa(t) + "\t" + decimal.Itoa(c) + "\t9000000\t4000000\t0\t0\t1\t" + decimal.Itoa(r) + "\n")
	}
	f.write("lib/metrics/tandod.x", b.String())
}

// monitor_cost: silent for the first 7 days of data, then 2x the normal, capped at 600 ms
func TestMonitorCost(t *testing.T) {
	f := newFakeHost(t)
	f.settings("sample_seconds=0")
	f.costData(6, 100, 900, 0) // 6 days: far over, but too early to judge
	f.tick()
	if st := f.st("_host.monitor_cost.st"); st == "firing" || st == "pending" {
		t.Fatalf("judged after 6 days: %q", st)
	}
	// a day later (the normal is worked out again once a day): 7 days of data, normal 100 ms
	f.now = f.now.Add(24 * time.Hour)
	f.costData(7, 100, 150, 0)
	f.tick()
	if st := f.st("_host.monitor_cost.st"); st != "" && st != "ok" { // ("": ok, never anything else)
		t.Fatalf("150 ms against a normal of 100: %q", st)
	}
	f.costData(7, 100, 250, 0)
	f.tick()
	if st, det := f.st("_host.monitor_cost.st"), f.st("_host.monitor_cost.det"); st != "firing" || !strings.Contains(det, "used 250 ms of CPU a minute over the last hour, over its limit of 200 ms (its normal: 100 ms") {
		t.Fatalf("250 ms against a limit of 200: %q %q", st, det)
	}
	// readers' minutes are not judged: a dashboard open all hour leaves the state as it is
	f.costData(7, 100, 5000, 12)
	f.ticks(3)
	if st := f.st("_host.monitor_cost.st"); st != "firing" {
		t.Fatalf("readers' minutes judged: %q", st)
	}
	f.costData(7, 100, 100, 0)
	f.ticks(3)
	if st := f.st("_host.monitor_cost.st"); st != "ok" && st != "" {
		t.Fatalf("not resolved: %q", st)
	}
}

// the cap: a monitor whose normal is already high fires over 1% of a core, not over 2x
func TestMonitorCostCap(t *testing.T) {
	f := newFakeHost(t)
	f.settings("sample_seconds=0")
	f.costData(8, 400, 650, 0)
	f.tick()
	if st, det := f.st("_host.monitor_cost.st"), f.st("_host.monitor_cost.det"); st != "firing" || !strings.Contains(det, "limit of 600 ms") {
		t.Fatalf("650 ms with a normal of 400: %q %q", st, det)
	}
	f2 := newFakeHost(t)
	f2.settings("sample_seconds=0", "monitor_cost=off")
	f2.costData(8, 400, 650, 0)
	f2.tick()
	if st := f2.st("_host.monitor_cost.st"); st != "" {
		t.Fatalf("judged while off: %q", st)
	}
}
