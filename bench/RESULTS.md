# tando benchmark results

13 Nov 2026. Every number below is **measured** on this machine unless marked otherwise. Format:
median [min-max] (n = runs). Raw data is kept privately, not in this repository (the summary and phase files are
generated from it by `summarize.py` and `parse-phases.py`). How to rerun: `README.md`.

**Hardware.** Laptop: Apple M1 Pro (arm64), macOS, OrbStack 7.0 kernel, Docker 29.4. Each
"server" is a privileged Ubuntu 26.04 container with systemd as PID 1, limited to `--memory 2g
--cpus 1` and pinned to one vCPU (`--cpuset-cpus`, so `nproc` = 1). Data directories are on an
ext4 loop disk. The containers are arm64 Linux. The owner's real VPS is x86-64 with 1 vCPU and
1,962 MB RAM, so absolute times will differ. Memory, bytes, disk, request-failure counts and the
ratios between approaches should transfer. Seconds and CPU-seconds should not; see "Threats to
validity".

**Workload.** Next.js 16.2.6, `output: 'standalone'`: 4 pages (one dynamic) and `/api/version`
(the health path). The standalone release is 34 MB and 1,164 files; the app idles at about 46 MB
anon. This is smaller than the owner's real apps (about 60 MB per release, about 230 MB RAM).

**Approaches.**
- **A tando**: the `bench/snapshot` copy of bin/lib/server. Build on the laptop, rsync, systemd
  unit behind Caddy. Needs the wrapper `tando-next-stage.sh` (see bug 3).
- **B Kamal 2.12**: real Kamal, run from its official image. Kamal's local registry on the
  laptop, pulled by the server through Kamal's ssh tunnel, kamal-proxy, Docker Engine 29 on the
  server. The image follows Next's official with-docker Dockerfile (node:24-alpine).
- **C Build on server**: piku/Dokku/Coolify-default style, scripted (`c/build-deploy.sh`). rsync
  the source, `npm ci` + `next build` inside the 2 GB / 1 CPU server, systemd + Caddy, restart.
- **D Podman 5.7 quadlet**: a hand-written script, not a tool. Same image as B, built on the
  laptop, pushed to a registry container, `podman pull`, edit `Image=`, restart the unit, Caddy.

## Summary table

anon = anon+shmem from `memory.stat` (memory that cannot be reclaimed). "Peak" is the sum of the
per-slice `memory.peak` values, which includes page cache and is an upper bound.

| Metric | A tando | B Kamal 2 | C build on server | D Podman quadlet (scripted) |
|---|---|---|---|---|
| 1. Platform resident memory, zero apps (anon) | **Caddy 9.2 MB**, tando 0 (n=3 samples) | dockerd+containerd **61 MB** fresh; **151 MB** once used, with kamal-proxy (n=3) | Caddy 9.5 MB (n=3) | Caddy 9.6 MB, podman 0 (n=3) |
| 1. Whole server, one app: anon / memory.current | 68.0 / 132 MB (no ssh session open) | 193.6 / 342 MB | 68.0 / 269 MB | 53.6 / 158 MB |
| 1. Whole server, three apps (anon) | 169 MB | 315 MB | not run | 131 MB |
| 2. Per-app memory, app only (anon) | 45.9 MB (34.1 MB with `MALLOC_ARENA_MAX=2`) | 32.3 MB container | 47.1 MB | 32.5 MB (incl. conmon) |
| 2. Added per extra app (1 to 3 apps, anon / 2) | 48 MB | 61 MB | - | 39 MB |
| 3. Disk: platform | agent 24 KB + Caddy 47 MB + host Node 197 MB | docker.io+containerd+runc 261 MB (dpkg sizes) + kamal-proxy image 171 MB | Caddy + host Node (as A) | podman stack 101 MB + Caddy |
| 3. Disk: one release / three retained | 68 MB / 136 MB (incoming + releases, 34 MB each) | about 236 MB / about 356 MB (176 MB shared base + about 60 MB per version) | 468 MB / 536 MB (node_modules 309 MB, .next cache 38 MB, npm cache 87 MB, releases 34 MB) | 9 versions = 485 MB (`podman system df`) |
| 4. Cold deploy, total | 7.1 s (n=1); a laptop `npm ci` adds 3.6 s [3.4-3.8] (n=3) | 82.5 s (n=1) | 33.4 s (n=1) | about 65 s (n=1; see D notes) |
| 4. Warm deploy, total | **5.5 s [5.4-6.0] (n=5)** | 9.5 s [9.4-10.5] (n=5) | 11.1 s [8.9-13.5] (n=3) | 7.3 s [7.1-7.8] (n=3) |
| 5. Bytes to server, warm (eth0) | **405 KB [402-410] (n=5)**; rsync payload 136 KB | 11.2 MB (n=5) | 15 KB (n=3), source only | 11.1 MB (n=3) |
| 6. Server CPU per warm deploy | **0.90 s [0.88-0.92] (n=5)** | 1.27 s [1.16-1.33] (n=5) | 8.60 s [8.46-9.06] (n=3) | 0.97 s [0.97-1.07] (n=3) |
| 6. Peak memory during warm deploy (incl. cache) | 311 MB [254-352] (n=5) | 634 MB [591-704] (n=5) | 1,348 MB [1,307-1,439] (n=3); **anon 730 MB** (n=1, sampled) | 443 MB [377-480] (n=3) |
| 7. Failed requests per warm deploy (~10 req/s) | **2 [2-2] (n=5)**, HTTP 502 | **0 [0-0] (n=5)** | 2 [1-2] (n=3) | 0 [0-0] (n=3) |
| 7. Longest gap between 200s (baseline about 120 ms) | 331 ms [320-390] (n=5) | 122 ms [118-125] (n=5), no gap | 318 ms [251-351] (n=3) | 600 ms [565-613] (n=3), requests held |
| 8. Rollback time | 0.8 s [0.8-0.8] (n=3); 2 failed requests (n=1) | 3.0 s [2.9-3.0] (n=3); 0 failed (n=2) | no rollback | 0.8 s (n=1); 4 failed (n=1) |
| 9. Status query, server CPU | `tando ls` **15 ms [15-37] (n=10)**; `tando status` 25 ms (n=5) | `kamal details` 54 ms (n=3); `docker ps` 41 ms (n=5); `docker stats --no-stream` 68 ms [59-126], 2.1 s wall (n=5) | - | `podman ps` 46 ms, `podman stats` 48 ms (n=3) |
| 10. Broken release (health 500) | old version kept, 0 failed; failure reported after **34.3 s** (health_timeout 30) (n=1) | old version kept, 0 failed; failure after **38.3 s** (deploy_timeout 30) (n=1) | no gate (not run) | **no gate: broken version went live**, 361 of 462 requests failed (n=1) |
| Idle server CPU, one app | 63 ms per 20 s | 118 ms per 20 s | 64 ms per 20 s | 62 ms per 20 s |

## Per-metric detail

### 1. Idle platform overhead
Sampled 30 s after settling, 3 samples 10 s apart; median. Files: the private raw data.
- **A**: base OS (systemd, journald, sshd, logind, dbus) with Caddy is 18.2 MB anon; Caddy is
  9.2 MB of that. tando keeps no process. After a tando command, the ssh ControlPersist session
  adds about 4.5 MB in `user.slice` for 60 s (26.2 MB at zero apps). With it closed and one app:
  68.0 MB anon (the private raw data).
- **B**: freshly started dockerd (35.8 MB) + containerd (25.6 MB) = 61 MB anon, before Kamal does
  anything. After deploys, with kamal-proxy and zero apps: dockerd 98 MB + containerd 46 MB +
  kamal-proxy 7 MB = 151 MB anon. That is **about 140 MB more than Caddy alone, about 7% of a
  2 GB server and about 3.5% of 4 GB**. dockerd grows with use (pulls, builds of three services):
  103 MB with one app, 146 MB after the three-service run. Of dockerd's cgroup, 4 `docker-proxy`
  processes (ports 80/443, IPv4+IPv6) are about 42 MB PSS (the private raw data). A Kamal user
  could cut them with `userland-proxy: false` (not tested).
- **D**: Podman has no daemon: zero apps = Caddy + base, 20.7 MB anon, the same as A.

### 2. Per-app memory
- The same app uses **46 MB anon under tando (Ubuntu's glibc Node 24) and 32 MB in node:24-alpine**
  (B and D). Setting `MALLOC_ARENA_MAX=2` through `tando env set` brought tando to 34.1 MB
  (the private raw data). The difference is the runtime's allocator, not tando.
- Per-app overhead: B has one containerd-shim per container (about 8.5 MB PSS) plus dockerd
  growth. D has conmon (1.4 MB PSS). A has none: a Caddy site block costs nothing measurable.
- Going from 1 to 3 apps added 48 MB per app for A, 61 MB for B and 39 MB for D.

### 3. Disk
the private raw data, the private raw data, the private raw data, the private raw data; logical bytes (`du -b`).
- A keeps `incoming/` as a full extra copy beside the releases: 5 retained releases + incoming
  = 6 × 34 MB; ext4 used 232 MB. It needs Node on the host (197 MB) and Caddy (47 MB).
- B: the ext4 disk held 712 MB with 6 image versions + kamal-proxy, and 176 MB with kamal-proxy
  alone after `kamal app remove`. Docker reports 176 MB shared base and 111.8 MB "unique" per
  version (compressed content + unpacked layer). The ext4 arithmetic gives about 60 MB per extra
  version. Platform packages: 261 MB (dpkg Installed-Size).
- C keeps the whole toolchain on the server: node_modules 309 MB, npm cache 87 MB, `.next`
  build cache 38 MB.

### 4. Deploy time (phases)
the private raw data. Warm = one-line change to `lib/version.js`.

| Phase, warm | A tando (n=10) | B Kamal (n=10) | C (n=6) | D (n=6) |
|---|---|---|---|---|
| build (+ package) | 3.6 s [3.1-3.8] laptop `next build` + stage (n=3, ms timer); tando prints 3 s build + 1 s stage | 4.7 s [4.6-5.4] buildx build + push | npm ci 2.8 s + next build 7.5 s [5.4-9.7] on the server | 5.6 s build + 0.28 s push |
| transfer | upload 0 s [0-1] (whole seconds) | pull 0.77 s [0.70-0.83] | rsync 0.14 s | pull 0.70 s |
| activate | copy 0.05 + preflight 0.6 + switch 0.1 + verify 0.6 = about 1.35 s | docker run + kamal-proxy deploy 1.44 s, other Kamal steps 1.33 s | stage 0.02 + restart/health 0.32 s | 0.76 s |
| total (wall) | 5.5 s | 9.5 s (Kamal reports 9.2; the rest is starting its container) | 11.1 s | 7.3 s |

Cold: A 7.1 s (build 3, upload 2 s, 11 MB sent, activation 1.2 s). B 82.5 s: buildx 59.5 s
with a cold Kamal builder, including `npm ci` and pulling node:24-alpine; pull 2.5 s; 17.9 s of
other steps, mostly pulling and starting kamal-proxy on the server. B's first ever run on this
laptop took 135 s, because the laptop also had to pull registry:3 and buildkit. C 33.4 s
(`npm ci` 26.6 s from the internet, `next build` 6.0 s). D: build 61.0 s + push 0.4 s + pull
3.0 s. Its activation (32.8 s) is invalid because of a script bug (Caddy was reloaded after the
health wait; fixed in `run-d-podman.sh`, not re-measured), so D cold is about 65 s.

### 5. Bytes transferred (warm)
eth0 receive bytes on the server, quiet runs. tando: 405 KB in total, of which the rsync payload
is 136 KB. Next rewrites 40 files with new build ids for a one-line change; the rest is ssh,
agent calls and status polling. B and D send the whole standalone layer again (11.1-11.2 MB)
because `COPY .next/standalone` is one layer: **tando sends about 28 times fewer bytes than the
image tools**. C sends only the source (15 KB) but pays in server CPU and memory.

### 6. Server CPU and memory during a deploy
- tando 0.90 s CPU: rsync `-c` checksums all 1,164 files on the server, `cp -a` + `chown -R` of
  the release, and Next started twice (pre-flight, then the real unit).
- Kamal 1.27 s, Podman 0.97 s: pull, unpack, container start.
- C: 8.6 s of CPU on a 1-CPU server per warm deploy and 13.2 s cold. Sampled every 0.2 s during
  a warm build, the container's anon memory rose from 69 MB to **730 MB** (661 MB in the build
  session; the private raw data) for this tiny app. memory.peak, including page cache, was
  1.3-1.5 GB of the 2 GB.
- C's effect on the running app's latency during the build was small for this app: p95 20 ms
  [20-22] against 20.9 ms idle, max 45 ms [27-52] against 39 ms (the private raw data). The build
  is short (about 10 s) and the app's routes are trivial. With the owner's real app (850 MB,
  minutes of build, measured earlier in the design notes) this would not hold. Treat it as a lower bound.

### 7. Downtime
the private raw data; a new TCP connection per request through the proxy.
- tando: **exactly 2 failed requests (HTTP 502 from Caddy) on every one of 5 warm deploys**, gap
  320-390 ms, during `systemctl restart`. The pre-flight already proved the release, so this is
  only the restart window.
- Kamal: 0 failed requests in 5 of 5 deploys and 2 of 2 rollbacks; the gap equals the baseline
  request interval.
- Podman quadlet: 0 failed, but requests stalled up to 520 ms (gap 600 ms). Rollback: 4 failed
  (n=1).
- C (plain restart): 1-2 failed, like tando.

### 8. Rollback
tando 0.8 s (switch + restart + verify through Caddy), but with the same 2 × 502. Kamal 3.0 s
with 0 failures. tando keeps 5 releases, so a fourth consecutive rollback fails with `no earlier
verified release to roll back to` (by design).

### 9. Status query cost
`tando ls`: 15 ms of server CPU (n=10) and 176 ms wall over the ControlMaster connection, under
the 50 ms target in the prototype notes. `tando status`: 25 ms. Docker equivalents cost 41-68 ms;
`docker stats --no-stream` takes 2.1 s wall. `kamal details`: 54 ms server CPU, 0.7 s wall. tando
is cheapest, but every option is cheap.

### 10. Broken release
tando and Kamal both kept the old version serving with 0 failed requests. tando reported the
failure after 34.3 s, Kamal after 38.3 s (both with a 30 s timeout; tando keeps probing a release
that answers 500 until the timeout). A plain Podman quadlet (and C) has no gate: the broken
version went live and 361 of 462 requests failed until the next deploy.

## Where tando loses

1. **Downtime.** Kamal had zero failed requests on every deploy and rollback; tando drops about
   2 requests (330 ms) on every deploy and rollback. This is the clearest functional gap. A cheap
   mitigation to try: Caddy `reverse_proxy { lb_try_duration 5s }`, which retries the dial while
   the unit restarts (not tested).
2. **Per-app memory against an Alpine container.** Out of the box the tando app used 46 MB
   against 32 MB in node:24-alpine; with `MALLOC_ARENA_MAX=2` it is 34 MB. Per-app memory is
   about even once tuned, but tando currently ships the worse default.
3. **Against Podman quadlet, tando has no memory advantage.** Podman keeps no daemon either (zero
   apps: 20.7 MB against tando's 18-26 MB) and its three-app total was lower (131 against
   169 MB anon). tando's advantage over D is the health gate, automatic rollback, 28 times fewer
   bytes and the status view, not memory.
4. **Next.js support.** `tando init` writes an unusable config for Next, and even a correct
   config needs a wrapper (bugs 3-4). Kamal used Next's stock Dockerfile unchanged.
5. **Runtime on the host.** tando needs a host Node (197 MB disk) shared by all apps; images
   carry their own.
6. **Rollback speed is not an advantage in practice**: tando 0.8 s with 2 failures against Kamal
   3.0 s with none.

Where tando wins, measured: no resident platform (about 140 MB anon less than Docker + kamal-proxy
in use), fastest warm deploy (5.5 s against 9.5 s for Kamal), about 28 times fewer bytes per warm
deploy, lowest server CPU per deploy, least disk per release (34 MB against about 60 MB per image
version), cheapest status query, and the same safety as Kamal on a broken release. Against
building on the server it avoids 730 MB anon and 8.6 CPU-seconds per deploy on a 1-CPU, 2 GB box.

## Threats to validity

- **arm64 laptop, not x86 VPS.** M1 cores are much faster than one VPS vCPU: every seconds and
  CPU-seconds figure will be larger on the VPS, the build-on-server ones most of all. Memory and
  bytes are about architecture-neutral (x86 Node uses similar RSS). The ratios should hold.
- **Container, not VM.** Shared kernel and page cache with the OrbStack VM. `memory.current`
  includes cache, so the anon figures are the trustworthy ones. Disk is an ext4 loop file. The
  network is loopback through OrbStack port forwarding, so transfer *times* are optimistic;
  bytes are exact.
- **Small app.** 34 MB release, 46 MB RSS, 6 s build against the owner's 60 MB, 230 MB and a build
  of minutes. Per-app memory differences scale with the app; platform overheads do not.
  Build-on-server time, memory and latency impact are a lower bound here.
- **Single machine.** The laptop is also the registry host, the build host and the load
  generator. The other developer's e2e tests (`test/.e2e`, `tando-testvm`) ran on the same laptop
  during part of approach A, which could add noise to laptop-side wall times.
- **Small n.** Cold deploys n=1; C and D warm n=3; broken-release n=1. Ranges are tight for A and
  B (n=5).
- **Measurement method.** Peak memory is a sum of per-slice peaks, including cache (an upper
  bound). CPU deltas include the `docker exec` reads (a few ms). Kamal runs from its Docker image
  (adds about 0.3 s per command against a gem install). Next telemetry was disabled by env var
  in the scripts, but the first two exploratory builds ran before that.
- **Choices that favour or disfavour someone.** C ran `npm ci` (warm npm cache, about 3 s) on
  every deploy, as Dokku's buildpack does; a Docker-layer-cached build (Coolify) would skip it.
  B and D use node:24-alpine (smaller RSS) while A uses Ubuntu's glibc Node. No TLS anywhere (Caddy
  and kamal-proxy in plain http). Docker's `userland-proxy` left at its default.
- **Not measured.** Real Dokku and Coolify (not installed). Three apps for C. Rollback for C.
  D's cold activation (script bug). Reboot recovery. Behaviour under memory pressure (no app
  approached the 2 GB limit). The 4 GB+ case is inferred, not run.

## Verdict

On a 2 GB server the measurements support building tando further. Against Docker + Kamal it saves
about 140 MB of resident memory (7% of the RAM), deploys faster with 28 times fewer bytes and less
server CPU, and against building on the server it avoids a 730 MB, 8.6 CPU-second spike per
deploy. But it must fix the 2-requests-per-deploy downtime and its Next.js path, and on memory
alone it does not beat a plain Podman quadlet. On a 4 GB+ server the memory advantage shrinks to
about 3.5% of RAM while Kamal's zero-downtime switch and maturity remain, so there the
measurements favour Kamal unless tando closes the downtime gap.

## tando bugs and rough edges (newcomer feedback)

Snapshot hashes: `snapshot.sha256`. Outputs are kept privately.

1. **ssh ControlPath too long, so `host setup` fails** when `TANDO_CONFIG_DIR` is about 46+
   characters. `host_use` checks `${#CFG} + 44 < 100`, but ssh appends a 17-character random
   suffix while creating the master socket, and macOS allows 104 bytes:
   ```
   $ export TANDO_CONFIG_DIR=/path/to/a/long/config/dir
   $ tando host setup bencha apps_domain=localhost tls=off public_port=8311
   unix_listener: path "<config dir>/cm/<hash>.<suffix>" too long for Unix domain socket
   tando: could not install the agent (needs ssh + passwordless sudo)
   ```
   The error message blames ssh/sudo. Fix: budget 44 + 17 (or use `%C` under a short dir always).
2. **Every deploy, rollback and `env set` logs the unit as failed.** Node exits 143 on SIGTERM:
   ```
   tando-bench.service: Main process exited, code=exited, status=143/n/a
   tando-bench.service: Failed with result 'exit-code'.
   ```
   Add `SuccessExitStatus=143` (or `SIGTERM`) to the unit.
3. **`tando init` writes a config for Next.js that cannot deploy**, and `tando up` then fails:
   ```
   $ tando init
   next.js detected: the next recipe is not in this prototype; using node
   $ cat tando.conf      ->  build = npm run build / start = npm start / health = / / memory = 256M (no out)
   $ tando up
   │ ✓ 1/7  build           4s │
   tando: native module built for another platform (server is aarch64): node_modules/@img/sharp-darwin-arm64/lib/sharp-darwin-arm64.node
   ```
   With `out = .` it would also ship the whole 317 MB node_modules and run `next start`.
4. **Even a correct standalone config is refused on macOS.** Next traces
   `@img/sharp-darwin-arm64` into `.next/standalone`, and Next does not copy `.next/static` or
   `public`. Needed: `bench/tando-next-stage.sh` (copy static + public, replace the darwin sharp
   packages with `npm install --os=linux --cpu=<arch> sharp`). A `next` recipe should do this. A
   newcomer also hits Next guessing the wrong tracing root when a lockfile exists higher up (needed
   `outputFileTracingRoot`).
5. **A failed first `tando up` leaves the app half-created** on the server (user, port 4100, unit,
   Caddy site `nextapp.caddy`, `/opt/tando/apps/nextapp`). There is no command to delete an app.
6. **2 failed requests on every deploy and rollback** (see metric 7), although the pre-flight has
   already proven the release. Suggest Caddy `lb_try_duration` for tando sites.
7. **A broken release waits out the whole `health_timeout`** (pre-flight 29 s) although the app
   answered HTTP 500 at once. The failure box shows the app's startup log but not what the probe
   got; print the last HTTP status (for example "health /api/version answered 500").
8. **Client phase times are whole seconds** (`upload 0s`, `build 3s`) while server phases have
   0.1 s, and the history total is whole seconds. Hard to compare deploys of a few seconds.
9. **On a stage/guard failure the box closes after `build ✓`** with no `✗ stage` line; the error
   is printed below the box.
10. Design notes, not bugs: `incoming/` is one more full copy of the release beside the 5 kept releases (34 MB
    here). KEEP=5 limits rollback depth to 4. The ssh ControlPersist session holds about 4.5 MB on
    the server for 60 s after each command.

## v2: final comparison, 14 Nov 2026

Same Next.js 16 standalone app, same 2 GB / 1 CPU arm64 Ubuntu containers on one M1 Pro laptop.
median [range] (n). tando = the frozen snapshot `test/.work-freeze/tree` (0.1.0), `run-a-tando.sh`,
3 rounds, each from the bare image. Rivals: 3 rounds each (`run-rivals.sh`, `run-e-rounds.sh`);
empty-VM runs for C and D n=1 (their first-pass runs were invalid, see the private raw data).
**Host load average was high and uneven** because of other work on the laptop (the owner's
Lightroom at ~260% CPU during the tando rounds): rivals 8-41, Dokku 12-115, **tando 27-93 (heavier,
not lighter, than the rivals)**. A first tando attempt was discarded: the laptop paused for 2.8 h
mid-round. Wall times and CPU-seconds are therefore noisy; memory, bytes and failed-request counts
are the reliable rows. Raw: the private raw data, summary: the private raw data; v1 (13 Nov): the private raw data.

| Metric | A tando | B Kamal 2 | C build on server | D Podman quadlet | E Dokku 0.38.34 |
|---|---|---|---|---|---|
| Idle anon, whole server, 1 app | 78 MB [76-81] (3) | 190 MB [182-190] (3) | 71 MB [70-72] (3) | 51 MB [51-54] (3) | 148 MB [146-150] (3) |
| Idle anon, 3 apps | 152 MB [150-154] (3) | 267 MB [266-271] (3) | not run | 127 MB [127-131] (3) | 228 MB [219-231] (3) |
| Idle anon, 5 / 10 apps | 225 / 411 MB (3) | not measured | not measured | not measured | not measured |
| Cold deploy (first app, to live) | 54 s [48-91] (3), verified 87 s | 96 s [88-103] (3) | 36 s [35-39] (3) | 72 s [71-75] (3) | 116 s [108-148] (3) |
| Warm deploy, to live = command returns | 11.4 s [6.3-25.3] (9) | 11.9 s [10.3-13.8] (9) | 12.8 s [10.8-16.1] (9) | 8.9 s [7.9-11.7] (9) | 49 s [35-110] (9) |
| Warm deploy, verified (after 30 s soak) | 41.9 s [36.1-61.5] (9) | - | - | - | - |
| Server CPU per warm deploy | 3.85 s [2.32-7.63] (9) ¹ | 1.57 s [1.35-1.77] (9) | 10.4 s [9.9-13.2] (9) | 1.23 s [1.09-1.69] (9) | 39.5 s [30.4-69.4] (9) |
| Bytes to the server, warm | 238 KB [170-435] (9) ¹ | 11,212 KB (9) | 14 KB (9) | 11,052 KB (9) | 324 KB (9) |
| Peak anon during a warm deploy | 118 MB (+41) (3) | 276 MB (+56) (3) | 775 MB (+697) (3) | 113 MB (+50) (3) | 754 MB (+551) (3) |
| Peak incl. cache (sum of slices) | 394 MB [378-428] (9) | 598 MB [586-662] (9) | 1,327 MB (9) | 437 MB [377-482] (9) | 1,535 MB (9) |
| Failed requests per warm deploy, ~10 req/s | 0 [0-2] (9) ² | 0 [0-0] (9) | 2 [2-2] (9) | 1 [0-6] (9) | 0 [0-0] (9) |
| Longest gap between 200s during a warm deploy | 1,685 ms [492-10,323] (9) ² | 123 ms (9) | 381 ms (9) | 704 ms (9) | 460 ms (9) |
| 3 deploys in a row under one load loop | 0 failed (3 runs) | not run | - | - | - |
| Rollback | 1.5 s [1.0-8.3] (9), 0 failed (3) | 3.2 s (15), 0 failed (6) | none | 0.8 s (6), 4 failed (3) | 28.5 s (6), 0 failed (3) |
| Broken release (health 500 on /api/version) | went live with init's `health = /` (3) ³ | old kept, 40 s (3) | no gate | went live (3) | gated by app.json (not run in v2) |
| Status query, server CPU | `ls` 68 ms [42-400] (30); 10 apps 224 ms (9) | `kamal details` 63 ms (9) | - | `podman ps` 55 ms (9) | `ps:report` 887 ms (9) |
| Background checks | tando-watch 260 ms CPU/min [185-423] (3) | - | - | - | - |
| Empty VM to first live app | 121 s [96-275] (3) | 175 s [173-277] (3) | 88 s (1) | 292 s (1) | 610 s [588-620] (3) |
| Commands / hand-written files | 3 / 0 (`host add`, `host setup`, `up`) | 3 / 2 | 7 / 2 | 7 / 3 | 9 / 2 |
| One-command path | `tando go … --yes`: 89 s, 1 command (1) | - | - | - | - |

¹ The tando CPU and bytes window runs until "verified", 30 s after live, and includes about 30
`tando releases --json` polls by the harness (~50-60 ms server CPU each): an estimated 1.5-2 s of
the 3.85 s is the harness, not tando. Not separated by measurement.
² 4 failed requests in 9 warm deploys, all status 000 (5 s client timeouts, no HTTP error), all in
rounds 1-2 at host load 70-93; round 3 (load ~30): 0 in 3. The 3-deploys-under-load check had 0
failures in all 3 rounds (5,655 requests).
Requests are held by Caddy while the app restarts, so gaps of 0.5-10 s replace v1's 2 × 502.
³ `tando init` writes `health = /` for a Next app; the broken release only broke /api/version, so
the pre-flight passed. Kamal/Dokku were configured with /api/version. Same-load re-test with
`health = /api/version`: below.

Notes: tando's Caddy uses 23 MB anon here (9-10 MB in v1 and in D); per extra app tando and the
quadlet are even (37 vs 38 MB). Dokku was measured the default way (git push, Dockerfile builder on
the server); `dokku git:from-image` (prebuilt) exists but was not measured. Empty-VM times exclude
`tando domain add` (about 1 s). `host setup` run again: 11 s [2-21] (3).

### Same-load comparison (one round each, back to back, host load 24-43)

`run-same-load.sh`: Kamal, then Podman quadlet, then tando (with `health = /api/version`, like the
rivals), 20:37-21:05 WIB. Warm = 3 quiet + 3 under the request loop per approach.

| | tando | Kamal 2 | Podman quadlet |
|---|---|---|---|
| Warm deploy to live (command returns) | 6.3 s [5.8-27.8] (6); verified 37 s | 10.6 s [10.1-11.2] (6) | 8.6 s [8.5-9.6] (6) |
| Failed requests per warm deploy | 0 (3), longest gap 374-473 ms; 3-in-a-row: 0 of 1,164 | 0 (3), gap 112-133 ms | 0 (3), gap 609-716 ms |
| Cold (first app) | 31 s to live, 60 s verified (1) | 95 s (1) | 72 s (1) |
| Rollback | 0.9 s (3) | - | - |
| Broken release (health 500 on /api/version) | old kept, 0 failed, reported after 37 s (1) | (v2 above: old kept, 40 s) | (went live) |

One round per approach: a same-conditions check of the warm-deploy ordering, not a precise figure.


## Real server trial, 14 Nov 2026 (tando only)

The owner's test VPS: x86-64, 1 vCPU ("Common KVM processor"), 1,962 MB, Ubuntu 26.04, systemd 259,
Caddy 2.6.2, with a live Next.js site (not managed by tando) running next to the test apps. No
rival was installed there: Docker, Kamal or Dokku would compete with the live site for 2 GB. The
laptop was busy (load about 30). Raw data: the private raw data.

| Measure | Result |
|---|---|
| `tando host setup` on a server already running Caddy and a live site | 11 s; Caddy not restarted (same PID) |
| First app (2-file Node app), `tando up` to live HTTPS link | 10 s, Let's Encrypt certificate issued |
| Static site, `init` + `up` | 12 s |
| Flask app, first `up` (installs the venv on the server) | 26 s to live (venv 15.7 s, 10.5 s CPU, 94 MB peak) |
| Next.js 16 app, cold `up` (1,164 files, 11 MB) | 26 s to live |
| Next.js warm deploy, one-line change | 14 s to live [11-17] (5); laptop build 3.0 s, upload 1.2 s [0.7-4.1], copy 0.7 s, pre-flight 2.5 s, switch 0.7 s |
| Bytes sent, warm | 136 KB (5) |
| Failed requests during warm deploys | 0 of 665 (5 deploys, laptop to VPS over the internet) |
| Rollback | 3.5 s [3.1-4.4] (3), 0 of 130 requests failed |
| Broken release (health 500, `health = /api/version`) | refused after 23 s; old version kept serving; 0 of 167 failed |
| Server CPU per warm deploy, including the 30 s soak | about 9 s (one run): activation 3.6 s, pre-flight start of Next 1.9 s, restart of the app 1.9 s, ssh/rsync session the rest |
| `tando-agent status` for 4 apps | 0.3-0.6 s wall, about 0.5 s CPU; `tando ls` 1.0-1.5 s wall from the laptop |
| App memory (anon) | hello 13 MB, Next 34 MB, Flask + gunicorn 39 MB; Caddy 17 MB |
| Custom domain with real DNS (`tando domain add`, nip.io name) | 14 s including a Let's Encrypt certificate |
| One command in the app sandbox (`tando ssh app -- id -un`) | 1.1 s (10 s before the fix below) |
| The live site next to it | 0 failed of 1,257 checks at 1 per second; its process never restarted |

Not comparable with the local numbers above: this CPU is several times slower than the laptop's
cores that ran the local containers. The CPU cost per deploy (about 9 s on one slow core) and the
status call (about 0.5 s of CPU, against the 50 ms target) are the two results that are worse
than the local runs suggested.

Bugs the real server exposed, all fixed the same day:

- `tando host add` failed with no reason when the server was already in `~/.ssh/known_hosts`.
- The python recipe did not install `python3-venv` (`import venv` passes without it).
- `apt` installs could let Ubuntu's `needrestart` restart unrelated services; now suspended.
- `host setup` restarted Caddy to move its admin API; it now reloads through the old address.
- The app shell spent 4.4 s compiling one regular expression.

## Real server, 15 Nov 2026 (final code)

Same VPS, same live site next to the test apps. The server runs sudo-rs.

| Measure | Result |
|---|---|
| `tando host setup` over the older install | 21-25 s; Caddyfile unchanged (same SHA-256), Caddy and the live site not restarted (same PIDs) |
| First `up` of a Node app with `database = postgres` (installs PostgreSQL) | 82 s |
| Backup of that app (data + database), restore | 3 s each |
| Deploy with a CI deploy key, including the 30 s soak | 37-38 s; the key is refused a shell, sudo, sftp, forwarding and any other app |
| 2-file Node app, deploy to live (soak in the background) | 6-14 s |
| `env set` of a value the app does not start with | refused by the pre-flight in about 12 s; the app was not restarted |
| An app whose process hangs (SIGSTOP) | alert to the webhook and restart by tando-watch 3.5 min after it hung; incident of 2 min recorded in `tando health` |
| 60 s of load at 50 connections from the laptop, with deploy, rollback, deploy during it | 8,599 requests, 0 failed, 143 requests/s (limited by the laptop's link), p50 314 ms, p99 1.07 s |
| Earlier run, deploy + rollback + deploy under load | 0 non-2xx of 5,558 |
| The live site next to it | 0 failed of 15,026 checks over 5 h (05:39-10:42 WIB) and of every check during the evening work; its process and Caddy never restarted |

Bugs this day exposed, all fixed: the sudoers rule for CI keys under sudo-rs (`!requiretty` is
rejected), `tando alerts history` reading a root-only file without sudo, `$TANDO_DATA_DIR` not
created for an app without `data =`, and `tando errors` missing an exception name that follows a
logger's prefix.

Load numbers from the local 1-CPU container are in docs/STATUS.md.

## Go server programs, 16-17 Nov 2026 (test container, 1 CPU arm64)

The root-side programs were rewritten from bash to Go (srv/). Measured on the same kind of server as
the v1 and v2 runs: a privileged Ubuntu 26.04 container with systemd, `--memory 2g --cpus 1`, on the
arm64 laptop. **This is not the real server.** The VM is x86-64 and still runs the shell versions;
see "Real server" below. Ratios should transfer; milliseconds will not. Before = the shell version,
after = the Go version, same server state, same machine, CPU of the whole process tree unless a
row says wall time.

| Measure | Shell | Go | Where it comes from |
|---|---|---|---|
| `tando-metrics read`, 2,000 five-minute points | 362 ms | 3.2 ms | docs/TOP.md |
| `tando-logs req-summary`, 7 days (190 MB request log, 600,000 lines) | 2,197 ms | 44 ms (index current) | docs/LOGGING.md |
| `tando status` on the server, answered by the daemon, 3 apps | 35.5 ms | 2.2 ms | test/load/status-scale.sh |
| the same, 20 apps | 113 ms | 3.0 ms | |
| the same, 100 apps | 417 ms | 5.7 ms | |
| One monitoring tick (metrics sample + checks + log scan), 3 apps (as reported by the test container runs; to be replaced by real-server measurements) | 94 ms | 3.8 ms | docs/MONITORING.md, "Cost" |
| the same, 20 apps (as reported by the test container runs; to be replaced by real-server measurements) | 758 ms | 7.9 ms | |
| the same, 100 apps (as reported by the test container runs; to be replaced by real-server measurements) | 2,158 ms | 27 ms | |
| Log scan under heavy load | 1.4 x the Go time | 1 | Go is only 1.4 times faster: journalctl is the floor (docs/LOGGING.md) |
| `tando ls` from the laptop (wall, over ssh) | 582 ms | 478 ms | ssh and client rendering dominate |

**Memory** (daemon memory, as reported by the test container runs; to be replaced by real-server measurements). `tandod` uses 9-11.4 MB resident at 3 and 20 apps. Over a 65-minute soak (20 apps, about
240 requests a minute) it stayed flat: no growth, no restart. Under a flood of 2 million unique URLs
over 5 apps its peak was 14.2 MB (45 MB before the scan's caches were bounded). `tando-status` peaks
at 6.5 MB (11 MB for `status` of 100 apps).

**What the numbers say, and what they do not.**

- The large ratios (50 to 100 times) come from not starting processes: the shell version started
  bash, awk, `systemctl`, `df` and `openssl` per app and per call; the Go version reads /proc,
  cgroup files and the request-log index, and asks systemd over its private socket. At 3 apps the
  fixed cost of starting one program is most of what is left.
- Where the work is journalctl's own, Go cannot help. The scan under heavy load is only 1.4 times
  faster: journalctl's output of the new entries is most of the time.
- `tando ls` from the laptop improved by about a sixth (582 to 478 ms). The server's part went from
  tens of milliseconds to a few; the rest is ssh and the client's rendering. The Go programs do not
  make a deploy faster.
- One CPU, one container, an arm64 laptop: each number is a median of repeated runs, and repeats on this machine varied by up to 50% (the ratios held).
- Not measured: a real x86-64 CPU, a real disk, a real kernel's cgroup and journald behaviour with
  real traffic, and anything over weeks.

Method and raw output: `test/load/status-bench.sh`, `test/load/status-scale.sh`, the tables in
docs/MONITORING.md ("Cost"), docs/LOGGING.md and docs/TOP.md. All the figures here are shell versus
Go on the test container.

## Go server programs on the real server, 17 Nov 2026

The same x86-64 server as the earlier real-server trials (1 vCPU, 2 GB, Ubuntu, another production
site on the same Caddy). The shell version was measured there first, then removed, and tando was set
up again from the published code. This was the first run of the x86-64 builds on a real machine.

`tando host setup` on that server: 24 s, 9 steps, Caddy and the other site untouched (same Caddy
process before and after, 0 failed requests of the other site, asked every 2 s throughout). First
deploys: 8.6 s (Node app), 8.3 s (static site), 15 s (Node app with a new PostgreSQL database).

CPU and peak memory of one call on the server, 3 apps, 5 runs each (the median is given). Each call
ran as its own systemd unit (`systemd-run --wait`), so the figures are the kernel's accounting for
the whole process tree. The request log of the app had 19,500 lines for both versions.

| Call | Shell CPU | Go CPU | Shell peak | Go peak |
|---|---|---|---|---|
| status, all apps | 372 ms | 24 ms | 7.3 MB | 1.7 MB |
| status, one app | 380 ms | 21 ms | 7.9 MB | 1.7 MB |
| one round of alert checks | 422 ms | 19 ms | 7.6 MB | 1.9 MB |
| request errors, 7 days | 200 ms | 54 ms | 6.4 MB | 2.9 MB |
| request summary, 7 days | 495 ms | 62 ms | 9.2 MB | 2.9 MB |
| metrics sample | 67 ms | 31 ms | 3.4 MB | 2.1 MB |
| history | 115 ms | 21 ms | 4.6 MB | 1.7 MB |

The shell peak of the request summary was measured with `/usr/bin/time` (maximum resident size), the
others by the unit's `memory.peak`.

From the laptop, over ssh (median of 3, connection already open): `tando ls` 0.58 s, `tando status`
0.55 s, `tando health` 0.52 s, `tando requests` 0.67 s, `tando history` 0.49 s, `tando host status`
0.99 s. Most of that is the ssh round trip and the laptop's rendering.

The monitoring daemon (`tandod`: checks, metrics and the log scan once a minute) over its first 27
minutes with 3 apps, one of them frozen on purpose to raise an alert: 58 ms of CPU per minute (0.1%
of the one CPU), 8 MB of memory, peak 17 MB, no restart. The shell version spent about 490 ms per
minute on the same work (one round of checks plus one metrics sample, from the table above).
The frozen app: the alert fired after 3 failed checks, about 3.5 minutes, and tando restarted the app.

Not measured: a full day of the daemon, and more than 3 apps on this server.

## db studio (`tando db studio`), 20 Nov 2026

`bench/run-studio.sh` on a test server limited to 1 CPU (pinned) and 2 GB, PostgreSQL 18.6, through
the real client and its ssh forward. One run each (the laptop was shared with other test runs:
numbers move by about 30% between runs). Raw output: `bench/raw/studio/`.

| Measure | Result | Budget |
|---|---|---|
| Startup, server side (agent verb to ready) | 211 ms | 400 ms |
| Startup, laptop (command to a probed link, local server) | 0.95 s | 2.5 s |
| Idle, page open, 5 min: unit memory / CPU | 9.1 MB / 72 ms | 15 MB / 200 ms |
| First page of a 100,000-row table (100 rows), API time | 4 ms | 150 ms |
| Page 1,000 (offset 99,900) | 49 ms | 300 ms |
| Peak memory over 50 pages of 500 sorted rows | 12 MB | 30 MB |
| 10,000 rows x 10 columns: time, studio CPU, peak | 30 ms, 11 ms, 12 MB | 1.5 s, 0.6 s, 48 MB |
| SELECT of 5M rows (1,000 kept): time, peak, backends active 1 s later | 3 ms, 12 MB, 0 | 1 s, 48 MB, 0 |
| 20 MB cells x 100 rows (cut at 64 KB): time, peak | 1.1 s, 12 MB | -, 48 MB |
| Heavy query (self-join of 100k rows sorted on md5, aggregate): backend private memory | 14-15 MB | (work_mem 2 MB per node) |
| Page weight raw / gzip | 36,249 / 12,720 bytes | 53,248 / 18,432 |
| After stop: units, processes, files | 0 0 0 | 0 0 0 |

No budget missed. The binary is 7.2 MB (amd64) and 6.7 MB (arm64); the release grows by those two.

**App impact** (scoping): the app's own pgbench (2 clients; a point read, a range count and an
update per transaction) and 20 s of the other app's HTTP, (a) alone, (b) with a CPU-bound studio
query (`sum(hashtext(...))` over 400M generated rows) without the priority lowering (`prio=off`),
(c) the same with it (the backend moved into a scope of CPU and I/O weight 1, nice 19). Three
interleaved rounds; the medians:

| | app pgbench tps | p95 | other app HTTP req/s | p95 |
|---|---|---|---|---|
| (a) alone | 234 | 22.6 ms | 35 | 6.3 ms |
| (b) heavy query, not lowered | 181 | 26.2 ms | 33 | 5.5 ms |
| (c) heavy query, scoped | 202 | 21.9 ms | 37 | 5.3 ms |

Honestly: (c) brings the app's p95 back to (a)'s and recovers part of the throughput, but rounds
1 and 2 showed (c) equal to (b) and round 3 (c) above (a): the effect is within this machine's
noise. The other app's HTTP is not measurably affected in any case (it is mostly Caddy and Node,
not the database). The memory bound is from settings (2 MB per sort or hash node); an OOM kill of a
backend is never relied on.
