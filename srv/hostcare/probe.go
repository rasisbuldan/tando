package hostcare

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"tando/srv/internal/kvfile"
	"tando/srv/internal/valid"
)

// After a reboot every app must answer its health check again. The probe is tando-watch's (a
// domain package cannot import another, so this is a small copy with the same rules): GET
// <scheme>://<app>.<apps_domain><path><health> through the local Caddy (connected to 127.0.0.1
// on the URL's port, TLS without verification), no redirects, the probe secret header (so the
// request stays out of the request log); health_expect = [status|Nxx] [text], default any
// 2xx/3xx.

// Prober asks one URL; tests replace it.
type Prober interface {
	Probe(ctx context.Context, url string, timeout time.Duration) (code int, body string, err error)
}

type httpProber struct{ header string }

func (p httpProber) Probe(ctx context.Context, url string, timeout time.Duration) (int, string, error) {
	d := &net.Dialer{Timeout: 5 * time.Second}
	tr := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			_, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			return d.DialContext(ctx, network, net.JoinHostPort("127.0.0.1", port))
		},
		TLSClientConfig:    &tls.Config{InsecureSkipVerify: true}, // Caddy's own or a fresh certificate
		DisableKeepAlives:  true,
		DisableCompression: true,
	}
	c := &http.Client{Transport: tr, Timeout: timeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("User-Agent", "tando-probe")
	if b, err := os.ReadFile(p.header); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if k, v, ok := strings.Cut(strings.TrimRight(l, "\r"), ":"); ok && k != "" && !strings.ContainsAny(k, " \t") {
				req.Header.Set(k, strings.TrimSpace(v))
			}
		}
	}
	resp, err := c.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return resp.StatusCode, string(body), nil
}

var expectRe = regexp.MustCompile(`^[1-5]([0-9]{2}|xx)$`)

// healthy judges an answer by health_expect (watch's rule).
func healthy(code int, body, expect string) bool {
	exp, txt, _ := strings.Cut(expect, " ")
	if !expectRe.MatchString(exp) {
		exp, txt = "", expect
	}
	c := itoa(code)
	if len(c) != 3 {
		return false
	}
	switch {
	case exp == "" && c[0] != '2' && c[0] != '3':
		return false
	case strings.HasSuffix(exp, "xx") && c[0] != exp[0]:
		return false
	case len(exp) == 3 && !strings.HasSuffix(exp, "xx") && c != exp:
		return false
	}
	return txt == "" || strings.Contains(body, txt)
}

func itoa(n int) string {
	if n <= 0 {
		return "0"
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	return string(b)
}

// appProbe is one app that should answer after a reboot.
type appProbe struct {
	App, URL, Expect string
	Timeout          time.Duration
}

// probes: the deployed apps that are not stopped by their owner, with their health URL.
func (h *Host) probes() []appProbe {
	hc, _ := kvfile.Load(filepath.Join(h.Env.Root, "host.conf"))
	dom := hc["apps_domain"]
	if dom == "" {
		dom = "localhost"
	}
	scheme := "https://"
	if hc["tls"] == "" || hc["tls"] == "off" {
		scheme = "http://"
	}
	timeout := watchSetting(readFile(filepath.Join(h.Env.Root, "alerts.conf"), 1<<20), "health_timeout", 10)
	ents, _ := os.ReadDir(filepath.Join(h.Env.Root, "apps"))
	var res []appProbe
	for _, e := range ents {
		a := e.Name()
		if !valid.App(a) {
			continue
		}
		d := filepath.Join(h.Env.Root, "apps", a)
		conf, err := kvfile.Load(filepath.Join(d, "app.conf"))
		if err != nil || len(conf) == 0 {
			continue
		}
		st, _ := kvfile.Load(filepath.Join(d, "state"))
		if st["current"] == "" || st["stopped"] != "" || st["down"] != "" {
			continue
		}
		hp := conf["health"]
		if hp == "" {
			hp = "/"
		}
		url := scheme + a + "." + dom + conf["path"] + hp
		if cu := conf["check_url"]; cu != "" { // adopted app behind a hand-written Caddy site
			url = cu + conf["path"] + hp
		}
		res = append(res, appProbe{App: a, URL: url, Expect: conf["health_expect"],
			Timeout: time.Duration(timeout) * time.Second})
	}
	return res
}

// verifyApps probes every app until it answers well or its time is up (each probe at most its
// health_timeout, retried every 2 s, for at most total). It returns the apps that never did.
func (h *Host) verifyApps(ctx context.Context, total time.Duration) (failed []string, secs int64) {
	start := h.Env.Now()
	left := h.probes()
	for len(left) > 0 {
		var next []appProbe
		for _, p := range left {
			code, body, err := h.Probe.Probe(ctx, p.URL, p.Timeout)
			if err != nil || !healthy(code, body, p.Expect) {
				next = append(next, p)
			}
		}
		left = next
		if len(left) == 0 || h.Env.Now().Sub(start) >= total || ctx.Err() != nil {
			break
		}
		h.Sleep(2 * time.Second)
	}
	for _, p := range left {
		failed = append(failed, p.App)
	}
	return failed, int64(h.Env.Now().Sub(start).Seconds())
}
