package logs

import (
	"syscall"
	"unsafe"
)

// statBuf stats a NUL-terminated path with fstatat(2) into a reused buffer: no allocation (os.Stat
// makes a FileInfo and a C string each time; this runs for every app every minute).
type statBuf struct{ st syscall.Stat_t }

const atFDCWD = -100

func (b *statBuf) stat(p []byte) fsig {
	fd := atFDCWD
	_, _, e := syscall.Syscall6(sysFstatat, uintptr(fd), uintptr(unsafe.Pointer(&p[0])), uintptr(unsafe.Pointer(&b.st)), 0, 0, 0)
	if e != 0 {
		return fsig{}
	}
	return fsig{ok: true, ino: uint64(b.st.Ino), size: b.st.Size, mtime: b.st.Mtim.Sec*1e9 + b.st.Mtim.Nsec}
}
