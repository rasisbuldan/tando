#!/bin/bash
# test/lint.sh: shellcheck plus tando-specific checks (test/lint.pl) on every shell file, and the
# no-shell rule on the Go server programs (srv/**/*.go: RL15, RL16), compared with a baseline of
# known findings so that only new findings fail.
#
#   test/lint.sh                     list new findings; exit 1 when there is a new error
#   test/lint.sh --all               also list baseline, info (RL08 etc.) and stale baseline entries
#   test/lint.sh --strict            new warnings fail too
#   test/lint.sh --update-baseline   record every current finding as known (whole tree only)
#   test/lint.sh --list              print the files that would be linted, with their side
#   test/lint.sh --no-shellcheck     only the tando checks (no shellcheck, no Docker)
#   test/lint.sh --no-cache          ignore and do not write the shellcheck result cache (LINT_NO_CACHE=1)
#   test/lint.sh [options] file...   lint these files only
#
# The shellcheck binary is $SHELLCHECK, else `shellcheck` on PATH, else the Docker image
# $SHELLCHECK_IMAGE (default koalaman/shellcheck:stable), one run per batch of files (LINT_JOBS
# batches at a time, default 8). Configuration: .shellcheckrc. Results are cached per file in
# .tando/lint-cache, keyed by file content, path, options, .shellcheckrc and the shellcheck version
# or image id; --no-cache or LINT_NO_CACHE=1 bypasses it (neither reads nor writes).
# Severities: shellcheck error and warning -> error; info and style -> info. The tando checks
# (RL01-RL11) are described in docs/TESTING.md. Silence one line with a comment on it or above
# it: `# lint: allow RL05 <reason>` (shellcheck codes: shellcheck's own disable directive).
# A whole-tree run also runs scripts/secret-scan.sh: any finding fails (it has no baseline).
# Exit: 0 clean, 1 new errors (or new warnings with --strict) or a secret-scan finding, 2 the
# linter itself failed.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
cd "$ROOT" || exit 2
BASELINE=${LINT_BASELINE:-test/lint-baseline.txt}
IMG=${SHELLCHECK_IMAGE:-koalaman/shellcheck:stable}
mode=show sc=1 list=0 all=0 strict=0
nocache=${LINT_NO_CACHE:-0}
[ "$nocache" = 0 ] || nocache=1
files=()

while [ $# -gt 0 ]; do
  case $1 in
    --all) all=1;;
    --strict) strict=1;;
    --update-baseline) mode=update;;
    --no-shellcheck) sc=0;;
    --list) list=1;;
    --no-cache) nocache=1;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    -*) echo "lint: unknown option $1" >&2; exit 2;;
    *) files+=("$1");;
  esac
  shift
done

# kind <file>: bash | zsh | go | "" (none of these)
kind() {
  local first=""
  case $1 in
    srv/tools/*) return;;   # srv/tools/srvlint checks itself and the rest (test/go.sh g4)
    srv/*.go) echo go; return;;
    *.zsh|completions/_*) echo zsh; return;;
    *.sh|*.bash) echo bash; return;;
    *.py|*.pl|*.md|*.js|*.json|*.txt|*.conf|*.service|*.timer|*.caddy|Caddyfile) return;;
  esac
  [ -f "$1" ] || return 0
  IFS= read -r first < "$1" || true
  case $first in
    '#!'*zsh*) echo zsh;;
    '#!'*bash*|'#!'*/sh|'#!'*/sh' '*|'#!'*' sh') echo bash;;
  esac
}

side() {
  case $1 in
    server/*|srv/*|test/server/files/*|test/replica/files/*) echo server;;
    *) if grep -q '^#[[:space:]]*lint:[[:space:]]*side=\(server\|linux\)' "$1" 2> /dev/null; then echo linux
       else echo laptop; fi;;
  esac
}

all_files() {
  local f
  {
    for f in bin/* lib/* server/* install.sh uninstall.sh completions/* scripts/*; do
      [ -f "$f" ] && echo "$f"
    done
    find test -name '.*' -prune -o -name node_modules -prune -o -type f -print
    [ -d srv ] && find srv -name '*.go' -type f
  } | sort -u | while IFS= read -r f; do
    case $f in test/lint.pl|*/id_test*) continue;; esac
    [ -n "$(kind "$f")" ] && echo "$f"
  done
}

if [ ${#files[@]} -eq 0 ]; then
  partial=0
  while IFS= read -r f; do files+=("$f"); done < <(all_files)
else
  partial=1
  [ "$mode" = update ] && { echo "lint: --update-baseline needs the whole tree (no file arguments)" >&2; exit 2; }
fi

if [ "$list" = 1 ]; then
  for f in ${files[@]+"${files[@]}"}; do printf '%-7s %-5s %s\n' "$(side "$f")" "$(kind "$f")" "$f"; done
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tando-lint.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

frag=() prog=() zshf=() gof=()
for f in ${files[@]+"${files[@]}"}; do
  case $(kind "$f") in
    go) gof+=("$f");;
    zsh) zshf+=("$f");;
    bash)
      case $f in
        # sourced fragments of one program: globals defined in one file are used in another
        lib/*.sh|test/lib.sh) frag+=("$f");;
        *) prog+=("$f");;
      esac;;
  esac
done

# Shellcheck runner: $SHELLCHECK, else `shellcheck` on PATH, else the Docker image. Paths stay
# relative to the tree (the container mounts it at /mnt and works there), so findings read
# `lib/x.sh:3:1: ...` either way.
run_shellcheck() { # [shellcheck options] -- files...
  if [ -n "${SHELLCHECK:-}" ]; then "$SHELLCHECK" -f gcc "$@"
  elif command -v shellcheck > /dev/null 2>&1; then shellcheck -f gcc "$@"
  else docker run --rm -v "$ROOT:/mnt:ro" -w /mnt "$IMG" -f gcc "$@"
  fi
}

# One perl helper does the cache work (hashing 230 files in bash would cost a fork each):
#   lintcache plan  <cachedir> <ctx> <tmp> < "mode TAB file"   hits -> $tmp/hits; misses -> $tmp/miss.<mode>
#   lintcache store <cachedir> <ctx> <tmp>                      split $tmp/batch.* per file, save, -> $tmp/new
# Cache key = sha256(ctx, mode (= the shellcheck options), path, file content); ctx = the shellcheck
# version or image id and the .shellcheckrc. A file that has a `# shellcheck source=` directive is
# never cached (its findings can come from the file it follows) and runs in the "raw" mode.
lintcache() {
  perl -MDigest::SHA=sha256_hex -e '
    my ($cmd, $dir, $ctx, $tmp) = @ARGV;
    my %opt = (frag => "-e SC2034", prog => "", rawfrag => "-e SC2034", rawprog => "");
    sub slurp { local $/; open my $h, "<", $_[0] or return ""; my $c = <$h>; close $h; defined $c ? $c : "" }
    # a file that follows others (a `# shellcheck source=` directive, or a literal `. file`) can get
    # findings from them: their content is part of its key
    sub deps {
      my ($f, $c) = @_; my @d;
      (my $dd = $f) =~ s{[^/]*$}{}; $dd = "." if $dd eq "";
      for my $p ($c =~ /^\s*#\s*shellcheck\s.*\bsource=(\S+)/mg, $c =~ /^\s*(?:\.|source)\s+["\x27]?([^\s"\x27\$`()]+)/mg) {
        next if $p eq "/dev/null";
        push @d, "$dd/$p", $p, "$dd/../$p";
      }
      return join("\0", map { $_ . "\0" . (-f $_ ? slurp($_) : "-") } @d);
    }
    sub key { my $c = slurp($_[1]); sha256_hex(join("\0", $ctx, $opt{$_[0]}, $_[1], $c, $_[0] =~ /^raw/ ? deps($_[1], $c) : "")) }
    if ($cmd eq "plan") {
      my (%miss, %fmode);
      open my $hits, ">", "$tmp/hits" or die; open my $keys, ">", "$tmp/keys" or die;
      my $nocache = $ENV{LINT_NO_CACHE_EFFECTIVE};
      while (<STDIN>) {
        chomp; my ($m, $f) = split /\t/, $_, 2;
        { my $c = slurp($f);
          $m = "raw$m" if $c =~ /^\s*#\s*shellcheck\s.*\bsource(?:-path)?=/m || $c =~ /^\s*(?:\.|source)\s+["\x27]?[^\s"\x27\$`()]/m; }
        my $k = key($m, $f);
        if (!$nocache && -f "$dir/$k") { print $hits slurp("$dir/$k"); next }
        push @{$miss{$m}}, $f; print $keys "$k\t$f\t$m\n";
      }
      for my $m (keys %miss) { open my $o, ">", "$tmp/miss.$m" or die; print $o "$_\n" for @{$miss{$m}} }
    } else {
      my (%m, %k, %out, $raw);
      open my $keys, "<", "$tmp/keys" or die;
      while (<$keys>) { chomp; my ($k, $f, $mm) = split /\t/; $k{$f} = $k; $m{$f} = $mm; $out{$f} = "" }
      open my $new, ">", "$tmp/new" or die;
      # raw files: one run each, in miss order (batch.raw.<n>); the whole output is theirs
      for my $rm (qw(rawfrag rawprog)) {
        open my $rl, "<", "$tmp/miss.$rm" or next;
        my $n = 0;
        while (<$rl>) { chomp; $out{$_} = slurp("$tmp/batch.$rm.$n"); $n++ }
      }
      for my $b (grep { !/batch\.(?:err|raw)/ } glob "$tmp/batch.*") {
        open my $h, "<", $b or next;
        while (<$h>) {
          if (/^(.+?):\d+:\d+: / && exists $out{$1} && $m{$1} !~ /^raw/) { $out{$1} .= $_ } else { print $new $_ }
        }
      }
      if ($dir ne "") {
        require File::Path; File::Path::make_path($dir); 
        for my $f (keys %out) {
          open my $o, ">", "$dir/$k{$f}.$$" or next; print $o $out{$f}; close $o;
          rename "$dir/$k{$f}.$$", "$dir/$k{$f}";
        }
      }
      print $new $out{$_} for sort keys %out;
    }' -- "$@"
}

# The tando rules (lint.pl, several seconds) and the secret scan do not depend on shellcheck: they
# run now, in the background, while shellcheck works; their results are collected below, in the
# order the sequential version used.
if [ ${#frag[@]} -gt 0 ] || [ ${#prog[@]} -gt 0 ]; then
  ( perl "$ROOT/test/lint.pl" rules ${frag[@]+"${frag[@]}"} ${prog[@]+"${prog[@]}"} > "$tmp/f.rules"; echo $? > "$tmp/f.rules.rc" ) &
fi
if [ ${#gof[@]} -gt 0 ]; then
  ( perl "$ROOT/test/lint.pl" gorules ${gof[@]+"${gof[@]}"} > "$tmp/f.gorules"; echo $? > "$tmp/f.gorules.rc" ) &
fi
if [ "$partial" = 0 ] && [ "$list" = 0 ]; then
  ( "$ROOT/test/secret-scan-test.sh" > "$tmp/secrets-test" 2>&1; echo $? > "$tmp/secrets-test.rc" ) &
  ( "$ROOT/scripts/secret-scan.sh" > "$tmp/secrets" 2>&1; echo $? > "$tmp/secrets.rc" ) &
fi

: > "$tmp/found"
if [ "$sc" = 1 ] && [ $((${#frag[@]} + ${#prog[@]})) -gt 0 ]; then
  ctx=""
  if [ -n "${SHELLCHECK:-}" ] || command -v shellcheck > /dev/null 2>&1; then
    ctx=$(run_shellcheck --version 2>&1 | tr '\n' ' ')
  else
    if ! docker image inspect "$IMG" > /dev/null 2>&1 && ! docker pull -q "$IMG" > /dev/null 2>&1; then
      echo "lint: no shellcheck (install it, or start Docker; --no-shellcheck skips it)" >&2
      exit 2
    fi
    ctx=$(docker image inspect --format '{{.Id}}' "$IMG" 2> /dev/null)
  fi
  [ -n "$ctx" ] || ctx=unknown
  ctx="$ctx|$(cat .shellcheckrc 2> /dev/null)"
  cdir=.tando/lint-cache
  LINT_NO_CACHE_EFFECTIVE=$nocache
  export LINT_NO_CACHE_EFFECTIVE
  : > "$tmp/hits"
  {
    for f in ${frag[@]+"${frag[@]}"}; do printf 'frag\t%s\n' "$f"; done
    for f in ${prog[@]+"${prog[@]}"}; do printf 'prog\t%s\n' "$f"; done
  } | lintcache plan "$cdir" "$ctx" "$tmp" || exit 2
  # the files that missed the cache: a few shellcheck runs, each over many files (a Docker run
  # costs a second or more), LINT_JOBS batches at a time, balanced by file size (a 3700-line script
  # takes shellcheck far longer than a 30-line one: the biggest ones must not share a batch)
  jobs_n=${LINT_JOBS:-8}
  for mf in "$tmp"/miss.*; do
    [ -f "$mf" ] || continue
    m=${mf##*/miss.}
    case $m in frag|rawfrag) o="-e SC2034";; *) o="";; esac
    n=$(wc -l < "$mf" | tr -d ' ')
    [ "$n" -gt 0 ] || continue
    [ "$n" -lt "$jobs_n" ] && j=$n || j=$jobs_n
    if [ "${m#raw}" != "$m" ]; then   # one run per file (output not split): bin = line number
      j=$n; awk '{ print NR - 1, $0 }' "$mf" > "$tmp/bins.$m"
    else    # shellcheck disable=SC2046 # file names have no spaces
    wc -c $(cat "$mf") | grep -v ' total$' | sort -rn |
      awk -v j="$j" '{ b = 0; for (k = 1; k < j; k++) if (s[k] < s[b]) b = k; s[b] += $1; print b, $2 }' > "$tmp/bins.$m"
    fi
    i=0
    while [ "$i" -lt "$j" ]; do
      # shellcheck disable=SC2046,SC2086 # file names have no spaces; $o is "" or one option pair
      run_shellcheck $o -- $(awk -v i="$i" '$1 == i { print $2 }' "$tmp/bins.$m") \
        > "$tmp/batch.$m.$i" 2> "$tmp/batch.err.$m.$i" &
      i=$((i + 1))
    done
  done
  wait
  cat "$tmp"/batch.err.* > "$tmp/sc.err" 2> /dev/null
  if [ -s "$tmp/sc.err" ]; then
    echo "lint: shellcheck failed:" >&2; head -5 "$tmp/sc.err" >&2; exit 2
  fi
  : > "$tmp/new"
  lintcache store "$([ "$nocache" = 1 ] && echo '' || echo "$cdir")" "$ctx" "$tmp" || exit 2
  cat "$tmp/hits" "$tmp/new" > "$tmp/sc"
  # file:line:col: severity: message [SCnnnn]  ->  file TAB line TAB col TAB sev TAB code TAB message
  perl -ne 'next unless /^(.+?):(\d+):(\d+): (\w+): (.*) \[(SC\d+)\]$/;
    my %s = (error => "error", warning => "error", note => "info");
    print join("\t", $1, $2, $3, $s{$4} // "info", $6, $5), "\n"' "$tmp/sc" >> "$tmp/found"
fi

if [ ${#zshf[@]} -gt 0 ]; then
  if command -v zsh > /dev/null 2>&1; then
    for f in ${zshf[@]+"${zshf[@]}"}; do
      zsh -n "$f" 2> "$tmp/zsh" ||
        printf '%s\t1\t1\terror\tZSH\tzsh -n: %s\n' "$f" "$(head -1 "$tmp/zsh")" >> "$tmp/found"
    done
  else
    echo "lint: zsh not installed: skipped ${zshf[*]+${zshf[*]}}" >&2
  fi
fi

# generated completions must match the command list (whole-tree runs only)
if [ "$partial" = 0 ] && [ -x completions/gen.sh ] && ! completions/gen.sh --check > /dev/null 2>&1; then
  printf 'completions/tando.bash\t1\t1\terror\tRL12\t%s\n' \
    'completions are out of date with the command list: run completions/gen.sh' \
    >> "$tmp/found"
fi

wait
for r in rules gorules; do
  [ -f "$tmp/f.$r" ] || continue
  [ "$(cat "$tmp/f.$r.rc")" = 0 ] || exit 2
  cat "$tmp/f.$r" >> "$tmp/found"
done

echo "lint: ${#files[@]} files ($((${#frag[@]} + ${#prog[@]})) bash, ${#zshf[@]} zsh, ${#gof[@]} go)," \
  "shellcheck $([ "$sc" = 1 ] && echo on || echo off)"
[ "$all" = 1 ] && mode=$mode,all
[ "$strict" = 1 ] && mode=$mode,strict
LINT_PARTIAL=$partial perl "$ROOT/test/lint.pl" report "$BASELINE" "$mode" < "$tmp/found"
rc=$?
# credentials and private details in what git would commit (whole-tree runs only). Not part of the
# baseline on purpose: --update-baseline must never be a way to accept a secret.
if [ "$partial" = 0 ] && [ "$list" = 0 ]; then
  if [ "$(cat "$tmp/secrets-test.rc")" != 0 ]; then
    echo "lint: the secret scanner fails its own test (test/secret-scan-test.sh):"
    grep '^FAIL' "$tmp/secrets-test" | sed 's/^/lint: /'
    [ "$rc" = 0 ] && rc=1
  fi
  [ "$(cat "$tmp/secrets.rc")" = 0 ] || { [ "$rc" = 0 ] && rc=1; }
  sed 's/^/lint: /' "$tmp/secrets"
fi
exit "$rc"
