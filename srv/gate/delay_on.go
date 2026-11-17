//go:build tandogatedelay

package gate

import "time"

// rxStartDelay: a systemd-run that takes 6 s to start the unit (test build only).
const rxStartDelay = 6 * time.Second
