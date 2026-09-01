# Controlled System Update

A staged, compatibility-checked update procedure for Linux servers running the [Hermes Agent](https://github.com/NousResearch/hermes-agent) on a root-host git-clone deployment.

Turns "update the server" from an ad-hoc command sequence into a repeatable SRE workflow:

1. **Pre-Check & Compatibility Evaluation** — inventory OS, runtimes, and the Hermes Agent version; check release notes for breaking changes; produce an explicit GO/NO-GO before anything is upgraded.
2. **Dry Run & Simulation** — `apt-get upgrade --simulate` with inspection of incoming packages for breaking changes (Python bumps, libc/openssl, systemd).
3. **Staged Execution** — OS update → noninteractive upgrades (configs preserved) → Hermes Agent update (session-safe git path or backgrounded `hermes update`) → venv rebuild → gateway restart + dashboard rebuild.
4. **Post-Update Verification** — `hermes doctor`, gateway, Docker, BunkerWeb supervisor, dashboard/Hindsight/DDH health endpoints, and a live test invocation.
5. **Repair Playbook** — non-destructive fixes for the known failure modes (package pin/hold, stash conflicts, venv resync, dashboard rebuild).

## Why

`hermes update` restarts the gateway, which kills any agent session that invoked it. Combined with a venv that has no `pip` binary (uv-managed), a gateway that never auto-respawns, and apt prompts that hang non-interactive scripts, a naive "apt upgrade && hermes update" breaks the agent in at least four distinct ways. This skill encodes the working order of operations and the repair paths for each.

## Install

Hermes Agent skill — copy into your skills tree:

```bash
mkdir -p ~/.hermes/skills/devops/controlled-system-update
curl -fsSL https://raw.githubusercontent.com/Green-Needle-Tech/controlled-system-update/main/SKILL.md \
  -o ~/.hermes/skills/devops/controlled-system-update/SKILL.md
```

The skill loads on demand in new sessions. Requires: Ubuntu/Debian host (apt), Hermes Agent installed as a git clone at `/usr/local/lib/hermes-agent` with a uv-managed venv. The procedure generalizes to other layouts — adjust the paths in the Deployment Profile section.

## Quick Start

Ask your Hermes agent: *"run a controlled system update"* — the agent executes Phase 1 (pre-check, no changes), presents findings + planned commands, then proceeds through the staged phases with verification after each.

## Skill Preview

The full procedure lives in [SKILL.md](SKILL.md). Highlights:

- **GO/NO-GO gate** — no upgrade runs until the compatibility summary is presented
- **Session-safe Hermes update** — manual `git stash` → `git pull` → `git stash pop` path when running inside an agent session; backgrounded `hermes update --yes --no-backup` from a plain terminal
- **Prompt-free apt** — `DEBIAN_FRONTEND=noninteractive` + `--force-confdef --force-confold` so scripts never hang
- **Dashboard rebuild** — Hermes updates stop the dashboard; the skill rebuilds and restarts it every time
- **Verification table** — every check has a pass criterion and a logged repair action on failure

## License

MIT
