package watch

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"

	"tando/srv/internal/decimal"
)

// HTTP in tando-watch replaces the shell's curl calls with the same limits: no redirects
// followed, no proxy, no compression asked for, the same User-Agent and headers, a connect
// timeout of 5 s and a limit for the whole request.

// probeReq is one health probe: url is the app's link (http(s)://<app>.<domain><path>); the
// connection goes to the loopback address on the URL's port (curl --connect-to ::127.0.0.1:),
// TLS with the link's name (SNI) and without verification (curl -k).
type probeReq struct{ url string }

// probeRes is what curl's -w '%{http_code} %{exitcode} %{time_total}' said: code 0 when there
// was no answer, exit a curl exit code (0 ok, 7 refused, 28 timed out, 52 empty reply, ...),
// the first 4096 bytes of the body.
type probeRes struct {
	code int
	exit int
	ms   int64
	body string
}

// Prober runs the health probes (all at once, at most probeParallel in parallel) and the direct probe of
// the liveness check.
type Prober interface {
	Probe(ctx context.Context, reqs []probeReq, timeout time.Duration) []probeRes
	// Direct asks the app on its own port (any status counts as alive), 20 s at most; 0: none.
	Direct(ctx context.Context, url string) int
}

// CertReader reads the certificate served for a site through the loopback address on 443: its
// validity, and whether it verifies against the system's CAs (when verify is set).
type CertReader interface {
	Cert(ctx context.Context, site string, verify bool) (notBefore, notAfter time.Time, err error)
}

// errNoVerify: the certificate does not verify (curl's error 60).
var errNoVerify = errors.New("certificate does not verify")

// Sender posts a notification and pings the heartbeat.
type Sender interface {
	Post(ctx context.Context, url string, header [][2]string, body []byte) (int, error)
	Ping(ctx context.Context, url string) error
}

type httpProber struct {
	header   string // /opt/tando/probe.header: "X-Tando-Probe: <secret>" (root 600)
	loopback string
}

// client makes an http.Client that connects to the loopback address on the URL's port.
func loopClient(loopback string, timeout time.Duration) *http.Client {
	d := &net.Dialer{Timeout: 5 * time.Second}
	tr := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			_, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			return d.DialContext(ctx, network, net.JoinHostPort(loopback, port))
		},
		TLSClientConfig:    &tls.Config{InsecureSkipVerify: true}, // curl -k: Caddy's own or a fresh certificate
		DisableKeepAlives:  true,
		DisableCompression: true,
	}
	return &http.Client{Transport: tr, Timeout: timeout, CheckRedirect: noRedirect}
}

func noRedirect(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

// headerLines reads "Name: value" lines (curl -H @file); a missing file is no header.
func headerLines(path string) [][2]string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var h [][2]string
	for _, l := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(strings.TrimRight(l, "\r"), ":"); ok && k != "" && !strings.ContainsAny(k, " \t") {
			h = append(h, [2]string{k, strings.TrimSpace(v)})
		}
	}
	return h
}

func (p httpProber) Probe(ctx context.Context, reqs []probeReq, timeout time.Duration) []probeRes {
	res := make([]probeRes, len(reqs))
	c := loopClient(p.loopback, timeout)
	h := headerLines(p.header)
	sem := make(chan struct{}, probeParallel)
	var wg sync.WaitGroup
	for i, r := range reqs {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			res[i] = probe(ctx, c, r.url, h, 4096)
			<-sem
		}()
	}
	wg.Wait()
	return res
}

// probeParallel: health probes at once. Each waits health_timeout at most, so a run waits that
// long once for up to this many apps that hang, not once per app.
const probeParallel = 64

func probe(ctx context.Context, c *http.Client, u string, h [][2]string, keep int64) probeRes {
	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return probeRes{exit: 3}
	}
	req.Header.Set("User-Agent", "tando-probe")
	req.Header.Set("Accept", "*/*")
	for _, kv := range h {
		req.Header.Set(kv[0], kv[1])
	}
	resp, err := c.Do(req)
	if err != nil {
		return probeRes{exit: curlExit(err), ms: time.Since(start).Milliseconds()}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, keep))
	r := probeRes{code: resp.StatusCode, body: string(body)}
	if err != nil {
		r.exit = curlExit(err)
	}
	r.ms = time.Since(start).Milliseconds()
	return r
}

func (p httpProber) Direct(ctx context.Context, u string) int {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return 0
	}
	req.Header.Set("User-Agent", "tando-probe")
	req.Header.Set("Accept", "*/*")
	c := &http.Client{Timeout: 20 * time.Second, CheckRedirect: noRedirect,
		Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true, DisableCompression: true,
			DialContext: (&net.Dialer{Timeout: 20 * time.Second}).DialContext}}
	resp, err := c.Do(req)
	if err != nil {
		return 0
	}
	resp.Body.Close()
	return resp.StatusCode
}

// curlExit maps a Go network error to the curl exit code the shell classified by.
func curlExit(err error) int {
	var ne net.Error
	var dns *net.DNSError
	switch {
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &ne) && ne.Timeout():
		return 28
	case errors.As(err, &dns):
		return 6
	case errors.Is(err, syscall.ECONNREFUSED):
		return 7
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		return 52
	case errors.Is(err, syscall.ECONNRESET):
		return 56
	case isTLSError(err):
		return 35
	}
	return 56
}

func isTLSError(err error) bool {
	var rh tls.RecordHeaderError
	var ae tls.AlertError
	return errors.As(err, &rh) || errors.As(err, &ae) || strings.Contains(err.Error(), "tls: ")
}

type tlsCerts struct{ loopback string }

func (c tlsCerts) Cert(ctx context.Context, site string, verify bool) (time.Time, time.Time, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	d := tls.Dialer{NetDialer: &net.Dialer{Timeout: 5 * time.Second},
		Config: &tls.Config{ServerName: site, InsecureSkipVerify: !verify}}
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(c.loopback, "443"))
	if err != nil {
		var ve *tls.CertificateVerificationError
		var ua x509.UnknownAuthorityError
		var he x509.HostnameError
		var ci x509.CertificateInvalidError
		if errors.As(err, &ve) || errors.As(err, &ua) || errors.As(err, &he) || errors.As(err, &ci) {
			return time.Time{}, time.Time{}, errNoVerify
		}
		return time.Time{}, time.Time{}, err
	}
	defer conn.Close()
	certs := conn.(*tls.Conn).ConnectionState().PeerCertificates
	if len(certs) == 0 {
		return time.Time{}, time.Time{}, errors.New("no certificate")
	}
	return certs[0].NotBefore, certs[0].NotAfter, nil
}

// httpSender sends notifications (15 s, curl -m 15 --connect-timeout 5 --retry 0) and pings
// the heartbeat (10 s; any answer below 400 is fine, as curl -f). Never a proxy, never a redirect.
type httpSender struct{}

func sendClient(timeout time.Duration) *http.Client {
	return &http.Client{Timeout: timeout, CheckRedirect: noRedirect, Transport: &http.Transport{
		Proxy: nil, DisableKeepAlives: true, DisableCompression: true,
		DialContext:         (&net.Dialer{Timeout: 5 * time.Second}).DialContext,
		TLSHandshakeTimeout: 10 * time.Second,
	}}
}

func (httpSender) Post(ctx context.Context, u string, h [][2]string, body []byte) (int, error) {
	req, err := newRequest(ctx, http.MethodPost, u, body)
	if err != nil {
		return 0, err
	}
	for _, kv := range h {
		req.Header.Set(kv[0], kv[1])
	}
	resp, err := sendClient(15 * time.Second).Do(req)
	if err != nil {
		return 0, failed(sendWhy(err))
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	resp.Body.Close()
	return resp.StatusCode, nil
}

func (httpSender) Ping(ctx context.Context, u string) error {
	req, err := newRequest(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := sendClient(10 * time.Second).Do(req)
	if err != nil {
		return failed(sendWhy(err))
	}
	resp.Body.Close()
	if resp.StatusCode >= 400 {
		return failed("HTTP " + decimal.Itoa(int64(resp.StatusCode)))
	}
	return nil
}

// newRequest builds a request whose errors never carry the URL (it is a secret).
func newRequest(ctx context.Context, method, u string, body []byte) (*http.Request, error) {
	pu, err := url.Parse(u)
	if err != nil || (pu.Scheme != "http" && pu.Scheme != "https") || pu.Host == "" {
		return nil, failed("curl error 3") // (curl's "URL malformed")
	}
	var r io.Reader
	if body != nil {
		r = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, r)
	if err != nil {
		return nil, failed("curl error 3")
	}
	req.Header.Set("User-Agent", "tando-watch")
	req.Header.Set("Accept", "*/*")
	return req, nil
}

// sendWhy says why a delivery failed, in the shell's words, without the URL that Go's errors
// carry.
func sendWhy(err error) string {
	switch e := curlExit(err); e {
	case 6:
		return "could not resolve the host"
	case 7:
		return "connection refused"
	case 28:
		return "timed out"
	case 35:
		var ve *tls.CertificateVerificationError
		if errors.As(err, &ve) {
			return "TLS error (curl 60)"
		}
		return "TLS error (curl 35)"
	default:
		return "curl error " + decimal.Itoa(int64(e))
	}
}
