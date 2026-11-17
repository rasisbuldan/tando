package wrapperfunc

import "tando/srv/internal/run"

func quiet(argv ...string) run.Cmd { return run.Cmd{Argv: argv} }

func F() {
	quiet("systemctl", "x")
	quiet("ba"+"sh", "-c", "x")
	quiet()
}
