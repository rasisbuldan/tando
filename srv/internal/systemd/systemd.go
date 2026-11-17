// Package systemd asks systemd about units with one `systemctl show` call for all of them: one
// fork per run, whatever the number of apps.
//
// Layer: internal. It imports internal/run; never a domain package or daemon.
package systemd

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"strings"
	"time"

	"tando/srv/internal/run"
)

// showTimeout: a hung systemd (dbus) must not hold a per-minute run (tando-watch's `timeout 20`).
const showTimeout = 20 * time.Second

// Show returns the properties of each unit, in the order of units. systemctl answers for units
// that do not exist too (ActiveState=inactive), so a missing app unit is not an error. An empty
// or short answer is: a failed call must not read as "every unit is inactive".
func Show(ctx context.Context, r run.Runner, units []string, props ...string) ([]map[string]string, error) {
	if len(units) == 0 {
		return nil, nil
	}
	argv := append([]string{"systemctl", "show", "-p", strings.Join(props, ",")}, units...)
	b, err := r.Output(ctx, run.Cmd{Argv: argv, Timeout: showTimeout})
	if err != nil {
		return nil, err
	}
	res := parseShow(b)
	if len(res) != len(units) {
		return nil, fmt.Errorf("systemctl show: %d answers for %d units", len(res), len(units))
	}
	return res, nil
}

// parseShow splits `systemctl show` output into one map per unit: blocks of key=value lines
// separated by an empty line (the last block has none after it).
func parseShow(b []byte) []map[string]string {
	var res []map[string]string
	var cur map[string]string
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(nil, 1<<20)
	for sc.Scan() {
		l := sc.Text()
		if l == "" {
			if cur != nil {
				res = append(res, cur)
				cur = nil
			}
			continue
		}
		if cur == nil {
			cur = map[string]string{}
		}
		if k, v, ok := strings.Cut(l, "="); ok {
			cur[k] = v
		}
	}
	if cur != nil {
		res = append(res, cur)
	}
	return res
}
