//go:build profile

package main

import (
	"os"
	"runtime/pprof"
)

// startProfile (a build with -tags profile, for measuring; never shipped): TANDOD_PROFILE=<file>
// gets a CPU profile of the whole run, written when it ends.
func startProfile() func() {
	p := os.Getenv("TANDOD_PROFILE")
	if p == "" {
		return func() {}
	}
	f, err := os.Create(p)
	if err != nil {
		return func() {}
	}
	pprof.StartCPUProfile(f)
	return pprof.StopCPUProfile
}
