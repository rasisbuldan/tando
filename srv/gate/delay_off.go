//go:build !tandogatedelay

package gate

// rxStartDelay postpones the receiver's systemd-run; only the tandogatedelay build (a test of
// a slow unit start, never shipped: scripts/build-server.sh does not set the tag) has one.
const rxStartDelay = 0
