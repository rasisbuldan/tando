package watch

import (
	"os"
	"strings"
	"testing"

	"tando/srv/internal/decimal"
)

// tandod keeps the key=value files between ticks: a change of any of them is seen on the next
// tick, and a removed app leaves nothing behind.
func TestCacheRevalidation(t *testing.T) {
	f := newFakeHost(t)
	f.cache = NewCache()
	f.app("hog")
	f.app("site", "recipe=static")
	f.settings("liveness=0")
	f.notifier("hook", "type=webhook\nurl=http://h/hook\n")
	f.ticks(2)
	f.reset()
	n := f.cache.Len()
	if n < 5 {
		t.Fatalf("%d files cached", n)
	}
	// app.conf: health_fails=1 from now on (a rename, as the agent writes it)
	f.write("opt/apps/hog/app.conf.new", "port=4100\nhealth=/health\nrecipe=node\nhealth_fails=1\n")
	os.Rename(f.path("opt/apps/hog/app.conf.new"), f.path("opt/apps/hog/app.conf"))
	f.probe["http://hog.localhost/health"] = probeRes{code: 500}
	f.tick()
	if f.st("hog.health.st") != "firing" {
		t.Errorf("changed app.conf not seen: %q", f.st("hog.health.st"))
	}
	// settings edited in place (same inode): resolve_after=1
	delete(f.probe, "http://hog.localhost/health")
	f.settings("liveness=0", "resolve_after=1")
	f.tick()
	if f.st("hog.health.st") == "firing" {
		t.Errorf("changed settings not seen")
	}
	// state: the app is stopped (tando stop)
	f.unit("tando-hog.service", "inactive", "dead", "0")
	f.write("opt/apps/hog/state", "current=20261114-170102\nphase=idle\nstopped=1\n")
	f.ticks(3)
	if f.st("hog.down.st") != "" {
		t.Errorf("changed state not seen: down %q", f.st("hog.down.st"))
	}
	// a notifier's file changed: the new URL is used
	f.notifier("hook", "type=webhook\nurl=http://h/hook2\n")
	f.write("lib/watch/inbox/"+decimal.Itoa(f.now.Unix())+".site.x", "rollback\tsite\tx\trolled back\n")
	f.tick()
	if len(f.sends) == 0 || f.sends[len(f.sends)-1].url != "http://h/hook2" {
		t.Errorf("changed notifier not seen: %+v", f.sends)
	}
	// the app removed: forgotten by the checks and by the cache
	os.RemoveAll(f.path("opt/apps/hog"))
	delete(f.units, "tando-hog.service")
	f.tick()
	for k := range f.state() {
		if strings.HasPrefix(k, "hog.") {
			t.Errorf("state of a removed app: %s", k)
		}
	}
	for p := range f.cache.kv { // (pruned by the tick itself: the list of apps changed)
		if strings.Contains(p, "/apps/hog/") {
			t.Errorf("cache keeps %s", p)
		}
	}
}

// A file rewritten within the same second with the same size is still seen (nanosecond mtime,
// and the inode of a rename).
func TestCacheSameSizeRename(t *testing.T) {
	c := NewCache()
	p := t.TempDir() + "/f"
	os.WriteFile(p, []byte("a=1\n"), 0o600)
	if m, _ := c.load(p); m["a"] != "1" {
		t.Fatal(m)
	}
	os.WriteFile(p+".new", []byte("a=2\n"), 0o600)
	os.Rename(p+".new", p)
	if m, _ := c.load(p); m["a"] != "2" {
		t.Errorf("rename not seen: %v", m)
	}
	m, _ := c.load(p)
	m["a"] = "changed by the caller"
	if m2, _ := c.load(p); m2["a"] != "2" {
		t.Errorf("the cache handed out its own map")
	}
	os.Remove(p)
	if m, _ := c.load(p); len(m) != 0 || c.Len() != 0 {
		t.Errorf("removed file: %v, %d cached", m, c.Len())
	}
}
