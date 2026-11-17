package fsinfo

import (
	"os"
	"path/filepath"
	"testing"
)

func TestKinds(t *testing.T) {
	d := t.TempDir()
	dir, file, fifo := filepath.Join(d, "dir"), filepath.Join(d, "file"), filepath.Join(d, "fifo")
	os.Mkdir(dir, 0o755)
	os.WriteFile(file, nil, 0o644)
	os.Symlink(dir, filepath.Join(d, "ldir"))
	os.Symlink(file, filepath.Join(d, "lfile"))
	os.Symlink(filepath.Join(d, "nothing"), filepath.Join(d, "dangling"))
	mkfifo(fifo)
	type kinds struct{ dirF, dirN, regF, regN, exF, exN bool }
	for name, want := range map[string]kinds{
		"dir":      {true, true, false, false, true, true},
		"file":     {false, false, true, true, true, true},
		"ldir":     {true, false, false, false, true, true},
		"lfile":    {false, false, true, false, true, true},
		"dangling": {false, false, false, false, false, true},
		"nothing":  {false, false, false, false, false, false},
	} {
		p := filepath.Join(d, name)
		got := kinds{DirFollow(p), DirNoFollow(p), RegularFollow(p), RegularNoFollow(p), ExistsFollow(p), ExistsNoFollow(p)}
		if got != want {
			t.Errorf("%s: %+v, want %+v", name, got, want)
		}
	}
	if _, err := os.Lstat(fifo); err == nil && (RegularFollow(fifo) || RegularNoFollow(fifo) || DirFollow(fifo)) {
		t.Error("a FIFO is neither a regular file nor a directory")
	}
}

func TestStatfs(t *testing.T) {
	fs, err := Statfs(t.TempDir())
	if err != nil || fs.Blocks == 0 || fs.Unit == 0 || fs.Avail > fs.Blocks || fs.Free > fs.Blocks {
		t.Fatalf("%+v %v", fs, err)
	}
	if _, err := Statfs(filepath.Join(t.TempDir(), "nothing")); err == nil {
		t.Error("no error for a missing path")
	}
	f := FS{Unit: 4096}
	if f.KiB(3) != 12 || f.KiBUp(3) != 12 {
		t.Error("4 KiB blocks")
	}
	f.Unit = 512
	if f.KiB(3) != 1 || f.KiBUp(3) != 2 {
		t.Errorf("512 byte blocks: %d %d", f.KiB(3), f.KiBUp(3))
	}
}
