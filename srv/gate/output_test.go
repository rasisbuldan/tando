package gate

import (
	"io"
	"strings"
	"testing"

	"tando/srv/internal/out/outtest"
)

// The gate passes on rows of tando-agent, which ran as the deploy user (its output is not
// trusted): each field is cleaned through the out.Writer, control, C1 and bidi bytes included,
// and the rows keep their columns, empty ones too (srv/README.md, Output).
func TestOutputClean(t *testing.T) {
	h := outtest.Hostile
	agentOut := map[string]string{
		"deploy-status": "id=1\nphase=" + h + "\nresult=" + h + "\nmessage=" + h + "\n",
		"status":        "host\t" + h + "\napp\talpha\t" + h + "\t\t" + h + "\nrel\t" + h + "\nhist\talpha\t" + h + "\n",
		"history":       "hist\talpha\t" + h + "\t\t" + h + "\n",
		"releases":      "rel\t" + h + "\t\t" + h + "\n",
	}
	for verb, args := range map[string]string{"deploy-status": " 20261113-170102", "status": "", "history": "", "releases": ""} {
		g, f := deployGate(t, "")
		f.out = func(argv []string) ([]byte, error) { return []byte(agentOut[argv[1]]), nil }
		g.Caller.SSHCommand = g.P.Agent + " " + verb + " alpha" + args
		if err := g.Key([]string{dashC, g.P.Gate + " key 0123456789ab"}); err != nil {
			t.Fatal(err)
		}
		g.Stdout.Seek(0, 0)
		b, _ := io.ReadAll(g.Stdout)
		if err := outtest.Check(b); err != nil {
			t.Errorf("%s: %v", verb, err)
		}
		if strings.Count(string(b), "\n") != strings.Count(agentOut[verb], "\n") ||
			!strings.Contains(string(b), "evil") {
			t.Errorf("%s: rows lost or merged: %q", verb, b)
		}
		if verb != "deploy-status" && !strings.Contains(string(b), "\t\t") {
			t.Errorf("%s: an empty field is gone: %q", verb, b)
		}
	}
}

// The agent's releases verb ends with an origin row (user@machine:path of the last deployer,
// for the dashboard). A deploy key gets the release rows only: never who deployed from where.
// (An admin reads the agent directly, not through the gate: tando releases shows the row there.)
func TestKeyReleasesNoOrigin(t *testing.T) {
	agentOut := "rel\t20261113-170102\tverified\t1\t0\nrel\t20261112-090000\tverified\t0\t1\norigin\talice@laptop:/src/alpha\n"
	for _, verb := range []string{"releases", "status"} {
		g, f := deployGate(t, "")
		f.out = func(argv []string) ([]byte, error) { return []byte(agentOut), nil }
		g.Caller.SSHCommand = g.P.Agent + " " + verb + " alpha"
		if err := g.Key([]string{dashC, g.P.Gate + " key 0123456789ab"}); err != nil {
			t.Fatal(err)
		}
		g.Stdout.Seek(0, 0)
		b, _ := io.ReadAll(g.Stdout)
		if strings.Contains(string(b), "origin") || strings.Contains(string(b), "alice@laptop") {
			t.Errorf("%s: a deploy key got the origin row: %q", verb, b)
		}
		if strings.Count(string(b), "rel\t") != 2 {
			t.Errorf("%s: release rows lost: %q", verb, b)
		}
	}
}
