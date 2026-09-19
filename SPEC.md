# Controlled System Update — Specification

**Version:** 3.0.1
**Status:** Stable
**License:** MIT
**Repository:** https://github.com/Green-Needle-Tech/controlled-system-update

This document specifies the behaviour of `controlled-system-update`: what it
does, in what order, under what guarantees, and where the boundaries of those
guarantees lie. It is the reference for operators auditing the tool before
granting it unattended root on a production host, and for contributors
changing its behaviour.

Where this document and the code disagree, the code is authoritative and the
document is a bug. Every value quoted here was read from
`scripts/auto-update.sh` at version 3.0.1.

---

## 1. Scope and threat model

### 1.1 What this tool is

An unattended update runner for Debian/Ubuntu hosts running Docker services
and, optionally, [Hermes Agent](https://github.com/NousResearch/hermes-agent).
It updates OS packages, Snap packages, Docker images, Hermes Agent and Hermes
skills; verifies the host afterwards; and optionally asks an LLM to suggest
repairs for defects it finds.

### 1.2 What this tool is not

- **Not a configuration manager.** It does not converge a host to a declared
  state. It applies vendor updates and reports the result.
- **Not a backup system.** It takes no snapshots. On btrfs/ZFS or a VM,
  take a snapshot before enabling `AUTO_REBOOT` or `DIST_UPGRADE`.
- **Not a monitoring system.** It runs once a day and reports on that run.
- **Not an autonomous repair agent.** The LLM may only execute commands from
  a fixed allowlist (§6.3). It cannot write files, install packages, change
  configuration, or run arbitrary shell.

### 1.3 Trust boundaries

The tool runs as **root**. Three inputs cross a trust boundary into it:

| Input | Trust | Control |
|---|---|---|
| Configuration file | Trusted | Ownership + permissions validated before sourcing (§3.2) |
| Distribution package repositories | Trusted | Standard apt signature verification; outside this tool's remit |
| **LLM API response** | **Untrusted** | Allowlist + blocklist + metacharacter rejection + no `eval` + per-command timeout (§6.3) |

The LLM response is the only untrusted input that can influence command
execution, and it is the component this specification constrains most
tightly. **A blocklist alone is not a sound control against free-form text
produced by a model**; the design therefore requires a positive match against
a known-safe form before any rejection rule is even consulted.

### 1.4 Non-goals of the safety model

The safety model prevents the LLM from taking destructive, irreversible or
unbounded action. It does **not** attempt to prevent a *sufficiently
adversarial model* from causing a service restart or a cache prune. An
attacker who fully controls the LLM endpoint can, at worst, restart
allowlisted services and prune Docker images. Operators who consider that
unacceptable should set `LLM_REMEDIATION_ENABLED="false"`, which keeps the
diagnostic and disables execution entirely.

---

## 2. Platform support

| Platform | Status |
|---|---|
| Ubuntu 26.04 LTS (Resolute Raccoon), apt 3.x | Supported |
| Ubuntu 24.04 LTS (Noble), apt 2.x | Supported — reference host |
| Ubuntu 22.04 LTS (Jammy) | Supported |
| Debian 12+ | Expected to work, not continuously tested |
| amd64 / x86_64 | Supported, CI-tested |
| arm64 / aarch64 | Supported, CI-tested |
| armhf | Best effort |

### 2.1 Portability rules

These are requirements on the implementation, not merely observations:

1. **All package operations use `apt-get`, never `apt`.** `apt` has an
   explicitly unstable CLI; `apt-get` is the stable scripting interface in
   both apt 2.x and apt 3.x.
2. **No GNU-coreutils-specific behaviour.** Ubuntu 25.10+ ships Rust uutils
   coreutils as the default. Only POSIX-portable invocations of `df`, `free`,
   `sort`, `awk` etc. are used.
3. **No hardcoded architecture.** `uname -m` and `dpkg --print-architecture`
   are read at runtime; Docker pulls are pinned to the detected architecture
   (§5.3).
4. **Reboot markers are checked at both `/run/reboot-required` and
   `/var/run/reboot-required`.**
5. **systemd unit directives must be spelled correctly.** systemd ignores
   unknown keys with only a journal warning, so a typo silently disables the
   setting. CI rejects the known `Umask=` / `UMask=` case.

### 2.2 Runtime detection

Detected once at startup and reported in the log, the diagnostic report
header and every notification:

| Variable | Source |
|---|---|
| `OS_ID`, `OS_VERSION_ID`, `OS_CODENAME` | `/etc/os-release` |
| `HOST_ARCH` | `uname -m` |
| `DPKG_ARCH` | `dpkg --print-architecture` |
| `APT_MAJOR` | first field of `apt-get --version` |

If `apt-get` is absent the run aborts immediately with a clear message rather
than failing obscurely later.

---

## 3. Execution model

### 3.1 Invocation

| Path | Command | Notes |
|---|---|---|
| Scheduled | `controlled-system-update.timer` → `.service` | Daily 01:00 SGT (Asia/Singapore), `RandomizedDelaySec=30m`, `Persistent=false` |
| Manual (systemd) | `systemctl start controlled-system-update.service` | Preferred for manual runs — same environment as scheduled |
| Manual (direct) | `/usr/local/bin/auto-update.sh` | Bypasses systemd resource limits |
| Unit test | `CSU_SOURCE_ONLY=1 source scripts/auto-update.sh` | Loads functions without running `main` |

`Persistent=false` is deliberate: a host that was off for a week should
resume its normal daily cadence, not execute a backlog of missed runs at boot.

### 3.2 Configuration loading

1. Path from `CSU_CONFIG`, default
   `/etc/controlled-system-update/auto-update.conf`.
2. **Ownership check** — must be owned by uid 0, else abort.
3. **Permission check** — must not be group- or world-writable, else abort.
4. Sourced directly. **`set -a` is deliberately not used**: exporting the
   config would leak `TG_BOT_TOKEN` and `LLM_API_KEY` into the environment of
   every child process (`apt`, `docker`, `git`, `npm`).

Precedence: environment > config file > built-in default.

### 3.3 Mutual exclusion

A `flock` on `LOCK_FILE` (default `/var/lock/controlled-system-update.lock`)
is acquired non-blocking; a second instance exits immediately. The lock is
held by the kernel against the file descriptor, so it is released
automatically on exit, crash or `SIGKILL`.

> **Operator note:** lock ownership is determined by the kernel, not by the
> file's existence. Never "fix" a stuck lock by deleting the file — inspect
> it with `lslocks` instead.

### 3.4 Phase order

Phases run in a fixed order. Each handles its own failures and records them
via `add_error` / `add_warning`; a failing phase does not abort the run.

```
acquire_lock
  1. update_os_packages
  2. update_snap_packages
  3. update_docker_images
  4. update_hermes_agent
  5. update_hermes_skills
  6. verify_required_hermes_skills
  7. update_python_packages
  8. update_npm_packages
  9. run_health_checks
 10. run_diagnostic_and_remediate
 11. schedule_reboot_if_required
```

Two ordering constraints are load-bearing:

- **Hermes updates after Docker**, because Hermes may depend on containerised
  services.
- **Reboot scheduling is last**, after all updates and verification. Earlier
  versions scheduled it mid-run, which stopped services while later phases
  were still working.

### 3.5 Exit codes and logging

| Code | Meaning |
|---|---|
| `0` | Completed; no errors (warnings permitted) |
| `1` | Completed with errors, or aborted during preflight |

Each run writes `${LOG_DIR}/auto-update-<timestamp>.log`, with
`last-run.log` symlinked to the most recent. Logs older than
`LOG_RETENTION_DAYS` are deleted at the start of each run.

**Logging goes to stderr; only data goes to stdout.** This is a correctness
requirement, not a style preference: several helpers return values to their
caller through command substitution, and a log line written to stdout is
indistinguishable from returned data. Violating this rule caused a production
incident in which log lines were executed as shell commands (§8.1).

---

## 4. Guarantees

### 4.1 What the tool guarantees

1. **No interactive prompt can hang a run.** `DEBIAN_FRONTEND=noninteractive`
   plus `--force-confdef --force-confold` on every apt invocation.
2. **Existing configuration files are preserved** on package upgrade
   (`--force-confold`). `--force-confmiss` is never used.
3. **Every external command is bounded by a timeout.** No phase can run
   indefinitely.
4. **Held packages are never upgraded.** `PKG_HOLDS` is applied via
   `apt-mark hold` before the upgrade.
5. **The LLM cannot execute a command outside the allowlist** (§6.3).
6. **Secrets are not exported to child processes** (§3.2) and are not written
   to the log.
7. **Concurrent runs are impossible** (§3.3).
8. **No package is removed** unless the operator opts into `AUTO_REMOVE` or
   `DIST_UPGRADE`.
9. **No reboot occurs** unless the operator opts into `AUTO_REBOOT`.

### 4.2 What the tool explicitly does not guarantee

1. **That an update will not break your services.** It applies vendor
   updates. Use `PKG_HOLDS`, and snapshot before enabling `DIST_UPGRADE`.
2. **That the LLM's suggestions are correct.** They are *bounded*, not
   *correct*. A permitted command may still be the wrong one.
3. **Atomicity.** There is no transaction across phases. On apt 3.x
   (Ubuntu 26.04+) a failed upgrade can be rolled back manually with
   `apt history-undo`; the tool surfaces this hint but never rolls back
   automatically.
4. **That a standalone container is restarted** after its image updates. Only
   Compose-managed projects are recreated; standalone containers produce a
   warning (§5.3).
5. **Detection of a gateway that is running but wedged.** Liveness is
   process- and unit-level, not a functional probe.

---

## 5. Update phases

### 5.1 OS packages

```
apt-mark hold $PKG_HOLDS          # if configured
apt-get update
apt-get upgrade -y                 # + apt_opts
apt-get dist-upgrade -y            # only if DIST_UPGRADE=true
apt-get autoremove -y              # only if AUTO_REMOVE=true
apt-get autoclean -y
needrestart -r a                   # if installed and services need restart
```

`apt_opts` always supplies `--force-confdef`, `--force-confold` and
`Dpkg::Use-Pty=0`, plus
`APT::Get::Always-Include-Phased-Updates=true` when `INCLUDE_PHASED_UPDATES`
is enabled.

`dist-upgrade` and `autoremove` are opt-in because both can *remove*
packages. On failure with apt ≥ 3, the error output includes the
`apt history-info 0` / `apt history-undo 0` rollback path.

### 5.2 Snap packages

`snap refresh`. Failures are non-fatal warnings: snap frequently holds locks
during its own refresh cycles, and this is not a reason to fail a run.

### 5.3 Docker images

Containers are grouped by the `com.docker.compose.project` label.

- **Compose projects** — `docker compose pull` then
  `docker compose up -d --force-recreate`, once per project, in the project's
  working directory.
- **Standalone containers** — the image is pulled; if the image ID changed, a
  **warning** is raised advising manual recreation. The tool does not
  unilaterally recreate a container it did not create, because it cannot
  reconstruct the original `docker run` arguments.
- **Locally built images** (bare 12-hex-character IDs) are skipped. An image
  reference without a `/` is *not* treated as local — `nginx:latest` and
  `redis:alpine` are valid registry images.
- Pulls are pinned to the host architecture (`linux/amd64`, `linux/arm64`,
  `linux/arm/v7`) so a mixed fleet cannot silently acquire an emulated image
  from an incomplete manifest list.
- Dangling images are pruned afterwards.

Pull failures are recorded per-container and do not abort the phase; registry
rate limits are common and transient.

### 5.4 Hermes Agent

Runs the supported updater, `hermes update --yes`, under
`HERMES_UPDATE_TIMEOUT`. Custom git or `uv` logic is never used.

**Path and privilege resolution** (each step overridable by config):

| Value | Resolution order |
|---|---|
| `HERMES_CLI` | config → `hermes` on `PATH` → common install locations |
| `HERMES_USER_HOME` | config → owner of the running gateway process → owner of the CLI binary → `/root` |
| `HERMES_HOME` | config → `${HERMES_USER_HOME}/.hermes` |
| `HERMES_USER` | config → owner of `HERMES_USER_HOME` → `root` |

When running as root against a Hermes installation owned by a regular user,
all `hermes` invocations are dropped to that user via `runuser`. This is the
correct fix for git's "dubious ownership" protection; a global
`safe.directory=*` would weaken git's security posture for every repository
on the host.

**Partial-failure recovery.** `hermes update` can exit non-zero *after*
successfully pulling and installing new code, when only its own gateway
relaunch failed (for example an `ImportError` caused by mixed `sys.modules`
against the new checkout). Retrying the update does not help; restarting the
gateway does. On a non-zero exit that is not a timeout, the tool attempts a
bounded gateway restart and, if it succeeds, records a *recovered warning*
rather than an error.

**Gateway liveness** is determined by `gateway_is_running()`, which matches
the real interpreter invocation (`hermes_cli.main gateway run`) or an active
`hermes-gateway.service`. A looser pattern such as
`pgrep -f 'hermes.*gateway run'` is incorrect: it also matches an
administrator's `grep`, this script's own subshell, and any agent session
whose command line mentions those words. On the reference host that pattern
reported three matches for one running gateway.

**Gateway restart is never performed with `hermes gateway run --replace`**,
which runs in the foreground and never returns. The bounded
`hermes gateway restart` is used instead, under
`HERMES_GATEWAY_RESTART_TIMEOUT`, and is skipped entirely when the tool
detects it is running inside a Hermes agent session (§8.3).

### 5.5 Hermes skills

Governed by `HERMES_SKILLS_MODE`:

| Mode | Behaviour |
|---|---|
| `off` | No skill operations |
| `check` *(default)* | `hermes skills check` — report available updates only |
| `update` | `hermes skills check`, then `hermes skills update` |

`hermes skills audit` runs afterwards when `HERMES_SKILLS_AUDIT=true`.

**`--force` is never used.** Hermes intentionally skips a skill whose files
have been modified locally; forcing would discard those edits. The
conservative `check` default reflects that installing new third-party code is
not an OS-maintenance operation.

An optional inventory at
`/etc/controlled-system-update/hermes-skills.conf` declares required skills;
missing ones are reported as warnings. The tool **never installs a missing
third-party skill automatically.**

### 5.6 Python and npm (opt-in)

`uv tool upgrade` for each installed tool, and `npm update -g`. Both default
to disabled: they are development-toolchain maintenance, not OS maintenance.
uv operations run as `HERMES_USER`, because root-owned files inside a user's
home cause later breakage.

---

## 6. Verification and remediation

### 6.1 Health checks

A fast pass over systemd failed units, stopped Docker containers, Hermes
gateway liveness, disk usage (warn >80%, error >90%), available memory
(warn <256 MB) and load average (warn >2× CPU count).

### 6.2 Full diagnostic

Thirteen checks, written to `${LOG_DIR}/diagnostic-report.txt`:

1. `dpkg --audit` — half-installed packages
2. `apt-get check` — broken dependencies
3. systemd failed units
4. Journal errors, last 30 minutes, priority `err`+
5. Docker container health — unhealthy, exited, dead
6. Hermes gateway status and bounded `hermes doctor`
7. Disk usage, all mounts
8. Memory
9. Default gateway reachability
10. DNS resolution
11. Listening ports
12. `dmesg` errors
13. Load average

**Findings are classified before anything is remediated:**

| Class | Meaning | Eligible for remediation |
|---|---|---|
| **Actionable** | A concrete defect a command can fix: broken packages, failed units, dead or unhealthy containers, gateway down | Yes |
| **Advisory** | Pressure and noise signals: journal errors, memory, load — configurable via `DIAGNOSTIC_ADVISORY` | **No** |

With `REMEDIATE_ON_ACTIONABLE_ONLY="true"` (default), a run whose findings are
all advisory skips remediation entirely. This exists because a disk at 85% or
a noisy journal is a *human* decision; handing it to a model at 01:00
produces churn, not repair.

### 6.3 Remediation safety model

When actionable findings exist and `LLM_REMEDIATION_ENABLED="true"`, the
diagnostic report is sent to an OpenAI-compatible endpoint. Suggested commands
are returned one per line prefixed `CMD: `.

Every suggested command passes **five** independent controls:

**Control 1 — Structural rejection.** Any command containing `;` `|` `&`
`` ` `` `$(` `${` `>` or `<` is rejected. Without this, an allowlisted verb
can smuggle a second command:
`systemctl restart nginx; rm -rf /var`.

**Control 2 — Log-line rejection.** Text matching a log-line prefix
(`[YYYY-...`) is rejected. Defence in depth against §8.1.

**Control 3 — Allowlist (positive match required).** The command must match
one of these forms, anchored at both ends:

| Form |
|---|
| `systemctl restart\|start\|reload\|reset-failed <unit>` |
| `systemctl --user restart\|start\|reload\|reset-failed <unit>` |
| `systemctl daemon-reload` |
| `docker restart\|start <container>` |
| `docker compose [-f <file>] up -d [service...]` |
| `docker image prune -f` / `docker system prune -f` |
| `apt-get install -f \| check \| update \| autoclean` |
| `dpkg --configure -a` |
| `journalctl --vacuum-size=<n>` / `--vacuum-time=<t>` |
| `hermes gateway restart\|status` |
| `hermes doctor` |
| `needrestart -r a` |
| `snap refresh` |

Anything unrecognised is rejected and logged.

**Control 4 — Blocklist.** Applied even after an allowlist match. Covers
destructive and irreversible operations (`rm -rf /`, `mkfs`, `dd of=/dev/`,
`shutdown`, `reboot`, `fdisk`, `wipefs`, fork bombs, `curl|sh`,
`apt remove/purge`, `systemctl disable/mask`, `pip/npm uninstall`) **and
never-ending commands** (`hermes gateway run`, `hermes serve`, `tail -f`,
`journalctl -f`, `docker attach`, `watch`, long `sleep`). The second group
exists because a foreground command does not damage the host — it hangs the
update until systemd kills it (§8.2).

**Control 5 — Bounded execution.** Commands are split into an argv array and
executed **without `eval`**, under a hard `REMEDIATION_CMD_TIMEOUT`. Timeouts
are reported distinctly from failures.

Additionally, an allowlisted `hermes gateway restart` is routed through the
guarded helper rather than executed generically, so the agent-session
deadlock guard (§8.3) cannot be bypassed.

The diagnose → remediate → re-diagnose cycle repeats at most
`LLM_MAX_REMEDIATION_ATTEMPTS` times, and stops early if a round executes no
commands.

### 6.4 Test coverage of the safety model

`tests/safety-gate-test.sh` asserts the model directly — 46 assertions
covering allowlist acceptance, both production incidents, metacharacter
smuggling, destructive commands, never-ending commands, and the deadlock
guard. It runs in CI on amd64 and arm64.

---

## 7. Notifications

Telegram, controlled by `NOTIFY_LEVEL`:

| Outcome | `error` | `warning` *(default)* | `always` |
|---|---|---|---|
| Clean | silent | silent | summary |
| Warnings | silent | message | message |
| Errors | message | message | message |

Messages carry host label, timestamp, platform and log path, and are
truncated to Telegram's 4096-character limit. A failed notification is a
warning, never a run failure — the run's outcome does not depend on the
availability of a chat service.

---

## 8. Incident history

These are the defects that shaped the current design. They are recorded
because the constraints they justify look arbitrary without them.

### 8.1 Log output executed as shell commands (2026-09-16)

`log()` wrote to stdout. `llm_get_remediation()` returns its command list to
the caller on stdout via command substitution. Every `[INFO] …` line emitted
*inside* that function was therefore captured as part of the command list and
executed through `eval`.

**Fixes:** all logging moved to stderr; log-line pattern rejection (control
2); `eval` removed; allowlist introduced.

### 8.2 Foreground gateway hung the systemd unit (2026-09-16)

The same run then executed `hermes gateway run --replace`, suggested by the
model and permitted by the blocklist of the day. The command starts a gateway
in the foreground and never returns; the service ran until
`TimeoutStartSec` terminated it 55 minutes later.

Contributing factor: the blocklist patterns that would have caught this
existed on the reference host but had **never been committed**. The repository
and the deployed script had silently diverged.

**Fixes:** never-ending commands blocklisted; per-command timeout;
`TimeoutStartSec` raised to 5400s; installed script and repository verified in
sync as part of the release procedure.

### 8.3 Gateway restart deadlock (2026-09-17)

Found while verifying the fixes above. `hermes gateway restart` drains
in-flight agent turns before stopping, with a budget observed at ~1995s. When
the script runs *inside* a Hermes agent session, the gateway waits for the
very process that requested the restart, while that process waits for the
gateway. Neither yields; only an outer timeout breaks the cycle.

**Fixes:** `restart_hermes_gateway()` detects an agent session via
`HERMES_AGENT` / `AI_AGENT` / `HERMES_UI_SESSION_ID` and skips the restart
with an actionable warning; a dedicated `HERMES_GATEWAY_RESTART_TIMEOUT`
replaces the semantically wrong `HERMES_SKILLS_TIMEOUT`; the LLM path routes
through the guarded helper.

**Consequence to be aware of:** a gateway restart is *skipped*, not performed,
when the tool is run from inside an agent session. The systemd timer path —
where those variables are unset — is unaffected and still self-heals.

### 8.4 `Umask=` silently ignored (found 2026-09-17)

The unit specified `Umask=0077`. The correct directive is `UMask=`. systemd
ignores unknown keys with only a journal warning, so the unit had been running
with the default umask while appearing configured.

**Fix:** corrected, and CI now fails on the typo.

---

## 9. Configuration reference

All values are overridable by environment variable. Defaults below are the
built-in values from `scripts/auto-update.sh` v3.0.1.

### Notification

| Variable | Default | Meaning |
|---|---|---|
| `TG_BOT_TOKEN` | *(empty)* | Telegram bot token |
| `TG_CHAT_ID` | *(empty)* | Telegram chat ID |
| `HOSTNAME_LABEL` | `$(hostname -s)` | Host label in notifications |
| `NOTIFY_LEVEL` | `warning` | `error` \| `warning` \| `always` |

### Update phases

| Variable | Default | Meaning |
|---|---|---|
| `UPDATE_DOCKER` | `true` | Docker image updates |
| `UPDATE_HERMES` | `true` | Hermes Agent update |
| `UPDATE_SNAP` | `true` | Snap refresh |
| `UPDATE_NPM` | `false` | npm globals (opt-in) |
| `UPDATE_PYTHON` | `false` | uv tools (opt-in) |
| `DIST_UPGRADE` | `false` | `apt-get dist-upgrade` (can remove packages) |
| `AUTO_REMOVE` | `false` | `apt-get autoremove` (can remove packages) |
| `INCLUDE_PHASED_UPDATES` | `false` | Take Ubuntu phased updates immediately |
| `PKG_HOLDS` | *(empty)* | Space-separated packages never to upgrade |

### Reboot

| Variable | Default | Meaning |
|---|---|---|
| `AUTO_REBOOT` | `false` | Reboot when required (opt-in) |
| `REBOOT_DELAY` | `5` | Minutes before reboot; cancel with `shutdown -c` |

### Hermes

| Variable | Default | Meaning |
|---|---|---|
| `HERMES_CLI` | *auto* | CLI path |
| `HERMES_HOME` | *auto* | `${HERMES_USER_HOME}/.hermes` |
| `HERMES_USER_HOME` | *auto* | Home of the Hermes-owning user |
| `HERMES_USER` | *auto* | User to drop privileges to |
| `HERMES_UPDATE_TIMEOUT` | `1800` | Timeout for `hermes update` |
| `HERMES_GATEWAY_RESTART_TIMEOUT` | `600` | Timeout for `hermes gateway restart` — **not** the skills timeout; the gateway drains in-flight turns first |
| `HERMES_SKILLS_MODE` | `check` | `off` \| `check` \| `update` |
| `HERMES_SKILLS_AUDIT` | `true` | Run `hermes skills audit` |
| `HERMES_SKILLS_SCOPE` | `all` | Documents source-selection policy |
| `HERMES_SKILLS_TIMEOUT` | `600` | Timeout for skill operations |

### Diagnostic and remediation

| Variable | Default | Meaning |
|---|---|---|
| `DIAGNOSTIC_ENABLED` | `true` | Run the full diagnostic |
| `DIAGNOSTIC_ADVISORY` | `journal memory load` | Categories reported but never remediated |
| `REMEDIATE_ON_ACTIONABLE_ONLY` | `true` | Skip remediation when only advisory findings exist |
| `LLM_REMEDIATION_ENABLED` | `true` | Enable LLM remediation |
| `LLM_API_URL` | OpenRouter chat completions | OpenAI-compatible endpoint |
| `LLM_MODEL` | `z-ai/glm-5.2` | Model identifier |
| `LLM_API_KEY` | *(auto)* | From `~/.hermes/.env` if unset |
| `LLM_TIMEOUT` | `120` | Per-request timeout |
| `LLM_MAX_REMEDIATION_ATTEMPTS` | `3` | Max diagnose→remediate rounds |
| `REMEDIATION_CMD_TIMEOUT` | `120` | Hard timeout per remediation command |

### Logging

| Variable | Default | Meaning |
|---|---|---|
| `LOG_DIR` | `/var/log/controlled-system-update` | Log directory |
| `LOG_RETENTION_DAYS` | `30` | Delete logs older than N days; `0` disables |
| `LOCK_FILE` | `/var/lock/controlled-system-update.lock` | flock path |
| `CSU_CONFIG` | `/etc/controlled-system-update/auto-update.conf` | Config path (env only) |

---

## 10. systemd units

**Service** — `Type=oneshot`, `MemoryMax=1G`, `CPUWeight=50`, `Nice=10`,
`IOSchedulingClass=best-effort`, `UMask=0077`, `TimeoutStartSec=5400`,
`ConditionACPower=true`, after `network-online.target` and `docker.service`.

`TimeoutStartSec` is 5400s because a full run includes `hermes update`, which
rebuilds a web UI; on slower arm64 hosts that plus a large image pull crowded
the previous 3600s budget. Every inner phase has its own tighter timeout, so
this is a backstop, not the primary control.

**Timer** — `OnCalendar=*-*-* 01:00:00 Asia/Singapore`, `RandomizedDelaySec=30m`,
`Persistent=false`.

---

## 11. Development requirements

Changes must satisfy all of the following before merge:

1. `bash -n` on every shell file.
2. `shellcheck --severity=warning` clean.
3. `tests/safety-gate-test.sh` passing — **mandatory for any change touching
   `is_command_safe`, the remediation loop, or gateway handling.**
4. `e2e-test.sh` with zero failures.
5. CI green on `ubuntu-24.04`, `ubuntu-24.04-arm` and `ubuntu-latest`.
6. `CHANGELOG.md` updated; version bumped in `SKILL.md` frontmatter, which is
   the single source of truth read by `e2e-test.sh`.

### Release procedure

1. Bump the version in `SKILL.md`; update `CHANGELOG.md`, `README.md` and
   this document.
2. Run the full local suite (items 1–4 above).
3. `install.sh` on a reference host; confirm the deployed script matches the
   repository. **Divergence here caused §8.2** — verify, do not assume.
4. Commit, tag `vX.Y.Z`, push with tags.
5. Confirm all CI jobs pass, then publish a GitHub release.

### Adding a command to the remediation allowlist

Every addition widens the blast radius of a compromised or confused model.
Require all of:

- The command is **idempotent** — safe to run twice.
- The command **terminates on its own**, with no foreground or follow mode.
- The command **cannot remove data** or make the host unbootable.
- A regression assertion is added to `tests/safety-gate-test.sh`.
- The rationale is recorded in `CHANGELOG.md`.
