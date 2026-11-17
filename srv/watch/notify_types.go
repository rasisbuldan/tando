package watch

import (
	"context"
	"strings"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/run"
)

// The notifier types. Their bodies are the shell version's byte for byte (test/e2e-alerts.sh
// checks what the receivers get). URLs and tokens are secrets: they go into the request only.

var jsonHeader = [][2]string{{"Content-Type", "application/json"}}

// webhook: a JSON POST {"host","title","text","events":[{"state","app","check","detail","since"}]}.
type webhook struct {
	s   Sender
	url string
}

func (n webhook) Send(ctx context.Context, m composed) (string, error) {
	body := `{"host":` + jsonString(m.host) + `,"title":` + jsonString(m.title) + `,"text":` + jsonString(m.text) +
		`,"events":` + m.events + `}`
	return post(ctx, n.s, n.url, jsonHeader, body)
}

// slack: an incoming webhook (Slack, Mattermost, Discord's /slack URL): {"text": ...}.
type slack struct {
	s   Sender
	url string
}

func (n slack) Send(ctx context.Context, m composed) (string, error) {
	return post(ctx, n.s, n.url, jsonHeader, `{"text":`+jsonString(m.text)+`}`)
}

// telegram: the Bot API's sendMessage, at api.telegram.org or a self-hosted api=URL.
type telegram struct {
	s                Sender
	api, token, chat string
}

func (n telegram) Send(ctx context.Context, m composed) (string, error) {
	api := n.api
	if api == "" {
		api = "https://api.telegram.org"
	}
	body := `{"chat_id":` + jsonString(n.chat) + `,"text":` + jsonString(m.text) + `,"disable_web_page_preview":true}`
	return post(ctx, n.s, api+"/bot"+n.token+"/sendMessage", jsonHeader, body)
}

// ntfy: the text without its title as the body, the title in a header, high priority when
// something firing (not low severity), a rollback, a restart or a new error is in it.
type ntfy struct {
	s          Sender
	url, token string
}

func (n ntfy) Send(ctx context.Context, m composed) (string, error) {
	// (curl --data-binary sent this content type, as no other was given)
	h := [][2]string{{"Content-Type", "application/x-www-form-urlencoded"}, {"Title", strings.ReplaceAll(m.title, `"`, "")}}
	if m.hipri {
		h = append(h, [2]string{"Priority", "high"})
	}
	if n.token != "" {
		h = append(h, [2]string{"Authorization", "Bearer " + n.token})
	}
	return post(ctx, n.s, n.url, h, m.body())
}

// post sends and says how it went: 2xx is delivered ("HTTP 200"), anything else a failure.
func post(ctx context.Context, s Sender, url string, h [][2]string, body string) (string, error) {
	code, err := s.Post(ctx, url, h, []byte(body))
	if err != nil {
		return "", err
	}
	r := "HTTP " + decimal.Itoa(int64(code))
	if code < 200 || code > 299 {
		return "", failed(r)
	}
	return r, nil
}

// email: through the local sendmail (refused at notifier-add when there is none).
type email struct {
	w        Watch
	to, from string
}

func (n email) Send(ctx context.Context, m composed) (string, error) {
	sm := which("sendmail")
	if sm == "" {
		sm = "/usr/sbin/sendmail"
		if !fsinfo.RegularFollow(sm) {
			return "", failed("sendmail is not installed")
		}
	}
	from := n.from
	if from == "" {
		from = "tando@" + m.host
	}
	msg := "To: " + n.to + "\nFrom: " + from + "\nSubject: " + m.title +
		"\nContent-Type: text/plain; charset=utf-8\n\n" + m.text + "\n"
	// in a transient unit of its own: sendmail writes its spool (postfix's postdrop is setgid),
	// which the sandbox of tandod and of tando-watch's units (read-only /var, NoNewPrivileges)
	// does not allow. The message goes on stdin (--pipe); the address only in it
	_, err := n.w.Env.Run.Output(ctx, run.Cmd{Argv: []string{"systemd-run", "--quiet", "--pipe", "--wait", "--collect",
		"-p", "Description=tando-watch: email notification", sm, "-t", "-oi"}, Env: cmdEnv,
		Stdin: strings.NewReader(msg), Timeout: 20 * time.Second})
	if err != nil {
		return "", failed("sendmail failed")
	}
	return "handed to sendmail", nil
}
