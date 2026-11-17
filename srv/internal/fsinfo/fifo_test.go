package fsinfo

import "syscall"

func mkfifo(p string) { syscall.Mkfifo(p, 0o600) }
