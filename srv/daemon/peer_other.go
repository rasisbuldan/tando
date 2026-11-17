//go:build !linux

package daemon

import (
	"errors"
	"net"
	"syscall"
)

// peerUID: tandod runs on Linux only; elsewhere (a developer's laptop) every peer is refused.
func peerUID(net.Conn) (int, error) { return -1, errors.New("peer credentials: linux only") }

func umask(m int) int { return syscall.Umask(m) }
