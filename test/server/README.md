# tando test server

A throwaway Ubuntu 26.04 "VPS" in Docker (OrbStack): systemd as PID 1, sshd, sudo, Caddy 2 (official
apt repo), Node 24 (nodejs.org tarball in /usr/local), rsync 3.4 with `rrsync`, curl, flock, setpriv.

    test/server/up.sh            # build + start tando-testvm (idempotent), writes test/server/.ready
    test/server/up.sh --reset    # remove the container and start a clean one (~3 s with a cached image)
    test/server/down.sh          # remove the container (image kept)
    test/server/ssh.sh [cmd...]  # ssh vmadmin@127.0.0.1 -p 2222 with the test key, no known_hosts

- Login: `vmadmin`, key `test/server/id_test` (generated, git-ignored), passwordless sudo, groups
  `sudo,adm` (can read the journal without sudo).
- Ports, 127.0.0.1 only: 2222 -> ssh, 8080 -> Caddy :80. Links: `http://<app>.localhost:8080`.
- Caddyfile: a `:80` catch-all (404) plus `import /etc/caddy/tando/*.caddy` (empty dir is fine).
  Site files must use `http://<host>` addresses (no TLS here). `systemctl reload caddy` works; a bad
  file makes the reload fail and Caddy keeps the old config.
- ssh host keys are generated on first boot: stable across `docker restart`, new after `--reset`.
  Point your ssh at `UserKnownHostsFile=/dev/null` (or a temp file) for this host.
- The container runs `--privileged --cgroupns=private`; it is a test box, not a security boundary.

Unit sandbox directives: all tested ones work (NoNewPrivileges, ProtectSystem=strict, ProtectHome,
PrivateTmp, PrivateDevices, ReadWritePaths, SocketBindAllow/SocketBindDeny, MemoryMax incl. OOM kill).
Quirks: the kernel boot id is shared with the OrbStack VM, so `docker restart` does not start a new
`journalctl -b` boot; `memory.current` includes page cache (~80 MB of node binary for a hello app).
