package hostcare

import (
	"os"
	"syscall"
)

// devOf is the device a file is on (0: unknown).
func devOf(fi os.FileInfo) uint64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return uint64(st.Dev)
	}
	return 0
}
