# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/), dates in UTC.

## [2.3.0] - 2026-09-02

### Added
- Hermes hub-skill check/update/audit phase (`HERMES_SKILLS_MODE`, `HERMES_SKILLS_AUDIT`, `HERMES_SKILLS_TIMEOUT`)
- Hermes profile and command timeouts (`HERMES_HOME`, `HERMES_USER_HOME`, `HERMES_UPDATE_TIMEOUT`)
- Non-destructive test mode (`RUN_DESTRUCTIVE_TESTS` gate in e2e-test.sh)
- Configuration ownership and permissions validation before sourcing
- `AUTO_REMOVE` config option (opt-in, default: false)
- `last-run.log` is now a proper symlink (via `ln -sfn`)
- `Umask=0077` on systemd service unit
- `permissions: contents: read` on CI workflow

### Changed
- Hermes updates now use the supported `hermes update --yes` workflow (replaces custom git pull/uv sync/gateway restart logic)
- Bundled skills are synchronized by the Hermes updater (not manually)
- Reboot scheduling occurs only after all update and verification phases (services are not stopped prematurely)
- Existing configuration is preserved during reinstall (new template installed as `.dist`)
- Risky global npm, uv-tool, autoremove, and reboot operations are opt-in (default: false)
- Docker Compose projects are identified using Compose labels (not container names)
- Docker image updates grouped by Compose project for efficient batch recreation
- CI action pinned to version tag instead of `@master`
- Lock error message uses `lslocks` for PID lookup instead of reading lock file content

### Fixed
- Lock tests now acquire a real `flock` (no longer write a fake PID into the lock file)
- E2E tests preserve command exit status (no longer masked by `|| true`)
- Tests no longer perform live updates unless explicitly authorized (`RUN_DESTRUCTIVE_TESTS=true`)
- Official Docker Hub images (e.g. `nginx:latest`, `postgres:17`) are no longer misclassified as local
- `--force-confmiss` removed (was restoring intentionally deleted conffiles, contrary to config-preservation policy)
- `set -a`/`set +a` removed (Telegram secrets are no longer exported to every child process)
- `last-run.log` is now a symlink as documented (was a regular duplicate file)
- Removed unused `LOCK_TIMEOUT` and `HERMES_VENV` configuration variables
- Removed unused `HERMES_DIR`, `HERMES_WEB_DIR`, `UV_BIN` (replaced by Hermes CLI path and `HERMES_USER_HOME`)

### Security
- Configuration secrets are no longer exported to every child process
- CI actions are pinned (no longer using `@master`)
- Hermes skill updates retain scanner enforcement and never use automatic `--force`
- Configuration file ownership (root) and permissions (no group/other write) validated before sourcing

## [2.2.0] - 2026-09-01

### Changed
- Lock mechanism replaced with atomic `flock` (eliminates TOCTOU race condition and stale lock issues)
- Removed `set -e` in favor of explicit error handling via `add_error`/`add_warning` pattern
- `dist-upgrade` now opt-in via `DIST_UPGRADE` config (default: false — safer for automatic mode)
- Docker compose file detection now checks `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`
- Config file installed with permissions 600 (was 644 — contains bot token)
- Load average check no longer depends on `bc` (uses awk + bash arithmetic)
- Bare `except: pass` in inline Python replaced with `except Exception:`
- Removed unused `SCRIPT_DIR` variable

### Added
- `needrestart` integration: automatically restarts services after library upgrades (if installed)
- Log rotation: auto-deletes log files older than `LOG_RETENTION_DAYS` (default: 30)
- Pre-reboot graceful shutdown: stops Docker containers and Hermes gateway before `shutdown`
- GitHub Actions CI workflow with ShellCheck linting
- `CHANGELOG.md`
- `DIST_UPGRADE` config option
- `LOG_RETENTION_DAYS` config option

### Fixed
- Lock file race condition (test-then-set → atomic flock)
- Log files growing indefinitely (no cleanup → 30-day retention)
- Docker compose detection missing `.yaml` and `compose.yml`/`compose.yaml` variants

## [2.1.0] - 2026-09-01

### Changed
- `AUTO_REBOOT` default changed from false to true
- Pre-reboot Telegram notification sent so user is alerted before reboot

### Added
- `REBOOT_DELAY` config option (default: 5 minutes)

## [2.0.2] - 2026-08-31

### Fixed
- Duplicate logging via tee
- Docker local image filter improved
- Config path resolution

## [2.0.0] - 2026-08-31

### Added
- Fully automatic unattended update mode via systemd timer (daily 04:00)
- Updates: OS packages, Snap, Docker images, Hermes Agent, Python/uv tools, npm globals
- Telegram notification on failure/warnings only (silent on success)
- Lock file, low system priority, health checks, config file

## [1.0.0] - 2026-08-30

### Added
- Initial release: staged OS + Hermes update skill with compatibility pre-checks
- Manual SRE procedure with GO/NO-GO gate, dry-run, staged execution, post-verification
