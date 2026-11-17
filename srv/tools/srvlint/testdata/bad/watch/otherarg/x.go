package otherarg

import (
	"os"

	"tando/srv/internal/run"
)

func F(app string) {
	run.Cmd{Argv: []string{"systemctl", "show", os.Args[1]}}
	run.Cmd{Argv: []string{"du", "-smxc", "--", os.Args[1]}}
}
