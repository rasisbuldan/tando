#!/usr/bin/perl
# prefix each input line with seconds since start (3 decimals)
use Time::HiRes qw(time); $|=1; my $t0=time; while(<STDIN>){ printf "%8.3f %s", time-$t0, $_ }
