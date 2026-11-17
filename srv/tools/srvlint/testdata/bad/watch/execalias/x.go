package execalias

import x "os/exec"

func F() { x.Command("ls").Run() }
