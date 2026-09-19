---
name: controlled-system-update
description: "Safely stage and verify Linux, Docker, and Hermes updates"
author: Green-Needle-Tech
version: 3.1.0
platforms: [linux]
metadata:
  hermes:
    category: devops
    tags: [linux, apt, docker, updates, sre, hermes]
    requires_toolsets: [terminal]
---

# Controlled System Update

Expert Linux sysadmin/SRE procedure for comprehensive server updates: OS packages, Snap, Docker images, Hermes Agent (via supported updater), Hermes hub skills, and optional Python/uv tools and npm globals. Two modes: **automatic** (daily, unattended, Telegram on failure only) and **manual** (staged, compatibility-checked, interactive).

## When to Use

- User asks to update the server, run a controlled update, or update OS/Hermes/Docker
- Automatic mode is already installed and user wants to check/modify it
- A Hermes release notes breaking changes and a manual update is planned
- Don't use for: routine diagnostics, ad-hoc package installs

## Deployment Example (host-specific)

The following is an example deployment profile. Adjust paths and services for your specific host.

- OS: Ubuntu 24.04 LTS (kernel 6.8), package manager `apt-get`
  (the script also supports Ubuntu 22.04 → 26.04 LTS and Debian 12+, on
  amd64 and arm64; OS/arch/apt-generation are detected at runtime)
- Hermes: root-host git-clone at `/usr/local/lib/hermes-agent`
- Venv: managed by `uv` — no pip binary
- CLI: `/usr/local/bin/hermes`
- Gateway: `hermes gateway run --replace`
- Dashboard: systemd `hermes-dashboard` on port 9119
- Docker: BunkerWeb WAF + internal services
- Telegram: bot token + chat ID in `/etc/controlled-system-update/auto-update.conf`

## Mode 1 — Automatic Updates (default)

Runs daily at 01:00 SGT (Asia/Singapore) via systemd timer. No user intervention. Telegram notification ONLY on failure or warnings.

### What gets updated automatically (defaults)

1. **OS packages** — apt update + upgrade (dist-upgrade, autoremove, and auto-reboot are opt-in)
2. **Snap packages** — snap refresh (if snap is installed)
3. **Docker images** — pulls latest images for all running containers, recreates via Compose if changed, prunes dangling images
4. **Hermes Agent** — `hermes update --yes` (supported updater handles deps, backups, service discovery, bundled-skill sync)
5. **Hermes hub skills** — `hermes skills check` (conservative default; `update` mode installs available updates)
6. **Python/uv tools** — opt-in only (`UPDATE_PYTHON=true`)
7. **npm global packages** — opt-in only (`UPDATE_NPM=true`)

### Installation

```bash
git clone https://github.com/Green-Needle-Tech/controlled-system-update.git
cd controlled-system-update
sudo bash install.sh
```

Then edit the config:

```bash
sudo nano /etc/controlled-system-update/auto-update.conf
# Set TG_BOT_TOKEN and TG_CHAT_ID
```

### Configuration

Config file: `/etc/controlled-system-update/auto-update.conf`

Key settings:
- `TG_BOT_TOKEN` / `TG_CHAT_ID` — Telegram notification target (required for notifications)
- `UPDATE_DOCKER` / `UPDATE_HERMES` / `UPDATE_SNAP` — toggle each phase (default: true)
- `UPDATE_NPM` / `UPDATE_PYTHON` — opt-in phases (default: false — not OS maintenance)
- `PKG_HOLDS` — space-separated packages to exclude from upgrades
- `AUTO_REBOOT` — auto-reboot if `/var/run/reboot-required` (default: false — opt-in)
- `REBOOT_DELAY` — minutes to wait before auto-reboot (default: 5, cancel with `shutdown -c`)
- `DIST_UPGRADE` — run `apt-get dist-upgrade` (default: false — can remove packages)
- `AUTO_REMOVE` — run `apt-get autoremove` (default: false — opt-in)
- `LOG_RETENTION_DAYS` — delete log files older than N days (default: 30, 0 = disable)
- `HERMES_HOME` / `HERMES_USER_HOME` / `HERMES_USER` / `HERMES_CLI` — auto-detected at runtime (CLI on PATH/common locations; user home from the running gateway process owner; user from the home's owner); set only for non-standard installations (e.g. Hermes installed under `/home/ubuntu` where detection fails)
- Privilege drop: when the service runs as root but Hermes is owned by a regular user (e.g. `/home/ubuntu`), all hermes commands run as that user via `runuser` — avoids git's "dubious ownership" error without weakening `safe.directory`
- `HERMES_UPDATE_TIMEOUT` — timeout for `hermes update` in seconds (default: 1800)
- `HERMES_GATEWAY_RESTART_TIMEOUT` — timeout for `hermes gateway restart` (default: 600). Not the skills timeout: the gateway drains in-flight turns first.
- `HERMES_SKILLS_MODE` — external skill update mode: `off`, `check` (default), `update`
- `HERMES_SKILLS_AUDIT` — re-run security checks after check/update (default: true)
- `HERMES_SKILLS_SCOPE` — include all Hermes-managed sources: GitHub, URL, tap, hub, community (default: all)
- `HERMES_SKILLS_TIMEOUT` — timeout for skill operations in seconds (default: 600)
- `NOTIFY_LEVEL` — Telegram volume: `error`, `warning` (default), `always`
- `INCLUDE_PHASED_UPDATES` — take Ubuntu phased updates immediately (default: false)
- `DIAGNOSTIC_ENABLED` — run comprehensive post-update diagnostic (default: true)
- `DIAGNOSTIC_ADVISORY` — categories reported but never auto-remediated (default: `journal memory load`)
- `REMEDIATE_ON_ACTIONABLE_ONLY` — skip remediation when only advisory findings exist (default: true)
- `REMEDIATION_CMD_TIMEOUT` — hard timeout per remediation command in seconds (default: 120)
- `LLM_REMEDIATION_ENABLED` — attempt LLM-based auto-remediation when diagnostic finds issues (default: true)
- `LLM_API_URL` — OpenAI-compatible chat completions endpoint (default: OpenRouter)
- `LLM_MODEL` — model to use for remediation suggestions (default: z-ai/glm-5.2)
- `LLM_API_KEY` — API key; auto-detected from `~/.hermes/.env` (OPENROUTER_API_KEY or OPENAI_API_KEY) if not set
- `LLM_TIMEOUT` — timeout for each LLM API request in seconds (default: 120)
- `LLM_MAX_REMEDIATION_ATTEMPTS` — maximum diagnose→remediate→re-diagnose rounds (default: 3)

### Full Diagnostic + LLM Auto-Remediation

After all update phases and basic health checks, the script runs a comprehensive diagnostic that covers:

1. **dpkg audit** — half-installed/broken packages
2. **apt-get check** — broken dependencies
3. **systemd failed units** — detailed list
4. **Journal errors** — last 30 minutes, priority err and above
5. **Docker container health** — unhealthy and exited/dead containers
6. **Hermes gateway** — running status + `hermes doctor`
7. **Disk usage** — all mounts, alert at >80% critical >90%
8. **Memory** — available memory, alert at <256MB
9. **Network** — default gateway reachability (ping)
10. **DNS** — resolution test
11. **Listening ports** — summary via `ss`
12. **dmesg errors** — filesystem/hardware errors
13. **Load average**

Findings are classified as **actionable** (broken packages, failed units, dead
containers, gateway down — fixable by a command) or **advisory** (journal
noise, memory, load — reported only). With `REMEDIATE_ON_ACTIONABLE_ONLY=true`
(default), advisory-only runs skip remediation entirely. This is what stops a
healthy-but-busy host from generating nightly remediation churn.

If actionable issues are found and `LLM_REMEDIATION_ENABLED=true`, the report
goes to an LLM which suggests remediation commands. Each suggestion must pass
**two gates**:

1. **Allowlist** — must match a known-safe form: `systemctl
   restart|start|reload|reset-failed <unit>`, `systemctl daemon-reload`,
   `docker restart|start <container>`, `docker compose up -d`,
   `docker image|system prune -f`, `apt-get install -f|check|update|autoclean`,
   `dpkg --configure -a`, `journalctl --vacuum-size=|--vacuum-time=`,
   `hermes gateway restart|status`, `hermes doctor`, `needrestart -r a`,
   `snap refresh`. Anything else is rejected.
2. **Blocklist** — destructive patterns AND never-ending commands
   (`hermes gateway run`, `hermes serve`, `tail -f`, `journalctl -f`, `watch`,
   long `sleep`) are rejected even if gate 1 passed.

Shell metacharacters (`;` `|` `&` `` ` `` `$(` `>` `<`) are rejected outright,
commands run **without `eval`** as an argv array, and each runs under
`REMEDIATION_CMD_TIMEOUT`. The gates are covered by 44 assertions in
`tests/safety-gate-test.sh` (run in CI).

The cycle repeats up to `LLM_MAX_REMEDIATION_ATTEMPTS` times, re-running the
diagnostic after each round.

The diagnostic report is saved to `/var/log/controlled-system-update/diagnostic-report.txt`.

### Manual operations

```bash
# Run update immediately
sudo /usr/local/bin/auto-update.sh

# Trigger via systemd (preferred)
sudo systemctl start controlled-system-update.service

# Inspect the run independently
systemctl show controlled-system-update.service \
    --property=ActiveState,SubState,Result,ExecMainStatus

journalctl -u controlled-system-update.service \
    --since today \
    --no-pager

# Check timer status
systemctl status controlled-system-update.timer

# Check next scheduled run
systemctl list-timers controlled-system-update

# View logs
journalctl -u controlled-system-update -f
# or
tail -f /var/log/controlled-system-update/last-run.log

# Disable automatic updates
sudo systemctl disable --now controlled-system-update.timer

# Re-enable
sudo systemctl enable --now controlled-system-update.timer
```

### Notification behavior

- **Success (no issues)**: Silent — no Telegram message sent
- **Warnings (non-fatal)**: Telegram message with warning details
- **Errors (failures)**: Telegram message with error details + log path

### Safety features

- Atomic `flock` locking prevents concurrent runs (no race conditions, auto-releases on crash)
- `DEBIAN_FRONTEND=noninteractive` + `--force-confdef --force-confold` — no apt prompts
- Package holds respected (apt-mark hold)
- Low priority (Nice=10, CPUWeight=50) — won't starve production services
- Memory limit (1G) on systemd service
- `UMask=0077` on systemd service — restricts file creation permissions
  (the key is `UMask`, capital M; `Umask=` is silently ignored by systemd)
- `needrestart` integration: auto-restarts services after library upgrades (if installed)
- Log rotation: auto-deletes log files older than `LOG_RETENTION_DAYS` (default: 30)
- `last-run.log` is a symlink to the most recent run's log file
- Post-update health checks: systemd failed units, Docker container status, Hermes gateway, disk/memory/load
- Reboot scheduling deferred to end of run — services are not stopped prematurely
- Hermes updated via supported `hermes update --yes` (not custom git/uv logic)
- Hermes hub skills updated via `hermes skills check/update` (never `--force`)
- Configuration secrets are not exported to child processes (no `set -a`)
- Configuration ownership and permissions validated before sourcing
- All logging goes to stderr; only data goes to stdout, so log lines can never
  be captured by command substitution and executed
- Gateway liveness detected by the real interpreter invocation and systemd unit
  state, not a loose `pgrep` that matches any process mentioning the words
- A `hermes update` that pulls successfully but fails its own gateway relaunch
  is recovered with a bounded `hermes gateway restart` instead of failing
- GitHub Actions CI with ShellCheck linting on every push

## Mode 2 — Manual Controlled Update (SRE procedure)

For when a human-in-the-loop update with compatibility pre-checks is needed. Use when a major Hermes release is pending or when evaluating breaking changes.

### Phase 1 — Pre-Check & Compatibility Evaluation (no upgrades yet)

Completion criterion: a GO/NO-GO risk statement covering every finding.

```bash
# 1.1 Inventory
cat /etc/os-release | head -2
apt-get --version | head -1
node --version; python3 --version
hermes --version
hermes update --check                       # commits behind

# 1.2 Runtime requirements
grep -E 'requires-python|python' /usr/local/lib/hermes-agent/pyproject.toml | head -5

# 1.3 Changelog / breaking changes
# web_extract https://github.com/NousResearch/hermes-agent/releases (latest notes)
# flag: minimum Python/Node bumps, new daemon deps, config schema changes
```

Then summarize the dependency graph and state explicitly whether `apt upgrade` risks Hermes. Watch items: Python minor/major bumps, libc6/openssl, systemd, docker.io, nodejs. Present findings + planned commands before executing — production-host package updates require explicit approval.

### Phase 2 — Dry Run & Simulation

Completion criterion: incoming package list inspected, breaking changes flagged.

```bash
apt-get update
apt-get upgrade --simulate 2>/dev/null | grep '^Inst ' | awk '{print $2, $3}' | head -60
apt-get upgrade --simulate 2>/dev/null | grep -c '^Inst '   # total count
```

### Phase 3 — Staged Execution

#### 3.1 OS update

```bash
DEBIAN_FRONTEND=noninteractive apt-get update
```

#### 3.2 OS package upgrades (preserve configs, no prompts)

```bash
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
```

Completion criterion: exit 0, no dpkg errors, `apt-get upgrade --simulate` now reports 0.

#### 3.3 Hermes Agent update

Running INSIDE an agent session (the normal case): `hermes update` restarts the gateway, which kills the running agent mid-run — background it so it owns its own gateway restart:

```bash
setsid nohup hermes update --yes > /tmp/hermes-update.log 2>&1 & disown
```

Running from a plain terminal (no active session):

```bash
hermes update --yes
```

Completion criterion: `hermes --version` shows the new version; `hermes doctor` passes.

#### 3.4 Rebuild runtime deps (if pyproject/lockfile changed)

The supported `hermes update` handles dependency installation via lockfile-backed `uv sync`. Do not independently run `uv sync` or `uv pip install -e .` unless performing an explicitly documented recovery fallback.

#### 3.5 Restart gateway + rebuild dashboard (after ANY Hermes update)

Note: invoking a gateway restart from an active Hermes conversation may disconnect that conversation.

```bash
# If the updater did not restart the gateway automatically:
hermes gateway run --replace
sleep 5
pgrep -f "hermes.*gateway run" && echo "Gateway OK" || echo "Gateway DOWN"
```

### Phase 4 — Post-Update Verification

Completion criterion: every check passes or has a logged repair action.

```bash
hermes --version                                   # new version confirmed
hermes doctor                                      # env, SSL, packages, API connectivity
pgrep -f "hermes.*gateway run"                     # gateway alive
docker ps -a --format "table {{.Names}}\t{{.Status}}"
systemctl --failed
free -h; df -h /
```

Final: run a test Hermes invocation (simple prompt via CLI or a Telegram ping) to prove tool calling, API connections, and core loop execution.

## Updating Hermes Skills

Hermes skills have separate update lifecycles.

### Bundled skills

Bundled skills are synchronized by the Hermes core updater:

```bash
hermes update --check
hermes update --yes
```

Locally modified bundled skills are preserved.

### Unofficial GitHub and other external skills

Skills installed through the Hermes Skills Hub retain their source provenance.
This includes unofficial GitHub repositories, custom GitHub taps, direct URLs,
skills.sh, well-known endpoints, and community registries — anything installed
via `hermes skills install` and tracked in `${HERMES_HOME}/skills/.hub/lock.json`.

List and inspect tracked skills:

```bash
hermes skills list --source hub
hermes skills check
```

Update all changed, provenance-tracked skills:

```bash
hermes skills update
hermes skills audit
```

Update one specific GitHub-installed skill:

```bash
hermes skills update some-skill
```

Never use `--force` during unattended maintenance. Hermes normally skips a
skill when its installed files have been edited locally. Forced updates may
discard those edits.

A skill copied or cloned manually into `~/.hermes/skills/` is not managed by
the hub updater. Back it up and reinstall it once using its GitHub identifier:

```bash
hermes skills inspect owner/repository/skills/skill-name
hermes skills install owner/repository/skills/skill-name
```

All community skills must pass Hermes security scanning before installation.
A successful update does not imply that the upstream project is trustworthy;
review source changes and audit results before enabling automatic updates.

### Optional required-skill inventory

Create `/etc/controlled-system-update/hermes-skills.conf` to declare required
GitHub skills. The update script reports missing skills as warnings — it does
not silently install new third-party code during a system update.

```bash
HERMES_REQUIRED_GITHUB_SKILLS=(
    "Green-Needle-Tech/controlled-system-update"
    "some-owner/some-repository/skills/some-skill"
)
```

### Installing this project's own skill

Install it with tracked provenance rather than copying it manually:

```bash
hermes skills install \
  https://raw.githubusercontent.com/Green-Needle-Tech/controlled-system-update/main/SKILL.md \
  --category devops \
  --yes
```

Subsequent releases can then be applied through:

```bash
hermes skills update controlled-system-update
```

If the existing local skill was manually copied and therefore has no hub
provenance, perform one reviewed migration with `hermes skills install`; do
not automatically force replacement of local edits.

## Repair Playbook (non-destructive)

| Symptom | Fix |
|---|---|
| Gateway DOWN after restart | `hermes gateway run --replace`, verify with pgrep |
| venv import errors | `hermes doctor` or `hermes update --yes` (recovery) |
| Broken apt package | pin: `apt-get install <pkg>=<oldver>`; hold: `apt-mark hold <pkg>` |
| Lock file stuck | Verify ownership with `lslocks` or `flock -n`; do NOT blindly delete the lock file — the kernel-held lock, not file existence, determines ownership |
| Telegram not sending | Check TG_BOT_TOKEN/TG_CHAT_ID in config, test with curl |

## Output Format

### Automatic mode
1. Log file at `/var/log/controlled-system-update/auto-update-<timestamp>.log`
2. `last-run.log` symlink to most recent run
3. Telegram message only on failure/warning

### Manual mode
1. Pre-Check compatibility findings (versions, requirements, changelog risks, GO/NO-GO)
2. Planned commands, step-by-step
3. Each stage executed with results
4. Post-verification table (check -> result)
5. Status summary: what changed, versions before -> after, any repairs

## Pitfalls

- `hermes update` from inside an agent session kills the session (gateway restart) — background it
- `hermes update` can hang on TTY prompts — always use `--yes`
- apt prompts hang scripts — always DEBIAN_FRONTEND=noninteractive + force-confdef/confold
- Docker image pulls can fail due to rate limits — script logs but doesn't fail the whole run
- snap refresh can hold locks — non-fatal warning only
- Invoking a gateway restart from an active Hermes conversation may disconnect that conversation
- Do not use `--force` with `hermes skills update` — locally modified hub skills are intentionally preserved
- Root running git in a user-owned checkout fails with "dubious ownership" — never fix with a global `safe.directory=*`; the script's runuser privilege drop is the correct fix
- `hermes gateway restart` drains in-flight agent turns first. Run from INSIDE
  an agent session it deadlocks: the gateway waits for the calling process and
  the calling process waits for the gateway. Guard on `HERMES_AGENT` /
  `AI_AGENT` / `HERMES_UI_SESSION_ID` before issuing it from a script, or run
  the script from the systemd timer where those are unset.
- Never run `hermes gateway run --replace` from an unattended script: it runs
  in the foreground and holds the systemd unit open until `TimeoutStartSec`
  kills the whole update. Use the bounded `hermes gateway restart`.
- A helper that both logs and returns data must log to **stderr**; logging to
  stdout splices log lines into the caller's command substitution
- `Umask=` is not a systemd directive (it is `UMask=`); systemd ignores unknown
  keys with only a journal warning, so the setting silently does nothing
- `pgrep -f 'hermes.*gateway run'` matches admin greps, script subshells and
  agent sessions — it reports a gateway that is not there
- `hermes update` may exit non-zero after successfully pulling and installing
  the new code, when only its own gateway relaunch crashed; retrying the update
  does not help, restarting the gateway does
- On Ubuntu 26.04+ (apt 3.x) a failed upgrade can be rolled back with
  `apt history-info 0` then `sudo apt history-undo 0`

## Related Skills

- `host-maintenance` — deployment profile details, full pitfall catalog, disk cleanup, diagnostics
- `hermes-gateway-operations` — gateway restart protocol
- `hermes-cron-troubleshooting` — if re-automating updates via cron
- `automatic-docker-service-updates` — alternative Docker-only update approach
