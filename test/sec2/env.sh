# source me: environment for security review 2 (server tando-sec2 on 2260/8360; tando-sec2b on 2262/8362)
W=/Users/you/tando/test/.work-sec2
ROOT=$W/tree T=$W/tree R=$W/tree/bin/tando
: "${SEC2_B:=0}"
if [ "$SEC2_B" = 1 ]; then SP=2262 HP=8362 NAME=tando-sec2b CFGD=$W/cfgb; else SP=2260 HP=8360 NAME=tando-sec2 CFGD=$W/cfg; fi
export TANDO_TEST_NAME=$NAME TANDO_TEST_SSH_PORT=$SP TANDO_TEST_HTTP_PORT=$HP
export TANDO_CONFIG_DIR=$CFGD TANDO_COLOR=never GIT_CEILING_DIRECTORIES=$W
unset TANDO_DEPLOY_KEY TANDO_HOST TANDO_PORT TANDO_KNOWN_HOSTS TANDO_PLAIN CI GITHUB_ACTIONS
srv() { "$ROOT/test/server/ssh.sh" "$@"; }
KOPTS=(-F /dev/null -p "$SP" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes
       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
KA=$W/key.alpha$([ "$SEC2_B" = 1 ] && echo b) KB=$W/key.bravo$([ "$SEC2_B" = 1 ] && echo b)
kssh() { local k=$1 u=$2; shift 2; ssh "${KOPTS[@]}" -i "$k" "$u@127.0.0.1" "$@"; }
ka() { kssh "$KA" tando-d-alpha "$@"; }
AG=/opt/tando/bin/tando-agent INC=/opt/tando/apps/alpha/incoming/
begin_a() { ka "sudo -n $AG begin alpha x" 2> /dev/null | sed -n 's/^token=//p'; }
end_a() { echo "$1" | ka "sudo -n $AG end alpha" > /dev/null 2>&1; }
act_a() { echo "$1" | ka "sudo -n $AG activate alpha 0 0" 2>&1; }
get() { curl -s -m 5 "http://$1.localhost:$HP${2:-/}"; }
secret() { awk -v n="--- $2" '$0 == n { on = 1; next } /^--- / { on = 0 } on' "$1"; }
conf_set() { grep -v "^$2 *=" "$1" > "$1.tmp"; [ -n "$3" ] && echo "$2 = $3" >> "$1.tmp"; mv "$1.tmp" "$1"; }
# run as root in the container (setup and observation only, never as part of an attack step)
rootsh() { docker exec -i "$NAME" bash -c "$1"; }
# compromised app code: alpha's release has a backdoor that runs bash as tando-alpha inside its unit
x() { curl -s -m ${XT:-60} --data-binary @- "http://${XAPP:-alpha}.localhost:$HP/__x" <<< "$*"; }
cideploy() { # app dir key: tando deploy with the app's deploy key from the environment
  (cd "$1" && TANDO_DEPLOY_KEY=$2 TANDO_HOST=127.0.0.1 TANDO_PORT=$SP CI=true \
     TANDO_KNOWN_HOSTS=$(secret "$W/setup.$(sed -n 's/^app *= *//p' tando.conf)$([ "$SEC2_B" = 1 ] && echo b)" TANDO_KNOWN_HOSTS) TANDO_CONFIG_DIR=$W/cfg-ci$([ "$SEC2_B" = 1 ] && echo b) \
     "$R" deploy 2>&1); }
