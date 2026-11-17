package rawstring

import "tando/srv/internal/run"

const sh = `
	bash`

func F() {
	run.Cmd{Argv: []string{"s" + `h`, `-c`, `
		id
		id`}}
}
