package offsite

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/out"
)

// TestProviderLive runs the provider-compatibility subset against a real bucket, under a
// throwaway prefix that it removes again. Only when test/offsite-r2-check.sh (or the owner) sets
// R2_ACCOUNT_ID (or S3_ENDPOINT), R2_BUCKET, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY; skipped
// otherwise (never in the normal test run). The secret is never printed.
func TestProviderLive(t *testing.T) {
	acct, ep := os.Getenv("R2_ACCOUNT_ID"), os.Getenv("S3_ENDPOINT")
	bucket, ak, sk := os.Getenv("R2_BUCKET"), os.Getenv("R2_ACCESS_KEY_ID"), os.Getenv("R2_SECRET_ACCESS_KEY")
	if (acct == "" && ep == "") || bucket == "" || ak == "" || sk == "" {
		t.Skip("no R2_ACCOUNT_ID/R2_BUCKET/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY: see test/offsite-r2-check.sh")
	}
	m := map[string]string{"bucket": bucket, "access_key_id": ak, "secret_access_key": sk, "region": os.Getenv("S3_REGION")}
	if acct != "" {
		m["account_id"] = acct
	} else {
		m["endpoint"] = ep
	}
	rb := make([]byte, 6)
	rand.Read(rb)
	m["prefix"] = "tando-check-" + hexString(rb)
	c, err := confFrom(m)
	if err != nil {
		t.Fatal(err)
	}
	o := Offsite{Rand: rand.Reader, Tries: 4}
	o.Env.Now = time.Now
	cli, err := o.client(c)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	pre := c.Prefix + "/"
	t.Logf("endpoint %s, bucket %s, prefix %s", c.Endpoint, bucket, pre)
	defer func() {
		lp, err := cli.list(ctx, pre, "", 10)
		if err != nil {
			t.Errorf("cleanup list: %v", err)
			return
		}
		for _, ob := range lp.Objects {
			cli.del(ctx, ob.Key)
		}
		if lp, _ := cli.list(ctx, pre, "", 1); len(lp.Objects) > 0 {
			t.Errorf("cleanup: %d objects left under %s", len(lp.Objects), pre)
		}
	}()
	step := func(name string, err error) {
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		t.Logf("ok  %s", name)
	}
	// the probe `tando backup offsite set` runs
	var pb bytes.Buffer
	w := out.New(&pb)
	err = o.probe(ctx, w, c, "checkhost")
	w.Flush()
	t.Logf("probe:\n%s", pb.String())
	step("probe (write, read, list, delete, clock)", err)
	// single put, head, get, range get
	small := []byte("tando provider check " + time.Now().String())
	step("put", cli.put(ctx, pre+"small", small, "text/plain"))
	info, ok, err := cli.head(ctx, pre+"small")
	if err == nil && (!ok || info.Size != int64(len(small))) {
		err = errors.New("head: wrong size")
	}
	step("head", err)
	got, err := cli.getSmall(ctx, pre+"small", 4096)
	if err == nil && !bytes.Equal(got, small) {
		err = errors.New("get: different bytes")
	}
	step("get", err)
	rc, _, err := cli.getRange(ctx, pre+"small", 6, info.ETag)
	if err == nil {
		got, _ = io.ReadAll(rc)
		rc.Close()
		if !bytes.Equal(got, small[6:]) {
			err = errors.New("range get: different bytes")
		}
	}
	step("range get with If-Match", err)
	// multipart: 11 MiB in 5 MiB parts (the smallest S3 allows), the ETag checked
	big := make([]byte, 11<<20)
	rand.Read(big)
	step("multipart upload (3 parts)", cli.upload(ctx, pre+"big", bytes.NewReader(big), int64(len(big)), uploadHooks{partSize: 5 << 20}))
	rr, err := cli.openResumable(ctx, pre+"big", 3)
	if err == nil {
		got, err = io.ReadAll(rr)
		rr.Close()
		if err == nil && !bytes.Equal(got, big) {
			err = errors.New("multipart object differs")
		}
	}
	step("multipart read back", err)
	// an aborted upload leaves nothing
	id, err := cli.createMultipart(ctx, pre+"aborted")
	if err == nil {
		_, err = cli.uploadPart(ctx, pre+"aborted", id, 1, big[:5<<20])
	}
	if err == nil {
		err = cli.abortMultipart(ctx, pre+"aborted", id)
	}
	if _, ok, _ := cli.head(ctx, pre+"aborted"); ok {
		err = errors.New("an aborted upload is visible")
	}
	step("abort multipart upload", err)
	// list with paging (max-keys 2) and a delimiter
	for _, k := range []string{"d/1", "d/2", "d/3", "e/1"} {
		cli.put(ctx, pre+k, []byte(k), "")
	}
	p1, err := cli.listOne(ctx, pre+"d/", "", "", 2)
	if err == nil && (len(p1.Objects) != 2 || p1.Next == "") {
		err = errors.New("paging: no continuation after 2 keys")
	}
	if err == nil {
		p2, err2 := cli.listOne(ctx, pre+"d/", "", p1.Next, 2)
		if err = err2; err == nil && len(p2.Objects) != 1 {
			err = errors.New("paging: second page")
		}
	}
	step("list with paging", err)
	lp, err := cli.list(ctx, pre, "/", 5)
	if err == nil && len(lp.Prefixes) < 2 {
		err = errors.New("delimiter: no common prefixes")
	}
	step("list with a delimiter", err)
	// errors are recognised
	_, ok, err = cli.head(ctx, pre+"nope")
	if err == nil && ok {
		err = errors.New("a missing object exists")
	}
	step("missing object", err)
	bad := *cli
	bad.sig.secret = "wrong" + sk[5:]
	bad.tries = 1
	err = bad.put(ctx, pre+"x", []byte("x"), "")
	var se *S3Error
	if !errors.As(err, &se) || se.Code != "SignatureDoesNotMatch" {
		t.Errorf("wrong secret: %v (want SignatureDoesNotMatch)", err)
	} else {
		t.Logf("ok  wrong secret -> %s", strings.SplitN(err.Error(), ": ", 2)[1])
	}
	nb := *cli
	nb.bucket = "tando-no-such-bucket-" + hexString(rb)
	nb.tries = 1
	if err := nb.put(ctx, "x", []byte("x"), ""); err == nil {
		t.Error("a missing bucket accepted a put")
	} else {
		t.Logf("ok  missing bucket -> %v", err)
	}
	step("delete", cli.del(ctx, pre+"small"))
}
