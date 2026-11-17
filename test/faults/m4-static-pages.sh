#!/bin/bash
# m4: a static site with clean URLs and its own 404 page. Expect: /about serves about.html,
# /docs/ its index.html, a missing page answers 404 with the project's 404.html; without a
# 404.html still a plain 404. Run it on TANDO_TEST_CADDY=ubuntu (Caddy 2.6.2) too.
. "$(dirname "$0")/lib-fault.sh"
f_init m4 "static site: clean URLs, 404.html" "Caddy static site"
A=fm4
srv "sudo test -d /opt/tando/apps/$A" 2> /dev/null && echo "$A" | (cd "$W" && "$R" destroy -a $A --purge > /dev/null 2>&1)
mkdir -p "$W/$A/docs"
printf 'app = %s\nrecipe = static\n' $A > "$W/$A/tando.conf"
echo home-page > "$W/$A/index.html"; echo about-page > "$W/$A/about.html"
echo docs-page > "$W/$A/docs/index.html"; echo not-found-page > "$W/$A/404.html"
(cd "$W/$A" && "$R" up > "$W/up.out" 2>&1) || { cat "$W/up.out" >&2; echo "m4: up failed" >&2; exit 1; }
get() { curl -s -m 5 -o "$W/body" -w '%{http_code}' "$(url $A "$1")"; }
is() { local c; c=$(get "$1"); [ "$c" = "$2" ] && grep -qx "$3" "$W/body" || { echo "    $1 -> $c $(head -c 80 "$W/body")" >&2; return 1; }; }
ok "/ serves index.html" is / 200 home-page
ok "/about serves about.html" is /about 200 about-page
ok "/about.html still works" is /about.html 200 about-page
ok "/docs/ serves docs/index.html" is /docs/ 200 docs-page
ok "/nope answers 404 with 404.html" is /nope 404 not-found-page
ok "/docs/nope.png answers 404 with 404.html" is /docs/nope.png 404 not-found-page
rm "$W/$A/404.html"; echo about-2 > "$W/$A/about.html"
(cd "$W/$A" && "$R" deploy > "$W/d2.out" 2>&1) || { cat "$W/d2.out" >&2; F_FAILS=$((F_FAILS + 1)); }
ok "the new release serves /about" is /about 200 about-2
ok "without 404.html a missing page is still a 404" sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -m 5 $(url $A /nope))\" = 404 ]"
echo "$A" | (cd "$W" && "$R" destroy -a $A --purge > /dev/null 2>&1)
f_end
