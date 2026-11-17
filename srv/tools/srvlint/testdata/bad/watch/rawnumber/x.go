package rawnumber

import "syscall"

func F() {
	n := uintptr(59)
	syscall.Syscall(n, 0, 0, 0)
	syscall.RawSyscall(59, 0, 0, 0)
}
