package assign

import "tando/srv/internal/run"

func F(c run.Cmd, p string) {
	c.Argv = []string{p, "x"}
}
