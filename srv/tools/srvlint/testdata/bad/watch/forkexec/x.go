package forkexec

import "syscall"

func F() {
	syscall.ForkExec("/bin/x", nil, nil)
	syscall.StartProcess("/bin/x", nil, nil)
}
