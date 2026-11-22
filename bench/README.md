# tando benchmark

Measured comparison of tando (a snapshot of `bin/`, `lib/`, `server/`) against the deploy styles
of its rivals, on one Next.js standalone app. Results: `RESULTS.md`. Raw output: `raw/`.

## What is here

| Path | What |
|---|---|
| `snapshot/` | copy of `bin/ lib/ server/` taken at the start (`snapshot.sha256` has the hashes) |
| `app/` | the workload: Next.js 16.2 app, `output: 'standalone'`, pages `/`, `/about`, dynamic `/posts/[id]`, API `/api/version` (health path; returns 500 when the version starts with `broken`). `lib/version.js` is the one-line warm change. Also `Dockerfile` (after Next's official with-docker example), `config/deploy.yml` (Kamal), `tando.conf` |
| `tando-next-stage.sh` | wrapper tando needs for Next: copies `.next/standalone` + `.next/static` + `public` into `dist/`, swaps sharp's macOS binaries for the Linux ones (tando refuses foreign native modules) |
| `server/` | `Dockerfile` (copy of `test/server/Dockerfile`: Ubuntu 26.04, systemd, sshd, Caddy, Node 24), `Dockerfile.docker` (+ Docker Engine 29, Caddy disabled), `Dockerfile.podman` (+ Podman 5) |
| `lib.sh` | helpers: start a server container (2 GB, 1 CPU, pinned to one vCPU, ext4 loop disk), cgroup readings, peak memory watcher, request loop wrapper |
| `kamal.sh` | runs real Kamal 2.12 from `ghcr.io/basecamp/kamal` (host network, so its local registry and ssh tunnel work) |
| `reqloop.py`, `reqsummary.py` | ~10 req/s loop (new connection each), and its summary (failures, longest gap, latency) |
| `run-a-tando.sh` | A: tando, systemd + Caddy, laptop build, rsync |
| `run-b-kamal.sh`, `run-b-copies.sh` | B: real Kamal 2 (local registry + ssh tunnel, kamal-proxy, Docker Engine on the server); the copies script deploys 3 services for the 3-app memory reading |
| `run-c-server-build.sh`, `c/` | C: ship source, `npm ci` + `next build` on the server (piku/Dokku/Coolify-default style), systemd + Caddy |
| `run-d-podman.sh` | D: Podman quadlet, scripted by hand (build, push, pull, edit `Image=`, restart) |
| `npm-ci-laptop.sh` | laptop `npm ci` time (cold-start add-on for A) and ms-resolution laptop build+stage time |
| `run-a-extra.sh` | tando newcomer checks: `init`+`up` on a plain Next app, unit journal, memory without the ssh session, `MALLOC_ARENA_MAX=2` |
| `parse-phases.py` | per-phase seconds from the deploy logs -> `raw/phases.txt` |
| `summarize.py` | `raw/*/` -> `raw/summary.txt` (median [min-max] (n)) |
| `raw/bugs/` | exact output of tando bugs hit while setting up |
| `run-bare.sh` | v2: empty VM (bare Ubuntu 26.04) to first live app for Kamal, C, D: every user command timed and counted |
| `run-rivals.sh`, `summarize-v2.py` | v2: 3 rounds of every rival into `raw/v2/`, and its summary |
| `run-e-dokku.sh` | Dokku (bare 24.04, official bootstrap); 3 rounds via `run-e-rounds.sh` into `raw/v2/e/` |
| `server-bare/`, `server/build-images.sh` | bare image (copy of the test server, BARE=1); server images built with a dedicated builder |
| `density.sh` | density at scale (not in the test tiers): N apps with `idle_stop` on one test server; daemon-reload time, PID 1 RSS and units every 50 apps, idle journald instances, a new app's time and reloads (`OLD=<checkout>` for a before), and PID 1 across rounds of wake sockets driven into their trigger limit |
| `cleanup.sh` | removes every `tando-bench-*` container/volume/network/image, Kamal's builder and registry |

## Rerun

Needs OrbStack (or Docker) on an arm64 Mac, Node 24 + npm on the laptop, internet for npm and
image pulls. Uses ports 127.0.0.1:2411-2415, 8411-8415, 5412 (Kamal registry), 5414 (D registry); v1 used 23xx/83xx.
Never touches `tando-testvm` or anything not named `tando-bench-*` / `kamal-*` created here.

```sh
cd bench
(cd app && npm ci)                       # once
docker build -t tando-bench-base   -f server/Dockerfile        server
docker build -t tando-bench-docker -f server/Dockerfile.docker server
docker build -t tando-bench-podman -f server/Dockerfile.podman server
./run-a-tando.sh <snapshot-dir> 3 3   # tando, current CLI, from a frozen copy (never the live tree)
./run-b-kamal.sh 5        > raw/run-b.out 2>&1
./run-c-server-build.sh 3 > raw/run-c.out 2>&1
./run-d-podman.sh 3       > raw/run-d.out 2>&1
./npm-ci-laptop.sh 3
./run-a-extra.sh          > raw/run-a-extra.out 2>&1
python3 summarize.py; python3 parse-phases.py
./cleanup.sh
```

Run the approaches one at a time (they share `app/` and the laptop CPU). Each run script starts
its own fresh server container and leaves it running for inspection; `cleanup.sh` removes them.

## How things are measured

- Server = privileged systemd container, `--memory 2g --memory-swap 2g --cpus 1 --cpuset-cpus N`
  (the cpuset makes `nproc` 1, as on the 1 vCPU VPS; without it Next sees 10 CPUs and starts 7
  build workers). Data directories (`/opt/tando`, `/var/lib/docker`+`containerd`, `/srv`,
  `/var/lib/containers`) sit on an ext4 loop filesystem (direct-io) like a VPS disk.
- Memory: the container's cgroup (the cgroup namespace root): `memory.current` (includes page
  cache) and `anon + shmem` from `memory.stat` (what cannot be reclaimed), per child cgroup. Idle
  snapshots: 30 s settle, then 3 samples 10 s apart, median.
- Peak during a deploy: `memory.peak` cannot be reset at the namespace root, so it is reset per
  file descriptor on `init.scope`, `system.slice`, `user.slice` (+ `machine.slice`) and summed:
  an upper bound of the true combined peak; includes page cache.
- Server CPU: delta of `usage_usec` in the container's `cpu.stat` around the laptop command.
  Includes sshd, systemd, journald and everything else the deploy wakes up.
- Bytes to the server: delta of eth0 receive bytes in the container (all traffic: ssh, rsync,
  registry pull through the tunnel), measured on quiet runs without the request loop.
- Downtime: `reqloop.py` at ~10 req/s through the proxy (Caddy or kamal-proxy), new TCP
  connection per request, 5 s timeout, from 3 s before to 3 s after the deploy command. Failed =
  non-200 or connection error. Longest gap = longest time between two consecutive 200 responses.
- CPU, bytes and peak are taken from separate "quiet" deploys; downtime from "loop" deploys.
