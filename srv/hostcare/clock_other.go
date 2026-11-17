//go:build !linux

package hostcare

// adjtimex: not known off Linux (the package builds elsewhere for its tests).
func adjtimex() (synced, known bool) { return false, false }
