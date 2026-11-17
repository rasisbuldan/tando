package elemwrite

import (
	"os"

	"tando/srv/internal/run"
)

func F(r run.Runner) {
	a := []string{"systemctl"}
	a[0] = os.Getenv("Y")
	f := r.Output
	f(nil, run.Cmd{Argv: a})
}
