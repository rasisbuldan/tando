package gate

import (
	"strings"
	"testing"
)

// The dashboard's reads (tando snapshot, lib/cmd-snapshot.sh, and env-names) are admin reads: a
// deploy key gets none of them, as a whole command or piece by piece. The compound commands are
// the client's exact ones (snap_cmd) for app alpha, without and with --app.
func TestDashboardReadsRefused(t *testing.T) {
	load := `read -r l1 l5 l15 _x < /proc/loadavg 2> /dev/null && printf 'loadavg\t%s\t%s\t%s\n' "$l1" "$l5" "$l15"`
	clock := `printf 'clock\t%s\n' "$EPOCHREALTIME"`
	cheap := "sudo -n " + tAgent + " status; " + load + "; " + clock
	full := "sudo -n " + tAgent + " status; " + load + "; echo '@releases'; sudo -n " + tAgent + " releases alpha; echo '@history'; sudo -n " +
		tAgent + " history alpha 20; echo '@metrics'; if [ -x /opt/tando/bin/tando-metrics ]; then sudo -n /opt/tando/bin/tando-metrics read alpha 144 600;" +
		" else echo 'mx\tnone'; fi; echo '@health'; if [ -x /opt/tando/bin/tando-watch ]; then sudo -n /opt/tando/bin/tando-watch health alpha; fi;" +
		" echo '@audit'; sudo -n " + tAgent + " audit-read alpha 300; " + clock
	tests := []struct{ cmd, msg string }{
		{"sudo -n " + tAgent + " env-names alpha", "not allowed with a deploy key: env-names"},
		{tAgent + " env-names alpha", "not allowed with a deploy key: env-names"},
		{"sudo -n " + tAgent + " env-names bravo", "not allowed with a deploy key: env-names"},
		{"sudo -n " + tAgent + " audit-read alpha 300", "not allowed with a deploy key: audit-read"},
		{"sudo -n /opt/tando/bin/tando-metrics read alpha 144 600", "not allowed with a deploy key"},
		{"sudo -n /opt/tando/bin/tando-watch health alpha", "not allowed with a deploy key"},
		{load, "unexpected characters"},
		{clock, "unexpected characters"},
		{cheap, "unexpected characters"},
		{full, "request too long"},
	}
	for _, tt := range tests {
		t.Run(strings.ToValidUTF8(tt.cmd, "?"), func(t *testing.T) {
			r, err := ParseRequest(tt.cmd, tWant)
			if err == nil {
				t.Fatalf("accepted: %+v", r)
			}
			if !strings.HasPrefix(err.Error(), tt.msg) {
				t.Fatalf("refused with %q, want %q", err, tt.msg)
			}
		})
	}
}
