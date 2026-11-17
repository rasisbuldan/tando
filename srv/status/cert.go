package status

import (
	"encoding/asn1"
	"encoding/pem"
	"os"
	"path/filepath"
	"time"

	"tando/srv/internal/decimal"
)

// maxCert bounds the read of a certificate file (Caddy's holds the leaf and its chain).
const maxCert = 256 << 10

// certExpiry is cert_expiry: the epoch when Caddy's certificate for domain expires, "-" when it
// has none. The shell ran `find <certificates> -name "$1.crt" | head -1`, openssl x509 -enddate
// and date -d: three processes per domain. Caddy keeps <certificates>/<issuer>/<domain>/<domain>.crt,
// so each issuer directory is looked at, in directory order as find walked them.
//
// The store belongs to the caddy user, so nothing in it is followed: an issuer or domain
// directory that is a symlink is skipped and the file is opened with O_NOFOLLOW (find did not
// follow links while walking, but openssl opened what a matched link pointed to). A file that
// does not parse gives "-" (the shell's `date -d ""` printed today's midnight).
func (c *Collector) certExpiry(domain string) string {
	if domain == "" || domain[0] == '.' || filepath.Base(domain) != domain {
		return "-"
	}
	d, err := os.Open(c.Certs)
	if err != nil {
		return "-"
	}
	ents, err := d.ReadDir(-1) // (*File).ReadDir: directory order, not sorted
	d.Close()
	if err != nil {
		return "-"
	}
	for _, e := range ents {
		if !e.IsDir() { // (DirEntry type from readdir: a symlink is not a directory here)
			continue
		}
		dd := filepath.Join(c.Certs, e.Name(), domain)
		if fi, err := os.Lstat(dd); err != nil || !fi.IsDir() {
			continue
		}
		p := filepath.Join(dd, domain+".crt")
		fi, err := os.Lstat(p)
		if err != nil {
			continue
		}
		if !fi.Mode().IsRegular() {
			return "-" // what find would have matched first, and openssl not read as a certificate
		}
		b, err := readBounded(p, maxCert, true)
		if err != nil {
			return "-"
		}
		t, ok := notAfter(b)
		if !ok {
			return "-"
		}
		return decimal.Itoa(t.Unix())
	}
	return "-"
}

// notAfter reads the end of the validity of the first certificate in PEM data, as `openssl x509
// -enddate` does, without parsing the rest of the certificate.
func notAfter(b []byte) (time.Time, bool) {
	for {
		var blk *pem.Block
		blk, b = pem.Decode(b)
		if blk == nil {
			return time.Time{}, false
		}
		if blk.Type != "CERTIFICATE" && blk.Type != "X509 CERTIFICATE" && blk.Type != "TRUSTED CERTIFICATE" {
			continue
		}
		var cert struct {
			TBS struct {
				Raw       asn1.RawContent
				Version   asn1.RawValue `asn1:"optional,explicit,tag:0"`
				Serial    asn1.RawValue
				Algorithm asn1.RawValue
				Issuer    asn1.RawValue
				Validity  struct{ NotBefore, NotAfter time.Time }
			}
		}
		if _, err := asn1.Unmarshal(blk.Bytes, &cert); err != nil {
			return time.Time{}, false
		}
		return cert.TBS.Validity.NotAfter, true
	}
}
