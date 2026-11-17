//go:build !profile

package main

// startProfile: nothing in a real build (profile.go).
func startProfile() func() { return func() {} }
