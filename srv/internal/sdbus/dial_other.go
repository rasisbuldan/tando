//go:build !linux

package sdbus

import (
	"errors"
	"time"
)

// Dial is Linux only (the package builds elsewhere for its tests).
func Dial(path string, timeout time.Duration) (*Conn, error) {
	return nil, errors.New("sdbus: Linux only")
}
