#!/usr/bin/perl
# test/lint.pl: tando-specific shell checks that shellcheck cannot do, and the baseline report.
# Called by test/lint.sh; not meant to be run by hand.
#
#   lint.pl rules <file>...      print findings: file TAB line TAB col TAB severity TAB code TAB msg
#   lint.pl gorules <file>...    the same for the Go server programs (srv/): RL15, RL16
#   lint.pl report <baseline> <mode>   read findings on stdin, compare with the baseline, print
#                                      mode: show | all | update | strict
#
# The checks are line-based heuristics over a "masked" copy of each line: the contents of
# single-quoted strings are blanked (they are awk/perl/sed programs or remote commands, not
# local shell code), comments are removed and heredoc bodies are skipped. A finding is
# silenced for one line by a comment on that line or the line above:
#     # lint: allow RL05 <reason>
# Laptop-side rules (RL01, RL02, RL10) skip files that run on the server: server/, test/server/files/,
# test/replica/files/, or any file with a "# lint: side=server" line.
use strict;
use warnings;

my $mode = shift @ARGV // '';
if ($mode eq 'rules') { rules(@ARGV); exit 0 }
if ($mode eq 'gorules') { gorules(@ARGV); exit 0 }
if ($mode eq 'report') { exit report(@ARGV) }
die "usage: lint.pl rules <file>... | report <baseline> <mode>\n";

# ---------------------------------------------------------------------------------------------
# gorules: no shell, ever (srv/README.md). Every program srv/ starts goes through
# srv/internal/run, which takes an argv and refuses shells:
#   RL15  os/exec imported, or a process started (os.StartProcess, syscall.Exec/ForkExec), outside
#         srv/internal/run
#   RL16  a string literal that names a shell or its "-c": "sh", "bash", "dash", "zsh", "/bin/sh",
#         "/bin/bash", "/usr/bin/env", "-c" (anywhere in srv/, tests too)
# These are the cheap first line (test/go.sh g4); srv/tools/srvlint is the real check, on the syntax
# trees (aliases, raw syscalls, folded literals, the closed list of programs). srv/internal/run,
# which defines and tests the list of shells it refuses, is exempt from RL16; srv/tools/ is not
# read here at all (test/lint.sh), srvlint reads it.
# Line-based: string literals ("..." and one-line `...`) are found first, so a // comment or a
# word in a comment does not count. Silence one line: // lint: allow RL16 <reason>

sub gorules {
    for my $f (@_) {
        open my $fh, '<', $f or do { warn "lint.pl: cannot read $f\n"; next };
        my @lines = <$fh>;
        close $fh;
        chomp @lines;
        my $runpkg = $f =~ m{(?:^|/)srv/internal/run/[^/]+$};
        for my $i (0 .. $#lines) {
            my (@strs, $code);
            $code = '';
            my $l = $lines[$i];
            while ($l =~ /\G(?:("(?:[^"\\]|\\.)*")|(`[^`]*`)|(\/\/.*)|(.))/gc) {
                if (defined $1 || defined $2) { push @strs, [$1 // $2, $-[0] + 1]; $code .= '""' }
                elsif (defined $3) { last }
                else { $code .= $4 }
            }
            my %a = goallow(\@lines, $i);
            for my $s (@strs) {
                my ($lit, $col) = @$s;
                if (!$runpkg && $lit eq '"os/exec"' && !$a{RL15}) {
                    print join("\t", $f, $i + 1, $col, 'error', 'RL15',
                        'os/exec outside srv/internal/run: start programs with run.Cmd (argv, timeout, env)'), "\n";
                }
                if (!$runpkg && $lit =~ m{^["`](?:sh|bash|dash|zsh|/bin/sh|/bin/bash|/usr/bin/env|-c)["`]$} && !$a{RL16}) {
                    print join("\t", $f, $i + 1, $col, 'error', 'RL16',
                        "$lit: no shell, ever; pass an argv to run.Cmd"), "\n";
                }
            }
            if (!$runpkg && !$a{RL15} && $code =~ /\b(os\.StartProcess|syscall\.(?:Exec|ForkExec|StartProcess))\b/) {
                print join("\t", $f, $i + 1, $-[0] + 1, 'error', 'RL15',
                    "$1 outside srv/internal/run: start programs with run.Cmd"), "\n";
            }
        }
    }
}

# goallow(lines, i): codes silenced by "// lint: allow CODE..." on line i or the line above
sub goallow {
    my ($lines, $i) = @_;
    my %a;
    for my $j ($i - 1, $i) {
        next if $j < 0;
        if ($lines->[$j] =~ m{//\s*lint:\s*allow\s+((?:RL\d+)(?:[\s,]+RL\d+)*)}) { $a{$_} = 1 for split /[\s,]+/, $1 }
    }
    return %a;
}

# ---------------------------------------------------------------------------------------------
# rules

my (%safe, %safe_by_file, @out, $file_allow);

sub rules {
    my @files = @_;
    my %src;
    for my $f (@files) {
        open my $fh, '<', $f or do { warn "lint.pl: cannot read $f\n"; next };
        my @l = <$fh>;
        close $fh;
        chomp @l;
        $src{$f} = \@l;
    }
    # Names whose every assignment (in any linted file) is a literal that cannot be empty or
    # contain shell metacharacters: such variables are safe in remote commands and rm paths.
    my (%lit, %nonlit, %flit, %fnon);
    for my $f (keys %src) {
        for (@{ $src{$f} }) {
            while (/(?:^|[\s;(])(?:local\s+|readonly\s+|export\s+)?([A-Za-z_]\w*)=("?)([^\s"'`;]*)\2(?=\s|;|$)/g) {
                my ($n, $v) = ($1, $3);
                if ($v ne '' && $v =~ m{^[A-Za-z0-9_./:@%+,-]+$}) { $lit{$n} = $flit{$f}{$n} = 1 }
                else { $nonlit{$n} = $fnon{$f}{$n} = 1 }
            }
        }
    }
    # a name assigned in the file itself is judged by that file's assignments; otherwise by all
    # files (lib/*.sh use globals from lib/common.sh)
    my %global = map { $_ => 1 } grep { !$nonlit{$_} } keys %lit;
    for my $f (keys %src) {
        my %s = %global;
        for my $n (keys %{ $flit{$f} || {} }, keys %{ $fnon{$f} || {} }) {
            $s{$n} = ($flit{$f}{$n} && !$fnon{$f}{$n}) ? 1 : 0;
        }
        $safe_by_file{$f} = \%s;
    }
    check($_, $src{$_}) for sort keys %src;
    print @out;
}

sub emit {
    my ($f, $n, $col, $sev, $code, $msg, $allow) = @_;
    return if $allow->{$code} || $allow->{ALL} || ($file_allow && $file_allow->{$code});
    push @out, join("\t", $f, $n, $col, $sev, $code, $msg) . "\n";
}

# mask(line, state) -> (code, state). state: '' | 'sq' (inside a multi-line single-quoted string)
sub mask {
    my ($s, $st) = @_;
    my $o = '';
    my $q = $st;    # '', 'sq', 'dq'
    my @c = split //, $s;
    for (my $i = 0; $i < @c; $i++) {
        my $ch = $c[$i];
        if ($q eq 'sq') {
            if ($ch eq "'") { $q = ''; $o .= $ch } else { $o .= '_' }
            next;
        }
        if ($ch eq '\\') { $o .= $ch . ($c[$i + 1] // ''); $i++; next }
        if ($q eq 'dq') {
            $q = '' if $ch eq '"';
            $o .= $ch;
            next;
        }
        if ($ch eq "'") { $q = 'sq'; $o .= $ch; next }
        if ($ch eq '"') { $q = 'dq'; $o .= $ch; next }
        if ($ch eq '#' && ($i == 0 || $c[$i - 1] =~ /[\s;(|&]/)) { last }
        $o .= $ch;
    }
    # a double quote left open continues on the next line; treat the line as code
    return ($o, $q eq 'sq' ? 'sq' : '');
}

sub check {
    my ($f, $lines) = @_;
    %safe = %{ $safe_by_file{$f} || {} };
    my $server = $f =~ m{^(server/|test/server/files/|test/replica/files/)} ? 1 : 0;
    $server = 1 if grep { /^#\s*lint:\s*side=(?:server|linux)/ } @$lines;
    my %fa;    # "# lint: file-allow RL06 <reason>": the whole file
    for (@$lines) { if (/^#\s*lint:\s*file-allow\s+((?:RL\d+)(?:[\s,]+RL\d+)*)/) { $fa{$_} = 1 for split /[\s,]+/, $1 } }
    $file_allow = \%fa;
    my $test = $f =~ m{^test/} ? 1 : 0;
    my $shebang = @$lines && $lines->[0] =~ /^#!/ ? $lines->[0] : '';
    my $zsh = $shebang =~ /zsh/ || $f =~ /\.zsh$|_tando$/;
    return if $zsh;    # zsh completion: syntax-checked with zsh -n by lint.sh

    # set -u, file level
    my $setu = 0;
    for (@$lines) {
        my $l = $_;
        $l =~ s/\s#.*//;
        $setu = 1 if $l =~ /^\s*set\s+(-[a-zA-Z]*u|-o\s+nounset)|^\s*set\s+-[a-zA-Z]*\s+-[a-zA-Z]*u/;
    }
    $setu = 1 if $shebang =~ /\s-[a-zA-Z]*u/;
    $setu = 1 if !$setu && (sources_setu($f, $lines) || exec_only($lines));
    if ($shebang && !$setu) {
        my %a = allow($lines, 0);
        emit($f, 1, 1, $test ? 'warn' : 'error', 'RL09',
            'no `set -u` (or set -o nounset): a misspelt or unset variable expands to "" silently', \%a);
    }
    if ($shebang =~ m{^#!\s*/usr/bin/env\s+bash} && !$server && !$test) {
        my %a = allow($lines, 0);
        emit($f, 1, 1, 'info', 'RL11',
            '#!/usr/bin/env bash runs Homebrew bash 5 when it is first in PATH, hiding bash 3.2 bugs', \%a);
    }

    # arrays assigned only non-empty lists: safe to expand under set -u
    my (%arr_empty, %guarded);
    for (@$lines) {    # [ ${#a[@]} -gt 0 ] || exit ...: the script stops when a is empty
        $guarded{$1} = 1 if /\$\{#(\w+)\[@\]\}\s+-(?:gt|ne)\s+0\s*\]\s*\|\|.*\b(?:exit|die|return)\b/;
        $guarded{$1} = 1 if /\$\{#(\w+)\[@\]\}\s+-eq\s+0\s*\]\s*&&.*\b(?:exit|die|return)\b/;
    }
    for (@$lines) {
        while (/\b([A-Za-z_]\w*)=\(\s*\)/g) { $arr_empty{$1} = 1 }
        while (/\blocal\s+(?:-a\s+)?([A-Za-z_]\w*)(?=\s|$|;)/g) { $arr_empty{$1} = 1 }
    }

    my $st = '';
    my @hd;    # pending heredoc terminators
    my $in_hd;
    for my $i (0 .. $#$lines) {
        my $raw = $lines->[$i];
        my $n = $i + 1;
        my %a = allow($lines, $i);

        my $u = $raw;
        utf8::decode($u);
        my $len = length($u);
        emit($f, $n, 121, 'info', 'RL08', "line is $len characters (limit 120)", \%a) if $len > 120;

        if ($in_hd) {
            my ($tag, $dash) = @$in_hd;
            if ($raw eq $tag || ($dash && $raw =~ /^\t*\Q$tag\E$/)) {
                $in_hd = shift @hd;
            }
            next;
        }
        my ($c, $nst) = mask($raw, $st);
        $st = $nst;
        # a heredoc starts at a << outside quotes (found in the masked line); its tag is read from the
        # raw line, since masking turns <<'EOF' into <<'___', a tag that never ends
        while ($c =~ /(?<!<)<<(?!<)/g) {
            push @hd, [$3, $1 eq '-'] if substr($raw, pos($c)) =~ /^(-?)\s*\\?(["']?)([A-Za-z_][A-Za-z0-9_]*)\2/;
        }
        $in_hd = shift @hd if @hd;
        next if $c =~ /^\s*$/;
        my $rc = $raw;    # raw minus a trailing comment (keeps single-quoted text)
        $rc = substr($raw, 0, length($c));    # mask keeps one character per character

        my $remote = $c =~ /(?:^|[;&|(!{]|\bthen|\bdo|\belse|\$\()\s*(?:command\s+|exec\s+)?(?:ssh|srv|"\$SSH"|\$SSH|\S*ssh\.sh)\s/ ? 1 : 0;

        # ---- RL01 bash 4+ constructs (laptop side) -------------------------------------------
        if (!$server) {
            my @b4 = (
                [qr/\b(?:declare|local|typeset|readonly)\s+(?:-\w+\s+)*-\w*A/, 'associative array (bash 4)'],
                [qr/\b(?:declare|local|typeset)\s+(?:-\w+\s+)*-\w*n\b/, 'nameref declare -n (bash 4.3)'],
                [qr/\b(?:declare|typeset)\s+(?:-\w+\s+)*-\w*[glu]\b/, 'declare -g/-l/-u (bash 4)'],
                [qr/\$\{[#!]?\w+(?:\[[^\]]*\])?(?:\^\^?|,,?)/, 'case modification ${x,,} ${x^^} (bash 4)'],
                [qr/\$\{\w+(?:\[[^\]]*\])?\@[QEPAaUuLKk]\}/, '${x@Q}-style transformation (bash 4.4)'],
                [qr/\b(?:mapfile|readarray)\b/, 'mapfile/readarray (bash 4)'],
                [qr/&>>/, '&>> append redirect (bash 4)'],
                [qr/\|&/, '|& pipe (bash 4)'],
                [qr/\bwait\s+(?:-\w+\s+)*-\w*[np]/, 'wait -n / wait -p (bash 4.3/5.1)'],
                [qr/\bread\b[^;|&]*\s-\w*t\s*[0-9]*\.[0-9]/, 'read -t with a fraction (bash 4)'],
                [qr/\bprintf\s+-v\s+["']?\w+\[/, 'printf -v into an array element (bash 4.1)'],
                [qr/\$\{\w+\[-[0-9]/, 'negative array index (bash 4.3)'],
                [qr/\$\{\w+(?:\[[^\]]*\])?:(?![-=?+])[^:}{]*:\s*-[0-9]/, 'negative substring length (bash 4.2)'],
                [qr/\bcoproc\b/, 'coproc (bash 4)'],
                [qr/;;&|(?<![;&]);&(?!&)/, 'case fall-through ;;& or ;& (bash 4)'],
                [qr/\bshopt\s+-s\s+.*\b(?:globstar|lastpipe|autocd|direxpand|checkjobs)\b/, 'shopt option not in bash 3.2'],
                [qr/(?<!\\)\$\{?(?:EPOCHSECONDS|EPOCHREALTIME|BASHPID|BASH_ARGV0|SRANDOM)\b/, 'variable not in bash 3.2'],
                [qr/%\([^)]*\)T/, 'printf %(...)T (bash 4.2)'],
                [qr/(?:\[\[|\btest|\[)\s+-v\s/, 'test -v (bash 4.2)'],
                [qr/\{-?[0-9]+\.\.-?[0-9]+\.\.-?[0-9]+\}/, 'brace expansion with a step (bash 4)'],
                [qr/(?:^|\s)\{[A-Za-z_]\w*\}[<>]/, 'automatic fd {var}> (bash 4.1)'],
            );
            for my $r (@b4) {
                if ($c =~ $r->[0]) {
                    emit($f, $n, $-[0] + 1, 'error', 'RL01', "$r->[1] in `$&`: macOS /bin/bash is 3.2", \%a);
                }
            }
            # ---- RL10 empty array under set -u (bash < 4.4 calls it unbound) ------------------
            if ($setu) {
                while ($c =~ /\$\{(\w+)\[[@*]\](.)(.?)/g) {
                    my ($name, $nx, $nx2, $p) = ($1, $2, $3, $-[0]);
                    next if $nx eq '+' || $nx eq '-' || ($nx eq ':' && $nx2 =~ /[+-]/);
                    next unless $arr_empty{$name};
                    next if $guarded{$name};
                    next if $c =~ /\$\{\Q$name\E\[[@*]\]:?\+|\$\{#\Q$name\E\[[@*]\]\}\s+-(?:gt|ne)\s+0/;
                    emit($f, $n, $p + 1, 'warn', 'RL10',
                        "\"\${$name\[@]}\" with set -u: bash 3.2 reports 'unbound variable' when $name is empty;"
                          . " use \${$name\[@]+\"\${$name\[@]}\"}", \%a);
                }
            }
        }

        # ---- RL02 GNU-only tools and flags (laptop side) -----------------------------------------
        if (!$server && !$remote) {
            my @g = (
                [qr/\bsed\b[^|;&]*\s-[a-zA-Z]*i(?:\s|$)/, 'error',
                    'sed -i with no attached suffix: GNU and BSD sed parse it differently; use sed -i.bak or a temp file'],
                [qr/\bdate\b[^|;&]*\s(?:-d\s|--date)/, 'error', 'date -d/--date is GNU-only (BSD: date -j -f)'],
                [qr/\bdate\b[^|;&]*%N/, 'error', 'date %N is GNU-only (BSD prints N); use perl Time::HiRes'],
                [qr/\breadlink\s+-[a-z]*[fem]\b/, 'error', 'readlink -f/-e/-m: GNU (macOS only has -f since 12.3); resolve with cd + pwd -P'],
                [qr/\bstat\s+(?:-c|--format|--printf)\b/, 'error', 'stat -c is GNU-only'],
                [qr/\bstat\s+-[a-zA-Z]*f\s/, 'warn', 'stat -f is BSD-only: breaks the client on Linux'],
                [qr/\bgrep\b[^|;&]*\s(?:-[a-zA-Z]*P|--perl-regexp)/, 'error', 'grep -P is GNU-only'],
                [qr/\bmktemp\b[^|;&]*\s(?:-p\s|--)/, 'error', 'mktemp -p / long options are GNU-only; use mktemp "${TMPDIR:-/tmp}/x.XXXXXX"'],
                [qr/\bmktemp\s+(?:-d\s+)?-t\s/, 'warn', 'mktemp -t means prefix on BSD, template on GNU'],
                [qr/\bmktemp\b[^|;&]*\s-u\b/, 'warn', 'mktemp -u only names a file: racy'],
                [qr/(?:^|[;&|({!]|\bthen|\bdo|\belse|\$\()\s*timeout\s/, 'error', 'timeout(1) is not on macOS'],
                [qr/\bsort\b[^|;&]*\s(?:-[a-zA-Z]*V|--version-sort)/, 'error', 'sort -V is GNU-only'],
                [qr/\bfind\b.*\s-(?:printf|regextype|delete\s+-maxdepth)\b/, 'error', 'find -printf/-regextype are GNU-only'],
                [qr/(?:^|[;&|({!]|\bthen|\bdo|\$\()\s*(?:tac|nproc)\b/, 'error', 'tac/nproc are not on macOS'],
                [qr/(?:^|[;&|({!]|\bthen|\bdo|\$\()\s*(?:sha256sum|sha1sum|md5sum)\b/, 'warn',
                    'sha256sum/md5sum are missing on older macOS; use shasum -a 256 or cksum'],
                [qr/\b(?:cp|mv|ln)\s+(?:-\w+\s+)*-\w*T\b/, 'error', 'cp/mv/ln -T is GNU-only'],
                [qr/\binstall\s+(?:-\w+\s+)*-\w*D\b/, 'error', 'install -D is GNU-only'],
                [qr/\bxargs\s+(?:-\w+\s+)*-\w*d\b/, 'error', 'xargs -d is GNU-only'],
                [qr/\bbase64\s+(?:-\w+\s+)*-w\b/, 'error', 'base64 -w is GNU-only'],
                [qr/\bdu\s+-\w*b\b/, 'error', 'du -b is GNU-only'],
                [qr/\bhead\s+-n\s*-[0-9]|\btail\s+-n\s*\+0/, 'error', 'head -n -N is GNU-only'],
                [qr/(?:^|[;&|({!]|\bthen|\bdo|\belse|\$\()\s*(?:sed|cut|date|sort|ls|cp|mv|mkdir|stat|touch|head|tail|wc|uniq|du|df|find|xargs|readlink|mktemp|ln|chmod|chown|rm)\s+[^|;&)]*\s--[a-z][a-z-]+/,
                    'warn', 'GNU long option: BSD tools on macOS may reject it'],
            );
            for my $r (@g) {
                next unless $c =~ $r->[0];
                # "date -r/-j ... || date -d ...": the BSD form first, GNU as the fallback
                next if $r->[2] =~ /^date -d/ && $c =~ /\bdate\s+-[jr]\b/;
                # "elif command -v sha256sum ...; then sha256sum": a fallback after shasum
                next if $r->[2] =~ /^sha256sum/ && $c =~ /\bcommand\s+-v\b/;
                emit($f, $n, $-[0] + 1, $r->[1], 'RL02', $r->[2], \%a);
            }
            if ($raw =~ /\b(gensub|strftime|systime|asorti?|PROCINFO|mktime)\s*\(/ && $raw !~ /\bperl\b/) {
                emit($f, $n, $-[0] + 1, 'error', 'RL02', "awk $1() is gawk-only (macOS awk, mawk lack it)", \%a);
            }
        }

        # ---- RL03 eval / source of data ---------------------------------------------------------
        # eval of a single-quoted literal (also one that continues on the next lines) is a fixed program
        if ($c =~ /(?:^|[\s;&|(!])eval(?:\s|$)(?!\s*'_*(?:'\s*(?:$|[;&|)])|$))/) {
            my $p = $-[0] + 1;
            if ($rc =~ /\bssh\b|\bagent(?:_raw)?\b|\bcurl\b|<\(|\$TMPD|\.out\b|\$\(\s*cat/) {
                emit($f, $n, $p, 'error', 'RL03', 'eval of command output or a file: server output must never be evaluated', \%a);
            } else {
                emit($f, $n, $p, $test ? 'info' : 'warn', 'RL03', 'eval: make sure no part comes from the server or the network', \%a);
            }
        }
        if ($c =~ /(?:^|[;&|(]|\bthen|\bdo|\belse)\s*(?:source|\.)\s+(\S+)/) {
            my ($p, $arg) = ($-[1] + 1, $1);
            # "$(dirname "$0")/lib.sh", "$(cd "$(dirname ...)" && pwd)/x": next to the script itself
            my $rel = substr($c, $-[1]) =~ /^"?\$\((?:cd\s+"?\$\()?dirname\s/;
            if ($rel) {
            } elsif ($arg =~ /<\(|\/dev\/(?:stdin|fd)|\$\(/) {
                emit($f, $n, $p, 'error', 'RL03', 'source of command output: never source what the server prints', \%a);
            } elsif ($arg =~ /^"?\$\{?(\w+)/ && $1 !~ /^(?:TANDO_HOME|ROOT|HERE|here|D|DIR|dir|root|TOP|LIB|lib|T|TREE|BASH_SOURCE)$/) {
                emit($f, $n, $p, 'warn', 'RL03', "source of a path built from \$$1: make sure it is not a downloaded or server-written file", \%a);
            }
        }

        # ---- RL04 expansions in remote command strings -------------------------------------------
        if ($remote) {
            my $line = $rc;
            while ($line =~ /"((?:[^"\\]|\\.)*)"/g) {
                my $s = $1;
                next if $s !~ /\s/;                              # single word: an option or the target
                next if $s =~ /^\$\{?\w+(?:\[[@*]\])?\}?$/;
                next if $s =~ /^-/;
                while ($s =~ /(?<!\\)\$(\{)?(\w+|\()/g) {
                    my ($name, $at) = ($2, $-[0]);
                    next if $name eq '(' ? 0 : $safe{$name};
                    my $before = substr($s, 0, $at);
                    my $squotes = () = $before =~ /'/g;
                    next if $squotes % 2;                        # inside '...' for the remote shell
                    my $what = $name eq '(' ? 'a $(...) result' : "\$$name";
                    emit($f, $n, 1, $test ? 'info' : 'warn', 'RL04',
                        "$what is pasted into a command the remote shell parses again: validate it or quote it for the remote side", \%a);
                    last;
                }
            }
        }

        # ---- RL05 rm -r on a path built from a variable that could be empty -----------------------
        if ($c =~ /\brm\s+(?:-\w+\s+)*-\w*[rR]/) {
            my $args = substr($c, $+[0]);
            $args =~ s/[;&|].*//;
            while ($args =~ /(?:^|\s)"?(?:\$\{(\w+)(:\?)?[^}]*\}|\$(\w+))/g) {
                my ($name, $guard) = (defined $1 ? $1 : $3, $2);
                my $after = substr($args, $+[0], 2);
                next if $guard;
                next unless $after =~ m{^"?[/*]};
                next if $safe{$name} || $name eq 'HOME';
                emit($f, $n, 1, 'error', 'RL05',
                    "rm -r on \"\$$name/...\": if $name is ever empty this removes from /; use \"\${$name:?}/...\"", \%a);
            }
        }

        # ---- RL06 temp files outside mktemp -------------------------------------------------------
        if ($rc !~ /\bmktemp\b/) {
            if ($c =~ /(?<![:\w-])\/tmp\/[\w.\$\{-]/ && $c !~ /\$\{TMPDIR:-\/tmp\}/) {
                my $sev = ($server || $c =~ /\$\$/) ? 'error' : 'warn';
                emit($f, $n, $-[0] + 1, $sev, 'RL06',
                    'fixed name under /tmp: another user can pre-create or symlink it; use mktemp (or a 700 dir from mktemp -d)', \%a);
            } elsif ($c =~ /\$\{?TMPDIR\b[^}]*\}?\/[\w.-]*\$\$/) {
                emit($f, $n, $-[0] + 1, 'error', 'RL06', 'predictable temp name ($$): use mktemp', \%a);
            }
        }

        # ---- RL07 secrets on a command line (visible in ps on both ends) ---------------------------
        my $secret = qr/\$\{?\w*(?i:pass(?:wd|word)?|secret|token|api_?key|private_?key|credential)\w*/;
        if ($rc =~ /(?:^|[\s;&|(!])(?:ssh|srv|agent|agent_raw|curl|psql|mysql|"\$SSH"|\$SSH|docker\s+(?:run|exec))\s.*$secret/) {
            emit($f, $n, 1, $test ? 'info' : 'warn', 'RL07',
                'a secret-looking value is passed as a process argument (visible in ps, and in the remote shell\'s argv): send it on stdin', \%a);
        } elsif ($rc =~ /\bcurl\b.*(?:\s-u\s+\S*\$|Authorization:[^"]*\$)/) {
            emit($f, $n, 1, 'warn', 'RL07', 'credentials in curl arguments: use --netrc-file or -K - on stdin', \%a);
        }

        # ---- RL13 apt installs on the server without NEEDRESTART_SUSPEND --------------------------
        if ($server && !$test && $c =~ /\bapt(?:-get)?\s+(?:-\S+\s+)*install\b/ && $c !~ /\bNEEDRESTART_SUSPEND=1\s/) {
            emit($f, $n, $-[0] + 1, 'error', 'RL13',
                'apt install without NEEDRESTART_SUSPEND=1: Ubuntu\'s needrestart may restart services tando does not manage', \%a);
        }

        # ---- RL14 pipe into grep -q: grep exits at the first match, the writer gets SIGPIPE and
        # pipefail then reads a match as a failure. Use grepq (reads all input) -----------------------
        if (!$test && $c =~ /\|\s*grep\s+(?:-\S+\s+)*-[a-zA-Z]*q/) {
            emit($f, $n, $-[0] + 1, 'error', 'RL14',
                'pipe into grep -q: with pipefail an early exit turns a match into a failure; use grepq', \%a);
        }
    }
}

# sources_setu(file, lines): the script sources a file (found by name next to it, in its parent
# or in test/) that turns on set -u, e.g. faults/*.sh sourcing lib-fault.sh
sub sources_setu {
    my ($f, $lines) = @_;
    (my $dir = $f) =~ s{/[^/]*$}{};
    $dir = '.' if $dir eq $f;
    for my $l (@$lines) {
        next unless $l =~ /^\s*(?:\.|source)\s+(.*)/;
        my $rest = $1;
        my @n = $rest =~ /([\w.-]+\.(?:sh|bash))\b/g or next;
        my $base = $n[-1];
        next unless $base =~ /^[\w.-]+$/;
        for my $cand ("$dir/$base", "$dir/../$base", "test/$base") {
            open my $fh, '<', $cand or next;
            while (my $x = <$fh>) { return 1 if $x =~ /^\s*set\s+(?:-[a-zA-Z]*u|-o\s+nounset)/ }
        }
    }
    return 0;
}

# exec_only(lines): every command is `exec ...` (a script that only hands over to another)
sub exec_only {
    my $lines = shift;
    my $n = 0;
    for my $l (@$lines) {
        next if $l =~ /^\s*(?:#|$)/;
        return 0 unless $l =~ /^\s*(?:\w+=(?:"[^"]*"|'[^']*'|\S*)\s+)*exec\s/;
        $n++;
    }
    return $n > 0;
}

# allow(lines, i): codes silenced by "# lint: allow CODE..." on line i or the line above
sub allow {
    my ($lines, $i) = @_;
    my %a;
    for my $j ($i - 1, $i) {
        next if $j < 0;
        if ($lines->[$j] =~ /#\s*lint:\s*allow\s+((?:RL\d+|SC\d+|ALL)(?:[\s,]+(?:RL\d+|SC\d+))*)/) {
            $a{$_} = 1 for split /[\s,]+/, $1;
        }
    }
    return %a;
}

# ---------------------------------------------------------------------------------------------
# report

# false_positive(code, line, col, file lines): shellcheck findings known to be wrong here
#   SC1010: `done` used as a word (`pg phase done result ok`), not the loop keyword
#   SC2178/SC2179/SC2128: the name is a nameref (local -n) or a function-local variable that another
#   function uses as an array (shellcheck does not track local scope)
sub false_positive {
    my ($code, $l, $col, $src) = @_;
    if ($code eq 'SC1010') {
        return $l !~ /\b(?:for|while|until|select)\b/ && $l =~ /[\w-]\s+done\b/;
    }
    if ($code =~ /^SC21(?:78|79|28)$/) {
        my ($name) = substr($l, $col - 1) =~ /^\$?\{?(\w+)/;
        return 0 unless $name;
        for (@$src) {
            return 1 if /\b(?:local|declare|typeset)\s+(?:-\w+\s+)*-\w*n\w*\s+(?:\w+(?:=\S*)?\s+)*\Q$name\E\b/;
            return 1 if /^\s*local\s(?:[^#]*\s)?\Q$name\E(?:=|\s|$)/;
        }
    }
    return 0;
}

sub norm { my $s = shift; $s =~ s/^\s+|\s+$//g; $s =~ s/\s+/ /g; return $s }

sub report {
    my ($bfile, $mode) = @_;
    my %m = map { $_ => 1 } split /,/, $mode;    # show | all | strict | update
    my (%base, %srcs);
    if (open my $b, '<', $bfile) {
        while (<$b>) {
            chomp;
            next if /^#/ || !/\t/;
            $base{$_}++;
        }
    }
    my @f;
    while (<STDIN>) {
        chomp;
        my ($file, $line, $col, $sev, $code, $msg) = split /\t/, $_, 6;
        next unless defined $msg;
        unless ($srcs{$file}) {
            my @l;
            if (open my $fh, '<', $file) { @l = <$fh>; chomp @l }
            $srcs{$file} = \@l;
        }
        my $raw = $srcs{$file}[$line - 1] // '';
        next if false_positive($code, $raw, $col, $srcs{$file});
        my $text = norm($raw);
        my $key = join("\t", $file, $code, $text);
        push @f, { file => $file, line => $line, col => $col, sev => $sev, code => $code, msg => $msg, key => $key };
    }
    @f = sort { $a->{file} cmp $b->{file} || $a->{line} <=> $b->{line} || $a->{col} <=> $b->{col} || $a->{code} cmp $b->{code} } @f;
    # de-duplicate identical findings (shellcheck run on overlapping groups)
    my %seen;
    @f = grep { !$seen{"$_->{file}:$_->{line}:$_->{col}:$_->{code}"}++ } @f;

    # info findings are advice: never in the baseline, never failing, shown with --all only
    if ($m{update}) {
        @f = grep { $_->{sev} ne 'info' } @f;
        open my $o, '>', $bfile or die "cannot write $bfile\n";
        print $o "# test/lint-baseline.txt: known findings, written by `test/lint.sh --update-baseline`.\n";
        print $o "# One line per finding: file TAB code TAB source line (whitespace collapsed). Line numbers are\n";
        print $o "# not stored, so edits elsewhere in a file do not invalidate entries. Remove lines as fixed.\n";
        print $o "# Info findings (RL08 line length, shellcheck style notes) are never recorded here.\n";
        print $o "$_\n" for sort map { $_->{key} } @f;
        close $o;
        printf "lint: baseline written: %d findings in %s\n", scalar(@f), $bfile;
        return 0;
    }
    my %left = %base;
    my (%cnt, %bycode);
    for my $x (@f) {
        if ($x->{sev} ne 'info' && $left{ $x->{key} }) { $left{ $x->{key} }--; $x->{base} = 1 }
        my $k = ($x->{base} ? 'base' : 'new') . ".$x->{sev}";
        $cnt{$k}++;
        $bycode{ $x->{code} }{ $x->{base} ? 'base' : 'new' }++;
        next if ($x->{base} || $x->{sev} eq 'info') && !$m{all};
        printf "%s:%d:%d: %s: %s [%s]%s\n", $x->{file}, $x->{line}, $x->{col}, $x->{sev}, $x->{msg}, $x->{code},
            $x->{base} ? ' (baseline)' : '';
    }
    my $stale = 0;
    $stale += $_ for values %left;
    $stale = 0 if $ENV{LINT_PARTIAL};    # only some files were linted
    if ($stale && $m{all}) {
        for my $k (sort keys %left) { print "stale baseline entry: $k\n" x $left{$k} }
    }
    my $c = sub { $cnt{ $_[0] } // 0 };
    print "\n";
    printf "lint: %d new (%d error, %d warn, %d info); %d in baseline (%d error, %d warn, %d info)%s\n",
        $c->('new.error') + $c->('new.warn') + $c->('new.info'), $c->('new.error'), $c->('new.warn'), $c->('new.info'),
        $c->('base.error') + $c->('base.warn') + $c->('base.info'), $c->('base.error'), $c->('base.warn'), $c->('base.info'),
        $stale ? "; $stale baseline entries no longer found (fixed or moved: --update-baseline)" : '';
    my @codes = sort keys %bycode;
    print 'lint: by code: ', join(', ', map { "$_ " . (($bycode{$_}{new} // 0) + ($bycode{$_}{base} // 0)) . (($bycode{$_}{new}) ? " ($bycode{$_}{new} new)" : '') } @codes), "\n" if @codes;
    return 1 if $c->('new.error');
    return 1 if $m{strict} && $c->('new.warn');
    return 0;
}
