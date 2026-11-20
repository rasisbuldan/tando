package lock

import (
	"errors"
	"os"
	"syscall"
)

// Held: a process holds the lock on path exclusively (the agent's app lock: an activation, a
// rollback, a backup). It tries a SHARED lock and drops it at once: probes never see each other
// as "held" (tando-watch, tando status and the agent's busy check may probe at the same moment),
// and a verb never fails on a probe: its own `flock -n` try in that instant falls through to its
// waiting flock, which gets the lock as soon as the probe drops it (microseconds).
// (/proc/locks cannot answer this: the agent takes its locks through flock(1), a child that
// exits, and the kernel leaves out locks whose owner is gone.)
// A missing file, a symlink or another kind of file is held by nothing.
func Held(path string) bool {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return false
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return !errors.Is(err, os.ErrNotExist) && !errors.Is(err, syscall.ELOOP)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		return true
	}
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return false
}
