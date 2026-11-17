package rawexec

import "syscall"

func F() { syscall.Syscall(syscall.SYS_EXECVE, 0, 0, 0) }
