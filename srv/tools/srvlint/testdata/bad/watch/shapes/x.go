package shapes

import (
	"os"

	"tando/srv/internal/run"
)

func F() {
	run.Cmd{Argv: []string{"/usr/bin/rsync", "--server", "-e", "sh", ".", "/x/"}}
	run.Cmd{Argv: []string{"/usr/bin/rsync", "--rsh=ssh", "."}}
	run.Cmd{Argv: []string{"/usr/bin/rsync", "--rsync-path=x"}}
	run.Cmd{Argv: []string{"sendmail", "-C/tmp/x", "-t", "-oi"}}
	run.Cmd{Argv: []string{"sendmail", "-t", "-oi", "-X", "/tmp/log"}}
	run.Cmd{Argv: []string{"du", "-smxc", "--files0-from=/x"}}
	run.Cmd{Argv: []string{"du", "-s", os.Args[1]}}
	run.Cmd{Argv: []string{"nft", "-f", os.Args[1]}}
	run.Cmd{Argv: []string{"nft", "-i"}}
	run.Cmd{Argv: []string{"crontab", "-e"}}
	run.Cmd{Argv: []string{"crontab", "-l", "-u", "x"}}
	run.Cmd{Argv: []string{"caddy", "run"}}
	run.Cmd{Argv: []string{"caddy", "adapt", "--config", "/etc/caddy/Caddyfile"}}
	run.Cmd{Argv: []string{"python3", "-c", "import venv"}}
	run.Cmd{Argv: []string{"python3", "-I", "-c", os.Args[1]}}
	run.Cmd{Argv: []string{"node", "-e", "1"}}
	run.Cmd{Argv: []string{"visudo", "-c", "-q", "-f"}}
	run.Cmd{Argv: []string{"journalctl", "-q", "-o", "json"}}
}
