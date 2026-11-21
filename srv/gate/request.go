package gate

import (
	"regexp"
	"strings"
)

// The request a deploy key sends (SSH_ORIGINAL_COMMAND). The grammar, every word fixed or
// matched by a pattern:
//
//	rsync --server <option>... . <app's incoming>[/]        (rsync.go; options may follow the destination)
//	[sudo -n] <agent> info
//	[sudo -n] <agent> begin <app> <who>                     who: any word, ignored (the lease is this key's)
//	[sudo -n] <agent> end <app> [<token>]                   no token: it comes on stdin
//	[sudo -n] <agent> activate <app> [<token>] <secs> <secs>
//	[sudo -n] <agent> deploy-status <app> <release id>
//	[sudo -n] <agent> releases <app>
//	[sudo -n] <agent> history <app> [<1-3 digits>]
//	[sudo -n] <agent> status <app>
//
// <agent> is the full path /opt/tando/bin/tando-agent and <app> must be the caller's own app
// (from its uid). The whole request is at most 300 bytes of [A-Za-z0-9_.:=/@,+ -] (no control
// character, no byte above 0x7e, no quote, glob, $, ;, |, `, backslash or tab), at most 12 words.
// Checked in this order, with the shell version's messages.

const (
	maxRequest = 300
	maxWords   = 12
)

// Verb is what a request asks for.
type Verb int

// The verbs of a deploy key.
const (
	VInfo Verb = iota + 1
	VRsync
	VBegin
	VEnd
	VActivate
	VDeployStatus
	VReleases
	VHistory
	VStatus
)

// Request is a checked request. Only the fields of its verb are set.
type Request struct {
	Verb      Verb
	Rsync     []string // VRsync: the server options, each on the whitelist
	Token     string   // VEnd, VActivate: "" = read it from stdin
	Build     string   // VActivate: seconds, checked
	Upload    string
	ID        string // VDeployStatus: a release id
	Wait      string // VDeployStatus: "wait=<phase>" or "" (the agent answers once past that phase)
	HistoryN  string // VHistory: 1-3 digits ("20" when not given)
	TokenSent bool   // the token was a word of the request (not on stdin)
}

var (
	requestCharsRe = regexp.MustCompile(`^[A-Za-z0-9_.:=/@,+ -]+$`)
	releaseIDRe    = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}(-[0-9]{1,3})?$`)
	waitRe         = regexp.MustCompile(`^wait=[a-z]{1,16}$`)
	historyNRe     = regexp.MustCompile(`^[0-9]{1,3}$`)
)

// Words checks a request's characters and length and splits it into words (parse_request).
func Words(cmd string) ([]string, error) {
	if cmd == "" {
		return nil, die(msgNoShell)
	}
	if len(cmd) > maxRequest {
		return nil, die("request too long")
	}
	if !requestCharsRe.MatchString(cmd) {
		return nil, die("unexpected characters in the request")
	}
	w := strings.Fields(cmd) // only spaces can separate words here
	if len(w) < 1 || len(w) > maxWords {
		return nil, die("bad request")
	}
	return w, nil
}

const refusedMsg = "not allowed with a deploy key: %s (a deploy key uploads, activates and reads the status of its own app; everything else is the admin's)"

// helperVerb names "<verb>" in a request that mentions "/tando-<program> <verb>" and is not one of
// the verbs a key may use ("" when there is none): the words that the character and length
// rules would otherwise turn into "unexpected characters" or "bad request".
func helperVerb(cmd string) string {
	m := helperVerbRe.FindStringSubmatch(cmd)
	if m == nil {
		return ""
	}
	switch m[1] {
	case "info", "begin", "end", "activate", "deploy-status", "releases", "history", "status":
		return ""
	}
	return m[1]
}

var helperVerbRe = regexp.MustCompile(`/tando-[a-z]+ +([a-z][a-z0-9-]*)`)

// Want is what a request is compared with: the caller's app and the fixed paths.
type Want struct {
	App      string // from the caller's uid
	Agent    string // /opt/tando/bin/tando-agent
	Incoming string // /opt/tando/apps/<app>/incoming
}

// ParseRequest parses a deploy key's request into a Request, or refuses it.
func ParseRequest(cmd string, want Want) (Request, error) {
	w, err := Words(cmd)
	if err != nil {
		// a command of the admin's that is also malformed for a key (tando health wraps its call in
		// a shell test, tando doctor sends five checksums): say what is refused, like any other verb
		if v := helperVerb(cmd); v != "" {
			return Request{}, die(refusedMsg, clean(v))
		}
		return Request{}, err
	}
	if w[0] == "rsync" {
		opts, err := parseRsync(w[1:], want.Incoming)
		if err != nil {
			return Request{}, err
		}
		return Request{Verb: VRsync, Rsync: opts}, nil
	}
	// the client calls "[sudo -n] /opt/tando/bin/tando-agent <verb> <app> [args]"
	if len(w) >= 2 && w[0] == "sudo" && w[1] == "-n" {
		w = w[2:]
	}
	if len(w) == 0 || w[0] != want.Agent {
		return Request{}, die("not allowed with a deploy key")
	}
	verb := ""
	if len(w) > 1 {
		verb = w[1]
	}
	if verb == "info" {
		if len(w) != 2 {
			return Request{}, die("bad request")
		}
		return Request{Verb: VInfo}, nil
	}
	var v Verb
	switch verb {
	case "begin":
		v = VBegin
	case "end":
		v = VEnd
	case "activate":
		v = VActivate
	case "deploy-status":
		v = VDeployStatus
	case "releases":
		v = VReleases
	case "history":
		v = VHistory
	case "status":
		v = VStatus
	default:
		return Request{}, die(refusedMsg, clean(verb))
	}
	if len(w) < 3 || w[2] != want.App {
		return Request{}, die("this key deploys %s only", want.App)
	}
	args := w[3:]
	bad := die("bad request")
	r := Request{Verb: v}
	switch v {
	case VBegin: // who is ignored: the lease is held by this key
		if len(args) != 1 {
			return Request{}, bad
		}
	case VEnd: // the token as argument, or (current clients) on stdin so it stays out of process lists
		switch len(args) {
		case 0:
		case 1:
			if !validToken(args[0]) {
				return Request{}, bad
			}
			r.Token, r.TokenSent = args[0], true
		default:
			return Request{}, bad
		}
	case VActivate:
		switch len(args) {
		case 2:
			r.Build, r.Upload = args[0], args[1]
		case 3:
			if !validToken(args[0]) {
				return Request{}, bad
			}
			r.Token, r.TokenSent, r.Build, r.Upload = args[0], true, args[1], args[2]
		default:
			return Request{}, bad
		}
		if !validSecs(r.Build) || !validSecs(r.Upload) {
			return Request{}, bad
		}
	case VDeployStatus:
		if len(args) < 1 || len(args) > 2 || !releaseIDRe.MatchString(args[0]) {
			return Request{}, bad
		}
		r.ID = args[0]
		if len(args) == 2 {
			if !waitRe.MatchString(args[1]) {
				return Request{}, bad
			}
			r.Wait = args[1]
		}
	case VReleases, VStatus:
		if len(args) != 0 {
			return Request{}, bad
		}
	case VHistory:
		r.HistoryN = "20"
		switch len(args) {
		case 0:
		case 1:
			if !historyNRe.MatchString(args[0]) {
				return Request{}, bad
			}
			r.HistoryN = args[0]
		default:
			return Request{}, bad
		}
	}
	return r, nil
}

// ForcedKeyID parses the login shell's arguments: sshd runs "<shell> -c <forced command>", and
// the forced command is exactly "<gate> key <12 hex>". Anything else (a shell, a command without
// the key's forced command, su -c) is refused.
func ForcedKeyID(args []string, gate string) (string, error) {
	// lint: allow RL16 sshd starts the login shell with "-c <command>"; this is how it is recognised, not a shell
	if len(args) != 2 || args[0] != "-c" {
		return "", die(msgNoShell)
	}
	id, ok := strings.CutPrefix(args[1], gate+" key ")
	if !ok || !validKeyID(id) {
		return "", die(msgNoShell)
	}
	return id, nil
}
