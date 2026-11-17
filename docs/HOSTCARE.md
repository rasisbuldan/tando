# Host care: looking after the server itself

With Vercel nobody looks after a server. With tando there is one, and host care is what makes
that close to zero work: tando watches the machine (updates, security, health), tells you what
needs doing with the exact command, and, only where you allow it, does the routine part itself.

```sh
tando host status                  # the machine on one screen, and a to-do list
tando host care on --updates       # security updates install themselves (Ubuntu's unattended-upgrades)
tando host care on --reboot        # and reboots happen in a nightly window when an update needs one
tando host update                  # the pending security updates, now (--all: every update)
tando host reboot                  # a safe reboot: in the window, or at once with --now
```

`tando doctor` stays the check of tando itself (versions, Caddy, firewall rules, every app); it
has one row for host care that points here, and `tando host status` ends with tando-watch's rows
and a pointer to `tando doctor`. Nothing is listed in both.

## What is checked, and what to do about it

Facts are read from files wherever possible (`/proc`, `/run`, `/etc`, dpkg's status file, log
files); the few programs are run with fixed options: `sshd -T`, `systemctl show`/`list-units`,
one `journalctl` for the kernel's and sshd's messages since the last run, and, at most every
`apt_hours` (6) or after dpkg changed, `apt-get -s dist-upgrade` (a simulation: nothing changes),
`dpkg --audit`, `apt-config dump` and `needrestart -b -r l` (list only). Each finding has a state
(ok, warn, fail, or unknown: what cannot be determined on this machine, such as the load, memory
and clock inside a container, which are the host's; shown as "n/a", never counted or alerted), a one-line detail and the command that fixes it; `[tando can do it]` marks the
ones tando does for you (`tando host update`, `tando host reboot`, `tando host care on`).

| Finding | warn / fail when | Fix |
|---|---|---|
| security updates | pending (warn); pending longer than `updates_days` (3 days, fail). The age is counted from when tando first saw each one | `tando host update` |
| package lists | not refreshed for 2 days (warn) / 7 days (fail): new security updates are not even seen | `tando host update` |
| automatic updates | unattended-upgrades not installed, disabled, or not set up for security (warn; fail when care is on); its last run failed (fail, with the error line); has not run for 3 days (warn) | `tando host care on --updates`; the log in `/var/log/unattended-upgrades/` |
| dpkg | an install was cut off (`dpkg --audit`, half-configured packages): nothing installs until fixed | `tando host update` runs `dpkg --configure -a` first |
| held packages | `apt-mark hold` keeps them from updates | `sudo apt-mark unhold <pkg>` if not on purpose |
| apt lock | dpkg's lock held for more than an hour | see what holds it |
| old libraries | needrestart lists services still running replaced code | `tando host reboot` or restart the unit |
| reboot | `/run/reboot-required` (warn); for more than `reboot_days` (7, fail) | `tando host reboot` |
| kernel | a newer kernel is installed than the one running | `tando host reboot` |
| support | Ubuntu release past its end of standard support (fail) or within `eol_days` (60, warn); a release this tando does not know is "unknown", never guessed | `sudo do-release-upgrade` after a backup, or Ubuntu Pro (ESM) |
| open port | a TCP/UDP listener on an address other hosts can reach that is not sshd on its port, Caddy on 80/443, a DHCP client, or a tando app (whose answers to other hosts tando's nftables rules drop). Cross-checked with ufw (its own files): blocked by ufw counts as closed. With a hand-written nftables policy that drops by default, tando says it cannot tell. A provider's firewall is not visible from the server | bind it to 127.0.0.1, `sudo ufw deny <port>/<proto>`, or accept it: `tando alerts set allow_ports=tcp/5432` |
| firewall | none, or ufw allowing incoming by default (warn) | the ufw commands shown (keeping the ssh port open) |
| ssh login | passwords (or keyboard-interactive) accepted (warn); `PermitEmptyPasswords yes` (fail). Shows which users have keys (counts only) | a drop-in with `PasswordAuthentication no`, after checking your key works |
| ssh root | `PermitRootLogin yes` (warn) | `PermitRootLogin prohibit-password` |
| ssh attempts | 20+ failed logins in 24 h, passwords accepted and nothing (fail2ban, sshguard, crowdsec, `ufw limit`) slows them (warn) | turn off passwords, or `sudo apt install fail2ban` |
| accounts, sudo | an account with an empty password (warn); who has NOPASSWD sudo (information) | `sudo passwd -l <user>` |
| tando files | a secret readable by others (probe secret, notifier secrets, env files) or a world-writable file under /opt/tando (fail) | the `chmod` shown |
| services | failed systemd units (fail; tando's own app units are tando's `down` alert) | `sudo systemctl status <unit>` |
| file systems | a disk file system mounted read-only although /etc/fstab says otherwise (fail) | check the kernel log, then remount |
| disk errors | I/O errors in the kernel log in the last 24 h (fail) | a backup now, then ask the provider about the disk |
| disk / /var /boot | 90% (warn), 97% (fail); `/boot` at `boot_pct` (90, fail): kernel updates fail there | `tando host update` removes old kernels (`apt-get autoremove`) |
| memory, load, clock, journal, processes, out of memory, backups | memory/PSI and load as shown (tando alerts already alerts on them); the clock unsynchronised (warn) for `clock_min` (60 min, fail) or with no time service at all (fail); the journal over 15% of the disk; 20+ zombie processes; OOM kills in 24 h; apps whose daily backup is older than tando-watch's `backup_hours` | the command shown |
| tando | tando-watch's own rows (the checks running, notifiers) | `tando doctor` for versions, Caddy, firewall rules, apps |

Certificates are not checked here: tando alerts' `tls` check covers them (`tando status <app>`).

## Alerts

Host care feeds the alert pipeline (notifiers, silences, the state machine of
docs/MONITORING.md). tando-host writes its judgement to a summary file every hour; tando-watch
reads it as host checks (see "For tando-watch" below). Defaults:

| Check | Fires when | Priority |
|---|---|---|
| `updates` | a security update is pending longer than `updates_days` (3), unattended-upgrades fails, or dpkg is left half-configured | normal |
| `reboot` | a reboot has been needed for `reboot_days` (7) | normal, reminder daily |
| `exposed` | an unexpected port is open to the world | high |
| `ssh` | password or root login enabled | low, reminder daily |
| `units` | failed systemd units (not tando's own) | normal |
| `readonly`, `ioerr` | a file system read-only; disk I/O errors in 24 h | high |
| `clock` | not synchronised for `clock_min` (60) minutes | normal |
| `eol` | the release is past its end of support, or within `eol_days` (60) | normal, reminder weekly |
| `boot` | /boot at `boot_pct` (90%) | normal |

`tando alerts set` changes them (these keys go to tando-host, the others to tando-watch):
`updates_days`, `reboot_days`, `clock_min`, `eol_days`, `boot_pct`, `apt_hours`,
`allow_ports=tcp/5432,udp/51820`, and `<check>=off` for each check; `key=` goes back to the
default. They live in `/opt/tando/hostcare.conf` (root 644).

## Care mode: what tando may do by itself

Nothing is automatic until you turn it on, with one exception: `tando host setup` on a server it
set up from empty (it installed Caddy itself) turns on security updates (`care=off` keeps them
off). On a server whose Caddy also serves sites tando does not manage, nothing is turned on and
`tando host status` only gives hints.

**`tando host care on --updates`** (security updates every day):

- installs `unattended-upgrades` if it is missing (it is part of Ubuntu server), and enables
  `apt-daily.timer` and `apt-daily-upgrade.timer`;
- writes `/etc/apt/apt.conf.d/52tando-care`: daily package lists and upgrades, the allowed origins
  cleared and set to the security pockets only (`-security`, ESM apps and infra security), no
  automatic reboot by unattended-upgrades (tando's window does that, if you allow it);
- writes `/etc/systemd/system/apt-daily-upgrade.service.d/tando-care.conf` with
  `NEEDRESTART_SUSPEND=1`: an upgrade restarts no service tando does not manage (Ubuntu's
  needrestart would); `tando host status` lists what still runs old code;
- the hourly check puts these files back if they disappear, and, when `/boot` is 80% full,
  removes old kernels (`apt-get autoremove --purge`, `apt-get clean`); each change is an audit line.
- What was upgraded shows under "last upgrades" in `tando host status` and as an audit line
  (`host-upgraded`); a failing run fires `updates`.

It does not write your own updater, change Ubuntu's files (`20auto-upgrades`,
`50unattended-upgrades`), upgrade to a new release, or install non-security updates.
**`tando host care off`** removes tando's two files (unattended-upgrades stays as Ubuntu set it up).

**`tando host care on --reboot [--window 02:00-04:00] [--tz Asia/Jakarta] [--lead 10]`**: when an
update needs a reboot, tando reboots in the window. The rules (one function, `DecideReboot`):

- only when a reboot is needed, inside the window (in its time zone; a window may cross midnight;
  on a day whose clock skips the window for daylight saving time there is none);
- never while a deploy, an upload, a backup or a setup holds the server: tried again every 15
  minutes while the window lasts;
- never within a day of the last boot (no reboot loops);
- the first automatic reboot needs your confirmation (asked by `care on --reboot`) or one
  `tando host reboot` that came back healthy;
- never while Caddy serves sites tando does not manage, unless you passed
  `--even-with-other-sites` and confirmed; the message says why;
- apps whose daily backup is older than `backup_hours` get a backup first (no reboot if it fails);
- a notice goes out `--lead` minutes (10) before: "rebooting at 03:10 for a new kernel";
  `tando host care skip` cancels the next one (also mid-countdown);
- after the boot, `tando-host-boot.service` waits for every app's health check (at most 5
  minutes; the recover unit has brought them back) and sends "reboot done, all apps healthy in
  42s", or a notice naming the apps that did not come back;
- only root's configuration can start it: the window's timer runs `tando-host maintain`, which
  reads `/opt/tando/hostcare.conf` (root's, written only by `tando host care`); there is no socket
  verb, and nothing an app can write is read.

**`tando host update [--all]`**: refreshes the lists, shows what will change, asks, installs
the security updates (`--all`: every update, `apt-get upgrade --with-new-pkgs`, nothing removed)
with the same needrestart guard, says what still needs a reboot. **`tando host reboot [--now]`**:
the same rules as care's reboots (it waits for the window unless `--now`), then waits for ssh to
come back and reports each app. Both write audit lines (`tando audit`); a second run with nothing
to do changes nothing.

## How it runs

| Unit | Runs |
|---|---|
| `tando-host.timer` (hourly, 5 min after boot) | `tando-host check`: the facts, the summary, care's housekeeping |
| `tando-host-boot.service` (each boot) | `tando-host after-boot`: only after a reboot by tando |
| `tando-host-window.timer` (window start; only while care reboots or a reboot is planned) | `tando-host maintain` |

Files: `/opt/tando/hostcare.conf` (settings, root 644), `/var/lib/tando/hostcare/` (root 700:
`summary` and `state` root 600, `apt.json` the slow facts, `reboot` the last reboot by tando,
`skip`), `/var/log/tando-apt.log` (apt's output).

Cost: the hourly pass reads files and starts `sshd -T`, two `systemctl` and one `journalctl`;
`apt-get -s` and needrestart run at most every 6 hours. Measured by test/e2e-host.sh with
systemd's CPU accounting of `tando-host.service`.

## Summary file (for tando-watch and other readers)

`/var/lib/tando/hostcare/summary`, root 600, replaced whole on every run (temporary file, fsync,
rename). Tab-separated rows, every field cleaned (no tab, newline or control character), `-` for
empty; a reader ignores row types and trailing fields it does not know; a summary whose `<at>` is
more than 3 hours old is stale.

```
# tando-host summary, format 1 (docs/HOSTCARE.md)
summary 1 <at> <apt_at> <todo> <fail> <warn> <hostname>
alert   <check> <ok|bad|off> <since> <low|normal|high> <remind hours, 0 = default> <detail>
finding <id> <section> <ok|warn|fail|unknown> <since> <auto 0|1> <rank> <title> <detail> <fix>
```

`tando-status status` appends `hostcare <todo> <fail> <warn> <at>` from the first row (a file
read: `tando ls` shows "server: 3 to do" without any extra work).

### For tando-watch

tando-host does not touch srv/watch. To turn the summary into alerts, srv/watch needs one file
(a sketch is `srv/hostcare/testdata/check_hostcare.go.sketch`) and three one-line changes:

1. `check_hostcare.go`: read the summary (Lstat, regular, at most 1 MB); unless its `summary`
   row is format 1 and at most 3 hours old, hold every check; for each `alert` row whose check is
   one of `updates reboot exposed ssh units readonly ioerr clock eol boot`, `t.sample("_host."+c,
   "_host", c, bad|ok, detail, 1)` (need 1: tando-host has applied the time thresholds); `off`
   rows are left alone.
2. `check.go` `lastChecks()`: `hostFunc{"hostcare", checkHostcare}`.
3. `settings.go`: `lowSeverity` also true for `ssh`. Do not add these names to the settings
   table: `tando alerts set` sends them to tando-host.
4. Optional: `inbox.go` a `care` kind (`care\thost\t-\t<text>` → `CARE host: <text>`, normal
   priority). Until then tando-host's notices (reboot coming, reboot done) use the `monitor` kind,
   which is sent at high priority as `MONITOR host: ...`. The `remind` field (24 for reboot and
   ssh, 168 for eol) asks for slower reminders than `remind_hours`; honouring it is optional.
