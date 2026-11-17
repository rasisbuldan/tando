package sdbus

import (
	"fmt"
	"os"
	"syscall"
	"time"
)

// Dial connects to the socket at path and authenticates as this process's effective uid. A unix
// socket connects at once or not at all (a full backlog fails: the caller falls back to
// systemctl), so there is no connect timeout; timeout bounds the authentication.
func Dial(path string, timeout time.Duration) (*Conn, error) {
	fd, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC|syscall.SOCK_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	if err := syscall.Connect(fd, &syscall.SockaddrUnix{Name: path}); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("connect %s: %w", path, err)
	}
	f := os.NewFile(uintptr(fd), path) // (non-blocking: the runtime poller, so deadlines work)
	f.SetDeadline(time.Now().Add(timeout))
	return NewConn(f, os.Geteuid(), f.SetDeadline)
}
