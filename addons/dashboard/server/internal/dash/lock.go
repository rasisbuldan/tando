package dash

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// dash.lock (0600): one tando-dash per user. The running instance holds an flock on it and has
// written its pid, port, re-open URL and a key; a second tando-dash that cannot take the lock
// reads them and asks the running one for a fresh opening link (POST /api/newcode with the key).
// The file is emptied, never removed, at exit: removing it would let two instances lock two
// different files.

// LockInfo: what dash.lock holds
type LockInfo struct {
	Pid     int    `json:"pid"`
	Port    int    `json:"port"`
	URL     string `json:"url"`
	Key     string `json:"key"`
	Started string `json:"started"`
}

// Lock: the held dash.lock
type Lock struct {
	f *os.File
}

// AcquireLock: the lock (we are the one instance), or the running instance's info
func AcquireLock(path string) (*Lock, *LockInfo, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, nil, err
	}
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, nil, err
	}
	_ = f.Chmod(0o600)
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, nil, err
		}
		// the holder may be writing it right now: a few tries
		for i := 0; i < 20; i++ {
			var li LockInfo
			if b, err := os.ReadFile(path); err == nil && json.Unmarshal(b, &li) == nil && li.Port > 0 {
				return nil, &li, nil
			}
			time.Sleep(50 * time.Millisecond)
		}
		return nil, nil, errors.New("another tando-dash holds " + path + " but has not written it")
	}
	return &Lock{f: f}, nil, nil
}

// Write the instance's info into the held lock
func (l *Lock) Write(li LockInfo) error {
	b, err := json.Marshal(li)
	if err != nil {
		return err
	}
	if err := l.f.Truncate(0); err != nil {
		return err
	}
	if _, err := l.f.WriteAt(append(b, '\n'), 0); err != nil {
		return err
	}
	return l.f.Sync()
}

// Release: empty the file, unlock
func (l *Lock) Release() {
	_ = l.f.Truncate(0)
	_ = syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	l.f.Close()
}
