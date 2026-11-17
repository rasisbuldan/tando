package watch

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
)

// composed is one notification: every queued line of a notifier in one message.
type composed struct {
	host, title, text string
	events            string     // JSON array for the webhook
	hipri             bool       // something firing (not low severity), rolled back, restarted, a new error
	read              []readFile // the queue files it was made of (delivered: these, and only these, go)
}

// readFile is a queue file as compose read it: a file of the same name that is not this one
// (written after the read) is not deleted with the message it was not part of.
type readFile struct {
	path string
	ino  uint64
}

// readQueued reads a queue file and notes which file it was.
func readQueued(p string) ([]byte, readFile, bool) {
	f, err := os.Open(p)
	if err != nil {
		return nil, readFile{}, false
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, readFile{}, false
	}
	b, err := io.ReadAll(io.LimitReader(f, 4<<20))
	if err != nil {
		return nil, readFile{}, false
	}
	return b, readFile{p, inode(fi)}, true
}

func inode(fi os.FileInfo) uint64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return uint64(st.Ino)
	}
	return 0
}

// removeRead deletes the files a delivered message was made of, if they are still those files.
func removeRead(rs []readFile) {
	for _, r := range rs {
		if fi, err := os.Stat(r.path); err == nil && inode(fi) == r.ino {
			os.Remove(r.path)
		}
	}
}

// Notifier delivers one composed message. The returned text says what happened ("HTTP 200",
// "handed to sendmail", or why it failed) and never holds a secret: it is shown by tando alerts
// and kept in the state.
type Notifier interface {
	Send(ctx context.Context, m composed) (string, error)
}

// failed is a delivery that did not work; its text is the reason shown to the user.
type failed string

func (f failed) Error() string { return string(f) }

// notifier reads $SEC/notify-<name> (root 600) and returns the notifier of its type.
func (w Watch) notifier(name string) Notifier {
	n, _ := w.Cache.load(filepath.Join(w.Sec, "notify-"+name))
	switch n["type"] {
	case "webhook":
		return webhook{w.Send, n["url"]}
	case "slack":
		return slack{w.Send, n["url"]}
	case "telegram":
		return telegram{w.Send, n["api"], n["token"], n["chat"]}
	case "ntfy":
		return ntfy{w.Send, n["url"], n["token"]}
	case "email":
		return email{w, n["to"], n["from"]}
	}
	return unknownType{}
}

type unknownType struct{}

func (unknownType) Send(context.Context, composed) (string, error) {
	return "", failed("unknown notifier type")
}

// hostName is the name in messages: the setting `name`, else the kernel's host name.
func (w Watch) hostName(cfg settings) string {
	if h := cfg.str("name"); h != "" {
		return h
	}
	return w.hostname()
}

// compose turns queued message files (oldest first) into one message: a title that counts what
// happened ("tando web1: 1 firing, 2 resolved"), one text line per message, and the events as
// JSON for the webhook.
func (w Watch) compose(cfg settings, files []string) composed {
	var nf, nr, nb, nrs, ne int
	var text, ev strings.Builder
	m := composed{host: w.hostName(cfg)}
	for _, f := range files {
		b, rf, ok := readQueued(f)
		if !ok {
			continue
		}
		m.read = append(m.read, rf)
		for _, l := range bashread.Lines(b) {
			p := strings.SplitN(l, "\t", 5)
			for len(p) < 5 {
				p = append(p, "")
			}
			kind, a, c, d, t := cleanAll(p[0]), cleanAll(p[1]), cleanAll(p[2]), cleanAll(p[3]), p[4]
			if kind == "" {
				continue
			}
			low := ""
			if lowSeverity(c) {
				low = " (low)"
			}
			switch kind {
			case "firing", "still firing":
				nf++
				if low == "" {
					m.hipri = true
				}
			case "resolved":
				nr++
			}
			switch kind {
			case "reboot":
				text.WriteString("RESTARTED host: " + d + "\n")
			case "monitor":
				m.hipri = true
				text.WriteString("MONITOR host: " + d + "\n")
			case "rollback":
				nb++
				m.hipri = true
				text.WriteString("ROLLED BACK " + a + ": " + d + "\n")
			case "restart":
				nrs++
				m.hipri = true
				text.WriteString("RESTARTED " + a + ": " + d + "\n")
			case "newerror":
				ne++
				m.hipri = true
				text.WriteString("NEW ERROR " + a + ": " + d + "\n")
			case "log":
				text.WriteString("    | " + d + "\n")
				continue
			default:
				word := upper(kind)
				if kind == "flap" {
					word = "FLAPPING"
				}
				text.WriteString(word + " " + a + "/" + c + low + ": " + d + "\n")
			}
			if !decimal.IsDigits(t) {
				t = "0"
			}
			if ev.Len() > 0 {
				ev.WriteByte(',')
			}
			ev.WriteString(`{"state":` + jsonString(kind) + `,"app":` + jsonString(a) + `,"check":` + jsonString(c) +
				`,"detail":` + jsonString(d) + `,"since":` + t + `}`)
		}
	}
	var parts []string
	add := func(n int, s string) {
		if n > 0 {
			parts = append(parts, decimal.Itoa(int64(n))+" "+s)
		}
	}
	add(nf, "firing")
	add(nr, "resolved")
	add(nb, "rolled back")
	add(nrs, "restarted")
	if ne > 1 {
		add(ne, "new errors")
	} else {
		add(ne, "new error")
	}
	if len(parts) == 0 {
		parts = []string{"notice"}
	}
	m.title = "tando " + m.host + ": " + strings.Join(parts, ", ")
	m.text = m.title + "\n" + strings.TrimSuffix(text.String(), "\n")
	m.events = "[" + ev.String() + "]"
	return m
}

// upper: ASCII letters to upper case (bash ${kind^^} under LC_ALL=C).
func upper(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return string(b)
}

// body is the text without its title line (ntfy carries the title in a header).
func (m composed) body() string {
	_, b, _ := strings.Cut(m.text, "\n")
	return b
}
