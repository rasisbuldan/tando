# Set up your laptop

Install tando on a Mac or Linux laptop, register a server, check the connection.
Next: [SETUP-EMPTY-VM.md](SETUP-EMPTY-VM.md) for a fresh server,
[SETUP-EXISTING-VM.md](SETUP-EXISTING-VM.md) for a server that already runs things.

## Requirements

| You need | Used for | Notes |
|---|---|---|
| macOS or Linux | | |
| `/bin/bash` 3.2 or newer | tando itself | The scripts start with `#!/bin/bash`. macOS's own bash 3.2 is enough. tando does not check the version when it runs. |
| `ssh`, `ssh-keygen`, `ssh-keyscan` (OpenSSH) | every command | `host add` uses the last two to show the server's host key. |
| `rsync` | uploading a release | GNU rsync 3.x or Apple's openrsync: tando reads the statistics of both. |
| `perl` | `tando domain add` (DNS check), `host setup` (turning a host name into an address) | Present on macOS and most Linux. |
| `curl` | `install.sh --from <URL>` and `--version` only | |
| `shasum`, `sha256sum` or `openssl` | `install.sh` checks the archive's SHA-256 | |
| Go | only to install from a git checkout | The checkout builds the server programs. A release archive already has them. |
| Node and npm, or docker/podman | building your app on the laptop | Next.js and Node apps build here. The `container` recipe needs docker or podman here. |

`install.sh` stops if `/bin/bash` is missing and only warns if `ssh` or `rsync` is missing.
The server side needs nothing from you: `tando host setup` installs it.

## Install

Homebrew, npm and apt packages are planned. They do not exist yet. `install.sh` is the only method.
It puts `tando` in `~/.local/bin`, the rest in `~/.local/lib/tando`.

**From a release archive** (if a release exists for you; `.sha256` next to it is checked):

1. `./install.sh --from tando-0.1.0.tar.gz`

   You should see `checksum ok`, then `tando 0.1.0 installed`. Or unpack the archive and run the
   `install.sh` inside it.

**From a git checkout** (needs Go):

1. `git clone <repository URL> && cd tando && ./install.sh`

   You should see `tando 0.1.0 installed`.

Other forms:

| Flag | Effect |
|---|---|
| `--prefix DIR` | Install into `DIR` instead of `~/.local`. No spaces in the path. |
| `--system` | Install into `/usr/local`, with `sudo` when it is not writable. |
| `--version 0.2.0` | Download that GitHub release. Needs `TANDO_REPO=<owner>/<repo>` set: `install.sh` has only a placeholder. |
| `--sha256 HEX` | Expected checksum of the archive. |
| `--insecure` | Allow a plain `http://` `--from` (refused otherwise). |
| `--no-completions` | Skip the completion files. |

2. `tando version`

   Prints `tando 0.1.0`. If `tando` is not found, add `~/.local/bin` to `PATH`
   (`install.sh` prints the line to use) and open a new terminal.

## Shell completions

`install.sh` copies them unless you pass `--no-completions`:

- bash: `~/.local/share/bash-completion/completions/tando`. Add
  `source ~/.local/share/bash-completion/completions/tando` to `~/.bashrc`.
- zsh: `~/.local/share/zsh/site-functions/_tando`. Add
  `fpath=(~/.local/share/zsh/site-functions $fpath)` before `compinit` in `~/.zshrc`.

With `--prefix` or `--system`, replace `~/.local` by that prefix.

## Where tando keeps your settings

`~/.config/tando/` (mode 700; set `TANDO_CONFIG_DIR` to move it). It holds:

| Path | What |
|---|---|
| `hosts/<name>` | One file per server: address, port, key, kind. |
| `known_hosts` | Host keys you trusted with `tando host add`. ssh reads it next to `~/.ssh/known_hosts`. |
| `cm/` | ssh connection sockets (a connection is reused for 60 s). |
| `go/`, `cache/`, `last-host` | Wizard answers, app-name cache, the server used last. |

Paths with spaces are refused (`TANDO_CONFIG_DIR` and `--key`). Project settings live in
`tando.conf` in each app's directory, not here.

## Give tando an ssh key and a server

tando runs ssh with `BatchMode=yes`: it never asks for a passphrase or a password.

1. `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`

   Skip it if you already have a key. Creates `~/.ssh/id_ed25519` and `.pub`.

2. `ssh-add ~/.ssh/id_ed25519`

   Needed only if the key has a passphrase: tando uses the agent. Skip otherwise.

3. `ssh-copy-id -i ~/.ssh/id_ed25519.pub admin@203.0.113.10`

   Skip it if the provider already installed your key. It asks for the password once.

4. `tando host add vps admin@203.0.113.10 --key ~/.ssh/id_ed25519`

   `vps` is the name you choose (letters, digits, `.`, `_`, `-`). Without `--key`, ssh uses your usual
   keys. tando lists the server's host keys and asks:
   `Trust them? Compare with ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the server [y/N]`.
   Compare, type `y`. Then you should see `connected`, `sudo ok, not set up yet: tando host setup vps`
   and `added host vps (admin@203.0.113.10, port 22)`.

The entry is saved only when login and passwordless sudo work. Other flags: `--port N` (not
`user@host:port`), `--yes` (trust the host key without asking), `--force` (replace a different
entry of that name), `--no-check` (save without connecting). Run the same command again after
fixing what it complained about.

## Check it

1. `tando host ls`

   One row per server: `NAME`, `TARGET`, `PORT`, `APPS`, `CARE`, `REACHABLE`, `HOST KEY`.
   `REACHABLE` should say `yes`; `HOST KEY` says `strict`.

2. `tando doctor vps`

   Works after `tando host setup vps` (see SETUP-EMPTY-VM.md). It prints a table of checks and ends
   with a line such as `0 failed, 1 warning`; the exit status is non-zero when a check failed.
   It needs the agent that `host setup` installs, so run it after setup.

3. `tando version`

   In an app directory or with one server registered it also prints `agent 0.1.0 (vps)`.

## Update and uninstall

- Update: run `install.sh` again with the new archive or checkout. The new tree replaces the old one in
  one rename; `~/.config/tando` is not touched. Then update the server's side: `tando host setup vps`
  (tando says `host vps runs agent X, this client is Y: tando host setup vps updates it` when they
  differ).
- Uninstall: `~/.local/lib/tando/uninstall.sh` (add `--prefix DIR` or `--system` to match the install).
  It removes the files `install.sh` listed in its manifest and nothing else. `--purge` also offers to
  remove `~/.config/tando` (you type `yes`). Servers are not touched: their apps keep running.

## Try it without a server

A git checkout contains a throwaway Ubuntu 26.04 "server" in Docker (`test/server/`). It is a test
fixture, developed with OrbStack; it is not in the release archive. It needs Docker, internet (the
image build downloads packages), and Go for the checkout install. The container runs `--privileged`:
a test box, not a security boundary. Ports, bound to `127.0.0.1` only: **2222** to ssh, **8080** to
Caddy's port 80. Login `vmadmin`, key `test/server/id_test` (made by the script, git-ignored),
passwordless sudo.

1. `test/server/up.sh`

   Builds the image and starts `tando-testvm`. You should see
   `tando-testvm ready: ssh vmadmin@127.0.0.1 -p 2222 ...`.

2. `tando host add local vmadmin@127.0.0.1 --port 2222 --key test/server/id_test --insecure-test`

   `--insecure-test` skips the host-key check: use it only for this box (its host keys change on `--reset`).

3. `tando host setup local public_port=8080`

   The address is loopback, so the apps domain stays `localhost` and TLS stays off: links are
   `http://<app>.localhost:8080`.

4. `cd examples/hello && tando up`

   You should see `live in ...s`. `curl http://hello.localhost:8080` prints a line starting `hello v`.

5. `cd ../.. && tando destroy hello -H local --yes`, then `test/server/down.sh`

   Removes the app, then the container (the image stays). `tando host rm local` forgets the entry.

Variants: `test/server/up.sh --reset` starts a clean container; `TANDO_TEST_BARE=1 test/server/up.sh`
makes a fresh-VM image (no Caddy, Node, rsync or curl) to rehearse SETUP-EMPTY-VM.md;
`TANDO_TEST_CADDY=ubuntu` uses the distribution's older Caddy (2.6.x). `TANDO_TEST_NAME`,
`TANDO_TEST_SSH_PORT` and `TANDO_TEST_HTTP_PORT` change the name and the two ports: then use
the same numbers in `--port` and `public_port=`. `test/server/ssh.sh [command]` logs in.
