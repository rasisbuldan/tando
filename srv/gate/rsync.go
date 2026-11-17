package gate

import (
	"regexp"
	"strings"
)

// The rsync server arguments of an upload into <app>/incoming/. The options must be on a
// whitelist (what Apple's openrsync and GNU rsync 3.x send for tando' upload); the destination
// must be the app's own incoming/ and is replaced by our own path. Restrictions, and where each
// is enforced (docs/CI.md):
//
//   - server mode, receiving only: the first word is --server; --sender, --daemon and every other
//     long option but six are refused (here).
//   - short options: only l p t r c z v, packed (-ltprcz), plus GNU's e.<capabilities> suffix of
//     letters only; -e<anything> as an option of its own (a remote shell) is refused (here).
//     Stricter than the shell version: an "e" must be followed by "." and the capabilities (rsync
//     would take the next word as its value otherwise).
//   - long options: --delete, --delete-before, --delete-during, --delete-delay, --dirs, --stats
//     (here); nothing that names a second path (--temp-dir, --link-dest, --backup-dir,
//     --partial-dir, --log-file, --files-from, ...), keeps links (-K, -L), devices, owners or
//     groups (-D, -o, -g), hard links (-H), or changes how names are written (--iconv,
//     --munge-links).
//   - exactly one "." and then the destination, which must be <app>/incoming or
//     <app>/incoming/; the receiver is then started with our own path, not the client's (here
//     and receive.go).
//   - the receiver runs as the deploy user in a unit tando-rx-<app>@<nonce> (receive.go): read-only
//     everywhere but incoming/, no network, private /tmp and /dev, no /run/user, no capabilities,
//     NoNewPrivileges, MemoryMax 512M, TasksMax 16, LimitFSIZE = the per-file limit,
//     RuntimeMaxSec = what is left of the lease; one per app (fixed unit name).
//   - symlinks that resolve outside incoming/ are removed before and after each receive (rx mode),
//     setuid/setgid bits are stripped, incoming/ is set back to 700.
//   - a root watchdog stops the unit when incoming/ holds more bytes or entries than the app's
//     limit (receive.go); a key's upload needs its own lease, not frozen, not expired, and no
//     other receiver of the app running (rootmode.go).
//   - root never copies the upload: it scans it frozen (tree.go) and tando-agent copies it.

var (
	rsyncLongOK = map[string]bool{"--delete": true, "--delete-before": true, "--delete-during": true,
		"--delete-delay": true, "--dirs": true, "--stats": true}
	rsyncLettersRe = regexp.MustCompile(`^[lptrczv]*$`)
	rsyncCompatRe  = regexp.MustCompile(`^\.[A-Za-z]{0,16}$`)
)

// rsyncOption checks one option word (it starts with "-").
func rsyncOption(x string) error {
	switch {
	case rsyncLongOK[x]:
		return nil
	case strings.HasPrefix(x, "-e"):
		return die("rsync: option not allowed: %s", clean(x))
	case strings.HasPrefix(x, "--"):
		return die("rsync: option not allowed: %s", clean(x))
	}
	// GNU rsync packs short options and ends them with e.<capabilities> (-ltprcze.iLsfxCIvu)
	letters, compat, hasE := strings.Cut(x[1:], "e")
	if !rsyncLettersRe.MatchString(letters) || (hasE && !rsyncCompatRe.MatchString(compat)) || letters == "" && !hasE {
		return die("rsync: option not allowed: %s", clean(x))
	}
	return nil
}

// parseRsync checks the words after "rsync" and returns the options to pass on.
func parseRsync(args []string, incoming string) ([]string, error) {
	if len(args) == 0 || args[0] != "--server" {
		return nil, die("rsync: server mode only")
	}
	var opts []string
	dot, dest := false, ""
	for _, x := range args[1:] {
		switch {
		case strings.HasPrefix(x, "-"):
			if err := rsyncOption(x); err != nil {
				return nil, err
			}
			opts = append(opts, x)
		case x == ".":
			if dot || dest != "" {
				return nil, die("rsync: bad arguments")
			}
			dot = true
		default:
			if !dot || dest != "" {
				return nil, die("rsync: bad arguments")
			}
			dest = x
		}
	}
	if !dot || (dest != incoming+"/" && dest != incoming) {
		return nil, die("rsync: a deploy key uploads to %s/ only", incoming)
	}
	return opts, nil
}

// checkRsyncOpts checks options passed to rx mode by root (they were parsed by parseRsync; rx
// checks them again so the receiver never runs with anything else).
func checkRsyncOpts(opts []string) error {
	for _, x := range opts {
		if !strings.HasPrefix(x, "-") {
			return die("rsync: bad arguments")
		}
		if err := rsyncOption(x); err != nil {
			return err
		}
	}
	return nil
}
