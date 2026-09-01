# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/), dates in UTC.

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
