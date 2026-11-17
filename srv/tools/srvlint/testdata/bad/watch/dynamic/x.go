package dynamic

import (
	"os"

	"tando/srv/internal/run"
)

func F() {
	prog := os.Getenv("PROG")
	run.Cmd{Argv: []string{prog, "x"}}
}
