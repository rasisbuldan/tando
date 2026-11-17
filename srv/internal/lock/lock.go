// Package lock takes the flock(2) locks the shell programs take with `exec N> file; flock -w`,
// on the same files, so a Go program and a shell one exclude each other.
//
// Layer: internal: the standard library only; never a domain package or daemon.
package lock

import (
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"
)

// ErrBusy: another process held the lock for the whole timeout.
var ErrBusy = errors.New("lock busy")

// poll is how often a busy lock is tried again.
const poll = 50 * time.Millisecond

// Lock is a held lock; Release it (or exit: the kernel drops it with the descriptor).
type Lock struct{ f *os.File }

// Acquire takes an exclusive lock on path, waiting up to timeout. The file is made a regular
// file owned by this process's user (root) with mode 0600 first: a lock file any user can open
// is one any app can hold, and every run would wait for it (tando-watch's and the agent's
// `lockfile`). A symlink or another kind of file there is refused; one owned by someone else is
// replaced.
func Acquire(path string, timeout time.Duration) (*Lock, error) {
	f, err := open(path)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(timeout)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return &Lock{f: f}, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EINTR) {
			f.Close()
			return nil, fmt.Errorf("lock %s: %w", path, err)
		}
		if time.Now().After(deadline) {
			f.Close()
			return nil, fmt.Errorf("%s: %w after %s", path, ErrBusy, timeout)
		}
		time.Sleep(poll)
	}
}

// Release drops the lock.
func (l *Lock) Release() error { return l.f.Close() }

func open(path string) (*os.File, error) {
	fi, err := os.Lstat(path)
	switch {
	case err == nil && !fi.Mode().IsRegular():
		return nil, fmt.Errorf("lock file %s is not a regular file", path)
	case err == nil && owner(fi) != os.Geteuid():
		if err := os.Remove(path); err != nil {
			return nil, fmt.Errorf("lock file %s: %w", path, err)
		}
	case err != nil && !os.IsNotExist(err):
		return nil, fmt.Errorf("lock file %s: %w", path, err)
	}
	// O_NOFOLLOW: a symlink planted between the check and the open is refused, not followed
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, fmt.Errorf("lock file %s: %w", path, err)
	}
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return nil, fmt.Errorf("lock file %s: %w", path, err)
	}
	return f, nil
}

func owner(fi os.FileInfo) int {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return int(st.Uid)
	}
	return -1
}
