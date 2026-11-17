package sysexec

import sc "syscall"

func F() { sc.Exec("/bin/x", nil, nil) }
