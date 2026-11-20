package lock

import (
	"os"
	"strconv"
	"strings"
	"syscall"
)

// Held: a process holds a flock(2) lock on path (the agent's app lock: an activation, a rollback,
// a backup). It reads /proc/locks and takes no lock itself. A probe that tried the lock (flock -n,
// LOCK_EX|LOCK_NB) held it for that instant: another probe then saw "held", and a verb's own try
// failed or waited for it. A missing file, a symlink or another kind of file is held by nothing.
// Without /proc/locks (not Linux: the unit tests on a laptop) it tries the lock as before.
//
// Matched by inode number (and lock kind FLOCK): /proc/locks names the device of the file system
// that holds the inode, which for a file on overlayfs (a container) is not the device stat sees.
// Another file system's inode of the same number with a flock on it reads as "held": a probe then
// waits for a turn it did not need, it never decides for a lock that is held.
func Held(path string) bool { return heldIn(path, "/proc/locks") }

func heldIn(path, locks string) bool {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return false
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	b, err := os.ReadFile(locks)
	if err != nil {
		return tryHeld(path)
	}
	ino := strconv.FormatUint(uint64(st.Ino), 10)
	for _, l := range strings.Split(string(b), "\n") {
		// "1: FLOCK  ADVISORY  WRITE 1234 08:01:5678 0 EOF"; a waiter's line has "->" after "1:"
		f := strings.Fields(l)
		if len(f) < 6 || f[1] != "FLOCK" {
			continue
		}
		if i := strings.LastIndexByte(f[5], ':'); i >= 0 && f[5][i+1:] == ino {
			return true
		}
	}
	return false
}

// tryHeld: the lock tried and released at once (flock -n path true); only where /proc/locks is missing
func tryHeld(path string) bool {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return true
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return true
	}
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return false
}
