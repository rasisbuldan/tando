package hostcare

import "syscall"

// staUnsync is the kernel's STA_UNSYNC: set while no time service keeps the clock in step
// (timedatectl's NTPSynchronized reads the same flag).
const staUnsync = 0x0040

// adjtimex asks the kernel whether its clock is synchronised (a read: modes 0, no privilege).
func adjtimex() (synced, known bool) {
	var t syscall.Timex
	if _, err := syscall.Adjtimex(&t); err != nil {
		return false, false
	}
	return t.Status&staUnsync == 0, true
}
