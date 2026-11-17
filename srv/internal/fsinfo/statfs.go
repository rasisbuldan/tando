package fsinfo

import "syscall"

// FS is what statfs(2) says of a file system, in df's terms. Block counts are in units of Unit
// bytes.
type FS struct {
	Blocks, Free, Avail uint64 // total, free, available to a user other than root
	Files, FilesFree    uint64 // inodes: total and free (0 total: the file system does not say)
	Unit                uint64 // the fragment size df counts blocks in (f_frsize), else f_bsize
}

// Statfs measures the file system path is on.
func Statfs(path string) (FS, error) {
	var s syscall.Statfs_t
	if err := syscall.Statfs(path, &s); err != nil {
		return FS{}, err
	}
	return FS{Blocks: uint64(s.Blocks), Free: uint64(s.Bfree), Avail: uint64(s.Bavail),
		Files: uint64(s.Files), FilesFree: uint64(s.Ffree), Unit: unit(&s)}, nil
}

// KiB is n blocks in KiB, rounded down.
func (f FS) KiB(n uint64) uint64 { return n * f.Unit / 1024 }

// KiBUp is n blocks in KiB rounded up, as GNU df -k rounds.
func (f FS) KiBUp(n uint64) uint64 { return (n*f.Unit + 1023) / 1024 }
