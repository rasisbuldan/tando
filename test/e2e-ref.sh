#!/bin/bash
# test/e2e-ref.sh: where the code of a release comes from (docs/COMMANDS.md, "deploy"): the git
# commit, branch and uncommitted files recorded with every release and shown by history, releases,
# status and their JSON; the warning for a dirty tree, require_clean and --clean; deploy --ref
# (a clean temporary checkout of a branch, tag or sha: exactly the committed content, the tando.conf
# of that commit, build_files, removed after a deploy, a failure and a signal); and the version
# string of a git build (0.2.2+<sha>), which nothing compares but its base.
#   R1  provenance of a clean deploy: the state file, history, releases, status, --json
#   R2  a dirty tree: one warning with the count (ignored files and other directories of a monorepo do not count), shown as dirty
#   R3  --clean and require_clean = true refuse, nothing is deployed
#   R4  --ref: a branch, a tag, a full sha: the committed content although the tree differs
#   R5  --ref: the tando.conf of that commit; an untracked one is copied and said so
#   R6  build_files: copied into the checkout when listed, never printed, nothing else
#   R7  the temporary checkout is gone after a deploy, a failed build, an unknown ref and SIGTERM/SIGINT
#   R8  the version: 0.2.2+<sha> of a checkout, plain from a release archive or an exact tag,
#       the server's VERSION, no version note, install.sh's BUILD file
# bash 3.2 compatible.
# shellcheck disable=SC2034  # (RID, n0-n3, C3 are read in the eval strings of check)
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-ref   # work dir: test/.<suite>-<server>, or $T_WORK (all.sh)
srv() { "$SSH" "$@"; }
t_server_up --reset || exit 1
t_host_add test
"$R" host setup test public_port="$T_HTTP_PORT" >&2 || exit 1

# a git that reads nothing of the user's configuration
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export TMPDIR=$E/tmp; mkdir -p "$TMPDIR"
A=$E/w/refdemo
g() { git -C "$A" "$@"; }
get() { curl -s -m 5 "$(t_url refdemo "$1")"; }
leftovers() { find "$TMPDIR" -maxdepth 1 -name 'tando-ref.*' 2> /dev/null | wc -l | tr -d ' '; }
worktrees() { g worktree list | wc -l | tr -d ' '; }
nrel() { (cd "$A" && "$R" releases --json) | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["releases"]))'; }
# newest release's field from releases --json
rj() { (cd "$A" && "$R" releases --json) | python3 -c 'import json,sys; v=json.load(sys.stdin)["releases"][0].get(sys.argv[1]); print("null" if v is None else v)' "$1"; }
# dep <out file> args...: tando deploy in the project, output kept, status returned
dep() { local o=$1; shift; (cd "$A" && "$R" deploy "$@") > "$o" 2>&1; local rc=$?; cat "$o" >&2; return $rc; }

# ---- the project: a static site built by a command; the build shows which tando.conf and files it saw
mkdir -p "$A"
printf 'v1\n' > "$A/index.html"
cat > "$A/tando.conf" <<'EOF'
app = refdemo
host = test
recipe = static
out = dist
build = mkdir -p dist && cp index.html dist/index.html && echo conf-A > dist/which.txt && if [ -f .env.production.local ]; then echo present > dist/envstate.txt; else echo absent > dist/envstate.txt; fi && if [ -f .env.other ]; then echo present > dist/other.txt; else echo absent > dist/other.txt; fi
EOF
printf '.tando/\ndist/\nignored.txt\n.env*\n' > "$A/.gitignore"
g init -q -b main && g add -A && g commit -q -m c1 && g tag v1
C1=$(g rev-parse HEAD)

# ---- R1. a clean deploy records where the code came from
(cd "$A" && "$R" up) > "$E/up1.out" 2>&1; rc=$?; cat "$E/up1.out" >&2
check "R1a tando up from a clean tree (rc=$rc), no warning about uncommitted files" \
  eval '[ $rc = 0 ] && ! grep -q "uncommitted" "$E/up1.out" && [ "$(get /index.html)" = v1 ]'
RID=$(rj id)
check "R1b the server's state file has git_<id>=<sha>:0:main" \
  eval 'srv "sudo grep -x git_$RID=$C1:0:main /opt/tando/apps/refdemo/state" > /dev/null'
check "R1c releases --json: commit (full sha), branch, dirty_files 0" \
  eval '[ "$(rj commit)" = "$C1" ] && [ "$(rj branch)" = main ] && [ "$(rj dirty_files)" = 0 ]'
(cd "$A" && "$R" releases) > "$E/rel1.out" 2>&1
(cd "$A" && "$R" history) > "$E/his1.out" 2>&1
(cd "$A" && "$R" status) > "$E/sta1.out" 2>&1
S1=${C1:0:7}
check "R1d releases, history and status show the short sha ($S1), no \"dirty\"" \
  eval 'grep -q "$S1" "$E/rel1.out" && grep -q "$S1" "$E/his1.out" && grep -q "$S1" "$E/sta1.out" && ! grep -qi dirty "$E/rel1.out" "$E/his1.out" "$E/sta1.out"'
(cd "$A" && "$R" history --json) > "$E/his1.json" 2>&1
check "R1e history --json: the deploy has commit, branch and dirty_files" \
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"][0]; assert h["commit"]==sys.argv[2] and h["branch"]=="main" and h["dirty_files"]==0' "$E/his1.json" "$C1"
(cd "$A" && "$R" status --json) > "$E/sta1.json" 2>&1
check "R1f status --json: the release and the history entry have the commit" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["releases"][0]["commit"]==sys.argv[2] and d["history"][0]["commit"]==sys.argv[2]' "$E/sta1.json" "$C1"
(cd "$A" && "$R" snapshot --json --app refdemo) > "$E/snap1.json" 2>&1
check "R1g snapshot: the app's releases and history have the commit" \
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
a=d["app"] if "app" in d else [x for x in d["apps"] if x["name"]=="refdemo"][0]
assert a["releases"][0]["commit"]==sys.argv[2] and a["history"][0]["commit"]==sys.argv[2]' "$E/snap1.json" "$C1"

# the second commit
printf 'v2\n' > "$A/index.html"; g commit -q -am c2
C2=$(g rev-parse HEAD)
dep "$E/dep2.out"; rc=$?
check "R1h a second clean deploy (rc=$rc) records the new commit; history shows both" \
  eval '[ $rc = 0 ] && [ "$(rj commit)" = "$C2" ] && (cd "$A" && "$R" history) | grep -c "${C1:0:7}\|${C2:0:7}" | grep -qx 2'

# ---- R2. a dirty tree: one warning with the count; ignored files do not count
printf 'wip\n' > "$A/index.html"; printf 'x\n' > "$A/new.txt"; printf 'i\n' > "$A/ignored.txt"
n0=$(nrel)
dep "$E/dep3.out"; rc=$?
check "R2a deploy from a dirty tree goes live (rc=$rc) with one warning naming 2 uncommitted files and --ref" \
  eval '[ $rc = 0 ] && [ "$(grep -c "uncommitted" "$E/dep3.out")" = 1 ] && grep "uncommitted" "$E/dep3.out" | grep -q "deploying 2 uncommitted files" &&
        grep "uncommitted" "$E/dep3.out" | grep -q -- "--ref" && [ "$(get /index.html)" = wip ]'
check "R2b the release is dirty: dirty_files 2, the same commit as HEAD" \
  eval '[ "$(rj dirty_files)" = 2 ] && [ "$(rj commit)" = "$C2" ]'
(cd "$A" && "$R" releases) > "$E/rel3.out" 2>&1
(cd "$A" && "$R" history) > "$E/his3.out" 2>&1
(cd "$A" && "$R" status) > "$E/sta3.out" 2>&1
check "R2c releases, history and status mark it dirty" \
  eval 'grep -q "${C2:0:7} dirty" "$E/rel3.out" && grep -q "${C2:0:7} dirty" "$E/his3.out" && grep -q "${C2:0:7} dirty" "$E/sta3.out"'
check "R2d the dirty release's state line on the server says 2 files" \
  eval 'srv "sudo grep -E \"^git_.*=$C2:2:main\$\" /opt/tando/apps/refdemo/state" > /dev/null'

# the dirty count is the app directory's: a monorepo's other directories do not count
M=$E/mono; rm -rf "$M"; mkdir -p "$M/app" "$M/other"; printf 'a\n' > "$M/app/a.txt"; printf 'o\n' > "$M/other/o.txt"
git -C "$M" init -q -b main && git -C "$M" add -A && git -C "$M" commit -q -m m1
printf 'o2\n' > "$M/other/o.txt"; printf 'n\n' > "$M/other/new.txt"; printf 'a2\n' > "$M/app/new.txt"
check "R2e a monorepo: 3 files changed in the repo, 1 in the app directory: PROV_N is 1" \
  eval '[ "$(cd "$M/app" && bash -c ". \"$ROOT/lib/ui.sh\"; . \"$ROOT/lib/common.sh\"; . \"$ROOT/lib/deploy.sh\"; prov_detect; echo \$PROV_N" 2> /dev/null)" = 1 ]'

# ---- R3. --clean and require_clean refuse
n1=$(nrel)
dep "$E/dep4.out" --clean; rc=$?
check "R3a deploy --clean from a dirty tree is refused (rc=$rc), says how many files, nothing was deployed" \
  eval '[ $rc != 0 ] && grep -q "2 uncommitted files" "$E/dep4.out" && grep -q -- "--ref" "$E/dep4.out" && [ "$(nrel)" = "$n1" ]'
cp "$A/tando.conf" "$E/conf.keep"
printf 'require_clean = true\n' >> "$A/tando.conf"
dep "$E/dep5.out"; rc=$?
check "R3b require_clean = true refuses the same way (rc=$rc), nothing was deployed" \
  eval '[ $rc != 0 ] && grep -q "uncommitted files" "$E/dep5.out" && grep -q "require_clean" "$E/dep5.out" && [ "$(nrel)" = "$n1" ]'
check "R3c require_clean is validated (true or false)" \
  eval 'printf "app = ab\nrequire_clean = maybe\n" > "$E/bad.conf"; ! (cd "$E" && bash -c ". \"$ROOT/lib/ui.sh\"; . \"$ROOT/lib/common.sh\"; conf_load bad.conf" > "$E/bad.out" 2>&1) && grep -q "require_clean must be true or false" "$E/bad.out"'

# ---- R4. --ref: the committed content, whatever the working tree holds (still: wip, new.txt, require_clean)
n2=$(nrel)
dep "$E/ref1.out" --ref main; rc=$?
check "R4a deploy --ref main with require_clean = true in the dirty tree (rc=$rc): serves the committed v2, not wip" \
  eval '[ $rc = 0 ] && [ "$(get /index.html)" = v2 ] && ! grep -q uncommitted "$E/ref1.out" && [ "$(nrel)" = $((n2 + 1)) ]'
check "R4b the release records commit $C2 on main, clean (dirty_files 0)" \
  eval '[ "$(rj commit)" = "$C2" ] && [ "$(rj branch)" = main ] && [ "$(rj dirty_files)" = 0 ]'
check "R4c the output says what it deployed: the ref, the short sha and a clean checkout" \
  eval 'grep -q "building main (${C2:0:7} on main) from a clean checkout" "$E/ref1.out"'
dep "$E/ref2.out" --ref v1; rc=$?
check "R4d --ref v1 (a tag, an older commit; rc=$rc) serves the content of that commit; the branch is not claimed" \
  eval '[ $rc = 0 ] && [ "$(get /index.html)" = v1 ] && [ "$(rj commit)" = "$C1" ] && [ "$(rj branch)" = null ]'
dep "$E/ref3.out" --ref "$C2" --clean; rc=$?
check "R4e --ref <full sha> --clean on a dirty tree (rc=$rc): deploys that commit; the tree is not looked at" \
  eval '[ $rc = 0 ] && [ "$(get /index.html)" = v2 ] && [ "$(rj commit)" = "$C2" ] && [ "$(rj branch)" = main ]'
check "R4f the working tree was not touched by any of them (wip, new.txt, require_clean)" \
  eval '[ "$(cat "$A/index.html")" = wip ] && [ -f "$A/new.txt" ] && grep -q require_clean "$A/tando.conf"'
cp "$E/conf.keep" "$A/tando.conf"
out=$(cd "$A" && "$R" deploy --ref nosuchref 2>&1); rc=$?
check "R4g an unknown ref is refused before anything happens (rc=$rc)" \
  eval '[ $rc != 0 ] && printf "%s" "$out" | grep -q "no such branch, tag or commit"'
out=$(cd "$A" && "$R" up --ref main 2>&1); rc=$?
check "R4h tando up takes no --ref (usage error, rc=$rc)" eval '[ $rc = 2 ]'

# ---- R5. the tando.conf of the commit; an untracked one is copied, and it says so
printf 'v3\n' > "$A/index.html"
sed 's/conf-A/conf-WC/' "$E/conf.keep" > "$A/tando.conf"   # the working tree's conf differs (uncommitted)
dep "$E/ref4.out" --ref main; rc=$?
check "R5a --ref main builds with the tando.conf committed there (which.txt: conf-A), not the working tree's (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$(get /which.txt)" = conf-A ] && ! grep -q "not committed" "$E/ref4.out"'
cp "$E/conf.keep" "$A/tando.conf"
# a project whose tando.conf is not committed
U=$E/w/untracked; mkdir -p "$U"
printf 'u1\n' > "$U/index.html"; printf '.tando/\ndist/\ntando.conf\n' > "$U/.gitignore"
sed 's/^app = .*/app = refuntracked/' "$A/tando.conf" > "$U/tando.conf"
git -C "$U" init -q -b main && git -C "$U" add -A && git -C "$U" commit -q -m u1
(cd "$U" && "$R" up) > "$E/upu.out" 2>&1
printf 'u2\n' > "$U/index.html"; git -C "$U" commit -q -am u2
out=$(cd "$U" && "$R" deploy --ref main 2>&1); rc=$?
check "R5b an untracked tando.conf is copied from the working tree, and it says so (rc=$rc)" \
  eval '[ $rc = 0 ] && printf "%s" "$out" | grep -q "tando.conf is not committed: using the working tree" &&
        [ "$(curl -s -m 5 "$(t_url refuntracked /index.html)")" = u2 ]'
rm -f "$U/tando.conf"
out=$(cd "$U" && "$R" deploy --ref main 2>&1); rc=$?
check "R5c without any tando.conf the ref is refused with a reason (rc=$rc)" \
  eval '[ $rc != 0 ] && printf "%s" "$out" | grep -q "no tando.conf at that commit"'

# ---- R6. build_files: only what tando.conf lists, copied into the checkout, never printed
printf 'SECRET-VALUE-4711\n' > "$A/.env.production.local"; printf 'OTHER-4712\n' > "$A/.env.other"
dep "$E/ref5.out" --ref main
check "R6a without build_files the ignored local files are not in the checkout (build sees none)" \
  eval '[ "$(get /envstate.txt)" = absent ] && [ "$(get /other.txt)" = absent ]'
printf 'build_files = .env.production.local\n' >> "$A/tando.conf"; g add tando.conf; g commit -q -m "build_files"
C3=$(g rev-parse HEAD)
dep "$E/ref6.out" --ref main; rc=$?
check "R6b with build_files = .env.production.local only that file is copied in (rc=$rc), and it says which" \
  eval '[ $rc = 0 ] && [ "$(get /envstate.txt)" = present ] && [ "$(get /other.txt)" = absent ] &&
        grep -q "build_files: .env.production.local copied" "$E/ref6.out"'
check "R6c no output of tando shows the content of a copied file" \
  eval '! grep -rq "SECRET-VALUE-4711\|OTHER-4712" "$E/ref6.out" "$E/ref5.out"'
check "R6d the files are not part of the release (.env* never uploaded)" \
  eval '! srv "sudo find /opt/tando/apps/refdemo/releases -name \".env*\" | grep -q ."'
printf 'build_files = ../secret\n' > "$E/bf.conf"
check "R6e build_files refuses a path outside the project" \
  eval '! bash -c ". \"$ROOT/lib/ui.sh\"; . \"$ROOT/lib/common.sh\"; conf_load \"$E/bf.conf\"" > "$E/bf.out" 2>&1 && grep -q "build_files lists file names inside the project" "$E/bf.out"'

# ---- R7. nothing is left behind
check "R7a after all those --ref deploys no temporary checkout is left and git knows one worktree (left: $(leftovers), worktrees: $(worktrees))" \
  eval '[ "$(leftovers)" = 0 ] && [ "$(worktrees)" = 1 ]'
g checkout -q -b badbuild && sed 's/^build = .*/build = echo broken-build >\&2; false/' "$A/tando.conf" > "$E/bad.tando" && cp "$E/bad.tando" "$A/tando.conf" && g commit -q -am bad
out=$(cd "$A" && "$R" deploy --ref badbuild 2>&1); rc=$?
check "R7b a failed build (rc=$rc) leaves no checkout, and the build log is kept in the project's .tando/" \
  eval '[ $rc != 0 ] && [ "$(leftovers)" = 0 ] && [ "$(worktrees)" = 1 ] && grep -q broken-build "$A/.tando/build.log"'
g checkout -q main
g checkout -q -b slow && sed 's/^build = /build = sleep 6 \&\& /' "$E/conf.keep" > "$A/tando.conf" && g commit -q -am slow
g checkout -q main
cp "$E/conf.keep" "$A/tando.conf"; g checkout -q -- tando.conf 2> /dev/null
for sig in TERM INT; do
  n3=$(nrel)
  # lint: allow RL03 perl only resets SIGINT and SIGTERM to their defaults (a background job ignores SIGINT), then execs tando
  (cd "$A" && exec perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV' "$R" deploy --ref slow) > "$E/sig.$sig.out" 2>&1 &
  pid=$!
  # lint: allow RL03 the suite's own condition text, no server output
  t_until 30 eval '[ "$(leftovers)" = 1 ] && grep -q "build" "$E/sig.'"$sig"'.out"'
  sleep 1
  seen=$(leftovers)
  kill -"$sig" "$pid" 2> /dev/null
  wait "$pid" 2> /dev/null; rc=$?
  check "R7c SIG$sig during the build (rc=$rc): the checkout existed ($seen), is gone now, nothing was deployed" \
    eval '[ "$seen" = 1 ] && [ "$rc" != 0 ] && [ "$(leftovers)" = 0 ] && [ "$(worktrees)" = 1 ] && [ "$(nrel)" = "$n3" ]'
done
check "R7d the working tree is as it was (branch main, the same files, no stray worktree metadata)" \
  eval '[ "$(g rev-parse --abbrev-ref HEAD)" = main ] && [ -z "$(g worktree list | sed 1d)" ] && [ ! -d "$A/.git/worktrees" -o -z "$(ls -A "$A/.git/worktrees" 2>/dev/null)" ]'

# ---- R8. the version of a git build
ver=$(cat "$ROOT/VERSION")
out=$("$R" --version 2>&1 | head -1)
check "R8a tando --version from a git checkout: $ver+<sha> ($out)" \
  eval 'printf "%s" "$out" | grep -Eq "^tando $ver\+[0-9a-f]{7}(-dirty)?\$"'
sv=$(srv 'cat /opt/tando/VERSION')
check "R8b the server's VERSION is that string ($sv); the plain version is the base" \
  eval 'printf "%s" "$sv" | grep -Eq "^$ver\+[0-9a-f]{7}(-dirty)?\$"'
(cd "$A" && "$R" deploy --ref main) > "$E/ver.out" 2>&1
check "R8c no \"this client is\" version note although the server says $sv; ls and status print no version line" \
  eval '! grep -q "this client is" "$E/ver.out" && ! (cd "$A" && "$R" status) 2>&1 | grep -q "tando .* on the server"'
# a release archive and an exact tag: the plain version
REL=$E/rel
mkdir -p "$REL"; (cd "$ROOT" && tar -cf - bin lib server VERSION 2> /dev/null) | tar -xf - -C "$REL"
out=$("$REL/bin/tando" --version 2>&1 | head -1)
check "R8e a copy without .git (a release archive): plain version ($out)" t_eq "$out" "tando $ver"
git -C "$REL" init -q -b main && git -C "$REL" add -A && git -C "$REL" commit -q -m rel && git -C "$REL" tag "v$ver"
out=$("$REL/bin/tando" --version 2>&1 | head -1)
check "R8f exactly the tag v$ver, clean tree: plain version ($out)" t_eq "$out" "tando $ver"
printf '# x\n' >> "$REL/lib/ui.sh"
out=$("$REL/bin/tando" --version 2>&1 | head -1)
check "R8g the tag with a changed tracked file: $ver+<sha>-dirty ($out)" \
  eval 'printf "%s" "$out" | grep -Eq "^tando $ver\+[0-9a-f]{7}-dirty\$"'
git -C "$REL" commit -q -am more
out=$("$REL/bin/tando" --version 2>&1 | head -1)
check "R8h a commit after the tag: $ver+<sha> ($out)" eval 'printf "%s" "$out" | grep -Eq "^tando $ver\+[0-9a-f]{7}\$"'
# install.sh writes BUILD for a checkout (the installed tando prints it) and none for an exact tag
cp "$ROOT/install.sh" "$REL/"; git -C "$REL" add -A; git -C "$REL" commit -q -m inst
"$REL/install.sh" --prefix "$E/inst" --no-completions > "$E/inst.out" 2>&1
out=$("$E/inst/bin/tando" --version 2>&1 | head -1)
check "R8i install.sh from a checkout installs BUILD: $ver+<sha> ($out)" \
  eval '[ -f "$E/inst/lib/tando/BUILD" ] && printf "%s" "$out" | grep -Eq "^tando $ver\+[0-9a-f]{7}\$"'
git -C "$REL" tag -f "v$ver" > /dev/null 2>&1
"$REL/install.sh" --prefix "$E/inst2" --no-completions > "$E/inst2.out" 2>&1
out=$("$E/inst2/bin/tando" --version 2>&1 | head -1)
check "R8j install.sh at exactly the tag v$ver: no BUILD, plain version ($out)" \
  eval '[ ! -f "$E/inst2/lib/tando/BUILD" ] && [ "$out" = "tando $ver" ]'
t_done
