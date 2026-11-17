# Adversarial review and feasibility study of SPEC.md (draft 2)

13 Nov 2026. Review by an independent reader who saw only the spec and the two existing scripts.
"Checked" means confirmed on the laptop or the VM the same day; "estimate" means nobody measured it.

## Verdict

Not feasible as scoped. The deploy core is sound and mostly exists. Two things are wrong at design level:

1. The security model does not hold: the `deploy` user, a CI key and a second app owner are all
   root-equivalent as written (findings 1 to 3, 6, 7).
2. The line budgets are off by about 2x, and the interactive dashboard is the main cause (17 to 19).

## Findings

| # | Sev | Finding | Fix | Status |
|---|---|---|---|---|
| 1 | critical | `deploy` may call any agent verb, including `provision`, which sets root hooks, the unit and the run-as user | Separate admin login for provision/setup/agent install; sudoers lists exact verbs; never accept a unit from a repo | by design reading |
| 2 | critical | No per-app boundary: any key can upload to `/opt/*/incoming` and activate any app, gaining its secrets and data | One key per app and source, app pinned server-side in `authorized_keys` | by design reading |
| 3 | critical | Root copies and chowns trees writable by `deploy` or by the app user (symlinks, swaps during copy, carried image cache) | Copy unprivileged; reject anything not a regular file or directory; `chown -h`; cache outside the release | hardlink/symlink sysctls are on (checked); the rest stands |
| 4 | high | ssh drop or Ctrl-C mid-activate leaves an unverified release live, no rollback, no history line | Run activate detached (`systemd-run --wait --pipe`), state file, recover step before any mutating verb | by design reading |
| 5 | high | Upload happens outside the lock into one shared `incoming/`; two deploys mix files | `incoming/<id>/` with `--link-dest`, manifest hash verified by activate | by design reading |
| 6 | high | Hand-written restricted-key command parsing rsync is unsafe; also a second installed file | `rrsync -wo` per app | `rrsync` present on VM (checked) |
| 7 | high | `logs` passthrough can read any unit as root or start a pager as root | Agent builds argv itself, strict patterns, `--no-pager`, unit from registry only | by design reading |
| 8 | high | Laptop parses server output; `eval`-style parsing or raw escape sequences attack the laptop | Fixed key whitelist with `case`, strip control characters, agent validates history fields | by design reading |
| 9 | high | Pre-push hook builds the working tree not the pushed commit, deploys before the push can fail, blocks the push | Cut the hook, or build from a worktree of the pushed sha and refuse dirty trees | by design reading |
| 10 | high | bakery has no git repo of its own, so release ids, dirty flag and both auto-deploy paths do not apply | Give bakery its own repo first, or make the id git-independent | checked |
| 11 | medium | Client-generated ids: clock skew reorders releases; `--no-build` reuses an id | Server assigns the id; refuse existing ids | by design reading |
| 12 | medium | "Keep newest 3" can prune the last known-good release; repeated rollback walks into known-bad ones | `previous` pointer, good/failed markers, never prune last good | by design reading |
| 13 | medium | stop/restart/rollback do not take the deploy lock; one history file trimmed under per-app locks loses lines; failed-early deploys leave no record | All mutating verbs lock; per-app history file; start and end records | by design reading |
| 14 | medium | Warm-up failure no longer rolls back (today it does, and that catches a wrong-platform image library); pre-deploy backup copy dropped | Health is a list of URLs including one image URL; hook failure rolls back; hooks run as app user | regression against current script (checked) |
| 15 | medium | "A few file reads" understates a refresh: sshd channel, sudo with an auth log line each time, forks, a real page render per health check | Read-only verbs without sudo; 5 to 10 s refresh; cached health; drop log-size metric | 43 ms CPU per refresh measured = 2.2% of the CPU at 2 s; unprivileged reads work (checked) |
| 16 | medium | Isolation overstated: apps share loopback, can reach each other's ports and Caddy's admin API; releases are world-readable | Caddy `admin off` or unix socket; releases 750 group=app; hide `/opt` of other apps; add missing directives | Caddy admin answers on 127.0.0.1:2019, releases are 755 root (both checked); `systemd-analyze security bakery` = 8.3 "exposed" (checked) |
| 17 | medium | Budgets not credible: agent likely 700 to 900 lines (budget 400), CLI 2,500+ (budget 1,500) | Budget honestly or cut scope | estimate |
| 18 | medium | Interactive dashboard is fragile in bash 3.2: whole-second `read -t`, ESC versus arrows, no `wait -n`, width cap 100, sketch is 89 columns against an 80 minimum | Static boxed tables with `--watch N`; no key handling | static frame renders in 12 ms under bash 3.2 (checked); interactive loop untested |
| 19 | medium | Byte progress for upload needs rsync 3.1+; the Mac ships openrsync | Require Homebrew rsync or show file counts | laptop has openrsync, no Homebrew rsync; VM has 3.4.1 (checked) |
| 20 | medium | Repo config and server registry drift; "never executed" is untrue for `build`/`test`/hooks; example line is not flat key=value | Split client and server keys; refuse on drift; one key per line | by design reading |
| 21 | medium | Host bootstrap, agent upgrade and version skew unspecified; CI checks out tando unpinned | Admin path documented; protocol version range; pin tando by tag in the workflow | by design reading |
| 22 | medium | Phase 1 needs `provision`, which is in phase 3; existing releases have old-style ids and no `release.json` | Minimal adopt step in phase 1; tolerate legacy ids; test rollback to a pre-tando release | by design reading |
| 23 | medium | Node major and native modules other than sharp are not checked on the server | `node` key compared at check; agent verifies every `*.node` is ELF x86-64 | laptop 24.19, VM 24.22 today (checked) |
| 24 | medium | Failed deploy prints journal lines (customer names, phones) into CI logs | In Actions print only "unhealthy", fetch logs from a laptop | by design reading |
| 25 | low | `ln -sfn` not atomic; single-200 health misses crash loops; one Caddy snippet per app cannot share a domain by path; no secret-rotation verb; disk check after upload; rollback ignores data migrations | See individual fixes in the review | by design reading |

## Feasibility by component

| Component | Feasible in shell? | Evidence |
|---|---|---|
| Local build, pack, upload, activate, rollback | Yes | Runs today for bakery: 91 s deploy, 21/21 production checks |
| Server status without root | Yes | cgroup files and `systemctl show` readable unprivileged (checked) |
| Monitoring cost | Yes, at 5 s or slower | 43 ms CPU per refresh, 18 ms per history sample (measured) |
| Static boxed tables | Yes | 39-row frame in 12 ms under bash 3.2 with the existing 224 lines of UI code |
| Interactive two-pane dashboard with keys | Doubtful | Reviewer's analysis of bash 3.2 input handling; not prototyped |
| Restricted CI key | Yes | `rrsync` is on the VM |
| Deploy user with safe privilege split | Yes, but needs redesign | Findings 1 to 3 |
| Pre-push hook | Yes technically, wrong semantics | Finding 9 |
| GitHub Actions for bakery | Not yet | No repo of its own, no remote |
| Line budgets | No | Estimate: about 2x over |

## Recommended changes

Cut: interactive dashboard and its action keys (keep boxed tables with `--watch`), log-size metric,
history timer and webhook, Podman section (leave a paragraph).

Re-sequence:

- Phase 0: bakery gets its own git repo. Write the threat model: admin versus deploy, per-app keys,
  rrsync, unprivileged copy, detached activate with a state file, server-assigned ids, per-id incoming.
- Phase 1: agent with `activate`, `rollback`, `releases`, `status`, and a minimal adopt step run as
  admin. Plain CLI `deploy`. Exit test includes rollback to a legacy release and a killed-ssh deploy.
- Phase 2: Actions with pinned tando and a per-app key. History.
- Phase 3: boxed read-only tables, performance work.

If an interactive multi-host dashboard is a hard requirement, choose Go now: the spec's own 2,500-line
trigger would fire in phase 2 anyway.
