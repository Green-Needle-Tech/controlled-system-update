# Controlled System Update

A comprehensive, automatic + manual server update system for Linux servers running [Hermes Agent](https://github.com/NousResearch/hermes-agent) with Docker services.

Runs unattended once a day: OS packages, Snap, Docker images, Hermes Agent and
Hermes skills — then verifies the host and reports only when something needs
your attention.

- **[SPEC.md](SPEC.md)** — full specification: guarantees, safety model, incident history
- **[SKILL.md](SKILL.md)** — Hermes agent skill + manual SRE procedure
- **[CHANGELOG.md](CHANGELOG.md)** — version history

**Latest — v4.0.0.** LLM auto-remediation has been **removed** in favour of a
**compulsory server reboot** after every update run — a clean restart is a
simpler, more reliable recovery than asking a model to patch a broken host.
The comprehensive post-update diagnostic is retained for reporting. Adds
**Ubuntu 26.04 LTS (Resolute Raccoon)** and **arm64** support.

## Supported Platforms

| Platform | Status |
|---|---|
| Ubuntu 26.04 LTS (Resolute Raccoon), apt 3.x | supported |
| Ubuntu 24.04 LTS (Noble), apt 2.x | supported (reference host) |
| Ubuntu 22.04 LTS (Jammy) | supported |
| Debian 12+ | expected to work |
| amd64 / x86_64 | supported |
| arm64 / aarch64 | supported |
| armhf | best effort |

OS, architecture and apt generation are detected at runtime — there is nothing to configure. Package operations always use `apt-get`, the stable scripting interface across both apt 2.x and apt 3.x. No GNU-coreutils-specific behaviour is relied upon (Ubuntu 25.10+ ships Rust uutils coreutils). Docker pulls are pinned to the host architecture so mixed amd64/arm64 fleets cannot silently acquire an emulated image from an incomplete manifest list.

## What It Updates

The automatic mode updates the following by default:

| Component | Method | Default |
|-----------|--------|---------|
| OS packages | apt update + upgrade | enabled |
| Snap packages | snap refresh | enabled |
| Docker images | Pull latest for running containers, recreate via Compose if changed | enabled |
| Hermes Agent | `hermes update --yes` (supported updater) | enabled |
| Hermes external skills | `hermes skills check` (report only) | enabled |
| Full diagnostic | dpkg audit, broken deps, journal errors, Docker health, network/DNS, dmesg | enabled |

| Python/uv tools | uv tool upgrade | **opt-in** |
| npm global packages | npm update -g | **opt-in** |
| dist-upgrade | apt-get dist-upgrade | **opt-in** |
| autoremove | apt-get autoremove | **opt-in** |
| compulsory reboot | shutdown -r after every run | enabled |

## Two Modes

### Automatic Mode (default)

- Runs daily at 01:00 SGT (Asia/Singapore) via systemd timer (with 30min random delay)
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

- Ubuntu/Debian host with `apt-get` (Ubuntu 22.04 → 26.04 LTS, amd64 or arm64)
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

# Compulsory reboot after every run (delay in minutes, cancel with shutdown -c)
REBOOT_DELAY="5"

# dist-upgrade (opt-in, default: false)
DIST_UPGRADE="false"

# autoremove (opt-in, default: false)
AUTO_REMOVE="false"

# Delete log files older than N days (0 = disable)
LOG_RETENTION_DAYS="30"

# Hermes — paths auto-detected; uncomment only if detection fails
# HERMES_HOME="/root/.hermes"
# HERMES_USER_HOME="/root"
# HERMES_CLI="/usr/local/bin/hermes"
HERMES_UPDATE_TIMEOUT="1800"
HERMES_GATEWAY_RESTART_TIMEOUT="600"

# Hermes external skills: off, check (default), update
HERMES_SKILLS_MODE="check"
HERMES_SKILLS_AUDIT="true"
HERMES_SKILLS_SCOPE="all"
HERMES_SKILLS_TIMEOUT="600"

# Full diagnostic (reporting only, no auto-remediation)
DIAGNOSTIC_ENABLED="true"

# Notification volume: error | warning | always
NOTIFY_LEVEL="warning"

# Take Ubuntu phased updates immediately (keeps a fleet uniform)
INCLUDE_PHASED_UPDATES="false"
```

## Full Diagnostic

After all update phases and basic health checks, the script runs a comprehensive diagnostic:

- **dpkg audit** — half-installed/broken packages
- **apt-get check** — broken dependencies
- **systemd failed units** — detailed list
- **Journal errors** — last 30 minutes
- **Docker container health** — unhealthy and exited/dead containers
- **Hermes gateway** — running status + `hermes doctor`
- **Disk/memory** — all mounts, available memory
- **Network** — default gateway reachability + DNS resolution
- **dmesg errors** — filesystem/hardware errors

Findings are reported in the log, the diagnostic report file
(`/var/log/controlled-system-update/diagnostic-report.txt`), and the Telegram
notification. No automated remediation is attempted — the script schedules a
**compulsory reboot** after every run instead, on the principle that a clean
restart is more reliable than patching a broken host unattended at 01:00.

## Compulsory Reboot

After all update phases, health checks, and diagnostic are complete, a
**compulsory reboot** is scheduled via `shutdown -r +REBOOT_DELAY` (default:
5 minutes). A Telegram notification is sent before the reboot so you know
it's coming. Cancel with `shutdown -c`.

This replaces the previous opt-in `AUTO_REBOOT` (which only rebooted when
`/var/run/reboot-required` was present) and the LLM auto-remediation loop. A
clean restart after updates is the simplest reliable recovery: it picks up
new kernels, restarts all services with upgraded libraries, and clears any
transient state.

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

Controlled by `NOTIFY_LEVEL`:

| Outcome | `error` | `warning` (default) | `always` |
|---------|---------|---------------------|----------|
| Success (no issues) | silent | silent | summary sent |
| Warnings (non-fatal) | silent | message with details | message with details |
| Errors (failures) | message + log path | message + log path | message + log path |

Every message carries the host label, timestamp and platform (OS, version, architecture).

### Immediate Critical Alerts

With `NOTIFY_IMMEDIATE="true"` (default), a Telegram alert is sent **the moment** a
high/critical error occurs during the run — apt failures, Docker pull/update
failures, Hermes update failure or gateway down, disk usage critical, broken
packages — instead of waiting for the end-of-run summary. Each alert is tagged
`🚨 CRITICAL` and includes the affected section and detail. Set to `"false"` to
receive only the end-of-run summary.

## Safety Features

- **Atomic locking** — `flock` prevents concurrent runs (no race conditions, auto-releases on crash)
- **Non-interactive apt** — `DEBIAN_FRONTEND=noninteractive` + `--force-confdef --force-confold`
- **Package holds** — `apt-mark hold` for critical packages
- **Config preservation** — dpkg options preserve existing config files (no `--force-confmiss`)
- **Config security** — secrets are not exported to child processes; ownership and permissions validated before sourcing
- **Low priority** — Nice=10, CPUWeight=50, IO best-effort — won't starve production
- **Memory limit** — 1G cap on systemd service
- **UMask=0077** — restricts file creation permissions on the systemd service (note: `Umask=` is *not* a systemd directive and is silently ignored; CI rejects the typo)
- **Compulsory reboot** — a clean restart after every run; no LLM-based auto-remediation
- **Precise gateway detection** — matches the real interpreter invocation and systemd unit state, not any process whose command line merely mentions "hermes gateway run"
- **Partial-update recovery** — a `hermes update` that pulls successfully but fails its own gateway relaunch is recovered with a bounded `hermes gateway restart` rather than failing the run
- **Deadlock guard** — the gateway restart drains in-flight agent turns, so it is skipped (with a warning) when the tool runs inside a Hermes agent session; the systemd timer path is unaffected
- **Compulsory reboot** — scheduled after all update and verification phases; cancel with `shutdown -c`
- **needrestart** — automatically restarts services after library upgrades (if installed)
- **Log rotation** — auto-deletes log files older than 30 days (configurable)
- **last-run.log** — symlink to most recent run's log file
- **Health checks** — systemd failed units, Docker status, Hermes gateway, disk/memory/load
- **Hermes-safe** — uses supported `hermes update --yes` (not custom git/uv logic)
- **External-skill-safe** — `hermes skills check` by default; never uses `--force` (locally modified skills preserved); covers all provenance-tracked GitHub, URL, tap, and hub-installed skills
- **Docker-safe** — groups containers by Compose project, uses Compose labels, official Docker Hub images not misclassified as local
- **No catch-up** — `Persistent=false` on timer, missed runs don't pile up
- **CI** — ShellCheck linting, gateway guard unit tests, a syntax matrix across `ubuntu-24.04` / `ubuntu-24.04-arm` / `ubuntu-latest`, and systemd unit-file validation on every push

## File Structure

```
controlled-system-update/
├── .github/workflows/lint.yml         # ShellCheck + gateway guard + arch matrix + unit checks
├── CHANGELOG.md                       # Version history
├── SPEC.md                            # Specification: guarantees, safety model, incidents
├── SKILL.md                           # Full SRE procedure + auto-mode docs
├── README.md                          # This file
├── LICENSE                            # MIT
├── install.sh                         # One-command installer (preserves config)
├── e2e-test.sh                        # End-to-end test suite (non-destructive by default)
├── tests/
│   └── gateway-guard-test.sh          # Unit tests for the gateway restart deadlock guard
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
