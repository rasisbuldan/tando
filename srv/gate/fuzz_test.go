package gate

import (
	"regexp"
	"strings"
	"syscall"
	"testing"

	"tando/srv/internal/bashread"
)

// argv shapes key mode may run, whatever the request: sudo of the exact root-mode argvs, or a
// read-only agent verb with checked words. (GATE and AGENT are the test's paths.)
var keyArgvRe = regexp.MustCompile(`^(sudo -n -- GATE root alpha (begin|end|activate|receive)|` +
	`AGENT (deploy-status alpha [0-9]{8}-[0-9]{6}(-[0-9]{1,3})?|releases alpha|history alpha [0-9]{1,3}|status alpha)|` +
	`uname -m|logger -p auth\.notice -t tando-gate -- .*)$`)

var paramsRe = regexp.MustCompile(`^token=[0-9a-f-]{36}\n(build=[0-9.]{1,8}\nupload=[0-9.]{1,8}\n)?$`)

func requestSeeds(f *testing.F) {
	for _, s := range []string{
		"sudo -n " + tAgent + " begin alpha runner@host",
		"sudo -n " + tAgent + " end alpha " + tTok,
		"sudo -n " + tAgent + " activate alpha 1.5 2",
		tAgent + " deploy-status alpha 20261113-170102-1",
		tAgent + " history alpha 9",
		tAgent + " info",
		"rsync --server -ltprcze.iLsfxCIvu --delete . " + tInc + "/",
		"rsync --server --sender -vlogDtpre.iLsfxC . /opt/tando/apps/bravo/env",
		"sudo -n " + tAgent + " begin alpha $(id)",
		"sudo -s", "", "\x00", "rsync --server -e.L . .", "a b c d e f g h i j k l m",
	} {
		f.Add(s)
	}
}

// FuzzParseRequest: no input panics, and an accepted request only carries checked values.
func FuzzParseRequest(f *testing.F) {
	requestSeeds(f)
	f.Fuzz(func(t *testing.T, cmd string) {
		r, err := ParseRequest(cmd, tWant)
		if err != nil {
			if strings.ContainsAny(err.Error(), "\n\x00") {
				t.Fatalf("message with a control character: %q", err)
			}
			return
		}
		if len(cmd) > maxRequest || !requestCharsRe.MatchString(cmd) {
			t.Fatalf("accepted %q", cmd)
		}
		for _, o := range r.Rsync {
			if rsyncOption(o) != nil || !strings.HasPrefix(o, "-") {
				t.Fatalf("option %q", o)
			}
		}
		if (r.Token != "" && !validToken(r.Token)) || (r.Verb == VActivate && (!validSecs(r.Build) || !validSecs(r.Upload))) ||
			(r.Verb == VDeployStatus && !releaseIDRe.MatchString(r.ID)) || (r.Verb == VHistory && !historyNRe.MatchString(r.HistoryN)) {
			t.Fatalf("unchecked value in %+v", r)
		}
	})
}

// FuzzKeyMode: whatever the request, key mode runs only the fixed argv shapes, and root mode's
// parameters are only checked values.
func FuzzKeyMode(f *testing.F) {
	requestSeeds(f)
	f.Fuzz(func(t *testing.T, cmd string) {
		g, fr := deployGate(t, "")
		rp := strings.NewReplacer(tAgent, g.P.Agent, tInc, g.incoming("alpha"))
		g.Caller.SSHCommand = rp.Replace(cmd)
		g.Key([]string{dashC, g.P.Gate + " key 0123456789ab"})
		back := strings.NewReplacer(g.P.Gate, "GATE", g.P.Agent, "AGENT")
		for i, a := range fr.calls {
			s := back.Replace(strings.Join(a, " "))
			if !keyArgvRe.MatchString(s) {
				t.Fatalf("ran %q", s)
			}
			if in := fr.stdin[i]; in != "" && !paramsRe.MatchString(in) {
				t.Fatalf("stdin %q", in)
			}
		}
	})
}

func FuzzReadParams(f *testing.F) {
	f.Add("token=" + tTok + "\nbuild=1.5\nupload=2\n")
	f.Add("keyid=x\n")
	f.Add(strings.Repeat("=\n", 9))
	f.Fuzz(func(t *testing.T, in string) {
		p, err := ReadParams(strings.NewReader(in))
		if err != nil {
			return
		}
		if (p.Token != "" && !validToken(p.Token)) || (p.Build != "" && !validSecs(p.Build)) || (p.Upload != "" && !validSecs(p.Upload)) {
			t.Fatalf("%+v", p)
		}
	})
}

func FuzzParsePublicKey(f *testing.F) {
	f.Add(tPub + " tando-ci-alpha")
	f.Add("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
	f.Add("ssh-rsa AAAA")
	f.Fuzz(func(t *testing.T, line string) {
		pub, fp, err := ParsePublicKey(line)
		if err != nil {
			return
		}
		if !pubRe.MatchString(pub) || !fpRe.MatchString(fp) || !strings.HasPrefix(line, pub) {
			t.Fatalf("%q -> %q %q", line, pub, fp)
		}
	})
}

var akLineRe = regexp.MustCompile(`^restrict,command="/opt/tando/bin/tando-gate key [0-9a-f]{12}" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43} tando-ci-alpha-[0-9a-f]{12}$`)

// FuzzKeyList: whatever the key list holds, authorized_keys gets only well-formed key lines
// (no option, no second key, no newline can be injected), and the list helpers do not panic.
func FuzzKeyList(f *testing.F) {
	f.Add(keyLine("0123456789ab", tFP, 1, tPub, "admin") + "x\t\t\ty\n")
	f.Add("0123456789ab\tfp\t1\t" + tPub + " x,command=\"id\"\tw\n")
	f.Add("\t\t\t\t\n\n")
	f.Fuzz(func(t *testing.T, keys string) {
		ak := AuthorizedKeys([]byte(keys), tGate, "alpha")
		for _, l := range bashread.LinesAll(ak) {
			if !akLineRe.MatchString(l) {
				t.Fatalf("authorized_keys line %q", l)
			}
		}
		if len(ak) > 0 && ak[len(ak)-1] != '\n' {
			t.Fatal("no final newline")
		}
		keyIDs([]byte(keys))
		revokeSel([]byte(keys), "0123456789ab")
		countNonEmpty([]byte(keys))
		for _, l := range bashread.LinesAll([]byte(keys)) {
			if f := bashread.Fields(l, 5); len(f) != 5 {
				t.Fatal("tabRead")
			}
		}
	})
}

func FuzzParsePasswd(f *testing.F) {
	f.Add("root:x:0:0:root:/root:/bin/bash\ntando-d-alpha:x:990:990::/opt/tando/ci/alpha:/opt/tando/bin/tando-gate\n")
	f.Add("a:x:-1:+2:::\n::::::\n")
	f.Fuzz(func(t *testing.T, data string) {
		for _, p := range ParsePasswd([]byte(data)) {
			if p.UID < 0 || p.GID < 0 || strings.ContainsAny(p.Name+p.Home+p.Shell, ":\n") {
				t.Fatalf("%+v", p)
			}
		}
	})
}

// FuzzResolve: link resolution always ends (loops, long chains) and a link it calls inside never
// resolves through ".." above the top.
func FuzzResolve(f *testing.F) {
	f.Add("a>b\nb>a", "a")
	f.Add("d/\nd/l>../../x", "d/l")
	f.Add("x>"+top+"/y\ny", "x")
	f.Fuzz(func(t *testing.T, spec, rel string) {
		tr := newTree(top)
		tr.add(&node{rel: "", mode: syscall.S_IFDIR})
		for _, l := range strings.Split(spec, "\n") {
			name, target, isLink := strings.Cut(l, ">")
			if name == "" || strings.HasPrefix(name, "/") || strings.Contains(name, "//") {
				continue
			}
			switch {
			case isLink:
				tr.add(&node{rel: name, mode: syscall.S_IFLNK, target: target})
			case strings.HasSuffix(name, "/"):
				tr.add(&node{rel: strings.TrimSuffix(name, "/"), mode: syscall.S_IFDIR})
			default:
				tr.add(&node{rel: name, mode: syscall.S_IFREG})
			}
		}
		if n := tr.nodes[rel]; n != nil && n.isLink() {
			tr.resolvesInside(rel)
		}
		tr.escapingLinks()
	})
}
