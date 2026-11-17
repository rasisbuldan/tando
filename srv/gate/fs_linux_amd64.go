//go:build linux && amd64

package gate

import "syscall"

const sysFstatat = syscall.SYS_NEWFSTATAT
