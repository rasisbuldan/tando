package linkname

import _ "unsafe"

//go:linkname forkExec syscall.forkExec
func forkExec()
