package watch

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"strings"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/decimal"
)

// Decide, record, send. A run decides in memory (states, events, messages), then records, then
// sends outside the lock (deliver.go). Recording must survive a kill at any point without losing
// or repeating a notification:
//
//  1. the run's effects are written to $V/commit (history lines and incidents to write, message
//     lines to queue, inbox notices to delete), atomically;
//  2. the state is written with _out=<id of that commit>, atomically: this rename is the commit
//     point;
//  3. the effects are applied: a queue file per notifier (named after the commit, so writing it
//     twice gives the same file), the inbox notices deleted, history and incidents appended;
//  4. $V/commit is removed.
//
// A run killed before 2 left a state without _out=<id>: the next run drops $V/commit and
// decides again from the old state (nothing was sent, nothing is lost). Killed after 2: the
// next run finds _out=<id> and applies $V/commit first. Queue files and inbox deletions are
// idempotent; only a history or incident line can be written twice, in a window of
// microseconds. (The shell queued before saving the state, so a kill in between sent the
// messages again on the next run, and deleted an inbox notice before queueing it, so a kill
// lost it.) Delivery itself is at least once: a message is deleted after the receiver's 2xx.
type commitLog struct {
	id     string // "<now>,<pid>"
	events []event
	msgs   []string // message lines with their newline
	inbox  []string
}

func (w Watch) commitPath() string { return filepath.Join(w.Dir, "commit") }

func (c commitLog) encode() []byte {
	var b bytes.Buffer
	b.WriteString("tando-watch commit " + c.id + "\n")
	for _, e := range c.events {
		b.WriteString("E\t" + e.kind + "\t" + e.app + "\t" + e.check + "\t" + e.detail + "\n")
	}
	for _, m := range c.msgs {
		b.WriteString("Q\t" + m)
	}
	for _, f := range c.inbox {
		b.WriteString("X\t" + f + "\n")
	}
	return b.Bytes()
}

func decodeCommit(b []byte) (commitLog, bool) {
	var c commitLog
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(nil, 1<<20)
	if !sc.Scan() {
		return c, false
	}
	id, ok := strings.CutPrefix(sc.Text(), "tando-watch commit ")
	if !ok || !numsRe.MatchString(id) {
		return c, false
	}
	c.id = id
	for sc.Scan() {
		kind, rest, _ := strings.Cut(sc.Text(), "\t")
		switch kind {
		case "E":
			p := strings.SplitN(rest, "\t", 4)
			if len(p) == 4 {
				c.events = append(c.events, event{p[0], p[1], p[2], p[3]})
			}
		case "Q":
			c.msgs = append(c.msgs, rest+"\n")
		case "X":
			c.inbox = append(c.inbox, rest)
		}
	}
	return c, true
}

// nextSeq numbers the commits of this process (0 when there is no counter: tests, a one-shot).
func (w Watch) nextSeq() int64 {
	if w.Seq == nil {
		return 0
	}
	return w.Seq.Add(1)
}

func (c commitLog) now() int64 {
	t, _, _ := strings.Cut(c.id, ",")
	return num(t, 0)
}

// commit records what the run decided (see above) and writes the state.
func (t *tick) commit() error {
	w := t.w
	msgs := t.messages()
	if len(t.events) == 0 && len(msgs) == 0 && len(t.inbox) == 0 {
		if t.st.dirty {
			return t.st.save(w.statePath())
		}
		return nil
	}
	// the id names the queue files: two commits of one process in the same second (tandod's tick of
	// the minute and a `tick` asked over the socket) must not write the same file
	c := commitLog{id: decimal.Itoa(t.now) + "," + decimal.Itoa(int64(w.PID)) + "," + decimal.Itoa(w.nextSeq()), events: t.events, msgs: msgs, inbox: t.inbox}
	if err := atomicfile.Write(w.commitPath(), c.encode(), atomicfile.Mode(0o600)); err != nil {
		return err
	}
	t.st.set("_out", c.id)
	if err := t.st.save(w.statePath()); err != nil {
		os.Remove(w.commitPath())
		return err
	}
	w.apply(c, t.st)
	if t.st.dirty { // (queue overflow counts)
		return t.st.save(w.statePath())
	}
	return nil
}

// recoverCommit finishes the commit of a run that was killed after its commit point, and drops
// the effects of one killed before it.
func (w Watch) recoverCommit(st *store) {
	b, err := os.ReadFile(w.commitPath())
	if err != nil {
		return
	}
	c, ok := decodeCommit(b)
	if ok && st.get("_out") == c.id {
		w.apply(c, st)
		return
	}
	os.Remove(w.commitPath())
}

// apply carries out a committed run's effects, most important first.
func (w Watch) apply(c commitLog, st *store) {
	if len(c.msgs) > 0 {
		data := []byte(strings.Join(c.msgs, ""))
		_, rest, _ := strings.Cut(c.id, ",")
		for _, n := range w.notifiers() {
			w.enqueue(n, decimal.Itoa(c.now())+"."+strings.ReplaceAll(rest, ",", "-"), data, st)
		}
	}
	for _, f := range c.inbox {
		os.Remove(f)
	}
	w.recordEvents(c.now(), c.events)
	os.Remove(w.commitPath())
}
