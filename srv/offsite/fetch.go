package offsite

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/kvfile"
	"tando/srv/internal/out"
)

const (
	maxManifest = 64 << 10
	maxEntry    = 1 << 40 // one file of a bundle
	maxConfig   = 4 << 20 // app.conf, env, inventory
)

// readObject streams an object through decryption (or not, when it is a plaintext bundle and
// encryption is off) into readBundle. A plaintext object is refused while encryption is on:
// whoever can write to the bucket could otherwise plant a backup tando would restore.
// It returns the SHA-256 and size of the object's bytes as read, and the SHA-256 of the plaintext.
func (o Offsite) readObject(ctx context.Context, s *session, host, app, file string, fn func(name string, size int64, r io.Reader) error) (readResult, error) {
	rr, err := s.cli.openResumable(ctx, s.key(host, app, file), 5)
	if err != nil {
		return readResult{}, err
	}
	defer rr.Close()
	h := sha256.New()
	br := bufio.NewReaderSize(io.TeeReader(rr, h), 256<<10)
	head, _ := br.Peek(len(cryptMagic))
	var src io.Reader = br
	switch {
	case bytes.Equal(head, []byte(cryptMagic)):
		op, err := newOpener(br, s.keys, objName(host, app, file))
		if err != nil {
			return readResult{}, err
		}
		src = op
	case bytes.HasPrefix(head, []byte(bundleMagic)):
		if s.conf.Encrypt {
			return readResult{}, errors.New("the object is not encrypted, and encryption is on here: refused (an object tando did not write?)")
		}
	default:
		return readResult{}, errors.New("not a tando offsite object")
	}
	ph := sha256.New()
	if err := readBundle(io.TeeReader(src, ph), maxEntry, fn); err != nil {
		return readResult{}, err
	}
	// whatever is left of the object (nothing, when it was whole) still counts for its hash
	io.Copy(io.Discard, br)
	return readResult{objSHA: hex.EncodeToString(h.Sum(nil)), objSize: rr.off, plainSHA: hex.EncodeToString(ph.Sum(nil))}, nil
}

type readResult struct {
	objSHA, plainSHA string
	objSize          int64
}

// readConfig: the small files of an app.rbk or inventory.rbk object, in memory
func (o Offsite) readConfig(ctx context.Context, s *session, host, app, file string) (map[string][]byte, error) {
	files := map[string][]byte{}
	_, err := o.readObject(ctx, s, host, app, file, func(name string, size int64, r io.Reader) error {
		if size > maxConfig {
			return fmt.Errorf("%s: %s too large", file, name)
		}
		b, err := io.ReadAll(r)
		files[name] = b
		return err
	})
	return files, err
}

func (o Offsite) manifest(ctx context.Context, s *session, host, app, id string) (map[string]string, error) {
	b, err := s.cli.getSmall(ctx, s.key(host, app, id+".manifest"), maxManifest)
	if err != nil {
		return nil, err
	}
	return kvfile.Parse(bytes.NewReader(b))
}

// Fetch brings a backup from the bucket back to /var/backups/tando/<app>/<id> (the verb `fetch
// <app> <id> [host id]`), verified: every chunk authenticates, and the object's and the
// plaintext's SHA-256 match its manifest. It is written to a temporary directory and renamed
// into place, so a backup directory is whole or absent. The agent then restores it as any other.
func (o Offsite) Fetch(ctx context.Context, w *out.Writer, app, id, host string) error {
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
	if err != nil {
		return err
	}
	if host == "" {
		host = s.hostID
	}
	if !ValidHostID(host) {
		return errors.New("bad host id")
	}
	dest := o.backupDir(app, id)
	if _, err := os.Lstat(dest); err == nil {
		w.KV("fetched", id)
		w.KV("already", "1")
		return nil
	}
	for _, d := range []string{o.Backups, filepath.Join(o.Backups, app)} {
		if err := os.Mkdir(d, 0o700); err != nil && !os.IsExist(err) {
			return err
		}
		if fi, err := os.Lstat(d); err != nil || !fi.IsDir() {
			return fmt.Errorf("%s is not a directory", d)
		}
	}
	man, merr := o.manifest(ctx, s, host, app, id)
	if merr != nil {
		var se *S3Error
		switch {
		case !errors.As(merr, &se) || se.Code != "NoSuchKey":
			return merr
		case !s.conf.Encrypt:
			// a plaintext object has no check of its own: its manifest's SHA-256 is the only one
			return fmt.Errorf("fetch %s: the backup has no manifest in the bucket, and encryption is off here: refused (nothing checks what it holds)", id)
		default:
			man = nil // (a backup whose manifest did not make it: the encrypted object authenticates itself)
		}
	}
	if man != nil && (man["app"] != app || man["backup"] != id) {
		return errors.New("the manifest is for another backup: refused")
	}
	tmp, err := os.MkdirTemp(filepath.Join(o.Backups, app), "."+id+".fetch")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	rres, err := o.readObject(ctx, s, host, app, id+".rbk", func(name string, size int64, r io.Reader) error {
		switch name {
		case "meta", "data.tar.gz", "db.dump":
		default:
			_, err := io.Copy(io.Discard, r) // (the app's config: dr-conf and dr-env read it)
			return err
		}
		f, err := os.OpenFile(filepath.Join(tmp, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return err
		}
		n, err := io.Copy(f, r)
		if err == nil {
			err = f.Sync()
		}
		if cerr := f.Close(); err == nil {
			err = cerr
		}
		if err == nil && n != size {
			err = fmt.Errorf("%s: %d of %d bytes", name, n, size)
		}
		return err
	})
	if err != nil {
		return fmt.Errorf("fetch %s: %w", id, err)
	}
	objSHA, objSize := rres.objSHA, rres.objSize
	if man != nil {
		if man["sha256_plain"] != "" && man["sha256_plain"] != rres.plainSHA {
			return fmt.Errorf("fetch %s: the backup's SHA-256 differs from its manifest: refused", id)
		}
		if man["sha256_object"] != "" && man["sha256_object"] != objSHA {
			return fmt.Errorf("fetch %s: the object's SHA-256 differs from its manifest: refused", id)
		}
		if man["size_object"] != "" && num(man["size_object"]) != objSize {
			return fmt.Errorf("fetch %s: the object's size differs from its manifest: refused", id)
		}
	}
	if _, err := os.Stat(filepath.Join(tmp, "meta")); err != nil {
		return fmt.Errorf("fetch %s: no meta in the backup", id)
	}
	st := map[string]string{"state": "uploaded", "source": host, "fetched": strconv.FormatInt(o.now(), 10),
		"object": s.key(host, app, id+".rbk"), "sha256": objSHA, "size": strconv.FormatInt(objSize, 10)}
	if b, err := kvfile.Format(cleanMap(st)); err == nil {
		os.WriteFile(filepath.Join(tmp, "offsite"), b, 0o600)
	}
	// the agent's prune keeps a fetched backup for a day (it may be older than what it keeps)
	os.WriteFile(filepath.Join(tmp, "fetched"), nil, 0o600)
	if err := os.Chmod(tmp, 0o700); err != nil {
		return err
	}
	if err := os.Rename(tmp, dest); err != nil {
		return err
	}
	w.KV("fetched", id)
	w.KV("size", strconv.FormatInt(objSize, 10))
	return nil
}

// remoteBackup is one backup object in the bucket.
type remoteBackup struct {
	id       string
	size     int64
	modified time.Time
}

// remoteBackups: the app's backup objects under host, newest first
func (o Offsite) remoteBackups(ctx context.Context, s *session, host, app string) ([]remoteBackup, error) {
	p := s.conf.rootPrefix() + objName(host, app, "")
	lp, err := s.cli.list(ctx, p, "", 100)
	if err != nil {
		return nil, err
	}
	var r []remoteBackup
	for _, ob := range lp.Objects {
		name := strings.TrimPrefix(ob.Key, p)
		id, ok := strings.CutSuffix(name, ".rbk")
		if !ok || !ValidBackupID(id) {
			continue
		}
		r = append(r, remoteBackup{id: id, size: ob.Size, modified: ob.Modified})
	}
	sort.Slice(r, func(i, j int) bool { return r[i].id > r[j].id })
	return r, nil
}

// Ls lists the app's backups in the bucket (the verb `ls <app> [host id]`): rows
//
//	offsite <id> <kind> <created epoch> <size> <local: 1|0>
func (o Offsite) Ls(ctx context.Context, w *out.Writer, app, host string) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	if err := checkApp(app); err != nil {
		return err
	}
	s, err := o.open()
	if err != nil {
		return err
	}
	if host == "" {
		host = s.hostID
	}
	if !ValidHostID(host) {
		return errors.New("bad host id")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	rb, err := o.remoteBackups(ctx, s, host, app)
	if err != nil {
		return err
	}
	for _, b := range rb {
		local := "0"
		if _, err := os.Lstat(o.backupDir(app, b.id)); err == nil {
			local = "1"
		}
		w.Row("offsite", b.id, backupKind(b.id), strconv.FormatInt(backupTime(b.id), 10), strconv.FormatInt(b.size, 10), local)
	}
	return nil
}

// Hosts lists the servers that keep backups in the bucket (the verb `hosts`): rows
//
//	host <host id> <hostname> <updated epoch> <tando version> <key id> <this: 1|0> <apps, comma-separated>
func (o Offsite) Hosts(ctx context.Context, w *out.Writer) error {
	if err := o.needRoot(); err != nil {
		return err
	}
	s, err := o.open()
	if err != nil {
		return err
	}
	lp, err := s.cli.list(ctx, s.conf.rootPrefix(), "/", 20)
	if err != nil {
		return err
	}
	for _, p := range lp.Prefixes {
		h := strings.TrimSuffix(strings.TrimPrefix(p, s.conf.rootPrefix()), "/")
		if !ValidHostID(h) {
			continue
		}
		b, err := s.cli.getSmall(ctx, s.key(h, "", "host.manifest"), maxManifest)
		m := map[string]string{}
		if err == nil {
			m, _ = kvfile.Parse(bytes.NewReader(b))
		}
		this := "0"
		if h == s.hostID {
			this = "1"
		}
		w.Row("host", h, m["hostname"], m["updated"], m["tando"], m["key_id"], this, strings.ReplaceAll(m["apps"], " ", ","))
	}
	return nil
}
