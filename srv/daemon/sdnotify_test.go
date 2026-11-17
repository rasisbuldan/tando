package daemon

import (
	"testing"
	"time"
)

// The watchdog interval comes from what main read of systemd's environment.
func TestWatchdogInterval(t *testing.T) {
	for _, tt := range []struct {
		sd   Systemd
		want time.Duration
	}{
		{Systemd{}, 0},
		{Systemd{WatchdogUSec: "300000000"}, 150 * time.Second},
		{Systemd{WatchdogUSec: "300000000", WatchdogPID: "42"}, 150 * time.Second},
		{Systemd{WatchdogUSec: "300000000", WatchdogPID: "43"}, 0}, // another process's watchdog
		{Systemd{WatchdogUSec: "-1"}, 0},
		{Systemd{WatchdogUSec: "x"}, 0},
	} {
		if got := tt.sd.watchdogInterval(42); got != tt.want {
			t.Errorf("%+v: %v, want %v", tt.sd, got, tt.want)
		}
	}
}
