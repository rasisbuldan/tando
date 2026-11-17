//go:build linux

package gate

import (
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func mkfs(t *testing.T) string {
	t.Helper()
	d := filepath.Join(t.TempDir(), "incoming")
	for _, p := range []string{"a", "a/b", "c"} {
		os.MkdirAll(filepath.Join(d, p), 0o755)
	}
	os.WriteFile(filepath.Join(d, "a/b/f"), []byte("hello"), 0o644)
	os.WriteFile(filepath.Join(d, "top"), []byte("x"), 0o644)
	os.Symlink("b/f", filepath.Join(d, "a/in"))
	os.Symlink("../../../outside", filepath.Join(d, "a/out"))
	os.Symlink("/etc", filepath.Join(d, "c/etc"))
	return d
}

func TestReadTreeAndScan(t *testing.T) {
	d := mkfs(t)
	uid := uint32(os.Getuid())
	var s scanResult
	tr, over, err := readTree(d, 100, func(n *node) { s.see(n, uid) })
	if err != nil || over {
		t.Fatal(err, over)
	}
	if n := tr.nodes["c/etc"]; n == nil || !n.isLink() || n.target != "/etc" {
		t.Fatalf("c/etc: %+v", n)
	}
	for rel := range tr.nodes {
		if filepath.Dir(rel) == "c/etc" || rel == "c/etc/passwd" {
			t.Fatalf("walked through the link to /etc: %s", rel)
		}
	}
	if s.n != 8 {
		t.Errorf("entries %d", s.n)
	}
	if v := s.verdict(tr, false, Limits{MaxBytes: 1 << 30, MaxFiles: 100}); v != "absolute symlink in the upload: c/etc" {
		t.Errorf("verdict %q", v)
	}
	os.Remove(filepath.Join(d, "c/etc"))
	s = scanResult{}
	tr, _, _ = readTree(d, 100, func(n *node) { s.see(n, uid) })
	if v := s.verdict(tr, false, Limits{MaxBytes: 1 << 30, MaxFiles: 100}); v != "symlink leaves the upload: a/out" {
		t.Errorf("verdict %q", v)
	}
	syscall.Mkfifo(filepath.Join(d, "fifo"), 0o644)
	s = scanResult{}
	tr, _, _ = readTree(d, 100, func(n *node) { s.see(n, uid) })
	if v := s.verdict(tr, false, Limits{MaxBytes: 1 << 30, MaxFiles: 100}); v != "special file in the upload: fifo" {
		t.Errorf("verdict %q", v)
	}
	// over the entry limit: counted, not all kept
	s = scanResult{}
	_, over, _ = readTree(d, 3, func(n *node) { s.see(n, uid) })
	if !over || s.n != 8 {
		t.Errorf("over %v n %d", over, s.n)
	}
}

func TestDropEscapingLinks(t *testing.T) {
	d := mkfs(t)
	g := &Gate{}
	g.dropEscapingLinks(d)
	for p, want := range map[string]bool{"a/in": true, "a/out": false, "c/etc": false, "a/b/f": true} {
		if _, err := os.Lstat(filepath.Join(d, p)); (err == nil) != want {
			t.Errorf("%s exists: %v, want %v", p, err == nil, want)
		}
	}
}

func TestStripSetidChmodChown(t *testing.T) {
	d := mkfs(t)
	f := filepath.Join(d, "a/b/f")
	os.Chmod(f, 0o6755)
	if err := stripSetid(d); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(f); fi.Mode()&(os.ModeSetuid|os.ModeSetgid) != 0 || fi.Mode().Perm() != 0o755 {
		t.Errorf("mode %v", fi.Mode())
	}
	if err := chmodDir(d, 0o700); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(d); fi.Mode().Perm() != 0o700 {
		t.Errorf("dir mode %v", fi.Mode())
	}
	if err := chmodDir(filepath.Join(d, "c/etc"), 0o700); err == nil {
		t.Error("chmodDir followed a symlink")
	}
	if err := chownTree(d, os.Getuid(), os.Getgid()); err != nil {
		t.Fatal(err)
	}
}

func TestRemoveOwned(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(root, "keep")
	os.WriteFile(outside, []byte("x"), 0o644)
	tmp := filepath.Join(root, "tmp")
	os.MkdirAll(filepath.Join(tmp, "d/e"), 0o755)
	os.WriteFile(filepath.Join(tmp, "d/e/f"), nil, 0o644)
	os.Symlink(outside, filepath.Join(tmp, "link"))
	os.Symlink(root, filepath.Join(tmp, "dirlink"))
	removeOwned(tmp, uint32(os.Getuid()))
	if ents, _ := os.ReadDir(tmp); len(ents) != 0 {
		t.Errorf("left %v", ents)
	}
	if _, err := os.Stat(outside); err != nil {
		t.Error("followed a link out")
	}
	removeOwned(tmp, uint32(os.Getuid())+1) // someone else's: nothing to do
}

// A directory swapped for a symlink (to /, to its parent) while the watchdog walks never takes
// the walk outside the tree, and never loops.
func TestMeasureSwapRace(t *testing.T) {
	d := mkfs(t)
	os.Remove(filepath.Join(d, "c/etc"))
	sub, alt := filepath.Join(d, "a"), filepath.Join(d, "a.real")
	var stop atomic.Bool
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; !stop.Load(); i++ {
			os.Rename(sub, alt)
			target := "/"
			if i%2 == 1 {
				target = "."
			}
			os.Symlink(target, sub)
			os.Remove(sub)
			os.Rename(alt, sub)
		}
	}()
	deadline := time.Now().Add(3 * time.Second)
	runs, max := 0, int64(0)
	for time.Now().Before(deadline) {
		_, n, err := measure(d, 1<<40, 1000)
		if err != nil && !gone(err) {
			t.Fatal(err)
		}
		if n > max {
			max = n
		}
		runs++
		var s scanResult
		tr, _, err := readTree(d, 1000, func(n *node) { s.see(n, uint32(os.Getuid())) })
		if err == nil && len(tr.nodes) > 20 {
			t.Fatalf("readTree left the tree: %d entries", len(tr.nodes))
		}
	}
	stop.Store(true)
	<-done
	if max > 20 {
		t.Fatalf("a walk counted %d entries: it left the tree", max)
	}
	t.Logf("%d walks during swaps, at most %d entries", runs, max)
}

// S4: a directory the upload left at mode 000 hides nothing from the deploy user's own walks
// (links are still removed, setuid bits still stripped), while root's scan refuses a tree it
// cannot read whole. Run as a normal user (as root, permissions do not stop anything).
func TestUnreadableDirInUpload(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("needs a non-root user: root reads every directory")
	}
	d := mkfs(t)
	hid := filepath.Join(d, "hidden")
	os.MkdirAll(filepath.Join(hid, "deeper"), 0o755)
	os.Symlink("/etc/passwd", filepath.Join(hid, "deeper/out"))
	os.WriteFile(filepath.Join(hid, "suid"), []byte("x"), 0o4755)
	os.Chmod(filepath.Join(hid, "deeper"), 0)
	os.Chmod(hid, 0)
	t.Cleanup(func() { os.Chmod(hid, 0o755); os.Chmod(filepath.Join(hid, "deeper"), 0o755) })
	// a walk that is not the user's own: an error, so root's scan would refuse the upload
	if _, _, err := readTree(d, 100, func(*node) {}); err == nil {
		t.Fatal("readTree went past an unreadable directory")
	}
	if _, _, err := measure(d, 1<<40, 1000); err == nil {
		t.Fatal("measure went past an unreadable directory")
	}
	os.Chmod(d, 0) // incoming/ itself at 000 too
	g := &Gate{}
	if err := chmodDir(d, 0o700); err != nil {
		t.Fatal(err)
	}
	g.dropEscapingLinks(d)
	if err := stripSetid(d); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(hid, "deeper/out")); err == nil {
		t.Error("the escaping link under a 000 directory was kept")
	}
	if fi, err := os.Stat(filepath.Join(hid, "suid")); err != nil || fi.Mode()&os.ModeSetuid != 0 {
		t.Errorf("setuid under a 000 directory: %v %v", fi, err)
	}
}
