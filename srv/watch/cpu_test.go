package watch

import (
	"os"
	"strings"
	"testing"

	"tando/srv/internal/decimal"
)

const cpuFiring = `"state":"firing","app":"hog","check":"cpu_sustained"`

// cpuUse sets the slice's cumulative CPU (usage_usec) and its limit (cpu.max).
func (f *fakeHost) cpuUse(app string, usec int64, max string) {
	sl := "cgroup/tando.slice/tando-" + app + ".slice"
	os.MkdirAll(f.path(sl+"/tando-"+app+".service"), 0o700)
	f.write(sl+"/cpu.stat", "usage_usec "+decimal.Itoa(usec)+"\nuser_usec 0\n")
	f.write(sl+"/cpu.max", max+"\n")
}

// An app whose slice uses its whole CPU limit for cpu_for minutes fires cpu_sustained once; a
// minute under it resets the count; a build or a deploy in between neither counts nor resets.
func TestCPUSustainedFiresAfterCpuForMinutes(t *testing.T) {
	f := newFakeHost(t)
	f.app("hog")
	f.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook\n")
	f.settings("cpu_for=3")
	use := int64(0)
	minute := func(pctOfCore int64) { // the next tick sees this minute's CPU
		use += pctOfCore * 600_000 // 1% of a core for 60 s = 600 ms
		f.cpuUse("hog", use, "25000 100000")
	}
	f.cpuUse("hog", use, "25000 100000")
	f.tick() // the first sample: nothing to compare with
	for range 2 {
		minute(25) // the whole limit (25% of one core)
		f.tick()
	}
	if f.countSent(cpuFiring) != 0 {
		t.Fatalf("fired after 2 minutes with cpu_for=3")
	}
	minute(5) // a quiet minute resets the count
	f.tick()
	for range 2 {
		minute(24)
		f.tick()
	}
	// a build runs: this minute counts neither way
	os.MkdirAll(f.path("cgroup/tando.slice/tando-hog.slice/tando-hog-build-1.service"), 0o700)
	minute(25)
	f.tick()
	os.Remove(f.path("cgroup/tando.slice/tando-hog.slice/tando-hog-build-1.service"))
	if f.countSent(cpuFiring) != 0 {
		t.Fatalf("fired with a build minute counted: %v", f.sentBodies())
	}
	minute(25)
	f.tick()
	if f.countSent(cpuFiring) != 1 {
		t.Fatalf("not fired after 3 high minutes: %q %v", f.st("hog.cpu_sustained.st"), f.sentBodies())
	}
	if d := f.st("hog.cpu_sustained.det"); !strings.Contains(d, "of its limit") {
		t.Errorf("detail %q", d)
	}
}

// Without a CPU limit the share is of one core; cpu_sustained=off for the app turns it off.
func TestCPUSustainedOneCoreAndOff(t *testing.T) {
	f := newFakeHost(t)
	f.app("hog")
	f.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook\n")
	f.settings("cpu_for=2")
	use := int64(0)
	f.cpuUse("hog", use, "max 100000")
	f.tick()
	for range 2 {
		use += 50 * 600_000 // half a core: under 90% of one core
		f.cpuUse("hog", use, "max 100000")
		f.tick()
	}
	if f.countSent(cpuFiring) != 0 {
		t.Fatalf("half a core without a limit fired")
	}
	for range 2 {
		use += 95 * 600_000
		f.cpuUse("hog", use, "max 100000")
		f.tick()
	}
	if f.countSent(cpuFiring) != 1 {
		t.Fatalf("95%% of a core for 2 minutes did not fire: %v", f.sentBodies())
	}
	g := newFakeHost(t)
	g.app("hog")
	g.notifier("hook", "type=webhook\nurl=http://127.0.0.1:9/hook\n")
	g.settings("cpu_for=1", "hog.cpu_sustained=off")
	use = 0
	g.cpuUse("hog", use, "max 100000")
	g.tick()
	use += 99 * 600_000
	g.cpuUse("hog", use, "max 100000")
	g.ticks(2)
	if g.countSent(cpuFiring) != 0 {
		t.Fatalf("fired although turned off")
	}
}
