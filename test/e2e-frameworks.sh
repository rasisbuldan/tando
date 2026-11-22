#!/bin/bash
# End-to-end test of what tando init detects for common frameworks (test/fixtures/apps): each
# fixture is deployed with a bare `tando up` (no tando.conf; tando up installs the dependencies
# from the lockfile, builds, and deploys what init wrote). Needs npm, corepack (pnpm) and network
# access for the installs. One PASS/FAIL line per check.
# Usage: test/e2e-frameworks.sh
set -u
. "$(dirname "$0")/lib.sh"
t_init e2e-frameworks
t_server_up --reset
W=$E/w; mkdir -p "$W"
get() { curl -s -m 5 "$(t_url "$1" "${2:-/}")"; }
code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$(t_url "$1" "$2")"; }
up() { # fixture: copy it, tando up in it; output in $E/<fixture>.out, rc in RC
  rsync -a "$ROOT/test/fixtures/apps/$1/" "$W/$1/"
  (cd "$W/$1" && "$R" up < /dev/null) > "$E/$1.out" 2>&1; RC=$?
  cat "$E/$1.out" >&2
}
t_host_add
"$R" host setup test public_port="$T_HTTP_PORT" >&2

# F1. Express with pnpm: pnpm-lock.yaml installs with pnpm (corepack when pnpm is not installed)
up express-pnpm
check "F1a pnpm Express: up (rc=$RC) and it answers" t_eq "$(get express-pnpm)" "express pnpm fixture"
check "F1b installed with pnpm, detected as Express" \
  eval 'grep -q "installed dependencies: \(corepack \)\{0,1\}pnpm install --frozen-lockfile" "$E/express-pnpm.out" &&
        grep -q "^detected: Express$" "$E/express-pnpm.out" && grep -q "^  why: express in package.json, start script, pnpm-lock.yaml$" "$E/express-pnpm.out"'

# F2. NestJS: nest build, then node dist/main
up nest
check "F2 NestJS: built with nest build, runs node dist/main (rc=$RC)" \
  eval 't_eq "$(get nest)" "nest fixture" && grep -q "^start = node dist/main" "$W/nest/tando.conf"'

# F3. Next.js without output: "standalone": refused before anything is installed, with the line to add
up next-pages
check "F3 Next.js without standalone: refused (rc=$RC) with the line to add, nothing installed" \
  eval '[ $RC != 0 ] && grep -q "needs  output: \"standalone\"  in next.config.js: tando ships" "$E/next-pages.out" &&
        [ ! -d "$W/next-pages/node_modules" ]'

# F4. Vite + Vue SPA: a static site from dist; a deep link gets index.html (the router's route)
up vite-vue
check "F4a Vite + Vue: up (rc=$RC), static, spa = true" \
  eval 'get vite-vue | grep -q "<title>vite vue fixture</title>" && grep -q "^spa = true" "$W/vite-vue/tando.conf"'
check "F4b the deep link /about/team is served index.html (status $(code vite-vue /about/team))" \
  eval '[ "$(code vite-vue /about/team)" = 200 ] && get vite-vue /about/team | grep -q "<title>vite vue fixture</title>"'
# F5. SvelteKit with adapter-node: node build
up sveltekit
check "F5 SvelteKit: up (rc=$RC), node build answers its page and /health" \
  eval 'get sveltekit | grep -q "sveltekit fixture" && t_eq "$(get sveltekit /health)" ok'

# F6. One package of a monorepo (a fresh clone: no node_modules anywhere), deployed from its own
# directory: tando up installs the workspace at its root with its lockfile, and the release holds
# the workspace package it uses (@fixture/greet, and greet's own dependency ms) as real files
for pm in pnpm npm; do
  rsync -a "$ROOT/test/fixtures/apps/ws-$pm/" "$W/ws-$pm/"
  (cd "$W/ws-$pm/apps/$pm-api" && "$R" up < /dev/null) > "$E/ws-$pm.out" 2>&1; RC=$?
  cat "$E/ws-$pm.out" >&2
  check "F6a $pm workspace member: up (rc=$RC) and the workspace package answers" \
    t_eq "$(get $pm-api)" "hello $pm workspace from the greet package (1m)"
  case $pm in pnpm) i="\(corepack \)\{0,1\}pnpm install --frozen-lockfile";; npm) i="npm ci";; esac
  check "F6b $pm: installed at the workspace root, detected as a member" \
    eval 'tr -d "│" < "$E/ws-$pm.out" | tr -s " \n" "  " | grep -q "installed dependencies: $i, in \.\./\.\. (node_modules was missing" &&
          grep -q "^  workspace: package apps/$pm-api of ../.., " "$E/ws-$pm.out"'
done

# F7. A Workers API app (recipe = workerd): detected from wrangler.toml, the pinned workerd
# binary installed on the server by tando up, one workerd process of its own; the module's sibling
# import works, tando env values arrive as bindings. Idle memory of the whole unit is logged next
# to a plain Node app's
cmdline() { # app: the command line and the user of the main process of its unit
  t_srv "p=\$(systemctl show -p MainPID --value tando-$1); tr '\\0' ' ' < /proc/\$p/cmdline; echo; ps -o user= -p \$p"
}
mem() { # app: PSS and RSS of every process of the app's unit (smaps_rollup)
  t_srv "sudo sh -c 'for p in \$(cat /sys/fs/cgroup\$(systemctl show -p ControlGroup --value tando-$1)/cgroup.procs); do grep -hE \"^(Pss|Rss):\" /proc/\$p/smaps_rollup; done'" |
    awk '$1 == "Pss:" { p += $2 } $1 == "Rss:" { r += $2 } END { printf "PSS %d KB, RSS %d KB", p, r }'
}
warm() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null -m 5 "$(t_url "$1" /)"; done; }
up workerd-hello
check "F7a workerd: up (rc=$RC), detected from wrangler.toml, answers (a module with an import) and /health" \
  eval 'grep -q "^recipe = workerd" "$W/workerd-hello/tando.conf" && grep -q "^detected: Cloudflare Workers$" "$E/workerd-hello.out" &&
        t_eq "$(get workerd-hello)" "workerd fixture" && t_eq "$(get workerd-hello /health)" ok'
check "F7b workerd: the unit's process is workerd, run by the app's own user, one process of its own" \
  eval 'cmdline workerd-hello | tr "\n" " " | grep -q "^/opt/tando/workerd/workerd serve .* tando-workerd-hello *$"'
check "F7c workerd: an env value is a binding (tando env set, then the app answers with it)" \
  eval '(cd "$W/workerd-hello" && "$R" env set GREETING=hallo > /dev/null 2>&1) && t_until 30 sh -c "[ \"\$(curl -s -m 5 $(t_url workerd-hello /env))\" = hallo ]"'
check "F7d workerd: the binary is pinned by checksum (a download that does not match is refused)" \
  eval 'grep -q "^WORKERD_SHA_64=[0-9a-f]\{64\}$" "$ROOT/server/tando-agent" && grep -q "the checksum of .* is not the one tando expects" "$ROOT/server/tando-agent"'
warm workerd-hello
log "idle memory, workerd app: $(mem workerd-hello)"

# F8. node_lite = true: the app's node runs with V8's --lite-mode (a node shim first in PATH: the
# flag is not allowed in NODE_OPTIONS); the answer is the same. A plain Node app beside it does not
up express-npm
rsync -a "$ROOT/test/fixtures/apps/express-npm/" "$W/lite-express/"
(cd "$W/lite-express" && "$R" init < /dev/null > /dev/null 2>&1 && printf 'node_lite = true\n' >> tando.conf)
(cd "$W/lite-express" && "$R" up < /dev/null) > "$E/lite-express.out" 2>&1; RC=$?
cat "$E/lite-express.out" >&2
check "F8a node_lite: up (rc=$RC) and it answers" t_eq "$(get lite-express)" "express npm fixture"
check "F8b node_lite: the node process runs with --lite-mode" \
  eval 'cmdline lite-express | grep -q -- "^node --lite-mode server.js"'
check "F8c without node_lite: no --lite-mode" \
  eval '! cmdline express-npm | grep -q -- "--lite-mode" && cmdline express-npm | grep -q "^node server.js"'
warm express-npm; warm lite-express
log "idle memory: node $(mem express-npm); node_lite $(mem lite-express)"

t_done
