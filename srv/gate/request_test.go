package gate

import (
	"fmt"
	"strings"
	"testing"
)

const (
	tAgent = "/opt/tando/bin/tando-agent"
	tGate  = "/opt/tando/bin/tando-gate"
	tInc   = "/opt/tando/apps/alpha/incoming"
	tTok   = "0b1d9a4e-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
)

var tWant = Want{App: "alpha", Agent: tAgent, Incoming: tInc}

// Requests a deploy key may send (the client's own, and what e2e-ci.sh sends).
func TestParseRequestAccepts(t *testing.T) {
	tests := []struct {
		cmd  string
		want Request
	}{
		{"sudo -n " + tAgent + " begin alpha runner@host-1", Request{Verb: VBegin}},
		{tAgent + " begin alpha x", Request{Verb: VBegin}},
		{"sudo -n " + tAgent + " end alpha", Request{Verb: VEnd}},
		{"sudo -n " + tAgent + " end alpha " + tTok, Request{Verb: VEnd, Token: tTok, TokenSent: true}},
		{"sudo -n " + tAgent + " activate alpha 12.5 3", Request{Verb: VActivate, Build: "12.5", Upload: "3"}},
		{"sudo -n " + tAgent + " activate alpha " + tTok + " 0 0", Request{Verb: VActivate, Token: tTok, TokenSent: true, Build: "0", Upload: "0"}},
		{"sudo -n " + tAgent + " deploy-status alpha 20261113-170102", Request{Verb: VDeployStatus, ID: "20261113-170102"}},
		{tAgent + " deploy-status alpha 20261113-170102-12", Request{Verb: VDeployStatus, ID: "20261113-170102-12"}},
		{tAgent + " releases alpha", Request{Verb: VReleases}},
		{tAgent + " history alpha", Request{Verb: VHistory, HistoryN: "20"}},
		{tAgent + " history alpha 999", Request{Verb: VHistory, HistoryN: "999"}},
		{tAgent + " status alpha", Request{Verb: VStatus}},
		{tAgent + " info", Request{Verb: VInfo}},
		{"  " + tAgent + "   status   alpha  ", Request{Verb: VStatus}},
		{"rsync --server -ltprcze.iLsfxCIvu --delete . " + tInc + "/", Request{Verb: VRsync, Rsync: []string{"-ltprcze.iLsfxCIvu", "--delete"}}},
		{"rsync --server -lptrcz --delete --stats . " + tInc, Request{Verb: VRsync, Rsync: []string{"-lptrcz", "--delete", "--stats"}}},
		{"rsync --server -ltpr . " + tInc + "/ --delete-delay", Request{Verb: VRsync, Rsync: []string{"-ltpr", "--delete-delay"}}},
	}
	for _, tt := range tests {
		t.Run(tt.cmd, func(t *testing.T) {
			got, err := ParseRequest(tt.cmd, tWant)
			if err != nil {
				t.Fatalf("refused: %v", err)
			}
			if fmt.Sprint(got) != fmt.Sprint(tt.want) {
				t.Fatalf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

// Requests that must be refused, with the start of the message (the e2e suite and the security
// reviews' attacks: other apps, verbs of the admin, injection, odd bytes, rsync options).
func TestParseRequestRefuses(t *testing.T) {
	inc := tInc + "/"
	tests := []struct{ cmd, msg string }{
		{"", "a deploy key runs tando deploy commands only (no shell)"},
		{strings.Repeat("a", 301), "request too long"},
		{fmt.Sprintf("sudo -n %s status alpha %0400d", tAgent, 0), "request too long"},
		{"   ", "bad request"},
		{strings.Repeat("a ", 13), "bad request"},
		// characters
		{"sudo -n " + tAgent + " begin alpha $(id)", "unexpected characters in the request"},
		{"sudo -n " + tAgent + " begin alpha;id", "unexpected characters"},
		{"sudo -n " + tAgent + " begin alpha|id", "unexpected characters"},
		{"sudo -n " + tAgent + " begin alpha `id`", "unexpected characters"},
		{"sudo -n " + tAgent + " end alpha *", "unexpected characters"},
		{"sudo -n " + tAgent + " begin alpha x\nid", "unexpected characters"},
		{tAgent + " begin alpha x\tx", "unexpected characters"},
		{"sudo -n " + tAgent + " status \xc3\xa9", "unexpected characters"},
		{"sudo -n " + tAgent + " status alpha\x01", "unexpected characters"},
		{"sudo -n " + tAgent + " status alpha\x00", "unexpected characters"},
		{"sudo -n " + tAgent + " status 'alpha'", "unexpected characters"},
		{"sudo -n " + tAgent + " status \"alpha\"", "unexpected characters"},
		{"sudo -n " + tAgent + " status alpha?", "unexpected characters"},
		{"sudo -n " + tAgent + " status alph[a]", "unexpected characters"},
		{"sudo -n " + tAgent + " status alpha\\", "unexpected characters"},
		{"sudo -n " + tAgent + " status ~alpha", "unexpected characters"},
		{"sudo -n " + tAgent + " status alpha#", "unexpected characters"},
		{"sudo -n " + tAgent + " status alpha&", "unexpected characters"},
		{"sudo -n " + tAgent + " status alpha>x", "unexpected characters"},
		{"rsync --server -ltprz --usermap=*:root . " + inc, "unexpected characters"},
		{"rsync --server -ltprz . ~/", "unexpected characters"},
		// shells and other programs
		{"bash -c id", "not allowed with a deploy key"},
		{"sh -c id", "not allowed with a deploy key"},
		{"id", "not allowed with a deploy key"},
		{"sudo -s", "not allowed with a deploy key"},
		{"sudo -n /bin/sh", "not allowed with a deploy key"},
		{"sudo -n " + tGate + " root bravo begin", "not allowed with a deploy key"},
		{"sudo -n " + tGate + " admin install", "not allowed with a deploy key"},
		{"sudo -n -u root " + tAgent + " status alpha", "not allowed with a deploy key"},
		{"sudo -n", "not allowed with a deploy key"},
		{"/usr/bin/tando-agent status alpha", "not allowed with a deploy key"},
		{"/bin/rsync --server -ltpr . " + inc, "not allowed with a deploy key"},
		{"internal-sftp", "not allowed with a deploy key"},
		// verbs of the admin
		{"sudo -n " + tAgent + " configure alpha", "not allowed with a deploy key: configure"},
		{tAgent + " env-ls alpha", "not allowed with a deploy key: env-ls"},
		{tAgent + " env-log alpha", "not allowed with a deploy key: env-log"},
		{tAgent + " env-log alpha 1", "not allowed with a deploy key: env-log"},
		{tAgent + " rollback alpha 20260101-000000", "not allowed with a deploy key: rollback"},
		{tAgent + " destroy alpha", "not allowed with a deploy key: destroy"},
		{tAgent + " setup", "not allowed with a deploy key: setup"},
		{tAgent + " doctor 1", "not allowed with a deploy key: doctor"},
		{tAgent + " logs alpha", "not allowed with a deploy key: logs"},
		{tAgent + " unlock alpha", "not allowed with a deploy key: unlock"},
		{tAgent + " run-activation alpha 20260101-000000 0 0", "not allowed with a deploy key: run-activation"},
		{tAgent, "not allowed with a deploy key: "},
		// other apps
		{"sudo -n " + tAgent + " begin bravo x", "this key deploys alpha only"},
		{"sudo -n " + tAgent + " begin ALPHA x", "this key deploys alpha only"},
		{tAgent + " status bravo", "this key deploys alpha only"},
		{tAgent + " status", "this key deploys alpha only"},
		{tAgent + " history", "this key deploys alpha only"},
		{tAgent + " status " + strings.Repeat("a", 40), "this key deploys alpha only"},
		{tAgent + " status -alpha", "this key deploys alpha only"},
		// arguments
		{tAgent + " info x", "bad request"},
		{tAgent + " begin alpha", "bad request"},
		{tAgent + " begin alpha x y", "bad request"},
		{tAgent + " end alpha x", "bad request"},
		{tAgent + " end alpha " + tTok + " x", "bad request"},
		{tAgent + " end alpha -" + tTok[1:], "bad request"},
		{tAgent + " activate alpha " + tTok + " 1 1 --x", "bad request"},
		{tAgent + " activate alpha " + tTok + " 1e9 1", "bad request"},
		{tAgent + " activate alpha " + tTok + " -1 1", "bad request"},
		{tAgent + " activate alpha " + tTok + " 1234567 1", "bad request"},
		{tAgent + " activate alpha " + tTok + " 1.25 1", "bad request"},
		{tAgent + " activate alpha ../../../etc 1 1", "bad request"},
		{tAgent + " activate alpha 1", "bad request"},
		{tAgent + " deploy-status alpha ../../bravo", "bad request"},
		{tAgent + " deploy-status alpha 20260101-000000 extra", "bad request"},
		{tAgent + " deploy-status alpha -20260101-000000", "bad request"},
		{tAgent + " deploy-status alpha 2026010-000000", "bad request"},
		{tAgent + " history alpha 9999", "bad request"},
		{tAgent + " history alpha -1", "bad request"},
		{tAgent + " history alpha 1 2", "bad request"},
		{tAgent + " status alpha extra", "bad request"},
		{tAgent + " releases alpha x", "bad request"},
		// rsync: direction, mode, options, destination
		{"rsync", "rsync: server mode only"},
		{"rsync --daemon --server .", "rsync: server mode only"},
		{"rsync --sender --server . " + inc, "rsync: server mode only"},
		{"rsync --server", "rsync: a deploy key uploads to " + inc + " only"},
		{"rsync --server --sender -vlogDtpre.iLsfxC . /opt/tando/apps/bravo/env", "rsync: option not allowed: --sender"},
		{"rsync --server -ltpr " + inc, "rsync: bad arguments"},
		{"rsync --server -ltpr . . " + inc, "rsync: bad arguments"},
		{"rsync --server -ltpr .. " + inc, "rsync: bad arguments"},
		{"rsync --server -ltpr . " + inc + " extra", "rsync: bad arguments"},
		{"rsync --server -ltpr . /opt/tando/apps/bravo/incoming/", "rsync: a deploy key uploads to"},
		{"rsync --server -ltpr . " + inc + "../../bravo/incoming/", "rsync: a deploy key uploads to"},
		{"rsync --server -ltpr . " + inc + "sub/", "rsync: a deploy key uploads to"},
		{"rsync --server -ltpr . " + inc + "/", "rsync: a deploy key uploads to"},
		{"rsync --server -ltpr . " + inc + "//", "rsync: a deploy key uploads to"},
		{"rsync --server -ltpr . /opt/tando/apps/alpha/", "rsync: a deploy key uploads to"},
		{"rsync --server -ltpr . /tmp/", "rsync: a deploy key uploads to"},
		{"rsync --server -ltpr . .", "rsync: bad arguments"},
		{"rsync --server -ltpr -e.LsfxC . " + inc, "rsync: option not allowed: -e.LsfxC"},
		{"rsync --server -ltpre.iLsfxCIvu --config=/x . " + inc, "rsync: option not allowed: --config=/x"},
		{"rsync --server -ltprDe.iLsfxCIvu . " + inc, "rsync: option not allowed"},
		{"rsync --server -ltpre.iLs/f . " + inc, "rsync: option not allowed"},
		{"rsync --server -ltpre . " + inc, "rsync: option not allowed"},
		{"rsync --server -ltpre.abcdefghijklmnopq . " + inc, "rsync: option not allowed"},
		{"rsync --server - . " + inc, "rsync: option not allowed"},
		{"rsync --server -- . " + inc, "rsync: option not allowed"},
		{"rsync --server --log-file=/tmp/l -ltprcze.iLsfxCIvu . " + inc, "rsync: option not allowed"},
	}
	// every server option the e2e suite tries (the attacker controls the client entirely)
	for _, o := range strings.Fields(`-H -D --devices --specials -o -g -ltprHe.iLsfxCIvu -ltprDze.iLsf
		-logDtpre.iLsfxCIvu --log-file=/tmp/x --log-file-format=%f --temp-dir=/tmp --backup-dir=/tmp -b --backup
		--link-dest=/opt/tando/apps/bravo/incoming --copy-dest=/opt/tando/apps/bravo/incoming
		--compare-dest=/opt/tando/apps/bravo/env --partial-dir=/tmp/p --partial --remove-source-files
		-K --keep-dirlinks -L --copy-links --copy-unsafe-links --max-delete=0 --chmod=u+s --suffix=x
		--write-devices --inplace --append -x --fake-super --files-from=/etc/passwd --from0
		--super --omit-dir-times --no-implied-dirs --munge-links --safe-links=no --sender --daemon
		--config=/tmp/c --address=0.0.0.0 --port=873 --iconv=x --checksum-seed=1 --out-format=%f
		--timeout=0 --bwlimit=1 --mkpath --remote-option=--sender --rsh=sh -e -E -X -A -U -N -S
		-W -R -u -y -m -i -k -s -T -f -F -C -B --info=all`) {
		want := "rsync: option not allowed"
		if strings.ContainsAny(o, "%") {
			want = "unexpected characters"
		}
		tests = append(tests, struct{ cmd, msg string }{"rsync --server -ltprz " + o + " . " + inc, want})
	}
	for _, tt := range tests {
		t.Run(strings.ToValidUTF8(tt.cmd, "?"), func(t *testing.T) {
			r, err := ParseRequest(tt.cmd, tWant)
			if err == nil {
				t.Fatalf("accepted: %+v", r)
			}
			if !strings.HasPrefix(err.Error(), tt.msg) {
				t.Fatalf("refused with %q, want %q", err, tt.msg)
			}
		})
	}
}

func TestForcedKeyID(t *testing.T) {
	ok := []string{dashC, tGate + " key 0123456789ab"}
	if id, err := ForcedKeyID(ok, tGate); err != nil || id != "0123456789ab" {
		t.Fatalf("got %q %v", id, err)
	}
	for _, a := range [][]string{
		nil, {dashC}, {dashC, "id"}, {dashC, "'" + tGate + " key 0123456789ab'"}, {dashC, tGate + " key 0123456789AB"},
		{dashC, tGate + " key 0123456789ab "}, {dashC, tGate + " key 0123456789abc"}, {dashC, tGate + "  key 0123456789ab"},
		{dashC, tGate + " key 0123456789ab", "x"}, {"-l"}, {"version"}, {dashC, "/tmp/tando-gate key 0123456789ab"},
		{dashC, tGate + " key 0123456789ab\nid"},
	} {
		if _, err := ForcedKeyID(a, tGate); err == nil || err.Error() != msgNoShell {
			t.Errorf("%q: %v", a, err)
		}
	}
}

func TestClean(t *testing.T) {
	for in, want := range map[string]string{
		"plain":                     "plain",
		"a\nb\tc\x1b[31m\x7f":       "a?b?c?[31m?",
		".env\xc2\x9b2J\xc2\x9d0;x": ".env?2J?0;x",
		"\xc2":                      "\xc2",
		"é":                         "é",
		strings.Repeat("x", 200):    strings.Repeat("x", 160),
	} {
		if got := clean(in); got != want {
			t.Errorf("clean(%q) = %q, want %q", in, got, want)
		}
	}
}

// dashC is how sshd starts a login shell with a command; the tests pass it as the gate's argument.
// lint: allow RL16 the argument sshd gives the login shell, not a shell being started
const dashC = "-c"
