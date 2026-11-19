# Working on tando: which tests to run

For coding agents and people. This page says what to run and when; the details of every suite
are in [docs/TESTING.md](docs/TESTING.md). Everything runs locally: CI on GitHub is two small jobs per push (checks and a smoke deploy) and is not
where changes are tested. Server suites need Docker
(each gets its own throwaway Ubuntu container); nothing here touches a real server.

## The loop

| When | Run | Takes | What it tells you |
|---|---|---|---|
| After every edit | `test/check.sh` | seconds | The changed files parse (bash 3.2 and the server's bash), lint is clean on them, the changed Go packages vet and pass, no secret or private detail is in the tree, the suite map knows the change. |
| Before you say a change works | `test/all.sh --tier quick` | minutes | The suites the changed files can break (it prints which, from `test/suites.map`) plus one smoke deploy. |
| Before a push to main, a tag, or when quick said "every suite" | `test/all.sh` (the full tier) | see docs/TESTING.md | Every suite, nothing cached, the fault scenarios in four parallel shards. |
| After a failure | `test/all.sh --failed` | the failed suites | Only what failed in the last run. Fix, then rerun this, then the tier you were in. |
| When the owner asks, or the machine is free | `--tier nightly`, `--tier weekly` | long | The fault scenarios in longer chains (order matters there), weekly with the long soak everywhere. |

`test/check.sh` passing proves little: it finds typos. Do not report a change as tested on it alone.

## Reading results

- Summary box at the end; logs in `.tando/all/latest/<suite>.log`. Every check is one line:
  `PASS <id> <text>`, `FAIL <id> <text>` or `SKIP <id> <text>`. Start from the first `FAIL`, and
  read the lines above it: suites print what the server said on stderr into the same log.
- `test/all.sh --slow` shows where the last run's time went (longest waits between two checks).
- A suite that failed because the test server could not be built or could not install a package
  (apt, network) did not test your change: rerun it (`--failed`) before drawing a conclusion,
  and say so in your report.
- Report what you ran and what it printed: the tier, the pass and fail counts, and the id and
  text of anything that failed or was skipped. "Should pass" is not a result.

## Picking suites by hand

`test/all.sh --only e2e,e2e-next` runs the named suites whatever the tier. One suite on its own
server: `TANDO_TEST_NAME=tando-x1 TANDO_TEST_SSH_PORT=2391 TANDO_TEST_HTTP_PORT=8391
TANDO_TEST_OWNED=1 T_WORK=$PWD/test/.x1 test/e2e-next.sh` (pick a name and ports nothing else
uses; `test/server/down.sh` with the same `TANDO_TEST_NAME` removes it).

| You changed | Suites that exercise it |
|---|---|
| `lib/ui.sh`, `lib/help.txt`, `completions/`, any `lib/cmd-*.sh` | `ui-test`, `e2e-cli`, and the command's own suite (`test/suites.map` lists them) |
| `lib/deploy.sh`, `lib/common.sh`, `lib/build.sh`, `bin/tando`, `server/tando-agent` | everything: use the full tier |
| `server/tando-adopt`, `lib/cmd-adopt.sh` | `ui-test` (the Caddyfile scan and edit on fixtures), `e2e-ci` (it must parse). No suite here adopts a real app: say that the adopt path itself was not exercised. |
| `srv/<package>` | `go`, and the suite of that package's feature: watch, hostcare → the alerts suites and `e2e-host`; logs → `e2e-logs`; offsite → `e2e-offsite`; status, metrics → `e2e-status`, `e2e-top`; gate → `e2e-ci`, `e2e-sec2`. `srv/internal`, `srv/daemon`, `srv/cmd`: everything. |
| Next.js handling (`recipe = next`, sharp, the image pre-flight) | `e2e-next` |
| backups, restore | `e2e-data`, `e2e-offsite` |
| anything about failure handling in a deploy | `e2e`, and the fault shards `e2e-faults-q1` to `q4` |
| a test suite | that suite, and `lint` |
| docs only | `lint`, `ui-test`, `e2e-cli`, `install-test` (they check that docs, help and commands agree) |

The map is a shortcut. When you are not sure what a change can reach, run the full tier.

## Rules that keep the tests honest

- Never weaken or delete a check to get a pass. A check that is wrong is fixed in its own change,
  with the reason.
- A wait that proves something did not happen (still healthy after N seconds, a grace period, a
  real timer) stays a wait. A wait for something to happen is a poll (`t_until` in test/lib.sh).
- New behaviour gets a check that fails without it. Say whether you saw it fail first.
- The laptop side (`bin/`, `lib/`, `test/`, `scripts/`, `install.sh`) must run under macOS
  `/bin/bash` 3.2: no associative arrays, no `[[ -v ]]`, no `${var,,}`. `server/` runs under the
  server's bash 5 but must still parse under 3.2 (`test/check.sh` checks both).
- When a suite starts depending on another part of the tree, add the rule to `test/suites.map`.
  A new suite file is picked up by name (`test/e2e-<name>.sh`); give it `t_init <name>` so it takes
  its server from the environment (docs/TESTING.md, "Conventions for a suite").
- One `test/all.sh` at a time per machine user (it holds a lock). To run suites beside it, give
  them their own server name and ports as shown above; never reset or remove a container you did
  not start.
- This repository is public. No real server addresses, domains, user names, home paths, keys or
  e-mail addresses in code, tests, logs you paste, or docs: `scripts/secret-scan.sh` (part of
  `test/check.sh`) must stay clean.

## What is not covered locally

Say so when your change touches one of these; do not imply it was tested.

- `tando adopt apply` and `undo` on a hand-deployed app (rehearsed on a private replica and run once
  on a real server; see docs/MIGRATION.md).
- A real x86-64 server, real DNS and public certificates, a real reboot, offsite backup against a
  real bucket (docs/STATUS.md lists what was verified where and when).
