# Controlled System Update

A comprehensive, automatic + manual server update system for Linux servers running [Hermes Agent](https://github.com/NousResearch/hermes-agent) with Docker services.

**v3.0.0** — Incident-driven hardening. Remediation is now **allowlist-gated** (a command must match a known-safe form before the blocklist is even consulted), `eval` is gone, shell metacharacters are rejected, and every command has a hard timeout. Adds **Ubuntu 26.04 LTS (Resolute Raccoon)** and **arm64** support, and splits diagnostic findings into *actionable* vs *advisory* so journal noise no longer triggers nightly remediation churn. See [CHANGELOG](CHANGELOG.md#300---2026-09-17) for the two production root causes this release fixes.

**v2.6.0** — Full post-update diagnostic + LLM auto-remediation: after all update phases, a comprehensive diagnostic (dpkg audit, broken deps, journal errors, Docker health, network/DNS, dmesg, Hermes doctor) runs automatically.

**v2.5.0** — Host-portable: Hermes paths (CLI, user home, HERMES_HOME) auto-detected at runtime, and all hermes commands run as the repo-owning user via `runuser` — fixes git's "dubious ownership" error when the systemd service runs as root but Hermes is installed for a regular user (e.g. /home/ubuntu).

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
| LLM auto-remediation | Send diagnostic to LLM, safety-check + execute suggested commands | enabled |
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

# Auto-reboot (opt-in, default: false)
AUTO_REBOOT="false"
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

# Hermes external skills: off, check (default), update
HERMES_SKILLS_MODE="check"
HERMES_SKILLS_AUDIT="true"
HERMES_SKILLS_SCOPE="all"
HERMES_SKILLS_TIMEOUT="600"

# Full diagnostic + LLM auto-remediation
DIAGNOSTIC_ENABLED="true"
LLM_REMEDIATION_ENABLED="true"
LLM_API_URL="https://openrouter.ai/api/v1/chat/completions"
LLM_MODEL="z-ai/glm-5.2"
# LLM_API_KEY=""  # auto-detected from ~/.hermes/.env
LLM_TIMEOUT="120"
LLM_MAX_REMEDIATION_ATTEMPTS="3"

# Hard timeout per remediation command (seconds)
REMEDIATION_CMD_TIMEOUT="120"

# Only remediate actionable findings; advisory ones are reported only
REMEDIATE_ON_ACTIONABLE_ONLY="true"
DIAGNOSTIC_ADVISORY="journal memory load"

# Notification volume: error | warning | always
NOTIFY_LEVEL="warning"

# Take Ubuntu phased updates immediately (keeps a fleet uniform)
INCLUDE_PHASED_UPDATES="false"
```

## Full Diagnostic + LLM Auto-Remediation

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

### Actionable vs advisory findings

Findings are classified before anything is remediated:

- **Actionable** — broken packages, failed units, dead/unhealthy containers, gateway down. These can be fixed by a command, so they are eligible for remediation.
- **Advisory** — journal noise, memory pressure, load average (configurable via `DIAGNOSTIC_ADVISORY`). These are reported in the log, the report and the notification, but are **never** handed to the model. A disk at 85% is a human decision, not something to "fix" unattended at 04:00.

With `REMEDIATE_ON_ACTIONABLE_ONLY="true"` (default), a run with only advisory findings skips remediation entirely.

### How remediation is gated

If actionable issues are found and `LLM_REMEDIATION_ENABLED=true`, the report is sent to an LLM which suggests remediation commands. Each suggestion passes through two gates before it can run:

1. **Allowlist (gate 1)** — the command must match a known-safe remediation form:
   `systemctl restart|start|reload|reset-failed <unit>`, `systemctl daemon-reload`,
   `docker restart|start <container>`, `docker compose up -d`, `docker image|system prune -f`,
   `apt-get install -f` / `check` / `update` / `autoclean`, `dpkg --configure -a`,
   `journalctl --vacuum-size=|--vacuum-time=`, `hermes gateway restart|status`,
   `hermes doctor`, `needrestart -r a`, `snap refresh`.
   Anything unrecognised is rejected. A blocklist alone cannot be sound against free-form text produced by a model.
2. **Blocklist (gate 2)** — destructive patterns (`rm -rf /`, `mkfs`, `dd of=/dev/`, `shutdown`, `reboot`, `apt purge`, `systemctl disable|mask`, `curl | sh`, fork bombs) **and never-ending commands** (`hermes gateway run`, `hermes serve`, `tail -f`, `journalctl -f`, `watch`, `sleep 1000`) are rejected even if gate 1 passed.

Additionally:

- Shell metacharacters (`;` `|` `&` `` ` `` `$(` `>` `<`) are rejected outright, so an allowed verb cannot smuggle a second command (`systemctl restart nginx; rm -rf /var`).
- Commands are executed **without `eval`**, as an argv array.
- Each command runs under a hard `REMEDIATION_CMD_TIMEOUT`, so one hung command cannot consume the systemd unit's whole time budget.
- Text that looks like a log line is rejected as a command.

The cycle repeats up to `LLM_MAX_REMEDIATION_ATTEMPTS` times. These gates are covered by 44 assertions in `tests/safety-gate-test.sh`, run in CI.

The LLM API key is auto-detected from `~/.hermes/.env` (`OPENROUTER_API_KEY` or `OPENAI_API_KEY`). The diagnostic report is saved to `/var/log/controlled-system-update/diagnostic-report.txt`.

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

## Safety Features

- **Atomic locking** — `flock` prevents concurrent runs (no race conditions, auto-releases on crash)
- **Non-interactive apt** — `DEBIAN_FRONTEND=noninteractive` + `--force-confdef --force-confold`
- **Package holds** — `apt-mark hold` for critical packages
- **Config preservation** — dpkg options preserve existing config files (no `--force-confmiss`)
- **Config security** — secrets are not exported to child processes; ownership and permissions validated before sourcing
- **Low priority** — Nice=10, CPUWeight=50, IO best-effort — won't starve production
- **Memory limit** — 1G cap on systemd service
- **UMask=0077** — restricts file creation permissions on the systemd service (note: `Umask=` is *not* a systemd directive and is silently ignored; CI rejects the typo)
- **Allowlist-gated remediation** — see above; no `eval`, no metacharacters, per-command timeout
- **Precise gateway detection** — matches the real interpreter invocation and systemd unit state, not any process whose command line merely mentions "hermes gateway run"
- **Partial-update recovery** — a `hermes update` that pulls successfully but fails its own gateway relaunch is recovered with a bounded `hermes gateway restart` rather than failing the run
- **Deferred reboot** — reboot scheduling occurs only after all update and verification phases
- **needrestart** — automatically restarts services after library upgrades (if installed)
- **Log rotation** — auto-deletes log files older than 30 days (configurable)
- **last-run.log** — symlink to most recent run's log file
- **Health checks** — systemd failed units, Docker status, Hermes gateway, disk/memory/load
- **Hermes-safe** — uses supported `hermes update --yes` (not custom git/uv logic)
- **External-skill-safe** — `hermes skills check` by default; never uses `--force` (locally modified skills preserved); covers all provenance-tracked GitHub, URL, tap, and hub-installed skills
- **Docker-safe** — groups containers by Compose project, uses Compose labels, official Docker Hub images not misclassified as local
- **No catch-up** — `Persistent=false` on timer, missed runs don't pile up
- **CI** — ShellCheck linting, safety-gate unit tests, a syntax matrix across `ubuntu-24.04` / `ubuntu-24.04-arm` / `ubuntu-latest`, and systemd unit-file validation on every push

## File Structure

```
controlled-system-update/
├── .github/workflows/lint.yml         # ShellCheck + safety gate + arch matrix + unit checks
├── CHANGELOG.md                       # Version history
├── SKILL.md                           # Full SRE procedure + auto-mode docs
├── README.md                          # This file
├── LICENSE                            # MIT
├── install.sh                         # One-command installer (preserves config)
├── e2e-test.sh                        # End-to-end test suite (non-destructive by default)
├── tests/
│   └── safety-gate-test.sh            # Unit tests for the remediation safety gate
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
