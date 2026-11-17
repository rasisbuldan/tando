//go:build !tandotest

package daemon

// testHook does nothing in a real build. A build with -tags tandotest (the test suites only,
// never shipped) can make a tick panic or the process die on purpose: hook_on.go.
func testHook() {}
