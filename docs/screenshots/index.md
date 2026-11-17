# tando screenshots

Real runs, captured 2026-11-14 on a 100x30 pseudo-terminal with colour (`TANDO_COLOR=always`,
`TERM=xterm-256color`), against the bare test server (`TANDO_TEST_BARE=1`, container
`tando-shots`, ssh 127.0.0.1:2278, http 8378), from a snapshot of the working tree. Host
registered with `tando host add prod vmadmin@127.0.0.1 --port 2278 --key test/server/id_test --yes`
(the normal way, no `--insecure-test`). Apps: hello, site, pyapp (python), nextdemo (next), notes
(postgres), all from `examples/`. Traffic: a curl loop through Caddy. Domain: `domain_tls=internal`
plus the fake resolver (`TANDO_TEST_RESOLVE`), as in test/e2e-bootstrap.sh. Alerts: one webhook
notifier to a local listener on the server; hello crash-looped on purpose (`CRASH_VERSION`).

Each capture has four files: `.ansi` (the raw bytes the command wrote), `.svg`, `.png` (the SVG
rendered by headless Chrome at 2x) and `.html` (a self-contained `<pre>` fragment).

| # | Command | What it shows |
|---|---|---|
| 01 | `tando host setup prod public_port=8378 domain_tls=internal` | the final 8-step box on the empty VM: Caddy, packages, firewall, timers installed (2m 7s) |
| 02 | `cd hello && tando up` (no tando.conf yet) | first deploy: writes tando.conf, installs Node 24 on demand, the step box and the live link |
| 03 | `tando ls` | host gauges and the five apps with state, memory, CPU, uptime, log size and link |
| 04 | `tando status` (in hello) | state, memory bar, 16-minute cpu/mem sparklines, domain with certificate, releases, history |
| 05 | `tando top` | one full frame of the live dashboard after about 80 s: apps table, hello detail, memory/cpu graphs, releases, deploys |
| 06 | `tando history` (in hello) | deploys, the failed one and the rollback, with per-phase times |
| 07 | `tando releases` (in hello) | kept releases: rolled-back, current and last good |
| 08 | `tando deploy` (hello with `require("./metrics")` added) | the failure box: pre-flight caught the missing module, the running app was not touched |
| 09 | `tando rollback` (in hello) | rollback to the previous verified release |
| 10 | `TANDO_TEST_RESOLVE=shop.test=203.0.113.9 tando domain add shop.test` | wrong DNS: refused, with the exact A records to create |
| 11 | `TANDO_TEST_RESOLVE=shop.test=127.0.0.1,www.shop.test=127.0.0.1 tando domain add shop.test` | right DNS: live with a certificate (Caddy local CA) |
| 12 | `tando doctor` | the end-to-end server check: 0 failed, 1 warning (Caddy 2.6.2 request log with a test port) |
| 13 | `tando requests -a nextdemo` | request stats from Caddy's log: rate, per-minute sparkline, latency percentiles, status codes, paths |
| 14 | `tando alerts` | a `health` alert firing on hello (crash loop), the webhook notifier, recent events |
| 15 | `tando alerts` | the same alert resolved after hello was fixed (`tando env unset CRASH_VERSION`) |
| 16 | `tando logs -n 12` (in hello) | the app's journal: the crash loop, then the healthy start |
| 17 | `tando go` (in a new static project) | the setup wizard, one capture per screen: `17-go-01-server` … `17-go-08-done` (Server, Setup, App, Link, Extras, Review, Run, Done) |

Notes:

- The request log only records requests whose Host has no port on Caddy 2.6.2 (doctor's warning), so
  the traffic for 13 was sent from the server itself to port 80; traffic from the laptop to
  `:8378` reaches the apps but is not counted.
