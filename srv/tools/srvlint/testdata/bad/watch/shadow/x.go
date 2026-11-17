package shadow

import "syscall"

func F() {
	// the real package, called through a variable of another name
	g := syscall.Syscall
	g(syscall.SYS_EXECVE, 0, 0, 0)
}
