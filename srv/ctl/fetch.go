package ctl

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"syscall"
	"time"
)

// Fetching an artifact (app.deploy): the node downloads what the control plane names, so the
// control plane's URL must not become a way to make the node talk to what it can reach and the
// control plane cannot (its loopback services, the cloud's metadata service, a private network).
//
//   - https only, also after a redirect (at most 3); no proxy from the environment
//   - the address is checked when the connection is made, after DNS: a name that resolves to a
//     private, loopback, link-local (the metadata service), CGNAT, multicast or reserved address is
//     refused, unless the operator's allowlist (/opt/tando/ctl/fetch-allow: CIDRs) names it. A
//     name cannot pass the check and then connect elsewhere (no second lookup)
//   - the body is at most the declared size (one byte more and it stops), in a time limit
//   - it goes to a file that is unlinked at once, in a root-only directory: the sha256 is computed
//     on that file descriptor, and the same descriptor is what is unpacked (nothing can swap it)

// FetchPolicy is what a fetch may reach.
type FetchPolicy struct {
	Allow   []netip.Prefix // operator's allowlist: these addresses may be reached although private
	Roots   *x509.CertPool // nil: the system's
	Timeout time.Duration  // the whole download
	MaxSize int64
}

// blocked are the ranges a fetch never reaches without the allowlist.
var blocked = func() []netip.Prefix {
	var p []netip.Prefix
	for _, s := range []string{
		"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
		"192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15",
		"198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
		"::/128", "::1/128", "::ffff:0:0/96", "64:ff9b::/96", "64:ff9b:1::/48", "100::/64",
		"2001:db8::/32", "2002::/16", "fc00::/7", "fe80::/10", "fec0::/10", "ff00::/8",
	} {
		p = append(p, netip.MustParsePrefix(s))
	}
	return p
}()

// AddrAllowed says whether a fetch may connect to ip.
func (p FetchPolicy) AddrAllowed(ip netip.Addr) bool {
	ip = ip.Unmap()
	for _, a := range p.Allow {
		if a.Contains(ip) {
			return true
		}
	}
	if !ip.IsValid() || !ip.IsGlobalUnicast() {
		return false
	}
	for _, b := range blocked {
		if b.Contains(ip) {
			return false
		}
	}
	return true
}

// ErrAddr: the destination is not one a fetch may reach.
var ErrAddr = errors.New("address not allowed")

// CheckURL is the URL check before any connection: https, a host, no user info, at most 2048 bytes.
func CheckURL(s string) (*url.URL, error) {
	if len(s) > 2048 || strings.ContainsFunc(s, func(r rune) bool { return r <= 0x20 || r == 0x7f }) {
		return nil, errors.New("not a URL (too long, or spaces and control characters)")
	}
	u, err := url.Parse(s)
	if err != nil {
		return nil, errors.New("not a URL")
	}
	if u.Scheme != "https" {
		return nil, errors.New("only https URLs are fetched")
	}
	if u.Host == "" || u.Hostname() == "" || u.User != nil || u.Opaque != "" {
		return nil, errors.New("the URL needs a host and no user info")
	}
	return u, nil
}

func (p FetchPolicy) client() *http.Client {
	d := &net.Dialer{Timeout: 20 * time.Second, Control: func(_, address string, _ syscall.RawConn) error {
		// (the address as it is dialled: after the lookup, for each address tried)
		ap, err := netip.ParseAddrPort(address)
		if err != nil || !p.AddrAllowed(ap.Addr()) {
			return fmt.Errorf("%w: %s (a private, loopback, link-local or reserved address; /opt/tando/ctl/fetch-allow lists the ones that may be fetched from)", ErrAddr, address)
		}
		return nil
	}}
	tr := &http.Transport{
		Proxy:                  nil,
		DialContext:            d.DialContext,
		TLSClientConfig:        &tls.Config{RootCAs: p.Roots, MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout:    20 * time.Second,
		ResponseHeaderTimeout:  60 * time.Second,
		DisableCompression:     true, // the bytes as stored: the sha256 is of those
		MaxResponseHeaderBytes: 64 << 10,
	}
	return &http.Client{Transport: tr, Timeout: p.Timeout, CheckRedirect: func(r *http.Request, via []*http.Request) error {
		if len(via) >= 3 {
			return errors.New("more than 3 redirects")
		}
		if r.URL.Scheme != "https" {
			return errors.New("a redirect to a URL that is not https")
		}
		if _, err := CheckURL(r.URL.String()); err != nil {
			return fmt.Errorf("redirect: %w", err)
		}
		return nil
	}}
}

// Fetch downloads rawURL into an unlinked file in dir and checks its size and sha256 on that
// descriptor. The file is returned at offset 0; the caller closes it.
func (p FetchPolicy) Fetch(ctx context.Context, dir, rawURL string, size int64, sum string) (*os.File, error) {
	u, err := CheckURL(rawURL)
	if err != nil {
		return nil, err
	}
	if size <= 0 || size > p.MaxSize {
		return nil, fmt.Errorf("size %d is not within 1 to %d bytes", size, p.MaxSize)
	}
	want, err := hex.DecodeString(sum)
	if err != nil || len(want) != sha256.Size {
		return nil, errors.New("sha256: 64 hex digits")
	}
	f, err := os.CreateTemp(dir, "fetch-*")
	if err != nil {
		return nil, err
	}
	// unlinked at once: only this descriptor reaches the bytes
	os.Remove(f.Name())
	ok := false
	defer func() {
		if !ok {
			f.Close()
		}
	}()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "tando-ctl")
	resp, err := p.client().Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch: %s", strings.ReplaceAll(err.Error(), rawURL, "<url>"))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetch: HTTP %d", resp.StatusCode)
	}
	if resp.ContentLength >= 0 && resp.ContentLength != size {
		return nil, fmt.Errorf("fetch: the server says %d bytes, the request %d", resp.ContentLength, size)
	}
	n, err := io.Copy(f, io.LimitReader(resp.Body, size+1))
	if err != nil {
		return nil, fmt.Errorf("fetch: %v", err)
	}
	if n != size {
		return nil, fmt.Errorf("fetch: got %d bytes, the request says %d", n, size)
	}
	if err := f.Sync(); err != nil {
		return nil, err
	}
	// the sha256 of what is on this descriptor (the one that is unpacked), not of the stream
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, err
	}
	if got := h.Sum(nil); !equal(got, want) {
		return nil, fmt.Errorf("sha256 mismatch: got %x", got)
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	ok = true
	return f, nil
}

func equal(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var d byte
	for i := range a {
		d |= a[i] ^ b[i]
	}
	return d == 0
}

// LoadAllow reads the operator's allowlist: one CIDR or address per line, # comments. The file
// must be root's and writable by root only (else it is not used: an error).
func LoadAllow(path string) ([]netip.Prefix, error) {
	b, err := readRootFile(path, 64<<10)
	if err != nil || b == nil {
		return nil, err
	}
	var out []netip.Prefix
	sc := bufio.NewScanner(strings.NewReader(string(b)))
	for n := 1; sc.Scan(); n++ {
		l := strings.TrimSpace(sc.Text())
		if i := strings.IndexByte(l, '#'); i >= 0 {
			l = strings.TrimSpace(l[:i])
		}
		if l == "" {
			continue
		}
		if !strings.Contains(l, "/") {
			a, err := netip.ParseAddr(l)
			if err != nil {
				return nil, fmt.Errorf("%s line %d: not an address or CIDR", path, n)
			}
			l = netip.PrefixFrom(a, a.BitLen()).String()
		}
		p, err := netip.ParsePrefix(l)
		if err != nil {
			return nil, fmt.Errorf("%s line %d: not an address or CIDR", path, n)
		}
		out = append(out, p.Masked())
	}
	return out, nil
}

// readRootFile reads a file that must be a regular file of root's, writable by root only; a
// missing file is nil, nil.
func readRootFile(path string, max int64) ([]byte, error) {
	fi, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !fi.Mode().IsRegular() || !ok || st.Uid != 0 || fi.Mode().Perm()&0o022 != 0 {
		return nil, fmt.Errorf("%s must be a file of root's that only root can write", path)
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, fmt.Errorf("%s is over %d bytes", path, max)
	}
	return b, nil
}
