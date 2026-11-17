package status

import "tando/srv/internal/run"

type C struct{ R run.Runner }

func (c *C) lookTool(prog string) (string, string) { return "/usr/bin/" + prog, "" }

func (c *C) tool(name, prog string, args []string) {
	path, _ := c.lookTool(prog)
	c.R.Output(nil, run.Cmd{Argv: append([]string{path}, args...)})
}

func (c *C) output(argv ...string) { c.R.Output(nil, run.Cmd{Argv: argv}) }

func (c *C) F() {
	c.tool("python", "python3", []string{"-I", "-c", "import sys"})
	c.tool("node", "node", []string{"--version"})
	c.output("/opt/tando/bin/tando-agent", "x")
	argv := []string{"caddy", "version"}
	c.output(argv...)
}
