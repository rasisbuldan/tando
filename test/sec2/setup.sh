#!/bin/bash
# Build the review environment on tando-sec2 (or tando-sec2b with SEC2_B=1): host setup, apps alpha
# (attacker: backdoor + job, data dir) and bravo (victim: data, env secret), deploy keys for both.
set -u
. /Users/you/tando/test/.work-sec2/env.sh
sfx=$([ "$SEC2_B" = 1 ] && echo b)
rm -rf "$TANDO_CONFIG_DIR" "$W/cfg-ci$sfx"; mkdir -p "$TANDO_CONFIG_DIR"
srv "echo 'PerSourcePenalties no' | sudo tee /etc/ssh/sshd_config.d/05-tando-test.conf > /dev/null && sudo sshd -t && sudo systemctl reload ssh"
"$R" host add test vmadmin@127.0.0.1 --port "$SP" --key "$ROOT/test/server/id_test" --yes > /dev/null
"$R" host setup test public_port="$HP" > "$W/setup$sfx.out" 2>&1 || { cat "$W/setup$sfx.out"; exit 1; }
for a in alpha bravo; do (cd "$W/w/$a" && "$R" up > "$W/up.$a$sfx" 2>&1) || { cat "$W/up.$a$sfx"; exit 1; }; done
(cd "$W/w/bravo" && "$R" env set SECRET_B=bravo-secret-value > /dev/null 2>&1)
(cd "$W/w/alpha" && "$R" env set SECRET_A=alpha-secret-value > /dev/null 2>&1)
srv "sudo -u tando-bravo sh -c 'umask 077; echo bravo-data-value > /opt/tando/apps/bravo/shared/data/db.json'"
(cd "$W/w/alpha" && "$R" ci setup > "$W/setup.alpha$sfx" 2> "$W/setup.alpha$sfx.err") || cat "$W/setup.alpha$sfx.err"
(cd "$W/w/bravo" && "$R" ci setup > "$W/setup.bravo$sfx" 2> /dev/null)
secret "$W/setup.alpha$sfx" TANDO_DEPLOY_KEY > "$KA"; secret "$W/setup.bravo$sfx" TANDO_DEPLOY_KEY > "$KB"; chmod 600 "$KA" "$KB"
echo "alpha: $(get alpha)"; echo "bravo: $(get bravo)"
echo "backdoor: $(x id)"
