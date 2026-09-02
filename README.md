# Controlled System Update

A comprehensive, automatic + manual server update system for Linux servers running [Hermes Agent](https://github.com/NousResearch/hermes-agent) with Docker services.

**v2.3.0** — Production hardening: supported Hermes updater, external skill lifecycle, deferred reboot, config preservation, safer defaults, real flock tests.

## What It Updates

The automatic mode updates the following by default:

| Component | Method | Default |
|-----------|--------|---------|
| OS packages | apt update + upgrade | enabled |
| Snap packages | snap refresh | enabled |
| Docker images | Pull latest for running containers, recreate via Compose if changed | enabled |
| Hermes Agent | `hermes update --yes` (supported updater) | enabled |
| Hermes external skills | `hermes skills check` (report only) | enabled |
| Python/uv tools | uv tool upgrade | **opt-in** |
| npm global packages | npm update -g | **opt-in** |
| dist-upgrade | apt-get dist-upgrade | **opt-in** |
| autoremove | apt-get autoremove | **opt-in** |
| auto-reboot | shutdown -r | **opt-in** |

## Two Modes

### Automatic Mode (default)

- Runs daily at 04:00 via systemd timer (with 30min random delay)
- **No user intervention** — fully unattended
- **Telegram notification ONLY on failure or warnings** — silent on success
- Atomic flock locking prevents concurrent runs
- Low system priority (Nice=10) — won't starve production services
- Post-update health checks (systemd, Docker, Hermes gateway, disk/memory/load)
- Reboot scheduling deferred to end of run — services are not stopped prematurely

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

Reinstalling preserves your existing configuration — the new template is installed as `auto-update.conf.dist` for reference.

### Requirements

- Ubuntu/Debian host with `apt`
- `curl` (for Telegram API)
- Docker (optional — skipped if not installed)
- Hermes Agent (optional — skipped if CLI not found)
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
UPDATE_NPM="false"      # opt-in
UPDATE_PYTHON="false"   # opt-in

# Packages to hold (never auto-upgrade)
PKG_HOLDS=""

# Auto-reboot (opt-in, default: false)
AUTO_REBOOT="false"
REBOOT_DELAY="5"

# dist-upgrade (opt-in, default: false)
DIST_UPGRADE="false"

# autoremove (opt-in, default: false)
AUTO_REMOVE="false"

# Delete log files older than N days (0 = disable)
LOG_RETENTION_DAYS="30"

# Hermes
HERMES_HOME="/root/.hermes"
HERMES_CLI="/usr/local/bin/hermes"
HERMES_UPDATE_TIMEOUT="1800"

# Hermes external skills: off, check (default), update
HERMES_SKILLS_MODE="check"
HERMES_SKILLS_AUDIT="true"
HERMES_SKILLS_SCOPE="all"
HERMES_SKILLS_TIMEOUT="600"
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

# Trigger via systemd (preferred)
sudo systemctl start controlled-system-update.service

# Inspect the run
systemctl show controlled-system-update.service \
    --property=ActiveState,SubState,Result,ExecMainStatus

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
- **Config preservation** — dpkg options preserve existing config files (no `--force-confmiss`)
- **Config security** — secrets are not exported to child processes; ownership and permissions validated before sourcing
- **Low priority** — Nice=10, CPUWeight=50, IO best-effort — won't starve production
- **Memory limit** — 1G cap on systemd service
- **Umask=0077** — restricts file creation permissions on systemd service
- **Deferred reboot** — reboot scheduling occurs only after all update and verification phases
- **needrestart** — automatically restarts services after library upgrades (if installed)
- **Log rotation** — auto-deletes log files older than 30 days (configurable)
- **last-run.log** — symlink to most recent run's log file
- **Health checks** — systemd failed units, Docker status, Hermes gateway, disk/memory/load
- **Hermes-safe** — uses supported `hermes update --yes` (not custom git/uv logic)
- **External-skill-safe** — `hermes skills check` by default; never uses `--force` (locally modified skills preserved); covers all provenance-tracked GitHub, URL, tap, and hub-installed skills
- **Docker-safe** — groups containers by Compose project, uses Compose labels, official Docker Hub images not misclassified as local
- **No catch-up** — `Persistent=false` on timer, missed runs don't pile up
- **CI** — ShellCheck linting via GitHub Actions on every push (pinned action)

## File Structure

```
controlled-system-update/
├── .github/workflows/lint.yml         # ShellCheck CI (pinned action)
├── CHANGELOG.md                       # Version history
├── SKILL.md                           # Full SRE procedure + auto-mode docs
├── README.md                          # This file
├── LICENSE                            # MIT
├── install.sh                         # One-command installer (preserves config)
├── e2e-test.sh                        # End-to-end test suite (non-destructive by default)
├── scripts/
│   └── auto-update.sh                 # Main automatic update script
├── config/
│   └── auto-update.conf               # Configuration template
└── systemd/
    ├── controlled-system-update.service  # systemd service unit
    └── controlled-system-update.timer    # systemd daily timer
```

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
