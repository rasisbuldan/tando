//go:build !linux

package fsinfo

import "syscall"

// unit: no f_frsize here (the package builds elsewhere for the tests)
func unit(s *syscall.Statfs_t) uint64 { return uint64(s.Bsize) }
