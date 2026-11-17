//go:build tandotest

package daemon

import "os"

// testHook (built only with -tags tandotest, by test/e2e-alerts.sh): TANDOD_TEST_PANIC=1 makes
// every tick panic, TANDOD_TEST_DIE=1 makes the process die in it.
func testHook() {
	if os.Getenv("TANDOD_TEST_DIE") == "1" {
		os.Exit(70)
	}
	if os.Getenv("TANDOD_TEST_PANIC") == "1" {
		panic("tandod test panic (TANDOD_TEST_PANIC=1)")
	}
}
