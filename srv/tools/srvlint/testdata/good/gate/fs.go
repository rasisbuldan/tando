package gate

import (
	"syscall"
	"unsafe"
)

const sysFstatat = syscall.SYS_NEWFSTATAT

func F(p *byte, b []byte) {
	syscall.Syscall6(sysFstatat, 1, uintptr(unsafe.Pointer(p)), 0, 0, 0, 0)
	syscall.Syscall6(syscall.SYS_READLINKAT, 1, uintptr(unsafe.Pointer(p)), 0, 0, 0, 0)
	syscall.Syscall(syscall.SYS_UNLINKAT, 1, uintptr(unsafe.Pointer(p)), 0)
}
