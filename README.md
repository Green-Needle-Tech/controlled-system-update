# Controlled System Update

A comprehensive, automatic + manual server update system for Linux servers running [Hermes Agent](https://github.com/NousResearch/hermes-agent) on a root-host git-clone deployment with Docker services.

**v2.2.0** — Hardened with atomic flock locking, needrestart integration, log rotation, GitHub Actions CI, and safer dist-upgrade defaults.

## What It Updates

The automatic mode updates **all software** on the server:

| Component | Method |
|-----------|--------|
| OS packages | apt update + upgrade + dist-upgrade + autoremove |
| Snap packages | snap refresh |
| Docker images | Pull latest for all running containers, recreate via compose if changed |
| Hermes Agent | git stash + pull + stash pop + uv sync + gateway restart + dashboard rebuild |
| Python/uv tools | uv tool upgrade (all installed tools) |
| npm global packages | npm update -g |

## Two Modes

### Automatic Mode (default)

- Runs daily at 04:00 via systemd timer (with 30min random delay)
- **No user intervention** — fully unattended
- **Telegram notification ONLY on failure or warnings** — silent on success
- Lock file prevents concurrent runs
- Low system priority (Nice=10) — won't starve production services
- Post-update health checks (systemd, Docker, Hermes gateway, disk/memory/load)

### Manual Mode (SRE procedure)

- Human-in-the-loop with compatibility pre-checks
- GO/NO-GO gate before any upgrades
- Dry-run simulation to inspect incoming packages
- Staged execution with verification after each phase
- Use when evaluating breaking changes from major releases

## Install

```bash
git clone https://github.com/Green-Needle-Tech/controlled-system-update.git
cd controlled-system-update
sudo bash install.sh
```

Then configure:

```bash
sudo nano /etc/controlled-system-update/auto-update.conf
# Set TG_BOT_TOKEN and TG_CHAT_ID for Telegram notifications
```

### Requirements

- Ubuntu/Debian host with `apt`
- `curl` (for Telegram API)
- Docker (optional — skipped if not installed)
- Hermes Agent installed as git clone (optional — skipped if not found)
- `uv` package manager (optional — for Python tool updates)
- `npm` (optional — for global package updates)
- A Telegram bot token and chat ID (for failure notifications)

### Getting Telegram credentials

1. Create a bot via [@BotFather](https://t.me/botfather) — get the **BOT_TOKEN**
2. Get your chat ID from [@userinfobot](https://t.me/userinfobot) — that's your **CHAT_ID**
3. Put both in `/etc/controlled-system-update/auto-update.conf`

## Configuration

Config file: `/etc/controlled-system-update/auto-update.conf`

```bash
# Telegram
TG_BOT_TOKEN="123456:ABC-DEF..."
TG_CHAT_ID="123456789"

# Toggle update phases
UPDATE_DOCKER="true"
UPDATE_HERMES="true"
UPDATE_SNAP="true"
UPDATE_NPM="true"
UPDATE_PYTHON="true"

# Packages to hold (never auto-upgrade)
PKG_HOLDS=""

# Auto-reboot if required (default: true)
# A Telegram notification is sent before rebooting
AUTO_REBOOT="true"

# Delay (in minutes) before auto-reboot — cancel with `shutdown -c`
REBOOT_DELAY="5"

# dist-upgrade can remove packages (riskier) — default: false
DIST_UPGRADE="false"

# Delete log files older than N days (0 = disable)
LOG_RETENTION_DAYS="30"

# Hermes paths (adjust for non-standard installs)
HERMES_DIR="/usr/local/lib/hermes-agent"
UV_BIN="/root/.local/bin/uv"
```

## Usage

### Automatic mode

```bash
# Check timer status
systemctl status controlled-system-update.timer

# See next scheduled run
systemctl list-timers controlled-system-update

# Run manually right now
sudo /usr/local/bin/auto-update.sh

# Trigger via systemd
sudo systemctl start controlled-system-update.service

# View logs
journalctl -u controlled-system-update -f
tail -f /var/log/controlled-system-update/last-run.log

# Disable/enable
sudo systemctl disable --now controlled-system-update.timer
sudo systemctl enable --now controlled-system-update.timer
```

### Manual mode (SRE procedure)

Ask your Hermes agent: *"run a controlled system update"* — the agent executes Phase 1 (pre-check, no changes), presents findings + planned commands, then proceeds through the staged phases with verification after each.

The full SRE procedure is documented in [SKILL.md](SKILL.md).

## Notification Behavior

| Outcome | Telegram |
|---------|----------|
| Success (no issues) | Silent — no message |
| Warnings (non-fatal) | Message with warning details |
| Errors (failures) | Message with error details + log path |

## Safety Features

- **Atomic locking** — `flock` prevents concurrent runs (no race conditions, auto-releases on crash)
- **Non-interactive apt** — `DEBIAN_FRONTEND=noninteractive` + `--force-confdef --force-confold`
- **Package holds** — `apt-mark hold` for critical packages
- **Config preservation** — dpkg options preserve existing config files
- **Low priority** — Nice=10, CPUWeight=50, IO best-effort — won't starve production
- **Memory limit** — 1G cap on systemd service
- **Auto-reboot** — reboots automatically when `/var/run/reboot-required` is present (default: enabled), with configurable delay and pre-reboot Telegram notification
- **needrestart** — automatically restarts services after library upgrades (if installed)
- **Log rotation** — auto-deletes log files older than 30 days (configurable)
- **Health checks** — systemd failed units, Docker status, Hermes gateway, disk/memory/load
- **Hermes-safe** — git stash/pop preserves local mods, gateway restart + dashboard rebuild
- **Docker-safe** — pulls images, recreates via compose, prunes dangling images
- **No catch-up** — `Persistent=false` on timer, missed runs don't pile up
- **CI** — ShellCheck linting via GitHub Actions on every push

## File Structure

```
controlled-system-update/
├── .github/workflows/lint.yml         # ShellCheck CI
├── CHANGELOG.md                       # Version history
├── SKILL.md                           # Full SRE procedure + auto-mode docs
├── README.md                          # This file
├── LICENSE                            # MIT
├── install.sh                         # One-command installer
├── e2e-test.sh                        # End-to-end test suite
├── scripts/
│   └── auto-update.sh                 # Main automatic update script
├── config/
│   └── auto-update.conf               # Configuration template
└── systemd/
    ├── controlled-system-update.service  # systemd service unit
    └── controlled-system-update.timer    # systemd daily timer
```

## Why

`hermes update` restarts the gateway, which kills any agent session that invoked it. Combined with a venv that has no `pip` binary (uv-managed), a gateway that never auto-respawns, and apt prompts that hang non-interactive scripts, a naive "apt upgrade && hermes update" breaks the agent in at least four distinct ways.

This project encodes the working order of operations, the repair paths for each failure mode, and wraps it all in a script that runs automatically — notifying you only when something goes wrong.

## Uninstall

```bash
sudo systemctl disable --now controlled-system-update.timer
sudo rm /usr/local/bin/auto-update.sh
sudo rm /etc/systemd/system/controlled-system-update.{service,timer}
sudo systemctl daemon-reload
sudo rm -rf /etc/controlled-system-update /var/log/controlled-system-update
```

## License

MIT
