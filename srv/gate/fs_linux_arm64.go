//go:build linux && arm64

package gate

import "syscall"

const sysFstatat = syscall.SYS_FSTATAT
