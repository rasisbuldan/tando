// Package atomicfile replaces files so that a reader (or a crash) sees the old content or the new,
// never a mix: the data goes to a temporary file in the same directory, is flushed to disk, gets
// its mode and owner, and is renamed over the target. The shell programs did the same with
// "temp file + mv" (without the flush, so a power cut could leave an empty state file).
//
// Layer: internal: the standard library only; never a domain package or daemon.
package atomicfile

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// Perm is the mode and owner a written file gets.
type Perm struct {
	Mode     fs.FileMode
	UID, GID int // -1: the writer's (root, for the server programs)
}

// Mode is a Perm that keeps the writer as owner.
func Mode(m fs.FileMode) Perm { return Perm{Mode: m, UID: -1, GID: -1} }

// Write replaces path with data.
func Write(path string, data []byte, p Perm) error {
	dir, base := filepath.Split(path)
	if dir == "" {
		dir = "."
	}
	f, err := os.CreateTemp(dir, "."+base+".tmp*")
	if err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	tmp := f.Name()
	err = fill(f, data, p)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
		return fmt.Errorf("write %s: %w", path, err)
	}
	// the rename itself reaches the disk with the directory
	if d, err := os.Open(dir); err == nil {
		d.Sync()
		d.Close()
	}
	return nil
}

func fill(f *os.File, data []byte, p Perm) error {
	if _, err := f.Write(data); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Chmod(p.Mode); err != nil { // (CreateTemp made it 0600)
		return err
	}
	if p.UID >= 0 || p.GID >= 0 {
		return f.Chown(p.UID, p.GID)
	}
	return nil
}

// WriteIfChanged writes only when path does not already hold data, and reports whether it
// wrote. An unchanged file keeps its mtime (tando-watch and doctor read mtimes) and is not
// flushed again for nothing.
func WriteIfChanged(path string, data []byte, p Perm) (bool, error) {
	old, err := os.ReadFile(path)
	if err == nil && bytes.Equal(old, data) {
		return false, nil
	}
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return false, fmt.Errorf("read %s: %w", path, err)
	}
	return true, Write(path, data, p)
}
