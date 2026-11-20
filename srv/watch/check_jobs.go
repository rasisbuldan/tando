package watch

import (
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/valid"
)

// Scheduled jobs (job.<name> in tando.conf). The agent writes one oneshot unit per job of the
// live release, tando-<app>_job-<name>.service, started by its timer or by `tando jobs run`
// ("_" is in no app or job name: the unit is exactly this app's job, never another app's unit).
// A run longer than its timeout (job_timeout, job.<name>.timeout) is ended by systemd with the
// result "timeout": a failed run like any other.
// How a job last ended is in systemd, where `tando jobs` reads it too: the unit's ActiveState and
// Result, the exit status of its process, and when the unit last became inactive or failed
// (InactiveEnterTimestampMonotonic, which changes with every run that ends: it tells one failed
// run from the next). The job units are asked in the run's one `systemctl show` call (tandod: on
// its open bus connection), so watching jobs starts no program and reads no journal.
//
//	never ran, or running now                 not judged (an alert that fires stays as it is)
//	failed                                    fires at once, check "job.<name>"; the detail names
//	                                          the job, how it ended and when
//	failed again (another run) while firing   one more message with the new detail (and it counts
//	                                          towards flapping: a job failing every minute pauses
//	                                          after flap_max messages)
//	succeeded                                 resolves at once
//	no longer scheduled                       resolves ("no longer scheduled"), its state is dropped
//
// A run by hand (`tando jobs run <name>`) is the same unit: its failure fires, its success
// resolves. After a restart of the host systemd has forgotten the last run: a firing alert stays
// until the job next succeeds. A stopped or deploying app does not hold its jobs' alerts.

var jobNameRe = regexp.MustCompile(`^[a-z][a-z0-9-]{0,20}$`)

func jobUnit(app, job string) string { return "tando-" + app + "_job-" + job + ".service" }

// jobsOf: the scheduled jobs of the app, as the agent's jobs_follow decides them: those the live
// release was deployed with (apps/<app>/jobs/<id>), app.conf's for a release from before that
// file; none without a release.
func (w Watch) jobsOf(a string) []string {
	state, _ := w.Cache.load(filepath.Join(w.appDir(a), "state"))
	id := state["current"]
	if !valid.ID(id) {
		return nil
	}
	file := filepath.Join(w.appDir(a), "jobs", id)
	if !fsinfo.RegularFollow(file) {
		file = filepath.Join(w.appDir(a), "app.conf")
	}
	conf, _ := w.Cache.load(file)
	var jobs []string
	for k := range conf {
		if j, ok := strings.CutPrefix(k, "job."); ok && jobNameRe.MatchString(j) {
			jobs = append(jobs, j)
		}
	}
	sort.Strings(jobs)
	return jobs
}

// checkJobs: each scheduled job of the app, by how its unit last ended.
func checkJobs(t *tick, a *appTick) {
	if !t.cfg.on("job", a.name) {
		return
	}
	W := t.st
	for _, j := range t.jobs[a.name] {
		u := t.units[jobUnit(a.name, j)]
		c := "job." + j
		k := a.key(c)
		state, ended := u["ActiveState"], u["InactiveEnterTimestampMonotonic"]
		if (state != "inactive" && state != "failed") || !decimal.IsDigits(ended) || num(ended, 0) == 0 {
			continue // running, never ran (or forgotten at a restart), or systemd did not answer
		}
		if state == "inactive" && or(u["Result"], "success") == "success" {
			t.recover[k] = 1 // a fact, not a measurement: one success resolves
			t.sample(k, a.name, c, ok, "", 1)
			continue
		}
		det := "job " + j + " failed at " + t.w.monoTime(t.now, num(ended, 0)) + ": " + jobEnd(u, a.conf["memory"]) +
			"; tando jobs run " + j + " -a " + a.name + " runs it again and shows its output"
		if W.get(k+".st") != "firing" {
			t.sample(k, a.name, c, bad, det, 1)
			W.set(k+".run", ended)
			continue
		}
		if W.get(k+".run") == ended {
			continue // the run that was reported
		}
		// another failed run while it fires: told again, once
		W.set(k+".run", ended)
		W.set(k+".det", clean(det))
		W.del(k+".okn", k+".okt")
		t.event("fire", a.name, c, det)
		if !t.silenced(display(a.name)) {
			t.flapNote(k, a.name, c)
		}
		t.again[k] = true
	}
}

// jobEnd says how the job's run ended: systemd's Result first (its timeout and the memory limit
// are results of the unit, whatever signal the process got), then the exit of its process.
func jobEnd(u map[string]string, memory string) string {
	xc, xs := u["ExecMainCode"], u["ExecMainStatus"]
	switch res := u["Result"]; {
	case res == "timeout":
		return "killed by its timeout"
	case res == "oom-kill":
		return "killed at its memory limit " + or(memory, "?")
	case xc == "2":
		return "killed by " + signame(xs)
	case xc == "3":
		return "core dumped (" + signame(xs) + ")"
	case xc == "1" && decimal.IsDigits(xs) && xs != "0":
		return "exit status " + xs
	default:
		return "it could not run (" + or(res, "unknown") + ")"
	}
}

// monoTime: a monotonic timestamp of systemd (microseconds since boot) as a time of day, from the
// seconds since boot of /proc/uptime (as the dead man's check reads the last run).
func (w Watch) monoTime(now, mono int64) string {
	at := min(now-(w.uptime()-mono/1000000), now)
	return time.Unix(at, 0).UTC().Format("01-02 15:04") + " UTC"
}

// dropJobs: the alerts of jobs that are no longer scheduled (removed from tando.conf and
// deployed, or gone with a rollback). One that fires resolves, once; the rest of its state goes.
func dropJobs(t *tick) {
	W := t.st
	for _, key := range W.keys() {
		a, rest, _ := strings.Cut(key, ".")
		jf, isJob := strings.CutPrefix(rest, "job.")
		if !isJob || strings.HasPrefix(a, "_") {
			continue
		}
		j, field, _ := strings.Cut(jf, ".")
		if slices.Contains(t.jobs[a], j) {
			continue
		}
		c := "job." + j
		k := a + "." + c
		switch field {
		case "st":
			if W.get(key) == "firing" {
				t.resolved[k] = "the job is no longer scheduled"
				t.event("resolve", a, c, t.resolved[k])
			}
			if W.get(key) != "ok" {
				W.set(key, "ok") // (reconcile sends the resolve if the firing was sent, then forgets it)
			}
		case "ns", "nt", "fl", "flap":
		default:
			W.del(key)
		}
	}
}
