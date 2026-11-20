Moved out of docs/COMMANDS.md, which is for users. The numbers are the ones COMMANDS.md
refers to ("mismatch 8").

# Docs vs code mismatches (for the developers)

"Ran" = reproduced with `bin/tando` on 14 Nov 2026; "read" = from the code. README.md and
ARCHITECTURE.md are listed but were not edited (owned by the core developer).

| # | Where | Docs say | Code does | Evidence |
|---|---|---|---|---|
| 1 | README.md "Commands" | fixed (CODE-REVIEW D8): README says only `-a -H --json --yes --force` go before the command, which is what `main` does; any other flag there gets the reordered command line | ran |
| 2 | help.txt overview "Flags: -a <app>, -H <host> ..." | `-a` as a general flag | `init`, `up`, `ls`, `top`, `host`, `doctor`, `version`, `recipes`, `adopt` refuse `-a` (exit 2) | ran `ls -a x`, `up -a x` |
| 3 | docs/TOP.md line 3 | `tando top [host] [-n seconds]` | `-n` refused ("top does not take -n"); the flag is `--watch N` | ran |
| 4 | `tando go --help`, help overview "Plugins" | now `go [user@address] [--port N] [--key FILE] [--domain D] [--dns wait\|skip] [--yes] [--forget] [public_port=N ...]` | also accepts `--www`, `--dns`, `--name`, `--memory`, `--port`, `--key`, `--no-swap`, `--free-link`, `--ci`, `--insecure-test`, `--plain` and `apps_domain= tls= public_port= domain_tls= swap= ufw=` (docs/EASE.md lists all but `--plain`) | read `lib/cmd-go.sh` `go_flags` |
| 5 | help.txt `@@ ci` usage, `tando ci --help` | no `--env` | `ci github --env NAME` accepted (flags line, and `ci_usage` in lib/cmd-ci.sh lists it) | ran `ci github --env x --help` |
| 6 | help.txt `@@ logs` usage | `--until` only with `pull`; no `--json`, no `-E` | `--until`, `--json` and `-E` (same as `--regex`) are accepted on plain `logs` too; docs/LOGGING.md documents `--until`/`--json` | read `lib/cmd-logx.sh`; help.txt flags line |
| 7 | help.txt `@@ host` usage | `host add ... [--port N] [--key FILE] [--yes] [--force]` | also `--no-check` (in the text), `--deploy` (registers a CI deploy key host) and `--insecure-test` (used in README's own transcript) | ran `host add a b@c --deploy --no-check` |
| 8 | help.txt `@@ deploy` usage | no `-a` | `deploy -a <app>` accepted | help.txt flags line |
| 9 | help.txt `@@ alerts` usage | `notifier add/rm/ls` | `notifiers` is accepted as a synonym (subs line) | read `lib/cmd-alerts.sh:279` |
| 10 | help.txt `@@ requests` vs docs/LOGGING.md and the plugin header | help: `--since`; LOGGING.md: `--last` | both work (`--last` is a synonym, help says so); only the wording differs | read |
| 11 | help.txt `@@ ls` | fixed (CODE-REVIEW B5): `ls --all` repaints with `--watch N`; `--json` is one object, `{"host","error"}` for a server that did not answer | ran; test/e2e-cli.sh 9i |
| 12 | README.md "tando.conf" ("Every key") | fixed: docs/CONFIG.md lists every key the parser accepts, and test/ui-test.sh fails when it and the code disagree | was: `build_memory`, `dockerfile`, `start_shell`, `access_log`, `log_max`, `log_keep`, `log_rate` were missing from the README list | read `lib/common.sh` `conf_load` |
| 13 | README.md "Commands" table | no `go`, `next`, `link`, `open`, `ssh`, `cheat` | all six exist as plugins and are listed by `tando help` | ran `tando help` |
| 14 | completions/ (CODE-REVIEW D-9) | fixed: each command is offered only the flags of its help.txt `flags:` line, `-E`, `--4xx` and `-H` included (completions/gen.sh) | read the regenerated `completions/tando.bash` |

Fixed since CODE-REVIEW (checked): `tando requests summary` and `tando alerts show` are accepted
(B6); help.txt `--release` text now says "the lines from the time that release was live" (D-2).
