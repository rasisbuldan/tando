package rawalias

import sc "syscall"

const n = sc.SYS_EXECVEAT

func F() {
	sc.RawSyscall6(n, 0, 0, 0, 0, 0, 0)
	sc.Syscall6(sc.SYS_READLINKAT, 0, 0, 0, 0, 0, 0)
}
