# tando go: from an empty server to a live link

    cd ~/code/my-app && tando go admin@203.0.113.7

`tando go` is a step-by-step wizard (Server, Setup, App, Link, Extras, Review, Run, Done) over the
real commands: `host add`, `host setup`, `init`, `up`, `domain add`, `alerts`, `ci`. Every screen
has a pre-selected default marked "(recommended)", so Enter on every screen gives a working deploy.
Arrows or 1-9 move, Enter accepts, b / left goes back, s skips, q or Ctrl-C quits. Nothing changes
on the server or in the project before Run; quitting keeps only your answers (in
`~/.config/tando/go/`), and the next `tando go` resumes at the same screen (`--forget` drops them).
Run prints each command before running it and runs only what is missing, so `tando go` is safe to
run again. Without a terminal (or TERM=dumb) the screens become numbered prompts; `--yes` takes
every default. Flags: `[user@]address`, `--domain D`, `--www redirect|serve|off`, `--dns wait|skip`,
`--name`, `--memory`, `--port`, `--key`, `--no-swap`, `--free-link`, `--ci`, `--forget`, and
`key=value` settings for `host setup` (`apps_domain=`, `tls=`, `public_port=`, ...).

Related: `tando next` (what to do next, one ssh call), `tando link`, `tando open`, `tando ssh [app]`,
`tando cheat`.

## Timing (test/e2e-ease.sh, bare Ubuntu 26.04 container, Apple silicon, both test servers busy)

Empty VM to a live link on a domain with one command: **79 s** (`host setup` 49 s, mostly apt;
`up` with Node installed on demand, the rest). A second run of the same command: 2 s, nothing run,
nothing changed on the server. In an earlier run under heavier load the same took 147 s and 163 s.

## Non-interactive, from the empty VM (real output, 80 columns)

The test server is reached on 127.0.0.1 (links are `http://<app>.localhost:8374`); the domain uses
Caddy's internal CA and a fake resolver. On a public server you would type only
`tando go root@203.0.113.7 --domain example.com --yes`.

```
$ tando go vmadmin@127.0.0.1 --port 2274 --key /tmp/tando-ease.x/id --insecure-test \
    public_port=8374 domain_tls=internal --domain shop.test --yes
╭─ tando go · Step 6 of 8 · Review ──────────────────────────────────── hello ─╮
│ ✓ Server  ✓ Setup  ✓ App  ✓ Link  ✓ Extras  ● Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Review                                                                       │
│ server   prod  vmadmin@127.0.0.1                                             │
│ app      hello (node), memory 256M, health /                                 │
│ link     shop.test (DNS: ok), else http://hello.localhost:8374               │
│ extras   alerts off, CI off                                                  │
│                                                                              │
│ These run, in this order:                                                    │
│   tando host add prod vmadmin@127.0.0.1 --port 2274 --key /tmp/tando-ease.x… │
│   tando host setup prod public_port=8374 domain_tls=internal                 │
│   tando init -H prod                                                         │
│   tando up                                                                   │
│   tando domain add shop.test                                                 │
│                                                                              │
╰──────────────────────────────────────────────────────────────────────────────╯
╭─ tando go · Step 7 of 8 · Run ─────────────────────────────────────── hello ─╮
│ ✓ Server  ✓ Setup  ✓ App  ✓ Link  ✓ Extras  ✓ Review  ● Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ ◌ 1/5  tando host add prod vmadmin@127.0.0.1 --port 2274 --key /tmp/tando-e… │
│ ◌ 2/5  tando host setup prod public_port=8374 domain_tls=internal            │
│ ◌ 3/5  tando init -H prod                                                    │
│ ◌ 4/5  tando up                                                              │
│ ◌ 5/5  tando domain add shop.test                                            │
╰─ each command is shown before it runs ───────────────────────────────────────╯

[1/5] $ tando host add prod vmadmin@127.0.0.1 --port 2274 --key \
      /tmp/tando-ease.x/id --insecure-test --yes
● connected sudo ok, not set up yet: tando host setup prod
added host prod (vmadmin@127.0.0.1, port 2274, host key NOT checked)

[2/5] $ tando host setup prod public_port=8374 domain_tls=internal
╭─ host setup prod ──────────────────────────────────────── vmadmin@127.0.0.1 ─╮
│ ✓ 1/8  agent               0.1.0 in /opt/tando/bin                           │
│ ✓ 2/8  packages            installed rsync curl nftables                     │
│ ✓ 3/8  caddy               2.6.2 (installed now)                             │
│ ✓ 4/8  config              tando sites imported; admin API on a unix socket  │
│ ✓ 5/8  firewall            loopback rules per app                            │
│ ✓ 6/8  system              units, journals                                   │
│ ✓ 7/8  apps                0 apps                                            │
│ ✓ 8/8  checks              alert checks and metrics, every minute            │
│ links       http://<app>.localhost:8374  (tls off)                           │
│ runtimes    none yet: tando up installs what an app needs                    │
│ took        49s  aarch64, caddy 2.6.2                                        │
╰─ next: cd your-app && tando up ──────────────────────────────────────────────╯

[3/5] $ tando init -H prod
wrote tando.conf (node, host prod)

[4/5] $ tando up
installing node 24 on prod (the first app that needs it; up to a minute)...
  node 24.22.3 (installed now)
╭─ deploy hello ──────────────────────────────────────────────────────── prod ─╮
│ – 1/7  build                 nothing to build (no build in tando.conf)       │
│ ✓ 2/7  stage         0.1s  2 files                                           │
│         created hello on prod: user tando-hello, port 4100                   │
│ ✓ 3/7  upload        0.0s  2 files changed, 984 B sent                       │
│         release 20261114-054924                                              │
│ ✓ 4/7  copy          0.1s                                                    │
│ ✓ 5/7  preflight     0.7s                                                    │
│ ✓ 6/7  switch        0.2s                                                    │
│         live at http://hello.localhost:8374; watching it for 2 s before cal… │
│ ✓ 7/7  verify        2.2s                                                    │
╰─ live in 5.0s  http://hello.localhost:8374 ──────────────────────────────────╯

[5/5] $ tando domain add shop.test
https://shop.test is live (certificate until 2026-11-15)

╭─ tando go · Step 8 of 8 · Done ─────────────────────────────────────── prod ─╮
│ ✓ Server  ✓ Setup  ✓ App  ✓ Link  ✓ Extras  ✓ Review  ✓ Run  ✓ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ ✓ hello is live  https://shop.test                                           │
│ also        http://hello.localhost:8374                                      │
│ took        1m 17s                                                           │
├─ next ───────────────────────────────────────────────────────────────────────┤
│ ● no one is told when an app goes down                                       │
│   tando alerts notifier add phone ntfy                                       │
│ ● deploys of hello only run from this laptop                                 │
│   tando ci setup && tando ci github                                          │
╰─ tando next: every suggestion · tando cheat: the commands that matter ───────╯
```

## The wizard screens (captured on a 80x24 pty by test/e2e-ease.sh)

Answers in this run: address typed, Enter on Setup, the name changed to web1 then (after going back
from Link) to web2, own domain shop.test whose DNS points elsewhere, "Use the free link for now",
Enter on Extras and Review.

```

--- 1 Server: address
╭─ tando go · Step 1 of 8 · Server ───────────────────────────────────── site ─╮
│ ● Server  ○ Setup  ○ App  ○ Link  ○ Extras  ○ Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Your server's address                                                        │
│ The IP address or name of a server with Ubuntu 24.04 or newer and ssh.       │
│ tando installs what it needs there. You can paste user@address.              │
│                                                                              │
│ Address [none]                                                               │
│ ❯ _                                                                          │
╰─ enter ok · esc back · ctrl-c quit ──────────────────────────────────────────╯

--- 2 Setup
╭─ tando go · Step 2 of 8 · Setup ────────────────────────────────────── site ─╮
│ ✓ Server  ● Setup  ○ App  ○ Link  ○ Extras  ○ Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Set up the server                                                            │
│ Installs Caddy (HTTPS), rsync, curl and nftables from apt, the tando progra… │
│ a firewall unit and alert checks every minute. Takes 1-2 minutes. RAM: 16 G… │
│                                                                              │
│ ❯ 1  Install everything (recommended)                                        │
│       and a swap file if the server has less than 2 GB of RAM                │
│   2  Install everything but the swap file                                    │
│       for servers that must not swap                                         │
│   3  Skip: I will run tando host setup myself                                │
│       deploying fails until it has run                                       │
╰─ ↑↓/1-9 move · enter ok · b back · s skip · q quit ──────────────────────────╯

--- 3 App
╭─ tando go · Step 3 of 8 · App ──────────────────────────────────────── site ─╮
│ ✓ Server  ✓ Setup  ● App  ○ Link  ○ Extras  ○ Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Your app                                                                     │
│ Detected: a static app in site/                                              │
│                                                                              │
│ ❯ 1  Continue with these settings (recommended)                              │
│       tando init writes them to tando.conf                                   │
│   2  Name          site                                                      │
│       the app's name on the server and in its link                           │
│   3  Health check  /                                                         │
│       must answer before a new release goes live                             │
╰─ ↑↓/1-9 move · enter ok · b back · s skip · q quit ──────────────────────────╯

--- 3b App: name
╭─ tando go · Step 3 of 8 · App ──────────────────────────────────────── site ─╮
│ ✓ Server  ✓ Setup  ● App  ○ Link  ○ Extras  ○ Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Your app                                                                     │
│                                                                              │
│ Name (a-z, 0-9, -) [site]                                                    │
│ ❯ web1_                                                                      │
╰─ enter ok · esc back · ctrl-c quit ──────────────────────────────────────────╯

--- 4 Link
╭─ tando go · Step 4 of 8 · Link ─────────────────────────────────────── site ─╮
│ ✓ Server  ✓ Setup  ✓ App  ● Link  ○ Extras  ○ Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Where should web2 answer?                                                    │
│                                                                              │
│ ❯ 1  http://web2.localhost:8375 (recommended)                                │
│       a free link that works now; you can add a domain any time              │
│   2  My own domain                                                           │
│       you create one DNS record; HTTPS comes from Let's Encrypt              │
╰─ ↑↓/1-9 move · enter ok · b back · s skip · q quit ──────────────────────────╯

--- 4b Link: domain
╭─ tando go · Step 4 of 8 · Link ─────────────────────────────────────── site ─╮
│ ✓ Server  ✓ Setup  ✓ App  ● Link  ○ Extras  ○ Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Your domain                                                                  │
│ The name visitors type, like shop.example.com or example.com.                │
│                                                                              │
│ Domain [none]                                                                │
│ ❯ shop.test_                                                                 │
╰─ enter ok · esc back · ctrl-c quit ──────────────────────────────────────────╯

--- 4c Link: www
╭─ tando go · Step 4 of 8 · Link ─────────────────────────────────────── site ─╮
│ ✓ Server  ✓ Setup  ✓ App  ● Link  ○ Extras  ○ Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ And www.shop.test?                                                           │
│                                                                              │
│ ❯ 1  www.shop.test redirects to shop.test (recommended)                      │
│       visitors who type either name get there                                │
│   2  Only shop.test                                                          │
│       nothing is set up for www.shop.test                                    │
│   3  Serve both names                                                        │
│       the same site on both, without a redirect                              │
╰─ ↑↓/1-9 move · enter ok · b back · s skip · q quit ──────────────────────────╯

--- 4d Link: DNS
╭─ tando go · Step 4 of 8 · Link ─────────────────────────────────────── site ─╮
│ ✓ Server  ✓ Setup  ✓ App  ● Link  ○ Extras  ○ Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ shop.test does not point at this server yet                                  │
│ At your DNS provider, create:                                                │
│   A     shop.test                     ->  127.0.0.1   (now 203.0.113.9)      │
│   A     www.shop.test                 ->  127.0.0.1                          │
│                                                                              │
│ ❯ 1  Wait for DNS during the run (recommended)                               │
│       checks every 10 s for up to 30 min; Ctrl-C skips the domain            │
│   2  Check again now                                                         │
│       after you created the records                                          │
│   3  Use the free link for now                                               │
│       later: tando domain add shop.test                                      │
╰─ ↑↓/1-9 move · enter ok · b back · s skip · q quit ──────────────────────────╯

--- 5 Extras
╭─ tando go · Step 5 of 8 · Extras ───────────────────────────────────── site ─╮
│ ✓ Server  ✓ Setup  ✓ App  ✓ Link  ● Extras  ○ Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Extras                                                                       │
│ All optional; each can be added later with the command shown on the Done sc… │
│                                                                              │
│ ❯ 1  Continue (recommended)                                                  │
│   2  Alerts        off                                                       │
│       a push message when the app goes down or the disk fills                │
│   3  CI deploys    off                                                       │
│       a deploy key and a GitHub Actions workflow                             │
╰─ ↑↓/1-9 move · enter ok · b back · s skip · q quit ──────────────────────────╯

--- 6 Review
╭─ tando go · Step 6 of 8 · Review ───────────────────────────────────── site ─╮
│ ✓ Server  ✓ Setup  ✓ App  ✓ Link  ✓ Extras  ● Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Review                                                                       │
│ server   prod  vmadmin@127.0.0.1                                             │
│ app      web2 (static), memory 256M, health /                                │
│ link     shop.test (DNS: skip), else http://web2.localhost:8375              │
│ extras   alerts off, CI off                                                  │
│                                                                              │
│ These run, in this order:                                                    │
│   tando host add prod vmadmin@127.0.0.1 --port 2275 --key /tmp/tando-ease.x… │
│   tando host setup prod public_port=8375                                     │
│   tando init -H prod                                                         │
│   tando.conf: app = web2                                                     │
│   tando up                                                                   │
│                                                                              │
│ ❯ 1  Run now (recommended)                                                   │
│       nothing has changed anywhere until now                                 │
│   2  Go back and change something                                            │
╰─ ↑↓/1-9 move · enter ok · b back · s skip · q quit ──────────────────────────╯

--- 6 Review at 60 columns
╭─ tando go · Step 6 of 8 · Review ───────────────── site ─╮
│ ✓ Server  ✓ Setup  ✓ App  ✓ Link  ✓ Extras  ● Review  ○… │
├──────────────────────────────────────────────────────────┤
│ Review                                                   │
│ server   prod  vmadmin@127.0.0.1                         │
│ app      web2 (static), memory 256M, health /            │
│ link     shop.test (DNS: skip), else http://web2.localh… │
│ extras   alerts off, CI off                              │
│                                                          │
│ These run, in this order:                                │
│   tando host add prod vmadmin@127.0.0.1 --port 2275 --k… │
│   tando host setup prod public_port=8375                 │
│   tando init -H prod                                     │
│   tando.conf: app = web2                                 │
│   tando up                                               │
│                                                          │
│ ❯ 1  Run now (recommended)                               │
│       nothing has changed anywhere until now             │
│   2  Go back and change something                        │
╰─ ↑↓/1-9 move · enter ok · b back · s skip · q quit ──────╯

--- 6 Review, TANDO_ASCII=1
+- tando go - Step 6 of 8 - Review ------------------------------------- site -+
| + Server  + Setup  + App  + Link  + Extras  * Review  . Run  . Done          |
+------------------------------------------------------------------------------+
| Review                                                                       |
| server   prod  vmadmin@127.0.0.1                                             |
| app      web2 (static), memory 256M, health /                                |
| link     shop.test (DNS: skip), else http://web2.localhost:8375              |
| extras   alerts off, CI off                                                  |
|                                                                              |
| These run, in this order:                                                    |
|   tando host add prod vmadmin@127.0.0.1 --port 2275 --key /tmp/tando-ease.x~ |
|   tando host setup prod public_port=8375                                     |
|   tando init -H prod                                                         |
|   tando.conf: app = web2                                                     |
|   tando up                                                                   |
|                                                                              |
| > 1  Run now (recommended)                                                   |
|       nothing has changed anywhere until now                                 |
|   2  Go back and change something                                            |
+- ^v/1-9 move - enter ok - b back - s skip - q quit --------------------------+

--- 6 Review with TERM=dumb
╭─ tando go · Step 6 of 8 · Review ───────────────────────────────────── site ─╮
│ ✓ Server  ✓ Setup  ✓ App  ✓ Link  ✓ Extras  ● Review  ○ Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ Review                                                                       │
│ server   prod  vmadmin@127.0.0.1                                             │
│ app      web2 (static), memory 256M, health /                                │
│ link     shop.test (DNS: skip), else http://web2.localhost:8375              │
│ extras   alerts off, CI off                                                  │
│                                                                              │
│ These run, in this order:                                                    │
│   tando host add prod vmadmin@127.0.0.1 --port 2275 --key /tmp/tando-ease.x… │
│   tando host setup prod public_port=8375                                     │
│   tando init -H prod                                                         │
│   tando.conf: app = web2                                                     │
│   tando up                                                                   │
│                                                                              │
│   1  Run now (recommended)                                                   │
│       nothing has changed anywhere until now                                 │
│   2  Go back and change something                                            │
╰──────────────────────────────────────────────────────────────────────────────╯
Choice [1] (1-2, b back, s skip, q quit):

--- 8 Done
[4/5] tando.conf: app = web2
[5/5] $ tando up
╭─ deploy web2 ───────────────────────────────────────────────────────── prod ─╮
│ – 1/7  build                 nothing to build (no build in tando.conf)       │
│ ✓ 2/7  stage         0.0s  1 file                                            │
│         created web2 on prod: user tando-web2, port 4100                     │
│ ✓ 3/7  upload        0.1s  1 file changed, 276 B sent                        │
│         release 20261114-055056                                              │
│ ✓ 4/7  copy          0.0s                                                    │
│ ✓ 5/7  preflight     0.1s                                                    │
│ ✓ 6/7  switch        0.1s                                                    │
│ ✓ 7/7  verify        0.1s                                                    │
╰─ live in 3.0s  http://web2.localhost:8375 ───────────────────────────────────╯
╭─ tando go · Step 8 of 8 · Done ─────────────────────────────────────── prod ─╮
│ ✓ Server  ✓ Setup  ✓ App  ✓ Link  ✓ Extras  ✓ Review  ✓ Run  ✓ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ ✓ web2 is live  http://web2.localhost:8375                                   │
│ took        1m 0s                                                            │
│ domain      skipped; when DNS is ready: tando domain add shop.test           │
├─ next ───────────────────────────────────────────────────────────────────────┤

--- 8b Done after Ctrl-C while waiting for DNS
│ extras   alerts off, CI off                                                  │
│                                                                              │
│ These run, in this order:                                                    │
│   tando domain add late.test --wait                                          │
│                                                                              │
╰──────────────────────────────────────────────────────────────────────────────╯
╭─ tando go · Step 7 of 8 · Run ──────────────────────────────────────── site ─╮
│ ✓ Server  ✓ Setup  ✓ App  ✓ Link  ✓ Extras  ✓ Review  ● Run  ○ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ ◌ 1/1  tando domain add late.test --wait                                     │
╰─ each command is shown before it runs ───────────────────────────────────────╯
[1/1] $ tando domain add late.test --wait
waiting for DNS; Ctrl-C skips the domain (later: tando domain add late.test)
waiting for DNS of late.test ( A late.test -> 192.168.215.13)...
^C
╭─ tando go · Step 8 of 8 · Done ─────────────────────────────────────── prod ─╮
│ ✓ Server  ✓ Setup  ✓ App  ✓ Link  ✓ Extras  ✓ Review  ✓ Run  ✓ Done          │
├──────────────────────────────────────────────────────────────────────────────┤
│ ✓ web2 is live  http://web2.localhost:8375                                   │
│ took        1.4s                                                             │
│ domain      skipped; when DNS is ready: tando domain add late.test           │
├─ next ───────────────────────────────────────────────────────────────────────┤
```
