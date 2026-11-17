# tando code review (maintainability, correctness, portability, performance, tests, docs)

Snapshot reviewed: `test/.work-review/tree`, taken 2026-11-14 01:50 UTC with rsync from the live tree,
which other people were editing at the time. Line numbers belong to that snapshot. Each finding also
names its function, so it can still be found after the tree moves.

Markers:
- **[ran]**: reproduced or measured by me. Sources: the review server `tando-review` (Ubuntu 26.04.1,
  uutils coreutils 0.10, mawk, systemd 259, Caddy 2.11.9), or macOS `/bin/bash` 3.2.57 with
  openrsync on this laptop.
- **[read]**: verified by reading the code.
- **[inferred]**: reasoned, not executed.

Three parts were reviewed by helper reviewers working from the same snapshot: the server helper
programs, the tests, and docs vs code. I re-checked the key claims; the ones I re-ran are marked
[ran].

Security and fault-injection findings already in `docs/SECURITY-REVIEW-*.md` and
`docs/FAULT-REVIEW.md` are not repeated here.

## Verdict

tando is careful code with very uneven structure. The parts written with the most care are solid:
- the agent's state machine,
- `strip`/`san_v` sanitising,
- `check_args` driven by `help.txt`,
- `ui.sh` without forks.

Around them, several authors built the same things side by side. There are:
- four ssh wrappers on the client,
- four copies of "install a binary into /opt/tando/bin",
- six time formatters,
- five server programs, each with its own `die`/`valid_app`/`now`/`load`/`save`/`row`,
- two state-file parsers with the same trailing-`=` bug.

Six `docs/*.patch` files are already applied. Docs describe the integration as "to do".

The worst problem is in testing, not in style. Every end-to-end suite registers its server with
`--insecure-test`. As a result, the path every real user takes was never run: `tando host add`
trusting the host key, followed by `tando up`. That path is broken twice:
1. `host add` exits 1 right after trusting the key.
2. Every upload fails with "the name 127.0.0.1 does not resolve" (B1, B2; both reproduced).

Maintainability verdict: **fair, getting worse**. The code is readable function by function. But:
- ~11.4k product lines contain an estimated 1.9–2.6k duplicated or dead lines;
- `docs/`, `test/` and the help text drift apart;
- the lint baseline has grown to 805 entries (not 364), so the gate no longer separates signal from
  noise.

A focused week can remove 15–20% of the product lines with no loss of features (plan below) and
fix the top 15 items.

## Counts

| | bug | risk | cleanup |
|---|---|---|---|
| client (bin, lib) + tando-agent | 6 | 6 | 10 |
| server helpers (+ shared destroy glob) | 11 | 8 | 6 (duplicated helpers, long functions) |
| tests / lint | 8 (checks that cannot fail or pass on errors) | 2 + ~25 sleeps | 6 |
| docs vs code | 10 mismatches | – | ~12 stale or undocumented |

Confirmed by reproduction (ran by me): B1, B2 (plus its fix), B3, B4, S-B3.
Ran by the helper reviewers: B6, S-B1, S-B2, S-B4, S-B5, and the T items marked V.

## 1. Findings: client (bin/tando, lib/*.sh) and server/tando-agent

| id | sev | file:function (line) | what | evidence | fix |
|---|---|---|---|---|---|
| B1 | **bug** | lib/common.sh:`host_add`→`host_trust` (l.90-91, 121) and `host_use` (l.197) | `tando host add` on a fresh config (no `$CFG/known_hosts` yet) trusts the key, saves it, then fails at once with "the host key of X is not trusted yet" and exits 1. `host_use` built `SSHO` *before* the file existed, so the `UserKnownHostsFile` option is missing. | **[ran]** `TANDO_CONFIG_DIR=$(mktemp -d) tando host add rv vmadmin@127.0.0.1 --port 2276 --key id_test --yes` → "trusted; saved in …/known_hosts", then "not trusted yet", rc=1. A second identical run with `--force` gives rc=0. | `host_trust`: after the `cat … >> "$CFG/known_hosts"` line, add `host_use "$HOST"` so SSHO picks up the file. |
| B2 | **bug, critical** | lib/deploy.sh:`upload` (l.105), with lib/common.sh:`host_use` (l.197-198) | `rsync -e "ssh ${SSHO[*]}"` flattens the array. The option `UserKnownHostsFile=$CFG/known_hosts $HOME/.ssh/known_hosts` contains a space, and openrsync (and GNU rsync) split `-e` on whitespace. The second path becomes ssh's *hostname*. **Every upload to a host trusted by `tando host add` fails**: "cannot reach rv: the name 127.0.0.1 does not resolve". No suite catches this because every suite uses `--insecure-test`. | **[ran]** host added with `--yes` (trusted), `tando up` in `examples/hello` → `✗ 3/7 upload … does not resolve`. Raw: `rsync -e "ssh … -o UserKnownHostsFile=$K $HOME/.ssh/known_hosts" …` → `ssh: Could not resolve hostname /users/me/.ssh/known_hosts`. With the fix below applied to a copy (`test/.work-review/fixed`), the same deploy goes live in 5.0 s. | `-SSHO+=(-o "UserKnownHostsFile=$CFG/known_hosts $HOME/.ssh/known_hosts")`<br>`+SSHO+=(-o "GlobalKnownHostsFile=$CFG/known_hosts")`<br>No space; `~/.ssh/known_hosts` stays the user file. Also add one e2e check that registers without `--insecure-test`. |
| B3 | **bug** | lib/cmd-alerts.sh:`cmd_alerts` heartbeat (l.281-285), `alerts_notifier` add; every `printf … \| watch_do …` | `watch_do` calls `bail 1` inside a pipeline subshell, so only the subshell exits. The success note prints and the command exits 0 on failure. | **[ran]** host on a closed port: `tando alerts heartbeat off -H dead` → "Connection refused", then "heartbeat removed", rc=0. | `printf 'off\n' > "$TMPD/in"; watch_do sudo heartbeat < "$TMPD/in" > "$TMPD/o"` (likewise for notifier add/set). |
| B4 | **bug** | server/tando-agent:`load` (l.70) and `cmd_configure` (l.1176). Same idiom in tando-watch:`load` (l.57) and `conf_load` (l.112), tando-logs:`load` (l.55), tando-gate (l.61), tando-adopt (l.456), and on the client in lib/common.sh:`kv_read` (l.380), `host_get` (l.147), lib/cmd-top.sh (l.360). | `IFS='=' read -r k v` drops **one trailing `=`** when the value has no other `=`. bash 3.2 and 5.3 behave the same. A base64 secret or a query string loses its last character. | **[ran]** `IFS="=" read -r k v <<< "a=b="` → `v=b` (3.2 and 5.3). End to end: `health = /health?probe=` in tando.conf → `/opt/tando/apps/hello/app.conf` has `health=/health?probe`. | `while IFS= read -r l; do k=${l%%=*} v=${l#*=}; …` in one shared `load` (see the simplification plan, S1). |
| B5 | bug | lib/views.sh:`cmd_ls_all` (l.446) | `ls --all` accepts `--watch N` but ignores it (no `watch_loop`). With `--json` it prints one object per host, plus a boxed text error for an unreachable host. README:107 promises one object. | [read] | Route it through `watch_loop`. For JSON, emit `{"hosts":[…]}`, with `{"host":h,"error":…}` for a failed host. |
| B6 | bug | lib/help.txt `@@ requests` (`default=summary`), `@@ alerts` (`default=show`) | Both name a default subcommand that is not in `subs:`, so `tando requests summary` and `tando alerts show` are usage errors. | [ran by docs reviewer] | Add `summary=0` / `show=0`, and accept the word in `cmd_requests`/`cmd_alerts`. |
| R1 | risk | server/tando-agent:`cmd_activate` (l.1323) | `flock -w 30 9 && { … S[seq_$id]=… }`: when an activation holds the app lock for more than 30 s (soak defaults to 30 s, plus health), the release silently gets **no sequence number**. `releases_by_seq` then sorts it as the *oldest*. That breaks `tando rollback` (no id), `fallback_of` and `prune` order. Admin deploys are protected by accident: `configure` takes `lock 120` first. CI deploy-key deploys skip `configure` and are exposed. | **[ran]** Two overlapping admin deploys with soak=50: the second waited inside `configure check` (1 m 41 s total) and got seq 3, so the race was not hit on this path. **[inferred]** for the deploy-key path. | `flock -w 30 9 \|\| die "…busy"`. Or better: keep the counter under the lease lock in `upload`'s file (`L[seq]`), since the lease is already held there. |
| R2 | risk | lib/deploy.sh:`do_deploy` / `configure check` | A second deploy that starts while another one soaks blocks with no message inside `configure check` for the whole soak (up to `lock 120`, then "app is busy"). | **[ran]** (above: no output for ~50 s) | `cmd_configure`: when the lock is not free at once, print `waiting=<who>` and let the client say "waiting for release X to finish (soak)". |
| R3 | risk | server/tando-agent:`ds` (l.43) | `${EPOCHREALTIME/./}` assumes a `.` decimal point. bash formats EPOCHREALTIME with the locale's separator. macOS ssh sends `LC_*`, Ubuntu's sshd accepts them and sudo keeps them, so a de_DE client on a server with that locale gets `$((t / 100000))` with a comma → arithmetic error in every activation timing. | [inferred]; the review box only has C/C.utf8 | `local t=${EPOCHREALTIME//[!0-9]/}` |
| R4 | risk | bin/tando global `LINES=100` (l.27, 42) | It reuses bash's special `LINES` (terminal rows) as the `-n` count. lib/ui.sh:`_ui_measure` (l.137) reads `LINES` as the row count when `stty` fails, so `tando top`/`status --watch` without a tty would size to 100 or to `-n`. | [read]; bash 5.3 `checkwinsize` did not overwrite it in a test [ran] | Rename to `NLINES`. |
| R5 | risk | lib/common.sh:`ctl_dir` (l.162), lib/cmd-top.sh (l.55, 175) | Three different ways to carry SSHO across a string boundary: `${SSHO[*]}` (B2), an `$'\037'`-joined string re-split with IFS (top), and a remote string. | [read] | One `ssh_cmd` wrapper script in `$TMPD/ssh` (`exec ssh "${SSHO[@]}" "$@"`), used as `rsync -e "$TMPD/ssh"` and by top. |
| R6 | risk | server/tando-agent: `${C[recipe]}` unguarded in `prune` (l.601), `link_shared` (l.1359), `import_release` (l.1461, 1488), `cmd_destroy` (l.2041), `job_dir` (l.2405); `${C[recipe]:-}` everywhere else | Under `set -u` a truncated app.conf (fault g4) aborts mid-prune or mid-destroy instead of using the default. | [read] | Use `${C[recipe]:-node}` (the value configure defaults to). |
| C1 | cleanup | lib/common.sh:`conf_load` (l.212), `trim` (l.210) | `trim` forks a subshell plus `sed` twice per line, and `cmd_deploy` parses tando.conf twice (`conf_load`, then again in `resolve`). | **[ran]** 10× `conf_load` on an 8-line file: 92 ms per call. A deploy run made 35 `sed` execs. | `trim() { local s=${1#"${1%%[![:space:]]*}"}; TRIM=${s%"${s##*[![:space:]]}"}; }` (no fork, tested). Skip the second load in `resolve` when `C_app` is set. |
| C2 | cleanup | lib/args.sh:`is_cmd`/`known_cmds`/`spec_has`/`spec` | Each command start runs ~11 `grep` and ~5 `awk` over help.txt (34 ms `is_cmd` + 30 ms `check_args`, measured). | **[ran]** | One `awk` pass at start-up that prints `cmd<TAB>flags<TAB>args<TAB>subs` for all sections into a bash 3.2 array. |
| C3 | cleanup | `agent_raw` (common.sh:308), `watch_raw` (cmd-alerts.sh:12), `gate_admin` (cmd-ci.sh:93), `lx_ssh` (cmd-logx.sh:58), plus raw `ssh` at bin/tando:317, 326 and cmd-requests.sh:129 | Four ssh+strip+error wrappers. Only `agent_raw` runs `ssh_explain`, so the alerts and CI paths print raw ssh errors. | [read] | `remote BIN [sudo] verb args…` (argument whitelist, strip, `ssh_explain`, `agent_msgs`). `agent_raw` = `remote tando-agent`. ~60 lines saved. |
| C4 | cleanup | `install_bin` (bin/tando:50), cmd-alerts.sh:151, cmd-adopt.sh:48, cmd-ci.sh:101 | Four copies of the `install -d … tee X.new … mv` remote snippet. | [read] | Keep `install_bin` in common.sh. ~40 lines. |
| C5 | cleanup | lib/views.sh:`local_time`, `ago`, `when`; cmd-audit.sh:`au_when`; cmd-requests.sh:`rq_when`; cmd-top.sh:`top_ago`; cmd-logx.sh:`lx_time` | Six time formatters, each with its own `date -r`/`date -d` fallback. | [read] | One `fmt_time epoch [style]` in views.sh. ~45 lines. |
| C6 | cleanup | bin/tando:`client_version` (l.70) vs lib/deploy.sh:`version_notice` (l.77) | Two VERSION readers; `version_notice` skips the validation. | [read] | Use `client_version`. |
| C7 | cleanup | lib/deploy.sh:`do_deploy` (136 lines) | It mixes pre-checks, build, stage, upload, polling and the result box. | [read] | Split into `deploy_precheck`, `deploy_build`, `deploy_follow`, `deploy_report`, with no change in behaviour. |
| C8 | cleanup | `node_major` called up to 3× in `runtimes` (deploy.sh:61, 67-68) | Each call runs tr, sed and grep on package.json. | [read] | Compute it once. |
| C9 | cleanup | bin/tando:`cmd_host` setup (66 lines) | Whitelist parsing, the progress box and the summary box in one `case` arm. | [read] | `host_setup_args`, `host_setup_summary`. |
| C10 | cleanup | lib/ui.sh: `_ui_table` (135 lines) plus `ui_table`/`ui_table_a`/`ui_table_lines`; `ui_flow` and `ui_flow_v`; `ui_box_line` and `ui_box_line_v` | Paired `x`/`x_v` functions are kept for every primitive, although almost every caller could use the `_v` form. | [read] | Keep only the `_v` forms plus a generic `ui_out fn args` that prints `UI_RET`. ~120 lines. |

### Server/tando-agent portability checks run on uutils 0.10 (all passed) [ran]
- `date -d '-5 sec'`
- `date -d "Feb  9 12:00:00 2027 GMT" +%s` (cert_expiry)
- `mv -Tf`
- `du -sbc` with hard links: counted once
- `stat -c %U`
- `df -Pk`
- `find -printf` (findutils, still GNU)

No uutils incompatibility was found in tando-agent.

## S. Findings: server helper programs (tando-watch, tando-logs, tando-metrics, tando-gate, tando-adopt) and one agent bug they share

The helper reviewer ran snippets in `tando-review`. The scripts are in `test/.work-review/server/`. I re-ran S-B3 end to end.

**Note on function sizes.** The task listed `cmd_valid` (168) and `cmd_log_stats` (135) as long functions. In this snapshot they are 1 and 9 lines; that count included the awk programs between them. The real long ones are:
- `adopt_scan` 300
- `cmd_run` 261
- `cmd_adopt_run` 162
- `cmd_logs` 88
- agent `cmd_setup`/`cmd_configure`/`cmd_doctor` ~140 each

| id | sev | file:function (line) | what | evidence | fix |
|---|---|---|---|---|---|
| S-B3 | **bug, critical** | server/tando-agent:`cmd_destroy` (l.2020-2035); tando-adopt:`adopt_restore` (l.565-568), `fingerprint` (l.442), `cmd_adopt_status` (l.784) | Globs `tando-$A-*` also match **other apps whose name starts with `$A-`**. `tando destroy hello` stops and kills `tando-hello-2.service` and deletes its unit file. Adopt undo does the same. | **[ran]** Deployed `hello` and `hello-2` and both were live. `tando destroy --yes --purge` in `hello` → `tando-hello-2` is **inactive**, its unit file is gone, and `hello-2.localhost` answers **502**. | Name the units exactly: `tando-$A.service`, `tando-$A-pre-*`/`-act-*` only with an id pattern (`tando-$A-pre-[0-9]*`), `tando-$A-job-<name>` from `C[jobs]`, as tando-logs:`app_units` already does. Because app names may contain `-`, no glob of the form `tando-$A-*` is ever safe. |
| S-B1 | bug | tando-watch:`memstat` (l.283) | The loop stops at `file`, but cgroup v2 lists `shmem` after `file`. The memory alert ignores shmem (tmpfs, `/dev/shm`). | [ran] anon 100 MB + shmem 400 MB → `MEM=100000000` | `anon) MEM+=v;; shmem) MEM+=v; break;;` |
| S-B2 | bug | tando-watch:`cmd_set` (l.1058), `cfgv` (l.127); tando-logs:`valid` (l.59), `hours`/`bytes`, `cmd_log_doctor` (l.852); tando-gate:`limits` (l.76) | Settings with a leading zero (`08`, `09d`) are accepted, then fail as octal. Effects: a check never fires (`down_after=08`), `roll_keep_for h` is written into every Caddy site (Caddy 2.11 rejects the config), and log-doctor aborts. | [ran] all three | Normalise with `$((10#$v))` on input and on read. |
| S-B4 | bug | tando-gate (`set -f` at l.23): `end_sessions` (l.314), `admin_install` (l.553) | With globbing off, `user-$uid.slice/*/` and `"$CI"/*/keys` stay literal: `cgroup.kill` never runs, and existing deploy users are never refreshed. | [ran] | Use `set +f` around the two globs, or `compgen -G`. |
| S-B5 | bug | tando-watch:`watch_rows` (l.928); tando-adopt:`timer_resume` (l.496) | `date -d` on systemd's local-zone timestamps (`… WIB`) fails, on uutils and GNU alike. `tando doctor` then says "no run yet" forever, so the dead-man check never fails. | [ran] uutils `date -d "Sat 2026-11-14 10:00:00 WIB"` fails | `systemctl show --timestamp=unix …`; `TZ=UTC systemd-analyze calendar`. |
| S-B6 | bug | tando-watch:`cmd_run` (l.332/360) | `caddy.service` is in the app unit list, so a Caddy OOM kill raises no alert. | [inferred] | Build `hostu` from app units only. |
| S-B7 | bug | tando-watch:`cmd_run` (l.333-347) | A failed or timed-out `systemctl show` leaves `U` empty, and "Caddy is not running" fires after one sample. | [inferred] | Check the call's status; hold the samples this run. |
| S-B8 | bug | tando-adopt:`rec_save` (l.449), `ap_result` (l.463) | The temp file is moved in even when writing it failed. A full disk replaces the adoption record that undo needs with an empty one. | [inferred] | `> "$tmp" && mv -f … \|\| die`. |
| S-B9 | bug | tando-adopt:`cmd_adopt_run` (l.699) | The pre-flight journal is read from the main journal, but the unit logs to `LogNamespace=tando-$A`, so the failure detail is always empty. | [inferred] | `--namespace=tando-$A`. |
| S-B10 | bug | tando-logs:`cmd_logs` (l.520) | `n=0` without follow prints the whole log. | [inferred] | Return early. |
| S-B11 | bug | tando-adopt:`adopt_scan` (l.352-356) | With no free port, adopt silently picks `port_max+1`. | [inferred] | `block`. |
| S-R1 | risk | tando-watch unit | `TimeoutStartSec=50` is less than the worst case (lock 30 s + `caddy validate` up to 30 s + health checks + serial TLS checks of 10 s per app). A run killed by the timeout saves no state, so it repeats. | [read] | Parallel cert check; save state after each phase. |
| S-R2 | risk | tando-logs `logs follow`, `req-tail follow` | They survive a client disconnect when the filter never matches, because the pipe is not written to. | [inferred] | Keepalive row every 30 s. |
| S-R3 | risk | Caddy 2.6.2 vs 2.11 | `skip_log` is deprecated on 2.11, `log_skip` is missing on 2.6.2, `output file { mode }` may need 2.8+, and `client_ip` needs 2.7+. Nothing in CI runs 2.6.2, although `TANDO_TEST_CADDY=ubuntu` exists. | [ran] on 2.11; 2.6.2 [inferred] | Add a Caddy 2.6.2 lane (`TANDO_TEST_CADDY=ubuntu test/e2e.sh`); choose directives by version. |
| S-R4 | risk | tando-logs:`audit_origin` (l.784) | `awk '{print $4}' /proc/$p/stat` misparses names that contain a space, and costs about 5 forks per ancestor on every mutating verb (about 35 forks). | [inferred] | Parse in bash after the last `) `. |
| S-R5..R8 | risk | adopt cron word-splitting with globbing (l.309); logs `app_stats` takes the newest 300k entries; watch `clean` can cut UTF-8 in half for notifiers; metrics run only as `ExecStartPre` of tando-watch, so `alerts disable` stops the graphs | | [read] | see the helper reviewer's notes in `test/.work-review/server/` |

**Portability (uutils 0.10, mawk, systemd 259): no other incompatibility found [ran].**
- Checked: `du -sB1/-sxb/--inodes`, `df --output`, `stat -c`, `od`, `tr` ranges, `paste -sd,`, `tail -F`, `touch -d @`, `date -d @`, mawk `strftime(fmt,t,1)` and `{n}`, `systemctl show --timestamp=unix`, `journalctl --output-fields`.
- uutils `cut -c` cuts bytes, so `audit_write` notes can end mid-character.

**Duplicated helpers.**
- `die` ×5, `valid_app` ×6 (same regex), `now` ×5, `load` ×4 (three reset policies), atomic write ×5. Of those five, only the agent's `save` cleans up and retries; adopt's does not check the write (S-B8).
- Four sanitising policies: watch `clean` (controls → space, 300), logs `row` (TAB only), gate `clean` (controls and C1 → ?, 160), agent `san_v`.

## T. Tests and lint

The test reviewer read every suite. Items I re-checked are marked [ran]/[read].

### Checks that cannot fail, or pass on errors

| id | sev | where | what | fix |
|---|---|---|---|---|
| T1 | **bug** | every e2e suite: `host add … --insecure-test` (e2e-bootstrap:33, e2e-adopt:84, e2e-alerts:123, e2e-ci:143, e2e-data:42 …) | The default trust path (known_hosts) is never exercised. That is why B1 and B2 shipped. [ran] | One suite (e2e-cli or e2e) registers with `--yes` and then deploys. |
| T2 | bug | test/e2e-faults.sh:30, test/e2e-sec2.sh:37, faults/lib-fault.sh:`f_fresh` (l.71-73) | Exit 2 counts as SKIP, and SKIP counts as success. `f_fresh` exits 2 when `up` or `deploy` fails, so a regression in deploy turns all fault scenarios into SKIP and the suite stays green. | Treat SKIP as failure unless `TANDO_ALLOW_SKIP=1`; `f_fresh` exits 1. |
| T3 | bug | negated ssh checks: e2e.sh 3d (l.110), 9c (l.322), 9d, 9e (l.335), 9f, 10b (l.356), 21b (l.184); e2e-bootstrap 3h (l.98); e2e-top 7f (l.303) | `! ssh … cmd` passes when ssh itself fails (255). Most of these are security assertions. | Assert the exact refusal (`rc=$?; [ $rc -ne 0 ] && [ $rc -ne 255 ]`) or grep the refusal text. |
| T4 | bug | test/e2e-ci.sh:295 (4j) | `… \| grep -q . ; test $? != 0` is inverted: it passes when the client never asked for agent forwarding. | Check the positive request first, then the refusal. |
| T5 | bug | test/e2e-alerts.sh:164 (3b) | `grep -q '^site.nr=' … \|\| true; curl …`: the watch-state assertion is discarded. | Drop `\|\| true`. |
| T6 | bug | test/ui-test.sh unit block (l.180-228) | Runs under `set -euo pipefail` in a child; the first helper that returns non-zero ends it silently, and empty output counts as "ok". | Run each unit check in its own subshell and compare its output to an expected value. |
| T7 | bug | test/lib.sh:`t_assert_width`, ui-test.sh:`check_widths`, `t_eq` | They pass on a missing or empty file, and `t_eq "" ""` passes. | `[ -s "$f" ] \|\| fail`. |
| T8 | bug | test/e2e-next.sh:89 | `shipped=$(isr_disk)` is never compared (the only real SC2034 among the baselined ones). | Assert that the shipped page is unchanged (`$shipped != $t2`). |
| T9 | risk | sec2/attacks/a16-devshm-shared.sh:16 | `[ "$n" -gt 400 ] && succeeded \|\| blocked`: an empty `n` reads as BLOCKED, i.e. PASS. The same pattern appears in a04:10, a05:18, a10:58 and f4:22. | `if`/`else`, and fail on a non-number. |
| T10 | risk | faults/lib-fault.sh:174 `wait_server … ; true` | The 90 s timeout is swallowed. | Remove `; true`. |

### Other test findings

**UI text instead of behaviour.** About 70 of ~430 checks grep only CLI output. The worst are those tied to glyph positions and step numbers:
- `e2e-bootstrap:38` `"✓ 2/8  packages"`
- `e2e.sh:363` `"✗ 2/7  stage"`
- `e2e.sh:449` counting `"╭─ tando ls"`
- `e2e-next.sh:44` (exact sentence with double spaces)
- `faults/g5:12` `"● ok"`

Assert `--json` output, server state or the exit code instead. `TANDO_ASCII=1 TANDO_COLOR=never` at least removes the glyph coupling.

**Sleeps standing in for conditions.** About 25 places. Examples:
- `e2e-next:143` and `e2e-recipes:194` `sleep 3` before `deploy-status`: poll `result != running`.
- `e2e-ci:287,291,501,538`: poll for the file in incoming/.
- `e2e-logs:348-354`: the reconnect test.
- `e2e-alerts:194,227`: poll NRestarts and the OOM marker.
- `e2e.sh:197,294`.

These suites wait on the real clock: `e2e-alerts` (62/121/240 s, the timer), `e2e-logs` (31/61 s) and `e2e-adopt` (60–75 s). `e2e-alerts` 21b's own comment says it fails one run in three. Give tando-watch a `run --now` verb for tests instead of waiting for the timer.

**Coupling between suites.**
- `test/all.sh` cannot run with its defaults: 12 parameterised suites need 12 slots, `NSLOTS` defaults to 4, and line 141 exits 2. RELEASING.md uses it as the release gate.
- `e2e-adopt` is never run by all.sh, because its usage comment (l.15) makes it "pinned".
- `TANDO_TEST_OWNED=1` is exported for containers all.sh did not create.
- `pkill -f "tando status --watch"` (`e2e.sh:294`) kills the user's own processes.
- `sec2/*` hard-codes `/Users/<name>/…`.

**No test at all for:**
- commands: `env import`, `db psql`, `host rm`, `domain ls`, `version` against a real agent, `alerts disable/history`, `adopt status`
- flags: `--json` on releases/history/ls, `ls --watch`, `destroy/up/deploy --yes`, `domain add --wait`, `--www serve`, `requests errors --4xx`, `adopt --no-jobs`
- the trusted-host path (T1)

`jobs` is run (`e2e.sh:358`) but nothing is asserted.

**test/lib.sh is mostly unused.** `t_until`, `t_loop_*`, `t_assert_width` and `t_free_ports` have no callers. Seven suites define their own `check`/`until_`. Moving them all onto lib.sh removes ~300 test lines.

### Lint gate

Ran: `test/lint.sh --all` on the snapshot, with shellcheck from Docker. 65 s; 0 new findings.

**The baseline holds 805 entries, not 364.**
- 431 are RL08 (line length).
- 638 are in test files.
- 110 are errors.
- 374 are non-RL08, which is probably where "364" came from.

**How entries match.** By file, code and normalised line text, as a multiset.
- Line drift does not matter.
- Identical lines share a count, so after one copy is fixed a new copy is hidden. Example: `e2e.sh SC2164 cd "$W/hello"` ×2.
- Stale entries are never reported, so the baseline only grows.

**lint.sh semantics.**
- shellcheck `warning` is mapped to `error`.
- `info` never fails, even with `--strict`.
- `--all` and `--strict` share one `mode` variable (the last one wins).
- RL12 (completions) is `warn`, so it never fails.

**Baseline entries that are actual bugs or hide bugs:**

Product files: none of the 22 "error" entries is a real bug.
- SC1010 (agent l.631, 642, 1394, 1589, 1606): `pg phase done …`, where `done` is a word, not the keyword.
- SC2178/2179/2128 (agent l.75, 2208; watch l.60, 174-179, 433-439, 762-765): `local -n` namerefs, and a name used as an array in one function and as a string in another.

The following entries do matter:
- **cmd-ci.sh:33-38 SC2329 "never invoked"**: six functions defined inside `ci_usage`. They are dead if not reached through `ci_key_ui`. Verify, then delete.
- **cmd-top.sh:375, 450 SC2153 `UI_RED`/`UI_ROWS`**: fine today (set in ui.sh). Add them to a `# shellcheck source=` chain instead of baselining them.
- **cmd-alerts.sh:97 SC2015 and agent l.1474, 1554, 1867, 2265; gate l.146-153, 272, 285, 425, 468**: `A && B || C`. I checked each `C` arm: harmless, except gate l.146-153 (let the server reviewer's table decide).

Test files:
- SC2164 `cd` without `|| exit`: e2e-data.sh:38, e2e-next.sh:64, e2e.sh:69, 310, 339. If the cd fails, `npm ci` and `tando up` run in the caller's directory.
- RL05 `rm -rf "$W/…"`: e2e-adopt.sh:45, replica/up.sh:26, sec2/setup.sh:7 (`${W:?}` costs nothing).
- SC2034 e2e-next.sh:89 (T8).
- SC2015 a16:16 (T9).

**False positives that inflate the baseline.**
- RL03 fires on `. "$(dirname "$0")/lib.sh"`: 63 of 81 entries.
- RL09 does not follow sourced files: 78 entries in faults/*.

Fix these two rules in lint.pl and drop RL08 to `info` (or wrap the 431 lines). The baseline then falls from 805 to under 120, and a reviewer can read every entry.

## D. Docs vs code

The docs reviewer checked everything with the client running under `/bin/bash` 3.2 and grep; I re-checked items 1, 3 and 9.

**Mismatches**
1. **help.txt `requests default=summary`, `alerts default=show`** (B6).
2. **help.txt `@@ logs`: "--release ID: the output of that release's start test".** The code (tando-logs:`release_ranges`, l.463) returns the logs from the time that release was current. The start test is `--deploy`. LOGGING.md:90 is right.
3. **docs/TOP.md:3 `tando top [host] [-n seconds]`.** `top -n 5` → "top does not take -n"; the flag is `--watch N`.
4. **MIGRATION.md:89-91: "the import line is the only change to the Caddyfile, ever".** False: `caddy_admin_private` (agent l.719-741) rewrites the global options block (`admin unix//run/caddy/admin.sock`) and **restarts** Caddy. This matters for the production migration runbook.
5. **MONITORING.md:37-38: Caddy holds requests "up to 30 s".** The code holds `HOLD=15s` (agent l.18), raised to `health_timeout` (l.412).
6. **LOGGING.md "Known weaknesses" (~l.277-283).** It says port-carrying Hosts are served unlogged (the code answers 400) and that the probe is filtered by User-Agent (it is the root-only `X-Tando-Probe` header).
7. **CI.md.**
   - l.190: the admin rsync path is now `tando-gate admin receive`.
   - l.204: "no disk quota" — the gate enforces `ci_max_mb/ci_max_files/ci_max_file_mb`.
   - l.95, 105, 224: still say "with the integration patch".
8. **README:103 "Flags may come before the command".** Only `-a -H --json --yes --force -h --version` may (`main`'s pre-loop).
9. **completions/gen.sh.**
   - Its flag regex (l.72) drops `logs -E` and `requests --4xx`.
   - `alerts` completes `rm`/`ls` as top-level subcommands, and `notifiers` is missing.
   - `-a` is offered to commands that refuse it: up, init, top, host, ls, doctor, version, recipes, help, adopt.
   - `gen.sh --check` passes because it checks the generator, not the result.
10. **MIGRATION.md:87.** The sslip name is `<ip-with-dashes>.sslip.io`, and it is used only for a public IPv4 (`public_ip`).

**Undocumented**
- tando.conf keys: `build_memory` and `dockerfile` (in no doc); `log_max/log_keep/log_rate/access_log` (only in LOGGING.md). README:121 says "every key".
- host settings: `unit_drop`, `ci_max_mb`, `ci_max_files`, `ci_max_file_mb`, `app_max_mb`.
- flags: `ci github --env`, `logs -E`, `host add --yes/--deploy/--insecure-test` (not in usage), `deploy -a`, `alerts notifiers`.
- env vars: `TANDO_COLOR`, `TANDO_TOP_MAX_W`, `TANDO_TOP_KEEP`, `TANDO_FETCH`, `TANDO_SHA`, `TANDO_METRICS_DIR`; `TANDO_CONFIG_DIR` (not in README).
- tando-watch `forget` is missing from MONITORING.md.
- README:7 omits the perl requirement (`clock`, `public_ip`).

**Stale**
- RELEASING.md:66-81 "What the integrator needs to wire": all four items are done.
- TOP.md:73 (metrics timer: now an `ExecStartPre` of tando-watch.service) and TOP.md:85 (status already reads metrics).
- LOGGING.md:9-10 and :320-357 "Integration".
- CI.md:180-200 "Integration".
- README:35-43 sample output says Caddy 2.6.2 for the same box that LOGGING.md says runs 2.11.9.

**docs/*.patch**: all six are **already applied**. None applies cleanly in either direction, because the code was refactored after the patches were taken. Status was judged line by line:

| patch | status |
|---|---|
| adopt-integration | applied (67/78 added lines verbatim, the rest reworded) |
| alerts-integration | applied (reworded) |
| ci-integration | applied (19/19 agent hunks); its `upload_as` line was later replaced by ci-security |
| ci-security | applied (`patch -R --dry-run` is clean) |
| logs-integration | applied (refactored) |
| top-integration | superseded: the metrics timer became `ExecStartPre` of tando-watch |

**Delete all six (~2.1k lines of docs) and the "Integration" sections that describe them.**

## Simplification plan

Base: the shell code that ships is about 12.0k lines: bin, lib, server, install/uninstall, scripts, completions. The estimates below are deliberately conservative. "Feature loss: none" holds for every item.

| # | item | functions involved → replacement | lines saved |
|---|---|---|---|
| P-1 | Shared server library `/opt/tando/lib/common.sh`, installed by `install_agent` | `die`, `need_root`, `valid_app`, `valid_id`, `now`, `san_v`, `row`, `load` (fixed per B4), `save`/`atomic` (the agent's version), `int` (`10#`), `wlock` — from tando-agent, -watch, -logs, -gate, -metrics, -adopt. It also fixes B4, S-B2 and S-B8 in one place. | 150–200 |
| P-2 | One client remote call | `agent_raw`, `watch_raw`, `gate_admin`, `lx_ssh` and the raw ssh in `cmd_backup` pull and `cmd_requests` tail → `remote BIN [sudo] verb args`, with one argument whitelist, strip, `ssh_explain` and `agent_msgs` | 60–80 |
| P-3 | One `install_bin` | bin/tando:`install_bin`, cmd-alerts.sh:151, cmd-adopt.sh:48, cmd-ci.sh:101 | 40 |
| P-4 | One time formatter | `local_time`, `ago`, `when`, `au_when`, `rq_when`, `top_ago`, `lx_time` → `fmt_time epoch rel\|short\|full` | 45 |
| P-5 | ui.sh keeps only the `_v` API | Drop the printing twins (`ui_bar`, `ui_meter`, `ui_spark`, `ui_badge`, `ui_dur`, `ui_bytes`, `ui_table_lines`, `ui_flow`) behind one `ui_print fn args`. Fold `ui_table`/`ui_table_a`/`ui_table_lines` into `_ui_table`. | 100–140 |
| P-6 | `tando top` reuses the views row builders | `top_apps_rows`, `top_detail_lines` (114 lines), `top_host_frags` duplicate `render_status`/`render_ls`/`host_line`. Build rows once in views.sh (`status_rows`, `ls_rows` filling arrays) and draw them in both. | 150–250 |
| P-7 | Merge tando-metrics into tando-watch | `cmd_sample` duplicates the `systemctl show` parse that `cmd_run` already does; keep `tando-metrics read` as a verb of tando-watch | 80 |
| P-8 | tando-watch `cmd_run` | Split out `check_app`, `check_caddy`, `health_batch`, plus a `thresh key app check value limit need det` helper for disk, inodes, swap, load, memory, backup and TLS | 35–60 |
| P-9 | tando-adopt | `adopt_scan` → `scan_*` steps plus a table of plan rows; `cmd_adopt_run` → a `step` helper; one `systemctl show -p A,B,…` instead of ~25 `sp` calls | 70–100 |
| P-10 | tando-logs awk | `hexval`/`cpdisp`/`unesc` are copied in `AWK_JOURNAL` and `AWK_REQLIB` → one `AWK_TEXT` | 35 |
| P-11 | args.sh one-pass parse | `spec_has`, `spec`, `help_usage`, `known_cmds`, `is_cmd` → one awk at start-up filling arrays | 30 |
| P-12 | Dead code | cmd-ci.sh l.33-38 (six functions never invoked, SC2329); bin/tando `cmd_deploy`'s duplicate `conf_load`; `version_notice`'s own VERSION read (C6); unused test/lib.sh helpers (tests) | 20 (+60 tests) |
| P-13 | Generated completions | `completions/_tando` and `tando.bash` are output of `gen.sh`. Generate them at install/release time instead of committing them (fixing gen.sh per D-9). | 213 |
| P-14 | agent `cmd_setup`/`cmd_doctor`/`cmd_configure` (~140 each) | `cmd_configure`: a table `key → regex → message` replaces 30 `case` arms. `cmd_doctor`: one `check name cmd…` helper. | 80–120 |
| P-15 | Docs (not counted in product lines) | Delete docs/*.patch (860 lines) and the "Integration" sections in LOGGING.md, CI.md, RELEASING.md and TOP.md; merge PROTOTYPE.md, SPEC-v1.md, SPEC-v2.md and REVIEW*.md into an `archive/` folder or delete them | 1.4k doc lines |

**Total for P-1..P-14: about 1.1k–1.5k lines, 9–12% of the product.** Adding P-6 at its upper end and P-13 gives 15%.

Reaching 20–25% needs two structural moves:
- **(a)** One server program with sourced modules (`tando-agent` + `lib/{watch,logs,gate,adopt}.sh`), so arg dispatch, usage, locking and state helpers exist once. Estimate 400–600 more lines.
- **(b)** The client's boxed renderers built from data tables (field list → `ui_kv`/`ui_table`) instead of hand-written `render_*` per view. Estimate 300 more.

Both are larger refactors and should come after the top 15 below.

## Performance

Measured on: MacBook (arm64, macOS bash 3.2) → `tando-review` container on the same machine. The ssh RTT is about 1 ms. With ControlMaster off, a bare `ssh true` takes 49 ms; with it on, about 10 ms. A real 1 vCPU VPS is roughly 3–4× slower per fork and per bash start than this box.

| # | where | now | proposal | expected saving | how to measure |
|---|---|---|---|---|---|
| F-1 | client start-up: `conf_load`→`trim` | 92 ms per `conf_load` (8-line file) **[ran]**. Runs twice in `deploy` (`cmd_deploy` and `resolve`). | Fork-free `trim` (tested on bash 3.2); parse once | −90 ms on every command in a project, −180 ms per deploy | `tando releases`, 5 runs: 287 ms now **[ran]** |
| F-2 | client start-up: `is_cmd`, `check_args`, `spec_has` greps | 34 + 30 ms **[ran]**; `help` with no network takes 104 ms | One awk pass (P-11) | −50 ms per command | Exec counts with the PATH shims in `test/.work-review/shim` (`mkshim.sh`): `status` 56 execs, of them sed 17 and grep 12. Target: under 15. |
| F-3 | deploy: polling `deploy-status` every 0.5 s | Each poll is an ssh mux round trip + sudo + a parse of the 2.5k-line agent: 26 ms server CPU on this box **[ran]**. With soak 30 s that is about 70 polls, so ≈2 s here and an estimated 5–7 s of CPU on a 1 vCPU VPS. That load lands exactly while the new release starts and is checked. | `deploy-status --follow`: one ssh, one agent process that prints a line when `activation` changes (poll the file mtime at 0.5 s inside that one process) | −95% of the poll CPU; fewer false "slow start" failures on small boxes | Server: `systemd-cgtop`/`CPUUsageNSec` of `user-1000.slice` during a deploy; client: count `ssh` in the shim log (13 in a soak=2 deploy **[ran]**) |
| F-4 | deploy: ssh round trips before the upload | `info`, `configure check`, `configure`, `begin`, then rsync, then `activate` **[ran]** | `configure check` returns the `info` fields; `configure` takes the lease (`begin`) in the same call | −2 round trips plus 2 sudo+agent starts: ≈0.2–0.4 s on a 100–150 ms link | Time the phases (`tando deploy` prints them) on a remote VPS |
| F-5 | deploy behind a soaking deploy | Blocks silently in `configure check` for up to 120 s (R2) **[ran]** | Say it is waiting; or let the upload proceed and queue the activation (the code already supports a queued state) | UX: a second deploy no longer looks hung | |
| F-6 | `tando status`/`ls` | 56/53 execs, about 390 ms **[ran]** | F-1 + F-2; `ago`/`when` already fork-free; drop 2 `date` | ≈ −150 ms per call (≈40%) | the loop timing above |
| F-7 | `tando top` / `status --watch 2` | One ssh + `sudo tando-agent status` per host every 2 s. A non-sudo status call is about 60 ms CPU on this box **[ran, 5 calls 0.30 s]**: ≈1.8 s of CPU per minute per watcher here, ≈5–9% of a 1 vCPU VPS. | `status --stream N`: one long-lived ssh per host, server-side loop, reusing loaded state; or top refreshes metrics every 2 s and full status every 10 s | −80–90% of server CPU while top is open | `CPUUsageNSec` of the ssh session's scope |
| F-8 | tando-watch every minute | 65 ms CPU per run with 1 app (`CPUUsageNSec` of tando-watch.service) **[ran]**. Per run: ≈19 forks + 2 per app + a separate tando-metrics bash; at 10 apps ≈40 forks/min [read]. | `EPOCHSECONDS`; nameref `evcount`/`ncpu`/`boot_time`; load app.conf once; merge metrics (P-7) | ≈ −60% forks; ≈ −30 ms/run here | Compare `systemctl show tando-watch -P CPUUsageNSec` before/after over 10 runs |
| F-9 | tando-gate `receive_confined` | Two `du` walks every 0.5 s: 41 ms per pair at 20k files, ≈8% CPU; near the 200k-file cap ≈0.4 s per pair, about one core **[ran]** | One `find -xdev -printf '%s\n' \| awk` walk (15 ms); back off to 2 s after 30 s | −60–90% CPU during CI uploads | time both commands on a 20k-file tree |
| F-10 | tando-logs `audit-write` | ≈35 forks per mutating verb [read] | Parse in bash (S-R4) | −30 forks on every deploy, env, restart… | shim the server PATH, or `strace -fc` |
| F-11 | tando-adopt scan | ≈25 `systemctl show` forks per unit; `tar -tzf` per data entry | One `systemctl show -p …`; list the tar once | seconds → under 1 s per plan on a slow box | `time tando adopt plan` |

## Top 15 fixes, ranked by value for effort

| rank | id | fix | effort |
|---|---|---|---|
| 1 | B2 | `GlobalKnownHostsFile=$CFG/known_hosts` instead of the two-path `UserKnownHostsFile` (common.sh:`host_use`). Every deploy to a trusted host works again (verified). | 1 line |
| 2 | B1 | `host_use "$HOST"` after saving the key in `host_trust` | 1 line |
| 3 | S-B3 | Exact unit names in agent `cmd_destroy` and adopt `adopt_restore`/`fingerprint`/`cmd_adopt_status`. Today destroying `hello` takes down `hello-2` (verified). | ~20 lines |
| 4 | T1 | One e2e path that registers a host **without** `--insecure-test` and deploys. This would have caught B1 and B2. | ~10 lines |
| 5 | B3 | `watch_do` never on the right of a pipe (alerts heartbeat, notifier add, set) | ~6 lines |
| 6 | S-B2 | `10#` normalisation of numeric settings in watch, logs and gate. Today a leading zero can break every Caddy site config. | ~10 lines |
| 7 | B4 | Line-based `load`/`kv_read`/`host_get`/configure parsing (no `IFS='='` read) | ~15 lines |
| 8 | T2, T3 | SKIP is no longer success in faults/sec2; negated ssh checks must see a real refusal, not exit 255 | ~30 lines |
| 9 | S-B4, S-B5, S-B1 | Gate `set -f` globs; `--timestamp=unix`; `memstat` shmem | ~10 lines |
| 10 | F-1, F-2 | Fork-free `trim`, one `conf_load`, one-pass `help.txt` parse: −150 ms per command, about −40% on `status`/`ls` | ~40 lines |
| 11 | R1 | `cmd_activate` seq: `\|\| die`, or keep the counter under the lease lock | 1–5 lines |
| 12 | D | Delete docs/*.patch and the "Integration"/"to wire" sections; fix help.txt (`--release` text, `summary=`/`show=`), TOP.md `-n`, MIGRATION.md Caddyfile claim, MONITORING.md 30 s → 15 s | docs only |
| 13 | lint | Fix the RL03 (sourcing lib.sh) and RL09 (sourced `set -u`) false positives, make RL08 `info`, rebuild the baseline (805 → about 120), make `--strict` fail on warnings | ~30 lines lint.pl |
| 14 | F-3 | `deploy-status --follow`: one ssh and one agent process per deploy instead of about 70 | ~40 lines |
| 15 | P-1 | Shared server library; it carries fixes 6 and 7 once instead of six times | ~200 lines net removed |

## What I ran

- **Setup:** `test/server/up.sh` as `tando-review` on ports 2276/8376, from the snapshot copy; `host setup`; 6 deploys, including two overlapping ones; `destroy`.
- **Lint:** `test/lint.sh --all`, 65 s, 0 new findings, 805 in the baseline.
- **Client:** exec-count shims; timings of help, releases, status, ls, history, conf_load, is_cmd, check_args.
- **bash behaviour:** bash 3.2 and 5.3 `IFS='=' read`; `set -u` empty-slice checks.
- **uutils / Caddy / systemd:** the date/mv/du/find checks listed in section 1.
- **Reproductions:** B1, B2 and its fix, B3, B4, S-B3; the R1 attempt.
- **Helper reviewers:** they ran the snippets marked [ran] in sections S, T and D.

Not run: `test/all.sh`. It needs 12 server slots (see T), and the permission check refused it for the test reviewer.

Scratch files: `test/.work-review/` (tree, fixed, shim, r1, server, tests, docs). The `tando-review` container was removed at the end.
