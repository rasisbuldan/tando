package unkeyed

import "tando/srv/internal/run"

func F() { run.Cmd{[]string{"systemctl"}, nil, nil, nil, 0, nil} }
