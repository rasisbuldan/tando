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

t_done
