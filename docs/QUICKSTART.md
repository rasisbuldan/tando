# Quickstart

From an empty Ubuntu server to a deployed Next.js (or any Node) app. About 5 minutes.
Hosts below are placeholders: use your own server address and domain.

You need: a Mac or Linux laptop, and a server with Ubuntu 24.04 or newer where you can
`ssh` in as a user with passwordless sudo.

**1. Install tando on your laptop.**
Download a release archive from the GitHub Releases page, then:

    ./install.sh --from tando-0.2.0.tar.gz

You should see `tando 0.2.0 installed`. Open a new terminal if `tando` is not found.
(From a checkout of the repository, `./install.sh` also works; it needs Go to build the server programs.)

**2. Check that you can log in to the server.**

    ssh admin@203.0.113.10 sudo true

You should see no password prompt and no error.

**3. Register the server.**

    tando host add vps admin@203.0.113.10

tando shows the server's key fingerprint. Compare it, type `y`. You should see `added host vps`.

**4. Set the server up (once).**

    tando host setup vps

You should see 9 steps with a check mark each, in 1 to 2 minutes, then `next: cd your-app && tando up`.

**5. Deploy your app.**

    cd my-app && tando up

tando writes `tando.conf`, creates the app and deploys. For Next.js it offers to add
`output: "standalone"` to your next config: answer yes. Your app must listen on `process.env.PORT`.
You should see `live in ...s` and a link such as `https://my-app.203-0-113-10.sslip.io`.

**6. Open the link.** The site answers over HTTPS. For your own domain, point its DNS at the
server, then run `tando domain add example.com`.

Shortcut for steps 3 to 6: `tando go admin@203.0.113.10` asks a few questions and runs them.

## The six commands you use next

Run them in the app's directory.

| Task | Command |
|---|---|
| Deploy a change | `tando deploy` |
| Go back to the previous release | `tando rollback` |
| Read the logs | `tando logs -f` |
| See state, memory, backups, alerts | `tando status` |
| Set a secret (asks for the value) | `tando env set STRIPE_KEY` |
| See and route alerts | `tando alerts` (send them to your phone: `tando alerts notifier add phone ntfy`) |

A deploy checks the new release before it takes traffic and rolls back by itself if it fails.
Something wrong? Run `tando doctor`. All commands: `tando help`.
