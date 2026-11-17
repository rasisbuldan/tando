// Package offsite copies every backup tando makes to S3-compatible object storage (Cloudflare
// R2 first; AWS S3, Backblaze B2, MinIO by configuration), encrypted on the server before it
// leaves, so that losing the server does not lose the data. docs/BACKUP.md is the user's side.
//
// Files:
//
//	/opt/tando/offsite.conf          the settings and the bucket's credentials (root 600, conf.go)
//	/opt/tando/offsite.key           the recovery keys (root 600, key.go)
//	/opt/tando/offsite.id            host_id=<12 hex>: this server's directory in the bucket (644)
//	/var/backups/tando/<app>/<id>/offsite   per backup: state=pending|uploading|uploaded|failed ...
//	/var/lib/tando/offsite/state/<app>      per app, for tando-watch and status (644, state.go)
//	/var/lib/tando/offsite/host      the credentials' last check, the inventory's last refresh
//	/var/lib/tando/offsite/locks/    one lock per app (pushes of an app run one at a time)
//
// Objects (layout.go): <prefix>/<host id>/<app>/<backup id>.rbk and .manifest, <app>/app.rbk,
// inventory.rbk, host.manifest.
//
// Layer: domain. It imports internal/* only; no other domain package, not daemon.
package offsite

import (
	"context"
	"crypto/rand"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/kvfile"
	"tando/srv/internal/valid"
)

// Offsite is the program's state: every path and every outside dependency, replaceable in tests.
type Offsite struct {
	Env      env.Env
	Conf     string // /opt/tando/offsite.conf
	KeyFile  string // /opt/tando/offsite.key
	IDFile   string // /opt/tando/offsite.id
	Dir      string // /var/lib/tando/offsite
	Backups  string // /var/backups/tando
	Units    string // /etc/systemd/system
	Hostname string
	Version  string
	HTTP     *http.Client // nil: TLS-verified, no proxy, no redirects (newHTTPClient)
	Rand     io.Reader    // crypto/rand
	Sleep    func(context.Context, time.Duration) error
	Tries    int   // attempts per request; 0: 6
	PartSize int64 // tests: a smaller multipart part size
	Stderr   io.Writer
	// Owner is the uid whose files root reads (root: 0); tests use their own
	Owner int
}

// New is the real machine.
func New(e env.Env, version string) Offsite {
	hn, _ := os.Hostname()
	return Offsite{
		Env: e, Conf: filepath.Join(e.Root, "offsite.conf"), KeyFile: filepath.Join(e.Root, "offsite.key"),
		IDFile: filepath.Join(e.Root, "offsite.id"), Dir: filepath.Join(e.Lib, "offsite"),
		Backups: "/var/backups/tando", Units: "/etc/systemd/system", Hostname: hn, Version: version,
		Rand: rand.Reader, Sleep: sleepCtx, Stderr: os.Stderr,
	}
}

var (
	reBackupID = regexp.MustCompile(`^([0-9]{8})-([0-9]{6})-(daily|predeploy|manual|safety|final)$`)
	reHostID   = regexp.MustCompile(`^[a-z0-9]{6,32}$`)
)

// ValidBackupID is the agent's valid_backup.
func ValidBackupID(s string) bool { return reBackupID.MatchString(s) }

// ValidHostID: what a host id looks like (12 lower-case hex digits when tando made it)
func ValidHostID(s string) bool { return reHostID.MatchString(s) }

func backupKind(id string) string { return reBackupID.FindStringSubmatch(id)[3] }

// backupTime: when the id says the backup was made (UTC), 0 when it cannot be read
func backupTime(id string) int64 {
	m := reBackupID.FindStringSubmatch(id)
	if m == nil {
		return 0
	}
	t, err := time.Parse("20060102150405", m[1]+m[2])
	if err != nil {
		return 0
	}
	return t.Unix()
}

var errRoot = errors.New("this needs root (sudo)")

func (o Offsite) needRoot() error {
	if o.Env.EUID != 0 {
		return errRoot
	}
	return nil
}

func (o Offsite) now() int64 { return o.Env.Now().Unix() }

func (o Offsite) bin(name string) string { return filepath.Join(o.Env.Root, "bin", name) }

func checkApp(a string) error {
	if !valid.App(a) {
		return errors.New("invalid app name")
	}
	return nil
}

// hostID reads this server's id; with create, makes one the first time.
func (o Offsite) hostID(create bool) (string, error) {
	m, err := kvfile.Load(o.IDFile)
	if err != nil {
		return "", err
	}
	if id := m["host_id"]; ValidHostID(id) {
		return id, nil
	}
	if !create {
		return "", errors.New("this server has no offsite host id yet: tando backup offsite set")
	}
	b := make([]byte, 6)
	if _, err := io.ReadFull(o.Rand, b); err != nil {
		return "", err
	}
	id := strings.ToLower(hexString(b))
	if _, err := kvfile.Save(o.IDFile, map[string]string{"host_id": id}, modeOf(0o644)); err != nil {
		return "", err
	}
	return id, nil
}

func hexString(b []byte) string {
	const h = "0123456789abcdef"
	s := make([]byte, 2*len(b))
	for i, c := range b {
		s[2*i], s[2*i+1] = h[c>>4], h[c&15]
	}
	return string(s)
}

// client builds the S3 client of conf
func (o Offsite) client(c Conf) (*s3Client, error) {
	u, err := checkEndpoint(c.Endpoint)
	if err != nil {
		return nil, err
	}
	hc := o.HTTP
	if hc == nil {
		hc = newHTTPClient()
	}
	tries := o.Tries
	if tries == 0 {
		tries = 6
	}
	sl := o.Sleep
	if sl == nil {
		sl = sleepCtx
	}
	return &s3Client{base: u, bucket: c.Bucket, hc: hc, now: o.Env.Now, sleep: sl, tries: tries,
		sig: signer{access: c.AccessKey, secret: c.Secret, region: c.Region, service: "s3"}}, nil
}

// session: the settings, keys and client of a configured server
type session struct {
	conf   Conf
	keys   []Key
	cli    *s3Client
	hostID string
}

var errOff = errors.New("offsite backups are not set up on this server: tando backup offsite set")

func (o Offsite) open() (*session, error) {
	c, ok, err := loadConf(o.Conf, o.Owner)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errOff
	}
	keys, err := loadKeys(o.KeyFile, o.Owner)
	if err != nil {
		return nil, err
	}
	if c.Encrypt {
		if _, ok := currentKey(keys); !ok {
			return nil, errors.New("encryption is on but there is no recovery key: tando backup offsite key --import (or set again)")
		}
	}
	cli, err := o.client(c)
	if err != nil {
		return nil, err
	}
	id, err := o.hostID(false)
	if err != nil {
		return nil, err
	}
	return &session{conf: c, keys: keys, cli: cli, hostID: id}, nil
}
