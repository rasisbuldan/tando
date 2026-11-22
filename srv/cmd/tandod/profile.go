package main

import (
	"os"
	"runtime/pprof"
)

// startProfile: TANDOD_PROFILE=<file> (off by default; set it in a drop-in of tandod.service to
// measure) gets a CPU profile of the whole run, written when the daemon stops (`go tool pprof
// <file>`). The breakdown by section needs no restart: tando-status cost.
func startProfile() func() {
	p := os.Getenv("TANDOD_PROFILE")
	if p == "" {
		return func() {}
	}
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return func() {}
	}
	if pprof.StartCPUProfile(f) != nil {
		f.Close()
		return func() {}
	}
	return func() { pprof.StopCPUProfile(); f.Close() }
}
