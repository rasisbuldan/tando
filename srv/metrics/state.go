package metrics

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strconv"
	"strings"
)

// hostKey is the host's line in .state (an app name cannot start with a dot).
const hostKey = ".host"

// entry is one line of .state: what the next sample needs from the last one.
type entry struct {
	usec  int64 // the unit's cpu usage_usec at the last sample (-1: not known); the next line holds the difference
	start int64 // when the current .tsv file began (0: not known yet)
	lines int64 // lines in the current .tsv file
	// x: an app's last disk walk (tried or done, unix time; 0: never); the host's total cpu
	// jiffies of /proc/stat (0: not known), whose busy jiffies are in usec
	x int64
	// an app's slice counters at the last sample (-1: not known): cpu.stat nr_periods and
	// nr_throttled, memory.events oom_kill
	periods, throttled, ooms int64
	// an app's uid's network bytes at the last sample (-1: not known): sent and received, the
	// nftables counters out_<uid> and in_<uid> of fw_sync
	out, in int64
}

// state maps an app (or hostKey) to its entry.
type state map[string]entry

// loadState reads .state; a missing one is empty (the first sample). Fields that are not numbers
// count as absent, as an empty one did in the shell (`${PU[$a]:-$usec}`).
func loadState(path string) (state, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return state{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	st := state{}
	sc := bufio.NewScanner(bytes.NewReader(b))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) == 0 {
			continue
		}
		e := entry{usec: -1, periods: -1, throttled: -1, ooms: -1, out: -1, in: -1}
		if len(f) > 1 {
			if n, err := strconv.ParseInt(f[1], 10, 64); err == nil {
				e.usec = n
			}
		}
		if len(f) > 2 {
			e.start, _ = strconv.ParseInt(f[2], 10, 64)
		}
		if len(f) > 3 {
			e.lines, _ = strconv.ParseInt(f[3], 10, 64)
		}
		if len(f) > 4 {
			e.x, _ = strconv.ParseInt(f[4], 10, 64)
		}
		for i, p := range []*int64{&e.periods, &e.throttled, &e.ooms, &e.out, &e.in} {
			if len(f) > 5+i {
				if n, err := strconv.ParseInt(f[5+i], 10, 64); err == nil {
					*p = n
				}
			}
		}
		st[f[0]] = e
	}
	return st, nil
}

// format renders .state in the order of keys.
func (st state) format(keys []string) []byte {
	var b bytes.Buffer
	for _, k := range keys {
		e := st[k]
		fmt.Fprintf(&b, "%s %d %d %d %d", k, e.usec, e.start, e.lines, e.x)
		if k != hostKey {
			fmt.Fprintf(&b, " %d %d %d %d %d", e.periods, e.throttled, e.ooms, e.out, e.in)
		}
		b.WriteByte('\n')
	}
	return b.Bytes()
}
