#!/bin/bash
# nft-flush.sh (as root on the server): the stock /etc/nftables.conf starts with `flush ruleset`,
# as do many firewall tools. After it, the tando per-app loopback rules are gone and stay gone:
# tando-watch raises nothing; only `tando doctor` warns. Restore: systemctl restart tando-firewall.
nft flush ruleset
nft list table inet tando 2>&1 | head -1
