//go:build !linux

package logs

import (
	"os"
	"syscall"
)

// statBuf: os.Stat where fstatat is not wired (the developer's Mac, for the unit tests).
type statBuf struct{}

func (b *statBuf) stat(p []byte) fsig {
	fi, err := os.Stat(string(p[:len(p)-1]))
	if err != nil {
		return fsig{}
	}
	var ino uint64
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		ino = uint64(st.Ino)
	}
	return fsig{ok: true, ino: ino, size: fi.Size(), mtime: fi.ModTime().UnixNano()}
}
