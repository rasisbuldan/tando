# Releasing and installing tando

## Versions

- `VERSION` holds the client version, `X.Y.Z`. The server agent ships inside the client (it is
  installed by `tando host setup`), so one version covers both.
- Bump Z for fixes, Y for new commands or agent verbs, X for a change to the agent protocol that an
  older client cannot read (the protocol only appends fields, so this should be rare).
- Every user-visible change gets a line under "Unreleased" in `CHANGELOG.md`.

## Making a release

```
test/all.sh && test/portability.sh             # everything green, on a Mac
$EDITOR VERSION CHANGELOG.md                   # 0.2.0; move "Unreleased" under "## 0.2.0 - <date>"
completions/gen.sh                             # if commands changed (lint warns RL12 otherwise)
scripts/release.sh                             # dist/tando-0.2.0.tar.gz, .sha256, SHA256SUMS
scripts/release.sh --check                     # optional: builds twice (Go from an empty cache), compares bytes
git tag -a v0.2.0 -m 'tando 0.2.0' && git push origin v0.2.0
gh release create v0.2.0 dist/tando-0.2.0.tar.gz dist/tando-0.2.0.tar.gz.sha256 dist/SHA256SUMS install.sh \
  --notes-file <(sed -n '/^## 0.2.0/,/^## /p' CHANGELOG.md | sed '$d')
```

The archive holds `tando-<v>/` with `bin/tando`, `lib/*.sh`, `server/*` (the shell programs),
`server/linux-amd64/<name>` and `server/linux-arm64/<name>` (the Go server programs, see
srv/README.md), `templates/*`, `completions/*`, `install.sh`, `uninstall.sh`, `VERSION`,
`README.md`, `CHANGELOG.md` (and `LICENSE` when there is one). No tests, examples, benchmarks,
Go source or `server/legacy/`. Making a release needs Go (`srv/go.mod`): `scripts/release.sh`
runs `scripts/build-server.sh` first.

**Go binaries**: `CGO_ENABLED=0`, `-trimpath`, `-buildvcs=false`, `-ldflags "-s -w -buildid= -X
.../buildinfo.Version=<VERSION>"`, `GOAMD64=v1`, `GOARM64=v8.0`, `GOTOOLCHAIN=local`, no
dependencies: the same source and Go version give the same bytes on any machine (verified on
macOS: a second build with an empty Go cache and another output directory). A different Go
version gives different bytes, so build releases with the Go that `srv/go.mod` names. Sizes at
0.1.0: tando-metrics 2.3 MB per CPU; the archive went from about 0.3 MB to 2.3 MB.

**Reproducible**: same input files, same bytes. The tar is written by perl's Archive::Tar from a
sorted list; every entry gets mtime `SOURCE_DATE_EPOCH` (default: the last commit's time, 0 when
there is none), uid/gid 0, empty owner names, mode 0755 for executables and 0644 otherwise; gzip
has no name and time 0. Verified: two builds on macOS give identical bytes. Not verified: that
macOS and Linux produce the same bytes (both use zlib through IO::Compress::Gzip, so they should;
a different zlib could change the compressed stream). The build needs a full perl (Archive::Tar,
IO::Compress::Gzip): macOS and GitHub runners have it, Debian `perl-base` alone does not.

## Installing

```
./install.sh                                   # from a checkout or an unpacked release, into ~/.local
./install.sh --system                          # /usr/local, sudo when needed
./install.sh --from ~/Downloads/tando-0.2.0.tar.gz
./install.sh --version 0.2.0      # from the GitHub release
curl -fsSLO https://github.com/rasisbuldan/tando/releases/download/v0.2.0/install.sh   # then as above
./uninstall.sh [--prefix DIR | --system] [--purge]
```

- From a checkout, install.sh builds the Go server programs first when Go is there (else it needs
  `dist/server/` from an earlier `scripts/build-server.sh`) and copies them to `server/linux-<cpu>/`.
- Result: `PREFIX/lib/tando/` (the tree, plus `.manifest`), `PREFIX/bin/tando` (a relative symlink
  into it; `bin/tando` resolves symlinks to find its libraries), completions in
  `PREFIX/share/bash-completion/completions/tando` and `PREFIX/share/zsh/site-functions/_tando`.
- An update copies the new tree next to the old one and switches with one `mv`; a failed install
  leaves the old one in place.
- `--from` takes a path, `file://` or `https://` (redirects stay on https). Plain `http://` is refused,
  because the archive and its `.sha256` could both be swapped on the way; `--insecure` allows it, and
  should come with `--sha256 HEX` from a trusted place.
- Archives are checked against SHA-256: `--sha256 HEX`, else `<archive>.sha256` from the same place.
  That catches corruption and a swapped file on a mirror, not a compromised release page; for that,
  compare with a checksum published elsewhere (the release notes, a signed tag).
- Archives with absolute paths or `..` are refused; the archive must hold one directory.
- Requirements: `/bin/bash` (3.2 or newer; NixOS and similar without `/bin/bash` are not supported),
  ssh, rsync; curl for downloads; shasum, sha256sum or openssl for the checksum.
- Tested here: install from the checkout, from a path, `file://` and `http://` with `--insecure` (a
  local server standing in for GitHub) on macOS; plain `http://` without it is refused; from a path and the checkout on Linux (Ubuntu image); a
  tampered archive and a 404 are refused; uninstall removes exactly what the manifest lists. Not
  tested: the real GitHub URL, `--system` with sudo.

`TANDO_REPO` defaults to `rasisbuldan/tando` in install.sh; set it to install from a fork.
