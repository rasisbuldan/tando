package hostcare

import (
	"os"
	"syscall"
)

// dpkgLockHolder: the process holding dpkg's front-end lock (apt, unattended-upgrades, dpkg),
// asked with F_GETLK (nothing is locked): 0 when free, -1 when held by a process the kernel does
// not name (an open file description lock).
func dpkgLockHolder(path string) int {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return 0
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() {
		return 0
	}
	lk := syscall.Flock_t{Type: syscall.F_WRLCK}
	if err := syscall.FcntlFlock(f.Fd(), syscall.F_GETLK, &lk); err != nil || lk.Type == syscall.F_UNLCK {
		return 0
	}
	if lk.Pid <= 0 {
		return -1
	}
	return int(lk.Pid)
}
