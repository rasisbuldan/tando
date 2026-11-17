package offsite

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"
)

// Uploads: an object of at most singleMax bytes goes in one PUT; a larger one as a multipart
// upload of equal parts (the last smaller). One part is in memory at a time, so memory stays
// under 16 MiB whatever the size: 8 MiB parts carry up to 80 GB (S3 allows 10,000 parts), 16 MiB
// parts up to 160 GB; larger backups are refused with a message. Until Complete nothing is
// visible under the key: an upload that is killed leaves no half object, only parts that
// AbortMultipartUpload removes (tando records the upload id first, so the next run aborts it; a
// bucket lifecycle rule for incomplete uploads is the second net, docs/BACKUP.md).

const (
	singleMax = 16 << 20
	maxParts  = 10000
	mib       = 1 << 20
)

// partSizeFor: the part size of an object of n bytes (0: too large)
func partSizeFor(n int64) int64 {
	for _, p := range []int64{8 * mib, 16 * mib} {
		if (n+p-1)/p <= maxParts {
			return p
		}
	}
	return 0
}

// uploadHooks let the caller record a multipart upload's id before any part is sent (so that a
// killed process's parts can be aborted later) and see progress.
type uploadHooks struct {
	started  func(uploadID string) error
	progress func(sent int64)
	partSize int64 // tests: a smaller part size (S3's minimum is 5 MiB but for the last part)
}

// upload sends exactly size bytes from r under key and checks what the store says it got.
func (c *s3Client) upload(ctx context.Context, key string, r io.Reader, size int64, hk uploadHooks) error {
	ps := hk.partSize
	if ps == 0 {
		ps = partSizeFor(size)
	}
	if ps == 0 {
		return fmt.Errorf("the backup is %d GB: larger than the %d GB an offsite object can be", size>>30, (16*mib*maxParts)>>30)
	}
	if size <= singleMax && hk.partSize == 0 {
		buf := make([]byte, size)
		if _, err := io.ReadFull(r, buf); err != nil {
			return fmt.Errorf("read the backup: %w", err)
		}
		if err := c.put(ctx, key, buf, "application/octet-stream"); err != nil {
			return err
		}
		return c.verifySize(ctx, key, size, "")
	}
	id, err := c.createMultipart(ctx, key)
	if err != nil {
		return err
	}
	if hk.started != nil {
		if err := hk.started(id); err != nil {
			c.abortQuietly(key, id)
			return err
		}
	}
	err = c.sendParts(ctx, key, id, r, size, ps, hk)
	if err != nil {
		c.abortQuietly(key, id)
		return err
	}
	return nil
}

func (c *s3Client) abortQuietly(key, id string) {
	// (a fresh context: the caller's may be what was cancelled)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	c.abortMultipart(ctx, key, id)
}

func (c *s3Client) sendParts(ctx context.Context, key, id string, r io.Reader, size, ps int64, hk uploadHooks) error {
	buf := make([]byte, ps)
	var parts []completedPart
	var sums []byte
	var sent int64
	for n := 1; sent < size; n++ {
		k := min(ps, size-sent)
		if _, err := io.ReadFull(r, buf[:k]); err != nil {
			return fmt.Errorf("read the backup: %w", err)
		}
		et, err := c.uploadPart(ctx, key, id, n, buf[:k])
		if err != nil {
			return err
		}
		m := md5.Sum(buf[:k])
		sums = append(sums, m[:]...)
		parts = append(parts, completedPart{PartNumber: n, ETag: et})
		sent += k
		if hk.progress != nil {
			hk.progress(sent)
		}
	}
	if len(parts) == 0 { // (an empty object is a single PUT; not reached)
		return errors.New("internal: no parts")
	}
	et, err := c.completeMultipart(ctx, key, id, parts)
	if err != nil {
		return err
	}
	// a multipart ETag is the MD5 of the parts' MD5s and "-<parts>" on S3, R2 and MinIO
	whole := md5.Sum(sums)
	want := hex.EncodeToString(whole[:]) + "-" + strconv.Itoa(len(parts))
	if strings.Contains(et, "-") && !strings.EqualFold(et, want) {
		return &S3Error{Op: "complete upload", Key: key, Status: 200, Code: "BadDigest"}
	}
	return c.verifySize(ctx, key, size, et)
}

// verifySize: the stored object has the size that was sent (and the ETag Complete gave)
func (c *s3Client) verifySize(ctx context.Context, key string, size int64, etag string) error {
	info, ok, err := c.head(ctx, key)
	if err != nil {
		return err
	}
	if !ok {
		return &S3Error{Op: "verify", Key: key, Status: 404, Code: "NoSuchKey"}
	}
	if info.Size != size || (etag != "" && info.ETag != "" && !strings.EqualFold(info.ETag, etag)) {
		return fmt.Errorf("verify %s: the storage holds %d bytes, %d were sent", key, info.Size, size)
	}
	return nil
}

// resumeReader reads an object and, when the connection breaks, asks again from where it
// stopped (If-Match: the same version), up to tries times.
type resumeReader struct {
	ctx   context.Context
	c     *s3Client
	key   string
	etag  string
	size  int64
	off   int64
	body  io.ReadCloser
	tries int
	idle  time.Duration
}

func (c *s3Client) openResumable(ctx context.Context, key string, tries int) (*resumeReader, error) {
	body, info, err := c.getRange(ctx, key, 0, "")
	if err != nil {
		return nil, err
	}
	return &resumeReader{ctx: ctx, c: c, key: key, etag: info.ETag, size: info.Size, body: body, tries: tries}, nil
}

func (r *resumeReader) Read(p []byte) (int, error) {
	for {
		if r.body == nil {
			if r.tries <= 0 {
				return 0, &S3Error{Op: "get", Key: r.key, Err: errors.New("the download broke off too often")}
			}
			r.tries--
			if err := r.c.sleep(r.ctx, backoff(1)); err != nil {
				return 0, err
			}
			b, info, err := r.c.getRange(r.ctx, r.key, r.off, r.etag)
			if err != nil {
				var se *S3Error
				if errors.As(err, &se) && se.Status != 0 {
					return 0, err // an answer (changed, gone): not worth retrying
				}
				continue
			}
			if info.Size != r.size {
				b.Close()
				return 0, &S3Error{Op: "get", Key: r.key, Status: 206, Code: "ObjectChanged"}
			}
			r.body = b
		}
		n, err := r.body.Read(p)
		r.off += int64(n)
		if err == io.EOF {
			if r.off != r.size {
				r.body.Close()
				r.body = nil
				if n > 0 {
					return n, nil
				}
				continue
			}
			return n, io.EOF
		}
		if err != nil {
			r.body.Close()
			r.body = nil
			if r.ctx.Err() != nil {
				return n, r.ctx.Err()
			}
			if n > 0 {
				return n, nil
			}
			continue
		}
		return n, nil
	}
}

func (r *resumeReader) Close() error {
	if r.body != nil {
		return r.body.Close()
	}
	return nil
}
