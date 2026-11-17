package logs

import "syscall"

// LimitProcessCPU is what tando-logs' main sets as Logs.LimitCPU: RLIMIT_CPU of the whole
// process, inherited by the commands it starts. Only a one-shot may use it (a long-running
// caller leaves LimitCPU nil: the limit would be its own).
func LimitProcessCPU(seconds uint64) error {
	return syscall.Setrlimit(syscall.RLIMIT_CPU, &syscall.Rlimit{Cur: seconds, Max: seconds})
}
