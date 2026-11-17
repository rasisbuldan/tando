package offsite

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"tando/srv/internal/kvfile"
)

// The offsite settings: /opt/tando/offsite.conf, root 600 (it holds the secret access key).
//
//	endpoint=https://<account id>.r2.cloudflarestorage.com
//	region=auto
//	bucket=<name>
//	prefix=tando                  objects are <prefix>/<host id>/...
//	access_key_id=...  secret_access_key=...
//	encrypt=on|off                on unless set off explicitly
//	alert_hours=6                 a backup not offsite after this long fires the backup alert
//	keep_daily=7 keep_weekly=4 keep_monthly=0 keep_other=5 keep_min=3
//	since=<epoch>                 offsite on since (older local backups are not uploaded)

// Conf is the parsed settings file.
type Conf struct {
	Endpoint   string
	Region     string
	Bucket     string
	Prefix     string
	AccessKey  string
	Secret     string
	Encrypt    bool
	AlertHours int
	Keep       Keep
	Since      int64
}

// Keep is the offsite retention: per app, the newest Daily daily backups, the newest of each
// of the Weekly ISO weeks and Monthly months before them, the newest Other of each other kind,
// every final; and whatever else, always the Min most recently uploaded.
type Keep struct{ Daily, Weekly, Monthly, Other, Min int }

// DefaultKeep mirrors the local policy (7 daily, 4 weekly, 5 of each other kind, every final).
var DefaultKeep = Keep{Daily: 7, Weekly: 4, Monthly: 0, Other: 5, Min: 3}

var (
	reBucket    = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$`)
	reAccount   = regexp.MustCompile(`^[0-9a-f]{32}$`)
	reRegion    = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)
	rePrefix    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}(/[A-Za-z0-9][A-Za-z0-9._-]{0,62}){0,3}$`)
	reAccessKey = regexp.MustCompile(`^[A-Za-z0-9+/=._-]{8,128}$`)
	reSecret    = regexp.MustCompile(`^[\x21-\x7e]{8,256}$`)
)

// settable: what `set` accepts on stdin (account_id is turned into endpoint)
var settable = map[string]bool{
	"account_id": true, "endpoint": true, "region": true, "bucket": true, "prefix": true,
	"access_key_id": true, "secret_access_key": true, "encrypt": true, "alert_hours": true,
	"keep_daily": true, "keep_weekly": true, "keep_monthly": true, "keep_other": true, "keep_min": true,
}

// R2Endpoint is the S3 endpoint of a Cloudflare account.
func R2Endpoint(account string) string { return "https://" + account + ".r2.cloudflarestorage.com" }

// checkEndpoint: https://host[:port] and nothing else; plain http only to this machine (tests)
func checkEndpoint(s string) (*url.URL, error) {
	u, err := url.Parse(s)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return nil, errors.New("endpoint must be https://host (no path, no user, no query), e.g. https://<account id>.r2.cloudflarestorage.com")
	}
	switch u.Scheme {
	case "https":
	case "http":
		h := u.Hostname()
		if ip := net.ParseIP(h); !(h == "localhost" || ip != nil && ip.IsLoopback()) {
			return nil, errors.New("endpoint must use https:// (plain http only to this machine, for tests)")
		}
	default:
		return nil, errors.New("endpoint must start with https://")
	}
	return &url.URL{Scheme: u.Scheme, Host: u.Host}, nil
}

func parseKeepNum(m map[string]string, k string, def, max int) (int, error) {
	v, ok := m[k]
	if !ok || v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 || n > max {
		return 0, fmt.Errorf("%s must be a number from 0 to %d", k, max)
	}
	return n, nil
}

// confFrom checks and builds a Conf from key=value settings.
func confFrom(m map[string]string) (Conf, error) {
	c := Conf{Endpoint: m["endpoint"], Region: m["region"], Bucket: m["bucket"], Prefix: m["prefix"],
		AccessKey: m["access_key_id"], Secret: m["secret_access_key"]}
	if a := m["account_id"]; a != "" {
		if !reAccount.MatchString(strings.ToLower(a)) {
			return Conf{}, errors.New("account_id must be the 32 hex characters of the Cloudflare account id (R2 overview page, right column)")
		}
		c.Endpoint = R2Endpoint(strings.ToLower(a))
	}
	if c.Endpoint == "" {
		return Conf{}, errors.New("missing endpoint (or account_id for Cloudflare R2)")
	}
	u, err := checkEndpoint(c.Endpoint)
	if err != nil {
		return Conf{}, err
	}
	c.Endpoint = u.String()
	if c.Region == "" {
		c.Region = "auto"
	}
	if !reRegion.MatchString(c.Region) {
		return Conf{}, errors.New("region: a-z, 0-9 and - (R2: auto; AWS: e.g. eu-central-1)")
	}
	if !reBucket.MatchString(c.Bucket) || strings.Contains(c.Bucket, "..") {
		return Conf{}, errors.New("bucket: 3-63 characters a-z, 0-9, . and -, starting and ending with a letter or digit")
	}
	if _, ok := m["prefix"]; !ok {
		c.Prefix = "tando"
	}
	if c.Prefix != "" && (!rePrefix.MatchString(c.Prefix) || strings.Contains(c.Prefix, "..")) {
		return Conf{}, errors.New("prefix: up to 4 path segments of A-Z a-z 0-9 . _ - (no .., no leading or trailing /)")
	}
	if !reAccessKey.MatchString(c.AccessKey) {
		return Conf{}, errors.New("access key id: 8-128 characters, letters, digits and +/=._-")
	}
	if !reSecret.MatchString(c.Secret) {
		return Conf{}, errors.New("secret access key: 8-256 printable characters, no spaces")
	}
	switch m["encrypt"] {
	case "", "on":
		c.Encrypt = true
	case "off":
	default:
		return Conf{}, errors.New("encrypt must be on or off")
	}
	if c.AlertHours, err = parseKeepNum(m, "alert_hours", 6, 720); err != nil {
		return Conf{}, err
	}
	if c.AlertHours == 0 {
		return Conf{}, errors.New("alert_hours must be 1 or more")
	}
	k := &c.Keep
	for _, x := range []struct {
		name     string
		p        *int
		def, max int
	}{{"keep_daily", &k.Daily, DefaultKeep.Daily, 3650}, {"keep_weekly", &k.Weekly, DefaultKeep.Weekly, 520},
		{"keep_monthly", &k.Monthly, DefaultKeep.Monthly, 600}, {"keep_other", &k.Other, DefaultKeep.Other, 1000},
		{"keep_min", &k.Min, DefaultKeep.Min, 1000}} {
		if *x.p, err = parseKeepNum(m, x.name, x.def, x.max); err != nil {
			return Conf{}, err
		}
	}
	if k.Min < 1 {
		return Conf{}, errors.New("keep_min must be 1 or more: the newest offsite backups are never deleted")
	}
	if s := m["since"]; s != "" {
		c.Since, _ = strconv.ParseInt(s, 10, 64)
	}
	return c, nil
}

// fields: the settings as stored
func (c Conf) fields() map[string]string {
	enc := "on"
	if !c.Encrypt {
		enc = "off"
	}
	return map[string]string{
		"endpoint": c.Endpoint, "region": c.Region, "bucket": c.Bucket, "prefix": c.Prefix,
		"access_key_id": c.AccessKey, "secret_access_key": c.Secret, "encrypt": enc,
		"alert_hours": strconv.Itoa(c.AlertHours),
		"keep_daily":  strconv.Itoa(c.Keep.Daily), "keep_weekly": strconv.Itoa(c.Keep.Weekly),
		"keep_monthly": strconv.Itoa(c.Keep.Monthly), "keep_other": strconv.Itoa(c.Keep.Other),
		"keep_min": strconv.Itoa(c.Keep.Min), "since": strconv.FormatInt(c.Since, 10),
	}
}

// loadConf reads the settings file; ok false when offsite is off (no file).
func loadConf(path string, uid int) (Conf, bool, error) {
	b, err := readRootFile(path, 64<<10, uid)
	if err != nil {
		if isNotExist(err) {
			return Conf{}, false, nil
		}
		return Conf{}, false, err
	}
	m, err := kvfile.Parse(bytes.NewReader(b))
	if err != nil {
		return Conf{}, false, err
	}
	c, err := confFrom(m)
	if err != nil {
		return Conf{}, false, fmt.Errorf("%s: %v (tando backup offsite set fixes it)", path, err)
	}
	return c, true, nil
}

// objectPrefix: "<prefix>/<host id>/" (or "<host id>/")
func (c Conf) hostPrefix(hostID string) string {
	if c.Prefix == "" {
		return hostID + "/"
	}
	return c.Prefix + "/" + hostID + "/"
}

func (c Conf) rootPrefix() string {
	if c.Prefix == "" {
		return ""
	}
	return c.Prefix + "/"
}
