package gate

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/valid"
)

// Admin is admin mode: root, through the admin's sudo (tando ci, tando host setup, destroy).
func (g *Gate) Admin(args []string) error {
	verb, app := "", ""
	if len(args) > 0 {
		verb = args[0]
	}
	if len(args) > 1 {
		app = args[1]
	}
	if g.Caller.EUID != 0 {
		return die("admin mode needs root (sudo)")
	}
	// a deploy user can never get here (its sudo rule names root mode only); refuse it anyway
	if strings.HasPrefix(g.Caller.SudoUser, "tando-d-") {
		return die("not for deploy users")
	}
	w := out.New(g.Stdout)
	if verb == "install" {
		if err := g.install(""); err != nil {
			return err
		}
		w.KV("ok", "1")
		return w.Flush()
	}
	if !valid.App(app) {
		return die("bad app name")
	}
	if !fsinfo.RegularFollow(filepath.Join(g.appDir(app), "app.conf")) && verb != "remove" {
		return die("no such app: %s", app)
	}
	var err error
	// every change of a key list (an app's, and its previews' copies) under one lock: a copy read
	// before a revoke and written after it would bring a revoked key back
	switch verb {
	case "key-add", "key-revoke", "preview-keys", "remove":
		kl, lerr := g.keysLock()
		if lerr != nil {
			return lerr
		}
		if kl != nil {
			defer kl.Release()
		}
	}
	switch verb {
	case "key-add":
		mode := ""
		if len(args) > 2 {
			mode = args[2]
		}
		switch mode {
		case "", "rotate", ScopePreviews:
		default:
			return die("key-add: rotate or previews only")
		}
		scope := ""
		if mode == ScopePreviews {
			scope = ScopePreviews
		}
		err = g.keyAdd(w, app, mode == "rotate", scope)
	case "key-ls":
		err = g.keyLs(w, app)
	case "key-revoke":
		err = g.keyRevoke(w, app)
	case "preview-keys":
		// a preview app's deploy user gets the keys of the app it belongs to (tando preview up, as admin)
		if parent := g.previewOf(app); parent == "" {
			err = die("%s is not a preview app", app)
		} else {
			err = g.mirrorKeys(parent, app)
		}
	case "receive":
		return g.adminReceive(app, args[2:])
	case "remove":
		// the keys of the app go: its previews' copies too (tando-agent destroys the previews of
		// an app first; one left behind, or made since, keeps no key of an app that is gone)
		var ids []string
		if data, rerr := os.ReadFile(filepath.Join(g.home(app), "keys")); rerr == nil {
			ids = keyIDs(data)
		}
		if err = g.removeUser(app); err == nil {
			if g.previewOf(app) == "" {
				err = g.syncPreviews(app, ids)
			}
			w.KV("removed", "tando-d-"+app)
		}
	default:
		return die("unknown admin verb")
	}
	if ferr := w.Flush(); err == nil {
		err = ferr
	}
	return err
}

// install: the host-wide pieces (the user sshd reads key files as, and the sshd drop-in), then
// every existing deploy user gets the current layout. skip: an app whose user the caller is
// about to set up itself.
func (g *Gate) install(skip string) error {
	fi, err := os.Stat(g.P.Gate)
	if err != nil || fi.Mode()&0o7777 != 0o755 || fi.Mode().Type() != 0 || ownerUID(fi) != 0 {
		return die("%s must be root-owned, mode 755", g.P.Gate)
	}
	if err := mkdirExact(g.P.CI, 0o755, g.Owner, g.Group); err != nil {
		return err
	}
	if _, ok := g.userByName(keysUser); !ok {
		if _, err := g.quiet(60*time.Second, "useradd", "--system", "--user-group", "--no-create-home",
			"--home-dir", "/nonexistent", "--shell", "/usr/sbin/nologin", "--comment",
			"tando sshd reads CI keys as this user", "--", keysUser); err != nil {
			return die("useradd %s failed", keysUser)
		}
	}
	if err := g.installSSHD(); err != nil {
		return err
	}
	// existing deploy users get the current layout too; one that fails is reported and the
	// others still are
	ents, _ := os.ReadDir(g.P.CI)
	for _, e := range ents {
		a := e.Name()
		if a == skip || !fsinfo.RegularFollow(filepath.Join(g.P.CI, a, "keys")) || !valid.App(a) ||
			!fsinfo.RegularFollow(filepath.Join(g.appDir(a), "app.conf")) {
			continue
		}
		err := g.ensureUser(a)
		if err == nil {
			err = g.writeKeys(a)
		}
		if err != nil {
			fmt.Fprintf(g.Stderr, "tando-gate: %v\n", err)
		}
	}
	return nil
}

// hostKeys: known_hosts material, the server's host public keys.
func (g *Gate) hostKeys(w *out.Writer) {
	for _, f := range g.P.HostKeys {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		l, _, _ := strings.Cut(string(data), "\n")
		p := strings.Split(l, " ")
		if len(p) > 2 {
			p = p[:2]
		}
		w.KV("hostkey", strings.Join(p, " "))
	}
}

// keyAdd registers a public key (stdin: one ssh-ed25519 line); rotate: and revokes all others.
// scope: "" (the key deploys the app) or ScopePreviews (only the app's previews).
func (g *Gate) keyAdd(w *out.Writer, app string, rotate bool, scope string) error {
	line, ok := readPiece(bufio.NewReader(g.Stdin), 600)
	if !ok && line == "" {
		return die("no public key on stdin")
	}
	pub, fp, err := ParsePublicKey(line)
	if err != nil {
		return err
	}
	if err := g.install(app); err != nil {
		return err
	}
	if err := g.ensureUser(app); err != nil {
		return err
	}
	h := g.home(app)
	kf := filepath.Join(h, "keys")
	old, err := os.ReadFile(kf)
	if err != nil {
		return err
	}
	if hasFingerprint(old, fp) {
		return die("this key is already registered")
	}
	var revoked []string
	var b bytes.Buffer
	if rotate {
		revoked = keyIDs(old)
	} else {
		b.Write(old)
	}
	idb := make([]byte, 6)
	if _, err := rand.Read(idb); err != nil {
		return err
	}
	id := hex.EncodeToString(idb)
	who := g.Caller.SudoUser
	if who == "" {
		who = "root"
	}
	b.WriteString(keyLineScope(id, fp, g.now(), pub, who, scope))
	if err := atomicfile.Write(kf, b.Bytes(), atomicfile.Mode(0o600)); err != nil {
		return err
	}
	if err := g.writeKeys(app); err != nil {
		return err
	}
	if len(revoked) > 0 { // rotated keys stop now
		g.endLeaseOf(app, revoked)
		g.evictUser(app)
	}
	serr := g.syncPreviews(app, revoked)
	w.KV("keyid", id)
	w.KV("fingerprint", fp)
	w.KV("user", "tando-d-"+app)
	w.KV("revoked", strconv.Itoa(len(revoked)))
	if scope != "" {
		w.KV("scope", scope)
	}
	g.hostKeys(w)
	return serr
}

// keyLs lists the keys: id, fingerprint, created, last deploy (or -), who added it.
func (g *Gate) keyLs(w *out.Writer, app string) error {
	h := g.home(app)
	data, err := os.ReadFile(filepath.Join(h, "keys"))
	if err != nil {
		return nil
	}
	for _, l := range bashread.Lines(data) {
		f := bashread.Fields(l, 6)
		if !validKeyID(f[0]) {
			continue
		}
		used := kv(filepath.Join(h, "state", "used-"+f[0]), "used")
		if keyScope(data, f[0]) != "" {
			w.Row("key", f[0], f[1], f[2], used, f[4], ScopePreviews)
		} else {
			w.Row("key", f[0], f[1], f[2], used, f[4])
		}
	}
	return nil
}

// keyRevoke removes keys (stdin: a key id, a SHA256: fingerprint or "all"), ends the revoked
// keys' lease and everything of the deploy user (other keys' uploads restart).
func (g *Gate) keyRevoke(w *out.Writer, app string) error {
	sel, ok := readPiece(bufio.NewReader(g.Stdin), 100)
	if !ok && sel == "" {
		return die("nothing to revoke")
	}
	kf := filepath.Join(g.home(app), "keys")
	data, err := os.ReadFile(kf)
	if err != nil {
		return die("%s has no deploy keys", app)
	}
	var ids []string
	var n int
	var kept []byte
	if sel == "all" {
		n, ids = countNonEmpty(data), keyIDs(data)
	} else {
		if !revokeSelRe.MatchString(sel) {
			return die("give a key id, a SHA256: fingerprint or all")
		}
		kept, ids, n = revokeSel(data, sel)
		if n == 0 {
			return die("no such key: %s (tando ci ls)", sel)
		}
	}
	if err := atomicfile.Write(kf, kept, atomicfile.Mode(0o600)); err != nil {
		return err
	}
	if err := g.writeKeys(app); err != nil {
		return err
	}
	if len(ids) > 0 {
		g.endLeaseOf(app, ids)
	}
	g.evictUser(app)
	serr := g.syncPreviews(app, ids)
	w.KV("revoked", strconv.Itoa(n))
	return serr
}

// endLeaseOf: the lease of a revoked key ends with it (tando-agent end, with the token root
// reads).
func (g *Gate) endLeaseOf(app string, ids []string) {
	l := g.lease(app)
	if l.Token == "" || !strings.HasPrefix(l.Who, "ci-") {
		return
	}
	for _, id := range ids {
		if l.Who == "ci-"+id {
			g.agent(false, 5*60, "end", app, l.Token)
		}
	}
}

// adminReceive is the admin's upload (lib/deploy.sh: --rsync-path="sudo -n <gate> admin receive
// <app> rsync"): the same confined receiver, during the admin's own lease.
func (g *Gate) adminReceive(app string, args []string) error {
	if len(args) == 0 || args[0] != "rsync" {
		return die("receive: rsync only")
	}
	opts, err := parseRsync(args[1:], g.incoming(app))
	if err != nil {
		return err
	}
	held, err := g.leaseLock(app)
	if err != nil {
		return err
	}
	defer held.Release()
	l := g.lease(app)
	if l.Token == "" || strings.HasPrefix(l.Who, "ci-") || l.ID != "" {
		return die("rsync: no upload lease of the admin (tando deploy takes one)")
	}
	if l.Remain <= 0 {
		return die("rsync: the upload lease expired")
	}
	if err := g.rxFree(app); err != nil {
		return err
	}
	pw, ok := g.userByName("tando-d-" + app)
	owner, err := ownerOf(g.incoming(app))
	if !ok || err != nil || int(owner) != pw.UID {
		return die("incoming/ of %s does not belong to tando-d-%s", app, app)
	}
	return g.receiveConfined(app, l.Remain, opts, held)
}
