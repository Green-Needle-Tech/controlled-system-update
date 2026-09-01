---
name: controlled-system-update
description: "Staged OS + Hermes updates with compatibility pre-check."
author: Iris (CTO Assistant)
version: 1.0.0
---

# Controlled System Update

Expert Linux sysadmin/SRE procedure for a controlled server update: OS packages, server software, and the Hermes Agent — compatibility-evaluated before execution, fully verified after. The automated daily/monthly update crons were removed on 2026-09-01 at David's request; this skill is now the manual, on-demand update path.

## When to Use

- David asks to update the server, run a controlled update, or update OS/Hermes
- A Hermes release notes breaking changes and an update is planned
- Don't use for: Docker image updates (`automatic-docker-service-updates`), skills/plugins updates, routine diagnostics (`host-maintenance`)

## Deployment Profile (this host)

- OS: Ubuntu, kernel 6.8, package manager `apt`
- Hermes: root-host git-clone at `/usr/local/lib/hermes-agent` (NOT Docker, NOT pip)
- Venv: `/usr/local/lib/hermes-agent/venv/` managed by `uv` (`~/.local/bin/uv`) — no pip binary
- CLI: `/usr/local/bin/hermes` wrapper
- Gateway: `hermes gateway run --replace`, NO auto-respawn — manual restart after any kill
- Dashboard: systemd `hermes-dashboard` on port 9119, needs `npm run build` after Hermes updates

## Phase 1 — Pre-Check & Compatibility Evaluation (no upgrades yet)

Completion criterion: a GO/NO-GO risk statement covering every finding.

```bash
# 1.1 Inventory
cat /etc/os-release | head -2
apt-get --version | head -1
node --version; python3 --version
hermes --version
cd /usr/local/lib/hermes-agent && git log -1 --format='%h %s (%ci)'
git status --short                          # local modifications (stash targets)
hermes update --check                       # commits behind

# 1.2 Runtime requirements
grep -E 'requires-python|python' /usr/local/lib/hermes-agent/pyproject.toml | head -5

# 1.3 Changelog / breaking changes
# web_extract https://github.com/NousResearch/hermes-agent/releases (latest notes)
# flag: minimum Python/Node bumps, new daemon deps, config schema changes
```

Then summarize the dependency graph and state explicitly whether `apt upgrade` risks Hermes. Watch items: Python minor/major bumps, libc6/openssl, systemd, docker.io, nodejs. Present findings + planned commands to David before executing — production-host package updates require his approval.

## Phase 2 — Dry Run & Simulation

Completion criterion: incoming package list inspected, breaking changes flagged.

```bash
apt-get update
apt-get upgrade --simulate 2>/dev/null | grep '^Inst ' | awk '{print $2, $3}' | head -60
apt-get upgrade --simulate 2>/dev/null | grep -c '^Inst '   # total count
```

## Phase 3 — Staged Execution

### 3.1 OS update

```bash
DEBIAN_FRONTEND=noninteractive apt-get update
```

### 3.2 OS package upgrades (preserve configs, no prompts)

```bash
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
```

Completion criterion: exit 0, no dpkg errors, `apt-get upgrade --simulate` now reports 0.

### 3.3 Hermes Agent update

Running INSIDE an agent session (the normal case): `hermes update` restarts the gateway, which kills the running agent mid-run — use the manual git path:

```bash
cd /usr/local/lib/hermes-agent
git stash push -m "pre-update-$(date +%Y%m%d-%H%M)"
git pull origin main
git stash pop
```

Running from a plain terminal (no active session): background it so it owns its own gateway restart:

```bash
setsid nohup hermes update --yes --no-backup > /tmp/hermes-update.log 2>&1 & disown
```

Completion criterion: `git log -1` shows the new upstream commit; `git status --short` matches the pre-check local-mods list.

### 3.4 Rebuild runtime deps (if pyproject/lockfile changed)

```bash
~/.local/bin/uv sync
~/.local/bin/uv pip install -e .
```

### 3.5 Restart gateway + rebuild dashboard (after ANY Hermes update)

```bash
kill -TERM $(pgrep -f "hermes.*gateway run") 2>/dev/null; sleep 3
nohup hermes gateway run --replace >> ~/.hermes/logs/gateway-stdout.log 2>&1 &
sleep 5
pgrep -f "hermes.*gateway run" && echo "Gateway OK" || echo "Gateway DOWN"
cd /usr/local/lib/hermes-agent/web && npm run build
systemctl restart hermes-dashboard
```

## Phase 4 — Post-Update Verification

Completion criterion: every check passes or has a logged repair action.

```bash
hermes --version                                   # new version confirmed
hermes doctor                                      # env, SSL, packages, API connectivity
pgrep -f "hermes.*gateway run"                     # gateway alive
docker ps -a --format "table {{.Names}}\t{{.Status}}"
docker exec bunkerweb supervisorctl status         # boot-race FATAL check
systemctl --failed
curl -s http://localhost:9119/ -o /dev/null -w '%{http_code}\n'    # dashboard 200
curl -s http://localhost:8888/health               # Hindsight
curl -sf https://daviddigitalhub.cloud/health      # DDH
free -h; df -h /
```

Final: run a test Hermes invocation (simple prompt via CLI or a Telegram ping) to prove tool calling, API connections, and core loop execution.

## Repair Playbook (non-destructive)

| Symptom | Fix |
|---|---|
| Gateway DOWN after restart | `nohup hermes gateway run --replace &`, verify with pgrep |
| `git stash pop` conflict | resolve manually, then `git stash drop`; never force |
| venv import errors | `uv sync && uv pip install -e .` |
| Dashboard "frontend not built" crash | `cd web && npm run build && systemctl restart hermes-dashboard` |
| Broken apt package | pin: `apt-get install <pkg>=<oldver>`; hold: `apt-mark hold <pkg>` |
| BunkerWeb FATAL after reboot | `docker exec bunkerweb supervisorctl start bunkerweb` |

## Output Format

1. Pre-Check compatibility findings (versions, requirements, changelog risks, GO/NO-GO)
2. Planned commands, step-by-step
3. Each stage executed with results
4. Post-verification table (check → result)
5. Status summary: what changed, versions before → after, any repairs

## Pitfalls

- `hermes update` from inside an agent session kills the session (gateway restart) — manual git path only
- `hermes update` can hang >5min on TTY prompts — always `--yes --no-backup`, background it, check `~/.hermes/logs/update.log`
- venv has NO pip — `uv` only
- Gateway never auto-respawns on this host — every kill needs a manual start + pgrep verify
- apt prompts hang scripts — always DEBIAN_FRONTEND=noninteractive + force-confdef/confold
- Hermes update stops the dashboard — always rebuild + restart it after
- Full pitfall catalog: `host-maintenance` skill

## Related Skills

- `host-maintenance` — deployment profile details, full pitfall catalog, disk cleanup, diagnostics
- `hermes-gateway-operations` — gateway restart protocol
- `hermes-cron-troubleshooting` — if re-automating updates via cron
