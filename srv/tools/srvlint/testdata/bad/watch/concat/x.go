package concat

import "tando/srv/internal/run"

func F() {
	run.Cmd{Argv: []string{"ba" + "sh", "-c", "id"}}
	run.Cmd{Argv: []string{"/bin/" + "sh"}}
}
