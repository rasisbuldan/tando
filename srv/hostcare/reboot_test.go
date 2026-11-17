package hostcare

import (
	"strings"
	"testing"
	"time"
)

func TestDecideReboot(t *testing.T) {
	jkt, _ := time.LoadLocation("Asia/Jakarta")
	ny, _ := time.LoadLocation("America/New_York")
	at := func(loc *time.Location, y int, m time.Month, d, hh, mm int) time.Time {
		return time.Date(y, m, d, hh, mm, 0, 0, loc)
	}
	// a server where everything allows an automatic reboot at 02:30 in Jakarta
	base := func() RebootInput {
		return RebootInput{Now: at(jkt, 2026, 11, 17, 2, 30), Loc: jkt, WindowStart: 120, WindowEnd: 240, Enabled: true, Required: true,
			Uptime: 3 * 24 * time.Hour, Proven: true, CaddyOurs: true}
	}
	for _, c := range []struct {
		name string
		mod  func(*RebootInput)
		want string // go, wait, no
		why  string // part of the reason
	}{
		{"all good", func(*RebootInput) {}, "go", ""},
		{"off", func(i *RebootInput) { i.Enabled = false }, "no", "off"},
		{"not needed", func(i *RebootInput) { i.Required = false }, "no", "no reboot is needed"},
		{"window start edge", func(i *RebootInput) { i.Now = at(jkt, 2026, 11, 17, 2, 0) }, "go", ""},
		{"window end edge (end is out)", func(i *RebootInput) { i.Now = at(jkt, 2026, 11, 17, 4, 0) }, "wait", "outside"},
		{"just before", func(i *RebootInput) { i.Now = at(jkt, 2026, 11, 17, 1, 59) }, "wait", "outside"},
		{"same instant in UTC is outside", func(i *RebootInput) { i.Loc = time.UTC }, "wait", "outside"},
		{"across midnight, after start", func(i *RebootInput) {
			i.WindowStart, i.WindowEnd, i.Now = 23*60, 60, at(jkt, 2026, 11, 17, 23, 30)
		}, "go", ""},
		{"across midnight, before end", func(i *RebootInput) {
			i.WindowStart, i.WindowEnd, i.Now = 23*60, 60, at(jkt, 2026, 11, 18, 0, 59)
		}, "go", ""},
		{"across midnight, outside", func(i *RebootInput) {
			i.WindowStart, i.WindowEnd, i.Now = 23*60, 60, at(jkt, 2026, 11, 18, 1, 0)
		}, "wait", "outside"},
		{"DST starts inside the window: no 02:xx that day", func(i *RebootInput) {
			// 2027-03-14 02:00 EST does not exist in New York; 03:30 EDT is outside 02:00-03:00
			i.Loc, i.WindowStart, i.WindowEnd, i.Now = ny, 120, 180, time.Date(2027, 3, 14, 7, 30, 0, 0, time.UTC)
		}, "wait", "outside"},
		{"DST ends: 01:30 happens twice, both inside", func(i *RebootInput) {
			i.Loc, i.WindowStart, i.WindowEnd, i.Now = ny, 60, 120, time.Date(2026, 11, 1, 6, 30, 0, 0, time.UTC) // the second 01:30 (EST)
		}, "go", ""},
		{"deploy in progress waits", func(i *RebootInput) { i.Busy = []string{"a deploy of shop is in phase verify"} }, "wait", "deploy of shop"},
		{"stale backup taken first", func(i *RebootInput) { i.StaleBackups = []string{"shop"} }, "go", ""},
		{"booted an hour ago", func(i *RebootInput) { i.Uptime = time.Hour }, "no", "less than a day"},
		{"skip flag", func(i *RebootInput) { i.Skip = true }, "no", "skipped"},
		{"never rebooted under tando, not confirmed", func(i *RebootInput) { i.Proven = false }, "no", "first reboot is yours"},
		{"other sites", func(i *RebootInput) { i.CaddyOurs = false }, "no", "does not manage"},
		{"other sites allowed", func(i *RebootInput) { i.CaddyOurs, i.OtherSitesOK = false, true }, "go", ""},
		{"manual: no need, not enabled, recent boot, not proven: in the window it goes", func(i *RebootInput) {
			i.Manual, i.Enabled, i.Required, i.Uptime, i.Proven = true, false, false, time.Minute, false
		}, "go", ""},
		{"manual outside the window waits for it", func(i *RebootInput) { i.Manual, i.Now = true, at(jkt, 2026, 11, 17, 12, 0) }, "wait", "outside"},
		{"manual --now outside the window", func(i *RebootInput) { i.Manual, i.NowFlag, i.Now = true, true, at(jkt, 2026, 11, 17, 12, 0) }, "go", ""},
		{"manual --now refused while deploying", func(i *RebootInput) {
			i.Manual, i.NowFlag, i.Busy = true, true, []string{"a host setup is running"}
		}, "no", "host setup"},
		{"manual with other sites, not allowed", func(i *RebootInput) { i.Manual, i.NowFlag, i.CaddyOurs = true, true, false }, "no", "does not manage"},
		{"--now does not skip the rules for care", func(i *RebootInput) { i.NowFlag, i.Now = true, at(jkt, 2026, 11, 17, 12, 0) }, "wait", "outside"},
	} {
		in := base()
		c.mod(&in)
		d := DecideReboot(in)
		got := "no"
		switch {
		case d.Go:
			got = "go"
		case d.Wait:
			got = "wait"
		}
		if got != c.want || !strings.Contains(d.Reason, c.why) {
			t.Errorf("%s: %s %+v", c.name, got, d)
		}
		if c.name == "stale backup taken first" && (len(d.BackupFirst) != 1 || d.BackupFirst[0] != "shop") {
			t.Errorf("backup first: %v", d.BackupFirst)
		}
		if d.Wait && !d.At.After(in.Now) {
			t.Errorf("%s: waits until %v, not after now %v", c.name, d.At, in.Now)
		}
	}
}

func TestNextWindow(t *testing.T) {
	jkt, _ := time.LoadLocation("Asia/Jakarta")
	now := time.Date(2026, 11, 17, 12, 0, 0, 0, jkt)
	if n := NextWindow(now, jkt, 120); !n.Equal(time.Date(2026, 11, 18, 2, 0, 0, 0, jkt)) {
		t.Errorf("next: %v", n)
	}
	if n := NextWindow(now, jkt, 13*60); !n.Equal(time.Date(2026, 11, 17, 13, 0, 0, 0, jkt)) {
		t.Errorf("today: %v", n)
	}
	// New York, spring forward: 02:30 does not exist on 2027-03-14, so the next one is a day later
	ny, _ := time.LoadLocation("America/New_York")
	n := NextWindow(time.Date(2027, 3, 13, 12, 0, 0, 0, ny), ny, 150)
	if !n.Equal(time.Date(2027, 3, 15, 2, 30, 0, 0, ny)) {
		t.Errorf("DST: %v", n)
	}
	// a busy server inside the window looks again in 15 minutes
	d := DecideReboot(RebootInput{Now: time.Date(2026, 11, 17, 2, 10, 0, 0, jkt), Loc: jkt, WindowStart: 120, WindowEnd: 240, Enabled: true,
		Required: true, Uptime: 48 * time.Hour, Proven: true, CaddyOurs: true, Busy: []string{"x"}})
	if !d.Wait || d.At.Sub(time.Date(2026, 11, 17, 2, 10, 0, 0, jkt)) != 15*time.Minute {
		t.Errorf("busy: %+v", d)
	}
	// ... unless that is past the window's end: then the next window
	d = DecideReboot(RebootInput{Now: time.Date(2026, 11, 17, 3, 50, 0, 0, jkt), Loc: jkt, WindowStart: 120, WindowEnd: 240, Enabled: true,
		Required: true, Uptime: 48 * time.Hour, Proven: true, CaddyOurs: true, Busy: []string{"x"}})
	if !d.Wait || !d.At.Equal(time.Date(2026, 11, 18, 2, 0, 0, 0, jkt)) {
		t.Errorf("busy at the end: %+v", d)
	}
}

func TestParseWindow(t *testing.T) {
	for w, ok := range map[string]bool{"02:00-04:00": true, "23:30-00:30": true, "02:00-02:00": false, "2:00-4:00": false, "24:00-01:00": false, "": false, "02:00-04:00 ": false} {
		if _, _, got := ParseWindow(w); got != ok {
			t.Errorf("%q: %v", w, got)
		}
	}
}
