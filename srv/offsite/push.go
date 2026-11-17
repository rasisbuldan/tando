package offsite

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/kvfile"
	"tando/srv/internal/lock"
	"tando/srv/internal/out"
)

// Object names (all under <prefix>/<host id>/, which only this server writes or deletes):
//
//	<app>/<backup id>.rbk        the backup (bundle: meta, data.tar.gz, db.dump, config/app.conf,
//	                             config/env), encrypted
//	<app>/<backup id>.manifest   key=value, not encrypted (manifest below)
//	<app>/app.rbk                the app's app.conf and env, refreshed daily and at each upload
//	inventory.rbk                host.conf and the list of apps, refreshed daily
//	host.manifest                hostname, tando version, apps, key id: what `hosts` lists
//
// The encryption context of an object (in its authenticated header) is its name without the
// prefix: "<host id>/<app>/<backup id>.rbk".

func (s *session) hostPrefix() string { return s.conf.hostPrefix(s.hostID) }

func objName(host, app, file string) string {
	if app == "" {
		return host + "/" + file
	}
	return host + "/" + app + "/" + file
}

func (s *session) key(host, app, file string) string {
	return s.conf.rootPrefix() + objName(host, app, file)
}

// hashWriter counts and hashes what passes
type hashWriter struct {
	w io.Writer
	h hash.Hash
	n int64
}

func (h *hashWriter) Write(p []byte) (int, error) {
	n, err := h.w.Write(p)
	h.h.Write(p[:n])
	h.n += int64(n)
	return n, err
}

// sealed: what an upload of a bundle produced
type sealed struct {
	plainSize, objSize int64
	plainSHA, objSHA   string
}

// putBundle encrypts (when on) and uploads the entries as one object; the bundle is produced in a
// goroutine into a pipe, the upload reads it part by part.
func (o Offsite) putBundle(ctx context.Context, s *session, key, context string, es []entry, hk uploadHooks) (sealed, error) {
	ps := bundleSize(es)
	size := ps
	var k Key
	if s.conf.Encrypt {
		k, _ = currentKey(s.keys)
		size = cipherSize(ps, defaultShift, len(context))
	}
	pr, pw := io.Pipe()
	objH := &hashWriter{w: pw, h: sha256.New()}
	plainH := &hashWriter{h: sha256.New()}
	done := make(chan error, 1)
	go func() {
		var err error
		if s.conf.Encrypt {
			var sl *sealer
			sl, err = newSealer(objH, k, context, defaultShift, o.Rand)
			if err == nil {
				plainH.w = sl
				err = writeBundle(plainH, es)
				if err == nil {
					err = sl.Close()
				}
			}
		} else {
			plainH.w = objH
			err = writeBundle(plainH, es)
		}
		pw.CloseWithError(err)
		done <- err
	}()
	if hk.partSize == 0 {
		hk.partSize = o.PartSize
	}
	err := s.cli.upload(ctx, key, pr, size, hk)
	pr.CloseWithError(errors.New("upload ended"))
	perr := <-done
	if err == nil && perr != nil {
		err = perr
	}
	if err == nil && (objH.n != size || plainH.n != ps) {
		err = fmt.Errorf("internal: %d bytes made, %d expected", objH.n, size)
	}
	if err != nil {
		return sealed{}, err
	}
	return sealed{plainSize: ps, objSize: size, plainSHA: hex.EncodeToString(plainH.h.Sum(nil)),
		objSHA: hex.EncodeToString(objH.h.Sum(nil))}, nil
}

// appEntries: the app's app.conf and env (root's files; missing for a destroyed app)
func (o Offsite) appEntries(app string, files *[]*os.File) []entry {
	var es []entry
	for _, x := range []struct{ name, file string }{{"config/app.conf", "app.conf"}, {"config/env", "env"}} {
		f, fi, err := openOwned(filepath.Join(o.Env.Root, "apps", app, x.file), o.Owner)
		if err != nil {
			continue
		}
		*files = append(*files, f)
		es = append(es, entry{name: x.name, f: f, size: fi.Size()})
	}
	return es
}

func closeAll(fs []*os.File) {
	for _, f := range fs {
		f.Close()
	}
}

// Push uploads one backup (the verb `push <app> <backup id>`; the agent starts it in a unit of
// its own right after the backup was made). A backup already uploaded is not sent again.
func (o Offsite) Push(ctx context.Context, w *out.Writer, app, id string) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	if err := checkApp(app); err != nil {
		return err
	}
	if !ValidBackupID(id) {
		return errors.New("bad backup id")
	}
	s, err := o.open()
	if err == errOff {
		w.KV("skipped", "offsite off")
		return nil
	}
	if err != nil {
		return err
	}
	o.ensureDirs()
	l, err := lock.Acquire(filepath.Join(o.Dir, "locks", app+".lock"), 30*time.Minute)
	if err != nil {
		return fmt.Errorf("another upload of %s holds its lock: %w", app, err)
	}
	defer l.Release()
	err = o.pushLocked(ctx, s, app, id)
	o.refreshBrief(app, &s.conf)
	if err != nil {
		return err
	}
	w.KV("uploaded", id)
	return nil
}

func (o Offsite) pushLocked(ctx context.Context, s *session, app, id string) error {
	dir := o.backupDir(app, id)
	if _, fi, err := statNoFollow(dir); err != nil || !fi.IsDir() {
		return fmt.Errorf("no such backup: %s", id)
	}
	st := o.loadBackupState(app, id)
	if st["state"] == "uploaded" {
		return nil
	}
	// an upload that was killed: its parts go before a new one starts
	if up := st["upload_id"]; up != "" && validUploadID(up) {
		actx, cancel := context.WithTimeout(ctx, 2*time.Minute)
		s.cli.abortMultipart(actx, s.key(s.hostID, app, id+".rbk"), up)
		cancel()
		delete(st, "upload_id")
	}
	tries := num(st["tries"]) + 1
	st["state"], st["tries"], st["started"] = "uploading", strconv.FormatInt(tries, 10), strconv.FormatInt(o.now(), 10)
	if err := o.saveBackupState(app, id, st); err != nil {
		return err
	}
	res, holds, err := o.uploadBackup(ctx, s, app, id, func(up string) error {
		st["upload_id"] = up
		return o.saveBackupState(app, id, st)
	})
	delete(st, "upload_id")
	if err != nil {
		st["state"], st["error"] = "failed", err.Error()
		st["next_try"] = strconv.FormatInt(o.now()+int64(retryDelay(tries)/time.Second), 10)
		o.saveBackupState(app, id, st)
		if ce := credsErrOnly(err); ce != nil {
			o.credsResult(ce)
		}
		return err
	}
	st = map[string]string{"state": "uploaded", "uploaded": strconv.FormatInt(o.now(), 10), "tries": strconv.FormatInt(tries, 10),
		"object": s.key(s.hostID, app, id+".rbk"), "size": strconv.FormatInt(res.objSize, 10), "sha256": res.objSHA, "holds": holds}
	o.credsResult(nil)
	return o.saveBackupState(app, id, st)
}

// retryDelay: 5 min, 10, 20, 40 ... up to 6 h between attempts of one backup
func retryDelay(tries int64) time.Duration {
	d := 5 * time.Minute << min(tries-1, 7)
	return min(d, 6*time.Hour)
}

// credsErrOnly: an error that says the credentials (or the bucket) no longer work; others
// (a timeout, a 5xx) are not the credentials' fault
func credsErrOnly(err error) error {
	var se *S3Error
	if errors.As(err, &se) {
		switch se.Code {
		case "InvalidAccessKeyId", "SignatureDoesNotMatch", "AccessDenied", "Forbidden", "NoSuchBucket", "RequestTimeTooSkewed":
			return err
		}
	}
	return nil
}

func statNoFollow(p string) (string, os.FileInfo, error) {
	fi, err := os.Lstat(p)
	return p, fi, err
}

// uploadBackup sends the backup directory as one object, then its manifest
func (o Offsite) uploadBackup(ctx context.Context, s *session, app, id string, started func(string) error) (sealed, string, error) {
	dir := o.backupDir(app, id)
	var files []*os.File
	defer func() { closeAll(files) }()
	var es []entry
	var holds []string
	for _, name := range []string{"meta", "data.tar.gz", "db.dump"} {
		f, fi, err := openOwned(filepath.Join(dir, name), o.Owner)
		if err != nil {
			if isNotExist(err) && name != "meta" {
				continue
			}
			return sealed{}, "", fmt.Errorf("backup %s: %w", id, err)
		}
		files = append(files, f)
		es = append(es, entry{name: name, f: f, size: fi.Size()})
		switch name {
		case "data.tar.gz":
			holds = append(holds, "data")
		case "db.dump":
			holds = append(holds, "db")
		}
	}
	if ce := o.appEntries(app, &files); len(ce) > 0 {
		es = append(es, ce...)
		holds = append(holds, "config")
	}
	key := s.key(s.hostID, app, id+".rbk")
	res, err := o.putBundle(ctx, s, key, objName(s.hostID, app, id+".rbk"), es, uploadHooks{started: started})
	if err != nil {
		return sealed{}, "", err
	}
	meta, _ := kvfile.Load(filepath.Join(dir, "meta"))
	k, _ := currentKey(s.keys)
	man := map[string]string{
		"format": "1", "host_id": s.hostID, "hostname": o.Hostname, "app": app, "backup": id,
		"kind": backupKind(id), "created": meta["created"], "tando": o.Version, "holds": strings.Join(holds, " "),
		"size_plain": strconv.FormatInt(res.plainSize, 10), "sha256_plain": res.plainSHA,
		"size_object": strconv.FormatInt(res.objSize, 10), "sha256_object": res.objSHA,
		"encrypted": "0", "uploaded": strconv.FormatInt(o.now(), 10),
	}
	if s.conf.Encrypt {
		man["encrypted"], man["key_id"] = "1", k.IDHex()
	}
	b, err := kvfile.Format(cleanMap(man))
	if err != nil {
		return sealed{}, "", err
	}
	if err := s.cli.put(ctx, s.key(s.hostID, app, id+".manifest"), b, "text/plain"); err != nil {
		return sealed{}, "", err
	}
	// the app's own object, so a new server can recreate it even when no backup is recent
	o.putAppConfig(ctx, s, app)
	return res, strings.Join(holds, " "), nil
}

// putAppConfig uploads <app>/app.rbk (app.conf and env); nothing when the app is gone
func (o Offsite) putAppConfig(ctx context.Context, s *session, app string) error {
	var files []*os.File
	defer func() { closeAll(files) }()
	es := o.appEntries(app, &files)
	if len(es) == 0 {
		return nil
	}
	_, err := o.putBundle(ctx, s, s.key(s.hostID, app, "app.rbk"), objName(s.hostID, app, "app.rbk"), es, uploadHooks{})
	return err
}

// putInventory uploads inventory.rbk (host.conf, the apps) and host.manifest
func (o Offsite) putInventory(ctx context.Context, s *session) error {
	apps := o.appNames()
	inv := map[string]string{"apps": strings.Join(apps, " "), "tando": o.Version, "hostname": o.Hostname,
		"host_id": s.hostID, "updated": strconv.FormatInt(o.now(), 10)}
	for _, a := range apps {
		c, _ := kvfile.Load(filepath.Join(o.Env.Root, "apps", a, "app.conf"))
		for _, k := range []string{"recipe", "domains", "database", "backup", "origin", "path"} {
			if c[k] != "" {
				inv[a+"."+k] = c[k]
			}
		}
	}
	ib, err := kvfile.Format(cleanMap(inv))
	if err != nil {
		return err
	}
	es := []entry{{name: "inventory", data: ib, size: int64(len(ib))}}
	var files []*os.File
	defer func() { closeAll(files) }()
	if f, fi, err := openOwned(filepath.Join(o.Env.Root, "host.conf"), o.Owner); err == nil {
		files = append(files, f)
		es = append(es, entry{name: "host.conf", f: f, size: fi.Size()})
	}
	if _, err := o.putBundle(ctx, s, s.key(s.hostID, "", "inventory.rbk"), objName(s.hostID, "", "inventory.rbk"), es, uploadHooks{}); err != nil {
		return err
	}
	for _, a := range apps {
		if err := o.putAppConfig(ctx, s, a); err != nil {
			return err
		}
	}
	k, _ := currentKey(s.keys)
	man := map[string]string{"format": "1", "host_id": s.hostID, "hostname": o.Hostname, "tando": o.Version,
		"apps": strings.Join(apps, " "), "updated": strconv.FormatInt(o.now(), 10), "encrypted": "0"}
	if s.conf.Encrypt {
		man["encrypted"], man["key_id"] = "1", k.IDHex()
	}
	mb, err := kvfile.Format(cleanMap(man))
	if err != nil {
		return err
	}
	return s.cli.put(ctx, s.key(s.hostID, "", "host.manifest"), mb, "text/plain")
}

// appNames: the apps with an app.conf, sorted
func (o Offsite) appNames() []string {
	ents, err := os.ReadDir(filepath.Join(o.Env.Root, "apps"))
	if err != nil {
		return nil
	}
	var r []string
	for _, e := range ents {
		if checkApp(e.Name()) == nil {
			if _, err := os.Stat(filepath.Join(o.Env.Root, "apps", e.Name(), "app.conf")); err == nil {
				r = append(r, e.Name())
			}
		}
	}
	sort.Strings(r)
	return r
}
