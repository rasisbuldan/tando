package metrics

import (
	"context"
	"path/filepath"
	"testing"

	"tando/srv/internal/usage"
)

// The metering ledger: one row per app and minute with its caps and the seconds its web unit was
// up, from systemd's monotonic timestamps; the cursor (seq) continues across samples, and the
// interval of a row starts where the app's last one ended (a restart of the sampler loses nothing
// up to an hour).
func TestSampleLedger(t *testing.T) {
	h := newHost(t)
	h.app("web", "tando.slice/tando-web.slice/tando-web.service", 100<<20, 5_000_000)
	h.write("opt/apps/web/app.conf", "port=4100\nmemory=512M\nworker.q=x\nworker.q.memory=128M\n")
	h.app("idle", "tando.slice/tando-idle.slice/tando-idle.service", 0, 0)
	h.write("opt/apps/idle/app.conf", "port=4101\nmemory=1G\nidle_stop=10m\n")
	h.app("site", "system.slice/tando-site.service", 0, 0)
	h.write("opt/apps/site/app.conf", "port=4102\nrecipe=static\n")
	h.write("proc/sys/kernel/random/boot_id", "0123abcd-ffff\n")
	h.write("proc/uptime", "1000.00 900.00\n")
	// idle: woke 20 s ago; site: never up (static); web: up since boot
	h.systemd = "ActiveState=active\nNRestarts=0\nActiveEnterTimestampMonotonic=980000000\nInactiveEnterTimestampMonotonic=500000000\n\n" +
		"ActiveState=inactive\nNRestarts=0\nActiveEnterTimestampMonotonic=0\nInactiveEnterTimestampMonotonic=0\n\n" +
		"ActiveState=active\nNRestarts=0\nActiveEnterTimestampMonotonic=1000000\nInactiveEnterTimestampMonotonic=0\n"
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(h.m.Env.Lib, "usage")
	p, err := usage.Read(dir, 0, 100, "")
	if err != nil {
		t.Fatal(err)
	}
	want := []usage.Row{
		{Seq: 1, T: h.now, Boot: "0123abcd", App: "idle", Interval: 60, AllocMB: 1024, AwakeS: 20, MemMB: 0},
		{Seq: 2, T: h.now, Boot: "0123abcd", App: "web", Interval: 60, AllocMB: 512, WorkersMB: 128, AwakeS: 60, MemMB: 100},
	}
	if len(p.Rows) != len(want) {
		t.Fatalf("rows: %+v", p.Rows)
	}
	for i := range want {
		if p.Rows[i] != want[i] {
			t.Errorf("row %d: got %+v, want %+v", i, p.Rows[i], want[i])
		}
	}
	// 90 s later (a missed minute): idle went to sleep 30 s after the last sample
	h.now += 90
	h.write("proc/uptime", "1090.00 900.00\n")
	h.app("web", "tando.slice/tando-web.slice/tando-web.service", 100<<20, 8_000_000)
	h.systemd = "ActiveState=inactive\nNRestarts=0\nActiveEnterTimestampMonotonic=980000000\nInactiveEnterTimestampMonotonic=1030000000\n\n" +
		"ActiveState=inactive\nNRestarts=0\nActiveEnterTimestampMonotonic=0\nInactiveEnterTimestampMonotonic=0\n\n" +
		"ActiveState=active\nNRestarts=0\nActiveEnterTimestampMonotonic=1000000\nInactiveEnterTimestampMonotonic=0\n"
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	p, err = usage.Read(dir, 2, 100, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Rows) != 2 || p.Next != 4 || p.Rows[0].App != "idle" || p.Rows[0].Interval != 90 || p.Rows[0].AwakeS != 30 ||
		p.Rows[1].AwakeS != 90 || p.Rows[1].CPUms != 3000 {
		t.Errorf("second minute: %+v", p)
	}
}
