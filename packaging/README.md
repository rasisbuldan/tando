# Packaging the tando client

Every package is built from the release archive (`scripts/release.sh`, which needs Go), so all ship the
same files: `bin/`, `lib/`, `templates/`, `completions/` and the Linux server programs in
`server/linux-{amd64,arm64}/`, which `tando host setup` installs on a server over ssh.

- Homebrew: `scripts/package.sh homebrew` writes `dist/homebrew/tando.rb` (version, sha256, URL).
- npm: `scripts/package.sh npm` writes `dist/npm/` and `dist/tando-cli-<v>.tgz`. No install scripts.
- Debian/Ubuntu: `scripts/package.sh deb` writes `dist/tando_<v>_all.deb`; needs `dpkg-deb`.
- `make package` builds all three. Set `TANDO_REPO=<owner>/<repo>` (and `TANDO_MAINTAINER` for the deb).

Not done, because they need the owner's accounts: no Homebrew tap repository, no `npm publish`
(the name `tando-cli` is unchecked: npm/NAME-CHECK.txt), no apt repository or signing.
The formula was syntax-checked and its layout run by hand, not installed by `brew`.
