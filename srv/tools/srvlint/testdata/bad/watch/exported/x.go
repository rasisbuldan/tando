package exported

import "tando/srv/internal/run"

// Start runs prog: callers in other packages are not followed
func Start(prog string) run.Cmd { return run.Cmd{Argv: []string{prog}} }
