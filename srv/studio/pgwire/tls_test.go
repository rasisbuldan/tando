package pgwire

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"io"
	"math/big"
	"net"
	"strings"
	"testing"
	"time"
)

// testCA: a CA and a server certificate for the IP 192.0.2.10 (a data node's)
func testCA(t *testing.T) (*x509.CertPool, tls.Certificate) {
	t.Helper()
	ck, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	ct := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test CA"}, NotBefore: time.Now().Add(-time.Hour),
		NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	cder, err := x509.CreateCertificate(rand.Reader, ct, ct, &ck.PublicKey, ck)
	if err != nil {
		t.Fatal(err)
	}
	ca, _ := x509.ParseCertificate(cder)
	sk, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	st := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "data node"}, NotBefore: time.Now().Add(-time.Hour),
		NotAfter: time.Now().Add(time.Hour), IPAddresses: []net.IP{net.ParseIP("192.0.2.10")}, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	sder, err := x509.CreateCertificate(rand.Reader, st, ca, &sk.PublicKey, ck)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(ca)
	return pool, tls.Certificate{Certificate: [][]byte{sder}, PrivateKey: sk}
}

// tlsPair: a fake server that answers the SSLRequest with S (or N) and then speaks TLS
func tlsPair(t *testing.T, answer byte, cert tls.Certificate, script func(f *fake)) Config {
	cfg := Config{Addr: "fake", User: "u", Database: "d", Password: "pencil", scramUser: "user", nonce: "rOprNGfwEbeRWgbNEkqO"}
	cfg.Dial = func(ctx context.Context, _ string) (net.Conn, error) {
		// (TCP on the loopback, not net.Pipe: a refused handshake's alert needs a buffer)
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return nil, err
		}
		defer l.Close()
		var d net.Dialer
		a, err := d.DialContext(ctx, "tcp", l.Addr().String())
		if err != nil {
			return nil, err
		}
		b, err := l.Accept()
		if err != nil {
			return nil, err
		}
		go func() {
			defer b.Close()
			var req [8]byte
			if _, err := io.ReadFull(b, req[:]); err != nil || string(req[:]) != "\x00\x00\x00\x08\x04\xd2\x16\x2f" {
				t.Errorf("no SSLRequest first: %q %v", req, err)
				return
			}
			b.Write([]byte{answer})
			if answer != 'S' {
				return
			}
			s := tls.Server(b, &tls.Config{Certificates: []tls.Certificate{cert}})
			if err := s.Handshake(); err != nil {
				return
			}
			script(&fake{t: t, nc: s, r: bufio.NewReader(s)})
		}()
		return a, nil
	}
	return cfg
}

func TestTLSVerifyFull(t *testing.T) {
	pool, cert := testCA(t)
	other, _ := testCA(t)
	try := func(answer byte, roots *x509.CertPool, name string, script func(f *fake)) (*Conn, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cfg := tlsPair(t, answer, cert, script)
		cfg.TLS = &tls.Config{RootCAs: roots, ServerName: name}
		return Connect(ctx, cfg)
	}
	// the right CA and the address the certificate names: the login runs inside TLS
	c, err := try('S', pool, "192.0.2.10", func(f *fake) { f.login() })
	if err != nil {
		t.Fatalf("verify-full with the pinned CA: %v", err)
	}
	if _, ok := c.nc.(*tls.Conn); !ok {
		t.Fatal("the session is not on TLS")
	}
	c.Kill()
	// another address than the certificate's, a CA that is not the pinned one: refused before
	// any password is sent
	if _, err := try('S', pool, "192.0.2.11", func(f *fake) { f.t.Error("logged in: wrong name") }); err == nil {
		t.Fatal("a certificate for another address was accepted")
	}
	if _, err := try('S', other, "192.0.2.10", func(f *fake) { f.t.Error("logged in: wrong CA") }); err == nil {
		t.Fatal("a certificate of another CA was accepted")
	}
	// a server without TLS: refused, nothing sent in the clear
	if _, err := try('N', pool, "192.0.2.10", nil); err == nil || !strings.Contains(err.Error(), "does not offer TLS") {
		t.Fatalf("a server without TLS: %v", err)
	}
}
