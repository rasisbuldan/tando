#!/bin/bash
# A fake tando for developing the web app without a server (never touches a real host):
#   TANDO_CONFIG_DIR=/tmp/x/cfg (with hosts/web-1 and hosts/web-2 files) tando-dash --no-open --tando dev/fake-tando.sh
# web-1 answers from the fixtures; web-2 is unreachable. Uses the repo's test/fixtures/json.
# snapshot and the writes go to dev/fake-state.mjs (state in $TMPDIR/tando-dash-dev/state; which
# app does what is at the top of that file).
F=$(cd "$(dirname "$0")/../../../.." && pwd -P)/test/fixtures/json
host=""; app=""; i=0; args=("$@")
sub=${2:-}
while [ $i -lt $# ]; do case ${args[$i]} in -H) host=${args[$((i+1))]};; --app) app=${args[$((i+1))]};; esac; i=$((i+1)); done
case $1 in
  --version) echo "tando 0.2.2";;
  help) echo "tando snapshot --json";;
  snapshot|deploy|rollback|stop|start|restart) exec node "$(dirname "$0")/fake-state.mjs" "$@";;
  doctor) cat "$F/doctor.sample.json";;
  host) cat "$F/host-status.sample.json";;
  jobs) cat "$F/jobs.sample.json";;
  requests) cat "$F/requests.sample.json";;
  errors) cat "$F/errors.sample.json";;
  alerts) cat "$F/alerts.sample.json";;
  history) cat "$F/history.sample.json";;
  env) case $sub in ls) cat "$F/env-ls.sample.json";; log) cat "$F/env-log.sample.json";; set) exec node "$(dirname "$0")/fake-state.mjs" "$@";; *) exit 2;; esac;;
  logs)
    follow=0; for a in "$@"; do [ "$a" = -f ] && follow=1; done
    line() { printf '{"time":"t","usec":%s,"src":"app","unit":"tando-%s%s.service","priority":%s,"level":"x","msg":"%s"}\n' "$(( $(date +%s) * 1000000 + $1 ))" "$2" "$3" "$4" "$5"; }
    i=0; while [ $i -lt 60 ]; do
      case $((i % 7)) in 0) line $i "$2" "" 3 "error: connection refused to db (attempt $i)";; 3) line $i "$2" "_worker-mail" 4 "slow job: sent 41 mails in 12 s";; *) line $i "$2" "" 6 "GET /api/items/$i 200 12ms request $i handled by the app with a fairly long message to test truncation and wrapping behaviour of the log viewer";; esac
      i=$((i+1)); done
    [ $follow = 1 ] && while :; do sleep 1; line $i "$2" "" 6 "live line $i"; i=$((i+1)); done; exit 0;;
  backup) cat "$F/backup-ls.sample.json";;
  db) # db studio <app> -H <host> --json: the ready line, then a line per "mint <app>" line on stdin,
      # until stdin closes (tando-dash stops it) or SIGTERM. The links lead nowhere: there is no studio here.
      [ "$sub" = studio ] || exit 2
      sleep 1
      n=0; printf '{"url":"http://127.0.0.1:47999/#c=fake%s&app=%s","port":47999,"sid":"0123456789ab"}\n' "$$" "$3"
      while IFS= read -r l; do case "$l" in "mint "*) n=$((n+1)); printf '{"url":"http://127.0.0.1:47999/#c=fake%sm%s&app=%s","port":47999,"sid":"0123456789ab"}\n' "$$" "$n" "${l#mint }";; esac; done
      exit 0;;
  *) echo "fake tando: $*" >&2; exit 2;;
esac
