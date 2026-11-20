# Documentation

Read in this order if you are new.

| Document | What it is |
|---|---|
| [QUICKSTART.md](QUICKSTART.md) | From an empty server to a deployed app, step by step |
| [SETUP-LAPTOP.md](SETUP-LAPTOP.md) | Install tando on a Mac or Linux laptop, add a server, try it without one |
| [SETUP-EMPTY-VM.md](SETUP-EMPTY-VM.md) | A fresh Ubuntu server: DNS, firewall, `host setup`, first app, alerts, backups |
| [SETUP-EXISTING-VM.md](SETUP-EXISTING-VM.md) | A server that already runs things: what tando touches, conflicts, `adopt`, removal |
| [EASE.md](EASE.md) | `tando go`, the one-command wizard |
| [COMMANDS.md](COMMANDS.md) | Every command and flag |
| [LOGGING.md](LOGGING.md) | App logs, request logs and how long they are kept |
| [MONITORING.md](MONITORING.md) | Alerts, health checks and where notices go |
| [BACKUP.md](BACKUP.md) | Backups, offsite copies (R2 or any S3 storage) and recovery |
| [HOSTCARE.md](HOSTCARE.md) | Looking after the server: updates, reboots, host checks |
| [CI.md](CI.md) | Deploying from GitHub Actions with a restricted key |
| [CROSS-ARCH.md](CROSS-ARCH.md) | Building on a Mac, running on Linux: native npm packages, what is swapped and verified |
| [TOP.md](TOP.md) | `tando top`, the live dashboard |
| [MIGRATION.md](MIGRATION.md) | Taking over an app that was deployed by hand |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the pieces fit: the client, the agent, the server programs, the files on the server |
| [STATUS.md](STATUS.md) | What is built, what is verified, what is open |
| [TESTING.md](TESTING.md) | How to run the test suites |
| [RELEASING.md](RELEASING.md) | How a release is made |
| [SECURITY-REVIEW-CI.md](SECURITY-REVIEW-CI.md), [SECURITY-REVIEW-2.md](SECURITY-REVIEW-2.md), [FAULT-REVIEW.md](FAULT-REVIEW.md), [VERIFY.md](VERIFY.md) | Review reports on security and faults |
| [CODE-REVIEW.md](CODE-REVIEW.md), [UX-REVIEW.md](UX-REVIEW.md), [UX-REVIEW-2.md](UX-REVIEW-2.md) | Review reports on code and usability |

Older design notes and specifications, kept for the record: [history/](history/).

Benchmarks against other tools: [../bench/RESULTS.md](../bench/RESULTS.md).
