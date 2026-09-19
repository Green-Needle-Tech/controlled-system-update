#!/usr/bin/env bash
#
# controlled-system-update: Automatic system update script
# Updates: OS packages, Snap, Docker images, Hermes Agent, Hermes external
#          skills, Python/uv tools, npm globals
# Notifies Telegram ONLY on failure (silent on success)
#
# Part of: https://github.com/Green-Needle-Tech/controlled-system-update
# License: MIT
# Author: Liew Wei Sung (Green-Needle-Tech)
#
set -uo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

CONFIG_FILE="${CSU_CONFIG:-/etc/controlled-system-update/auto-update.conf}"

# Load config if it exists — source directly (no set -a; secrets should not
# be exported to every child process like apt, docker, git, npm, etc.)
if [[ -f "$CONFIG_FILE" ]]; then
    # Validate ownership and permissions before sourcing
    config_uid="$(stat -c '%u' "$CONFIG_FILE" 2>/dev/null || echo '0')"
    config_mode="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo '600')"

    if [[ "$config_uid" != "0" ]]; then
        printf 'ERROR: %s must be owned by root\n' "$CONFIG_FILE" >&2
        exit 1
    fi

    if [[ -n "$config_mode" ]] && (( 8#$config_mode & 8#022 )); then
        printf 'ERROR: %s must not be writable by group or others\n' \
            "$CONFIG_FILE" >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Telegram settings (can be overridden in config or env)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
HOSTNAME_LABEL="${HOSTNAME_LABEL:-$(hostname -s)}"

# Paths and privilege (Hermes deployment profile)
# Hermes may be installed for root or for a regular user (e.g. /home/ubuntu).
# All paths are auto-detected at runtime; any value set in the config
# file or environment takes precedence over detection.
#
# Detection order:
#   HERMES_CLI:       config/env -> `hermes` on PATH -> common install locations
#   HERMES_USER_HOME: config/env -> user owning the running gateway process
#                     -> user owning the CLI binary -> /root
#   HERMES_HOME:      config/env -> ${HERMES_USER_HOME}/.hermes
#   HERMES_USER:      config/env -> owner of ${HERMES_USER_HOME} -> root
#
# Privilege drop: when this script runs as root but Hermes is owned by a
# regular user, all hermes invocations run as that user via runuser(1).
# Running git as root inside a user-owned checkout triggers git's
# "dubious ownership" protection (safe.directory); running as the owner
# avoids it entirely without weakening git's security defaults.
detect_hermes_cli() {
    local candidate
    if command -v hermes &>/dev/null; then
        command -v hermes
        return 0
    fi
    for candidate in \
        /usr/local/bin/hermes \
        /usr/bin/hermes \
        /opt/hermes/bin/hermes \
        /root/.local/bin/hermes \
        /home/*/.local/bin/hermes; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Resolve the home directory of a UID via getent passwd
home_of_uid() {
    local uid="$1"
    if [[ -n "$uid" ]] && command -v getent &>/dev/null; then
        getent passwd "$uid" 2>/dev/null | cut -d: -f6
    fi
}

detect_hermes_user_home() {
    local cli="$1" uid home gw_pid
    # Strongest signal: the user the gateway process actually runs as.
    # Multiple processes may match (wrappers, log tails) — take the first
    # match that resolves to a real user home.
    while IFS= read -r gw_pid; do
        [[ -z "$gw_pid" ]] && continue
        uid="$(ps -o uid= -p "$gw_pid" 2>/dev/null | tr -d ' ' || true)"
        home="$(home_of_uid "$uid")"
        if [[ -n "$home" ]]; then
            printf '%s\n' "$home"
            return 0
        fi
    done < <(pgrep -f 'hermes.*gateway' 2>/dev/null || true)
    # Fall back to the user owning the CLI binary
    uid="$(stat -c '%u' "$cli" 2>/dev/null || true)"
    home="$(home_of_uid "$uid")"
    if [[ -n "$home" ]]; then
        printf '%s\n' "$home"
        return 0
    fi
    return 1
}

if [[ -z "${HERMES_CLI:-}" ]]; then
    HERMES_CLI="$(detect_hermes_cli)" || HERMES_CLI=""
fi

if [[ -z "${HERMES_USER_HOME:-}" ]]; then
    HERMES_USER_HOME=""
    if [[ -n "$HERMES_CLI" ]]; then
        HERMES_USER_HOME="$(detect_hermes_user_home "$HERMES_CLI")" || HERMES_USER_HOME=""
    fi
    if [[ -z "$HERMES_USER_HOME" ]]; then
        HERMES_USER_HOME="/root"
    fi
fi

if [[ -z "${HERMES_HOME:-}" ]]; then
    HERMES_HOME="${HERMES_USER_HOME}/.hermes"
fi

# Resolve the user Hermes runs as. When this script runs as root (e.g. via
# the systemd service) but Hermes is installed for a regular user, hermes
# commands must run as that user: git refuses to operate on a repo owned
# by a different user ("dubious ownership") and `hermes update` runs git
# inside the installation checkout.
if [[ -z "${HERMES_USER:-}" ]]; then
    HERMES_USER=""
    if [[ -n "$HERMES_USER_HOME" ]]; then
        HERMES_USER="$(stat -c '%U' "$HERMES_USER_HOME" 2>/dev/null || true)"
    fi
    if [[ -z "$HERMES_USER" || "$HERMES_USER" == "UNKNOWN" ]]; then
        HERMES_USER="root"
    fi
fi

# runuser wrapper: run a command as $HERMES_USER when privilege drop is
# needed. As root with a non-root HERMES_USER, uses runuser -u (no PAM
# password prompt). Otherwise runs the command directly.
hermes_privileged_cmd() {
    if [[ $EUID -eq 0 && "$HERMES_USER" != "root" ]] && command -v runuser &>/dev/null; then
        runuser -u "$HERMES_USER" -- "$@"
    else
        "$@"
    fi
}
HERMES_UPDATE_TIMEOUT="${HERMES_UPDATE_TIMEOUT:-1800}"

# Hermes external skill update mode
# off:    do nothing
# check:  report available external skill updates without installing
# update: update all provenance-tracked external skills
HERMES_SKILLS_MODE="${HERMES_SKILLS_MODE:-check}"
HERMES_SKILLS_AUDIT="${HERMES_SKILLS_AUDIT:-true}"
HERMES_SKILLS_SCOPE="${HERMES_SKILLS_SCOPE:-all}"
HERMES_SKILLS_TIMEOUT="${HERMES_SKILLS_TIMEOUT:-600}"

# Optional inventory of required GitHub skills (for verification only)
# Populated from /etc/controlled-system-update/hermes-skills.conf if present
HERMES_REQUIRED_GITHUB_SKILLS=()

# Load optional skill inventory file if present
SKILLS_INVENTORY_FILE="${SKILLS_INVENTORY_FILE:-/etc/controlled-system-update/hermes-skills.conf}"
if [[ -f "$SKILLS_INVENTORY_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SKILLS_INVENTORY_FILE"
fi

# Logging
LOG_DIR="${LOG_DIR:-/var/log/controlled-system-update}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/auto-update-$(date +%Y%m%d-%H%M%S).log}"
LAST_LOG="${LOG_DIR}/last-run.log"

# Package holds (space-separated list to exclude from upgrades)
PKG_HOLDS="${PKG_HOLDS:-}"

# Whether to reboot if required (auto-reboot) — opt-in for safety
AUTO_REBOOT="${AUTO_REBOOT:-false}"

# Delay (in minutes) before auto-reboot
REBOOT_DELAY="${REBOOT_DELAY:-5}"

# Whether to run dist-upgrade (can remove packages — riskier)
DIST_UPGRADE="${DIST_UPGRADE:-false}"

# Whether to run apt-get autoremove — opt-in for safety
AUTO_REMOVE="${AUTO_REMOVE:-false}"

# Log retention: delete log files older than N days (0 = disable cleanup)
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# Whether to update Docker images
UPDATE_DOCKER="${UPDATE_DOCKER:-true}"

# Whether to update Hermes Agent
UPDATE_HERMES="${UPDATE_HERMES:-true}"

# Whether to update Snap packages
UPDATE_SNAP="${UPDATE_SNAP:-true}"

# Whether to update npm global packages — opt-in (not OS maintenance)
UPDATE_NPM="${UPDATE_NPM:-false}"

# Whether to update Python/uv tools — opt-in (not OS maintenance)
UPDATE_PYTHON="${UPDATE_PYTHON:-false}"

# Track whether a reboot is required (set during OS phase, acted on at end)
REBOOT_REQUIRED=false

# ─── Full Diagnostic + LLM Auto-Remediation ──────────────────────────────────

# Run a comprehensive post-update diagnostic (beyond basic health checks)
DIAGNOSTIC_ENABLED="${DIAGNOSTIC_ENABLED:-true}"

# LLM-based auto-remediation: when the diagnostic finds issues, send the
# report to an LLM which suggests remediation commands. Commands are
# safety-checked (blocklist) before execution. The cycle repeats up to
# LLM_MAX_REMEDIATION_ATTEMPTS times, re-running the diagnostic each round.
LLM_REMEDIATION_ENABLED="${LLM_REMEDIATION_ENABLED:-true}"
LLM_API_URL="${LLM_API_URL:-https://openrouter.ai/api/v1/chat/completions}"
LLM_MODEL="${LLM_MODEL:-z-ai/glm-5.2}"
LLM_API_KEY="${LLM_API_KEY:-}"
LLM_TIMEOUT="${LLM_TIMEOUT:-120}"
LLM_MAX_REMEDIATION_ATTEMPTS="${LLM_MAX_REMEDIATION_ATTEMPTS:-3}"

# Hard timeout for each individual remediation command. Any command that
# outlives it is killed, so a single hung command can never consume the
# whole TimeoutStartSec budget of the systemd unit.
REMEDIATION_CMD_TIMEOUT="${REMEDIATION_CMD_TIMEOUT:-120}"

# Timeout for `hermes gateway restart`. This is NOT the skills timeout: the
# gateway drains in-flight agent turns before stopping, so the command can
# legitimately run for many minutes. It must still be bounded, and it must be
# comfortably below the unit's TimeoutStartSec.
HERMES_GATEWAY_RESTART_TIMEOUT="${HERMES_GATEWAY_RESTART_TIMEOUT:-600}"

# Notification policy:
#   error   — notify only on errors (quietest)
#   warning — notify on errors and warnings (default, legacy behaviour)
#   always  — always send a run summary
NOTIFY_LEVEL="${NOTIFY_LEVEL:-warning}"

# Advisory diagnostic findings are recorded in the report and (optionally)
# the notification, but do NOT trigger LLM remediation. Journal noise and
# a disk at 81% are not things a model should try to "fix" at 01:00.
# Space-separated subset of: journal disk memory load dns ports dmesg
DIAGNOSTIC_ADVISORY="${DIAGNOSTIC_ADVISORY:-journal memory load}"

# Remediate only when an actionable issue is present (broken packages,
# failed units, dead containers, gateway down). Set to false to restore
# the pre-3.0 behaviour of remediating on any finding at all.
REMEDIATE_ON_ACTIONABLE_ONLY="${REMEDIATE_ON_ACTIONABLE_ONLY:-true}"

# Diagnostic report file (written by run_full_diagnostic, read by llm_remediate)
DIAGNOSTIC_REPORT="${LOG_DIR}/diagnostic-report.txt"

# ─── Platform detection ──────────────────────────────────────────────────────
#
# Supported: Debian/Ubuntu on amd64 and arm64, Ubuntu 22.04 through 26.04 LTS
# (Resolute Raccoon) and later. Everything below is derived at runtime — the
# script must never assume x86_64, a specific apt generation, or GNU coreutils
# (Ubuntu 25.10+ ships Rust uutils coreutils by default).

OS_ID="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-unknown}")"
OS_VERSION_ID="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-0}")"
OS_CODENAME="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-unknown}")"
HOST_ARCH="$(uname -m)"
if command -v dpkg &>/dev/null; then
    DPKG_ARCH="$(dpkg --print-architecture 2>/dev/null || printf 'unknown')"
else
    DPKG_ARCH="unknown"
fi

# apt major generation. Ubuntu 26.04 ships apt 3.x (new solver3 resolver,
# columnar output, `apt history-undo`). apt-get remains the stable scripting
# interface in both generations, which is why every call below uses apt-get.
APT_MAJOR=0
if command -v apt-get &>/dev/null; then
    APT_MAJOR="$(apt-get --version 2>/dev/null | awk 'NR==1 {split($2, v, "."); print v[1]}')"
    [[ "$APT_MAJOR" =~ ^[0-9]+$ ]] || APT_MAJOR=0
fi

# Phased updates: Ubuntu rolls some updates out to a fraction of machines.
# A fleet that silently diverges is harder to reason about than one that
# takes phased updates uniformly, but forcing them is a policy choice.
INCLUDE_PHASED_UPDATES="${INCLUDE_PHASED_UPDATES:-false}"

# Common apt-get options for every invocation in this script.
apt_opts() {
    printf '%s\n' \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        -o Dpkg::Use-Pty=0
    if [[ "$INCLUDE_PHASED_UPDATES" == "true" ]]; then
        printf '%s\n' -o APT::Get::Always-Include-Phased-Updates=true
    fi
}

# Reboot marker. /var/run is a symlink to /run on every modern systemd
# distribution, but checking both is free and survives odd images.
reboot_is_required() {
    [[ -f /run/reboot-required || -f /var/run/reboot-required ]]
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

# All log output goes to stderr on purpose. Several helpers return data on
# stdout via command substitution (llm_get_remediation, detect_* helpers);
# logging to stdout would splice log lines into that data. This was the root
# cause of the 2026-09-16 incident, where "[INFO] LLM response:" was captured
# as a remediation command and executed. main() merges stderr into the log
# file, so nothing is lost.
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] ${msg}" >&2
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# Telegram notification (failure only)
notify_telegram() {
    local message="$1"
    if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        log_warn "Telegram notification skipped: TG_BOT_TOKEN or TG_CHAT_ID not set"
        return 0
    fi
    # Truncate to 4096 chars (Telegram limit)
    local truncated
    truncated="$(echo "$message" | head -c 4000)"
    local response
    response="$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${truncated}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "disable_web_page_preview=true" \
        2>/dev/null || echo "000")"
    if [[ "$response" != "200" ]]; then
        log_warn "Telegram notification failed (HTTP ${response})"
    fi
}

# Track errors for final notification
ERRORS=""
add_error() {
    local section="$1"; shift
    local detail="$*"
    ERRORS+="\n<b>[${section}]</b> ${detail}\n"
    # Immediate critical alert: notify as soon as a high/critical error occurs,
    # not only in the end-of-run summary. Toggle with NOTIFY_IMMEDIATE=false.
    if [[ "${NOTIFY_IMMEDIATE:-true}" == "true" ]]; then
        notify_telegram \
            "<b>🚨 [${HOSTNAME_LABEL}] CRITICAL</b>\n[${section}] ${detail}\n\n(Sent immediately; full summary follows at end of run.)"
    fi
}

# Track warnings (non-fatal)
WARNINGS=""
add_warning() {
    local section="$1"; shift
    local detail="$*"
    WARNINGS+="\n<b>[${section}]</b> ${detail}\n"
}

# ─── Lock management (atomic via flock) ───────────────────────────────────────

LOCK_FILE="${LOCK_FILE:-/var/lock/controlled-system-update.lock}"
LOCK_FD=200

acquire_lock() {
    eval "exec ${LOCK_FD}>\"$LOCK_FILE\""
    if ! flock -n ${LOCK_FD}; then
        local lock_pids
        lock_pids="$(lslocks -o PID -n "$LOCK_FILE" 2>/dev/null | tr -d '\n' || echo 'unknown')"
        log_error "Another update is already running (PID: ${lock_pids})"
        exit 1
    fi
    echo $$ >&${LOCK_FD}
    # flock is automatically released when the process exits — no trap needed
}

# ─── Update functions ────────────────────────────────────────────────────────

update_os_packages() {
    log_info "=== OS Package Update ==="

    # Apply package holds if configured
    if [[ -n "$PKG_HOLDS" ]]; then
        log_info "Holding packages: $PKG_HOLDS"
        for pkg in $PKG_HOLDS; do
            apt-mark hold "$pkg" 2>/dev/null || true
        done
    fi

    log_info "Running apt-get update..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1; then
        add_error "OS" "apt-get update failed"
        log_error "apt-get update failed"
        return 1
    fi

    log_info "Running apt-get upgrade (apt ${APT_MAJOR}.x, ${DPKG_ARCH})..."
    local -a apt_flags
    mapfile -t apt_flags < <(apt_opts)
    if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        "${apt_flags[@]}" \
        >> "$LOG_FILE" 2>&1; then
        add_error "OS" "apt-get upgrade failed"
        log_error "apt-get upgrade failed"
        if (( APT_MAJOR >= 3 )); then
            # apt 3.x (Ubuntu 26.04+) records transactions and can roll back.
            log_error "Rollback available: apt history-info 0 / sudo apt history-undo 0"
            add_error "OS" "Rollback available on apt 3.x: 'apt history-info 0' then 'sudo apt history-undo 0'"
        fi
        return 1
    fi

    if [[ "$DIST_UPGRADE" == "true" ]]; then
        log_info "Running apt-get dist-upgrade (DIST_UPGRADE=true)..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
            "${apt_flags[@]}" \
            >> "$LOG_FILE" 2>&1; then
            add_error "OS" "apt-get dist-upgrade failed"
            log_error "apt-get dist-upgrade failed"
            return 1
        fi
    else
        log_info "Skipping dist-upgrade (DIST_UPGRADE=false) — use manual mode for dist-upgrade"
    fi

    if [[ "$AUTO_REMOVE" == "true" ]]; then
        log_info "Running apt-get autoremove (AUTO_REMOVE=true)..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >> "$LOG_FILE" 2>&1; then
            add_warning "OS" "apt-get autoremove had issues (non-fatal)"
            log_warn "apt-get autoremove had issues"
        fi
    else
        log_info "Skipping autoremove (AUTO_REMOVE=false)"
    fi

    log_info "Running apt-get autoclean..."
    DEBIAN_FRONTEND=noninteractive apt-get autoclean -y >> "$LOG_FILE" 2>&1 || true

    # Run needrestart to check for services needing restart after library upgrades
    if command -v needrestart &>/dev/null; then
        log_info "Running needrestart to identify services needing restart..."
        local nr_output
        nr_output="$(needrestart -b 2>/dev/null || true)"
        if [[ -n "$nr_output" ]]; then
            # Check if any services need restarting
            local nr_services
            nr_services="$(echo "$nr_output" | grep -E '^NEEDRESTART-SVC' | awk '{print $3}' || true)"
            if [[ -n "$nr_services" ]]; then
                log_info "needrestart identified services to restart: $(echo "$nr_services" | tr '\n' ' ')"
                # Restart services via needrestart in batch mode (non-interactive)
                needrestart -r a 2>/dev/null >> "$LOG_FILE" 2>&1 || true
                log_info "Service restarts completed via needrestart"
            else
                log_info "needrestart: no services need restarting"
            fi
        fi
    else
        log_info "needrestart not installed, skipping service restart check"
    fi

    # Record whether a reboot is required — do not act on it yet
    if reboot_is_required; then
        REBOOT_REQUIRED=true
        local reboot_pkgs=""
        if [[ -f /run/reboot-required.pkgs ]]; then
            reboot_pkgs="$(sort -u /run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')"
        fi
        log_warn "System reboot is required${reboot_pkgs:+ (packages: ${reboot_pkgs})}"
    fi

    log_info "OS package update complete"
}

update_snap_packages() {
    log_info "=== Snap Package Update ==="
    if ! command -v snap &>/dev/null; then
        log_info "Snap not installed, skipping"
        return 0
    fi
    if [[ "$UPDATE_SNAP" != "true" ]]; then
        log_info "Snap updates disabled, skipping"
        return 0
    fi

    log_info "Running snap refresh..."
    if ! snap refresh >> "$LOG_FILE" 2>&1; then
        add_warning "Snap" "snap refresh had issues (non-fatal)"
        log_warn "snap refresh had issues"
    fi
    log_info "Snap update complete"
}

update_docker_images() {
    log_info "=== Docker Image Update ==="
    if ! command -v docker &>/dev/null; then
        log_info "Docker not installed, skipping"
        return 0
    fi
    if [[ "$UPDATE_DOCKER" != "true" ]]; then
        log_info "Docker updates disabled, skipping"
        return 0
    fi

    # Get all running containers with their images
    local containers
    containers="$(docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null || true)"
    if [[ -z "$containers" ]]; then
        log_info "No running Docker containers, skipping"
        return 0
    fi

    local updated=0
    local failed=0

    # Group containers by Compose project for efficient batch recreation
    local compose_projects=""

    while IFS='|' read -r name image; do
        # Skip images that are locally built (image IDs are 12-char hex strings)
        if [[ "$image" =~ ^[a-f0-9]{12}$ ]]; then
            log_info "Skipping locally-built image (ID): $image (container: $name)"
            continue
        fi

        # Check if this container is part of a Compose project
        local compose_project
        compose_project="$(
            docker inspect \
                --format '{{ index .Config.Labels "com.docker.compose.project" }}' \
                "$name" 2>/dev/null || true
        )"

        if [[ -n "$compose_project" ]]; then
            # Track unique compose projects
            if ! echo "$compose_projects" | grep -qF "|${compose_project}|"; then
                compose_projects="${compose_projects}|${compose_project}|"
            fi
            continue
        fi

        # Standalone container — pull and check for updates
        # Do NOT classify images without '/' as local; official Docker Hub images
        # like nginx:latest, postgres:17, redis:alpine are valid registry images.
        # Pin the pull to this host's architecture. Multi-arch manifests
        # normally resolve correctly on their own, but being explicit keeps
        # mixed amd64/arm64 fleets from silently pulling an emulated image
        # when a manifest list is incomplete.
        local pull_platform=""
        case "$DPKG_ARCH" in
            amd64) pull_platform="linux/amd64" ;;
            arm64) pull_platform="linux/arm64" ;;
            armhf) pull_platform="linux/arm/v7" ;;
        esac

        log_info "Pulling image: $image (container: $name${pull_platform:+, ${pull_platform}})"
        if docker pull ${pull_platform:+--platform "$pull_platform"} "$image" >> "$LOG_FILE" 2>&1; then
            local new_id old_id
            new_id="$(docker inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")"
            old_id="$(docker inspect --format '{{.Image}}' "$name" 2>/dev/null || echo "")"
            if [[ -n "$new_id" && -n "$old_id" && "$new_id" != "$old_id" ]]; then
                log_info "Image updated for $name, manual recreate needed"
                add_warning "Docker" "Image updated for standalone container $name — manual recreate needed"
            fi
        else
            add_error "Docker" "Failed to pull image $image for container $name"
            log_error "Failed to pull $image"
            failed=$((failed + 1))
        fi
    done <<< "$containers"

    # Process Compose projects as a group
    for project in $(echo "$compose_projects" | tr '|' '\n' | grep -v '^$'); do
        local compose_files
        compose_files="$(
            docker inspect \
                --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' \
                "$(docker ps --filter "label=com.docker.compose.project=$project" -q 2>/dev/null | head -1)" \
                2>/dev/null || true
        )"
        local compose_dir
        compose_dir="$(
            docker inspect \
                --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' \
                "$(docker ps --filter "label=com.docker.compose.project=$project" -q 2>/dev/null | head -1)" \
                2>/dev/null || true
        )"

        if [[ -n "$compose_dir" && -n "$compose_files" ]]; then
            log_info "Updating Compose project: $project (dir: $compose_dir)"
            if (cd "$compose_dir" && docker compose pull >> "$LOG_FILE" 2>&1 && \
                docker compose up -d --force-recreate >> "$LOG_FILE" 2>&1); then
                updated=$((updated + 1))
                log_info "Compose project $project updated"
            else
                add_error "Docker" "Failed to update Compose project $project"
                failed=$((failed + 1))
            fi
        elif [[ -n "$compose_dir" ]]; then
            # Fallback: find compose file manually
            local compose_file=""
            for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
                if [[ -f "${compose_dir}/${f}" ]]; then
                    compose_file="${compose_dir}/${f}"
                    break
                fi
            done
            if [[ -n "$compose_file" ]]; then
                log_info "Updating Compose project: $project (file: $compose_file)"
                if (cd "$compose_dir" && docker compose -f "$compose_file" pull >> "$LOG_FILE" 2>&1 && \
                    docker compose -f "$compose_file" up -d --force-recreate >> "$LOG_FILE" 2>&1); then
                    updated=$((updated + 1))
                    log_info "Compose project $project updated"
                else
                    add_error "Docker" "Failed to update Compose project $project"
                    failed=$((failed + 1))
                fi
            else
                add_warning "Docker" "Compose project $project: no compose file found"
            fi
        fi
    done

    # Prune dangling images
    log_info "Pruning dangling images..."
    docker image prune -f >> "$LOG_FILE" 2>&1 || true

    log_info "Docker update complete: $updated projects updated, $failed failed"
}

run_hermes() {
    hermes_privileged_cmd env \
        HOME="$HERMES_USER_HOME" \
        HERMES_HOME="$HERMES_HOME" \
        "$HERMES_CLI" "$@"
}

run_hermes_with_timeout() {
    # hermes_privileged_cmd must wrap timeout (not the other way round):
    # timeout(1) execs its argument, and a shell function is not a binary.
    hermes_privileged_cmd timeout \
        --signal=TERM \
        --kill-after=30s \
        "$HERMES_SKILLS_TIMEOUT" \
        env \
        HOME="$HERMES_USER_HOME" \
        HERMES_HOME="$HERMES_HOME" \
        "$HERMES_CLI" "$@"
}

# Detect a genuinely running Hermes gateway.
#
# `pgrep -f 'hermes.*gateway run'` is too loose: it matches any shell whose
# command line merely mentions those words (an admin grepping the logs, this
# script's own subshell, an agent session running a diagnostic). A false
# positive hides a dead gateway; a false negative triggers a pointless
# restart. Match the actual interpreter invocation, and accept the systemd
# user unit as an equally authoritative signal.
gateway_is_running() {
    if pgrep -f 'hermes_cli\.main[[:space:]]+gateway[[:space:]]+run' >/dev/null 2>&1; then
        return 0
    fi
    # python -m hermes_cli.main gateway run may appear with a full venv path
    if pgrep -f 'venv/bin/python.*gateway[[:space:]]+run' >/dev/null 2>&1; then
        return 0
    fi
    # systemd user unit (root-owned installs typically use this)
    if command -v systemctl &>/dev/null; then
        if systemctl --user is-active --quiet hermes-gateway.service 2>/dev/null; then
            return 0
        fi
        if systemctl is-active --quiet hermes-gateway.service 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Restart the gateway through the supported, BOUNDED command.
#
# Never `hermes gateway run --replace` from this script: it runs in the
# foreground and will hold the systemd unit open until TimeoutStartSec
# kills the whole update (the 2026-09-16 failure).
restart_hermes_gateway() {
    [[ -x "$HERMES_CLI" ]] || return 1

    # Self-deadlock guard. `hermes gateway restart` drains in-flight agent
    # turns before stopping (up to agent.restart_after_turn_timeout +
    # restart_drain_timeout, which can be ~30 min). If this script is itself
    # running inside an agent turn — e.g. an operator ran it from a Hermes
    # session rather than the systemd timer — the gateway waits for this very
    # process to finish while this process waits for the gateway. Neither
    # yields, and only the outer timeout breaks it. Observed 2026-09-17.
    if [[ -n "${HERMES_AGENT:-}${AI_AGENT:-}${HERMES_UI_SESSION_ID:-}" ]]; then
        log_warn "Running inside a Hermes agent session — skipping gateway restart to avoid a drain deadlock"
        add_warning "Hermes" \
            "Gateway restart skipped: running inside an agent session. Restart manually with 'hermes gateway restart'."
        return 1
    fi

    log_info "Restarting Hermes gateway (bounded to ${HERMES_GATEWAY_RESTART_TIMEOUT}s)..."
    if hermes_privileged_cmd timeout \
        --signal=TERM \
        --kill-after=30s \
        "$HERMES_GATEWAY_RESTART_TIMEOUT" \
        env \
        HOME="$HERMES_USER_HOME" \
        HERMES_HOME="$HERMES_HOME" \
        "$HERMES_CLI" gateway restart >>"$LOG_FILE" 2>&1; then
        sleep 5
        if gateway_is_running; then
            log_info "Hermes gateway restarted successfully"
            return 0
        fi
        log_warn "Hermes gateway restart returned success but no gateway is running"
        return 1
    fi
    log_warn "Hermes gateway restart command failed"
    return 1
}

update_hermes_agent() {
    log_info "=== Hermes Agent Update ==="

    if [[ "$UPDATE_HERMES" != "true" ]]; then
        log_info "Hermes updates disabled, skipping"
        return 0
    fi

    if [[ ! -x "$HERMES_CLI" ]]; then
        add_warning "Hermes" "Hermes CLI not executable at $HERMES_CLI"
        return 0
    fi

    local old_version new_version
    old_version="$(run_hermes --version 2>/dev/null || printf 'unknown')"
    log_info "Current Hermes version: $old_version"

    log_info "Running supported Hermes updater (as user: $HERMES_USER)..."
    local update_rc=0
    hermes_privileged_cmd timeout \
        --signal=TERM \
        --kill-after=30s \
        "$HERMES_UPDATE_TIMEOUT" \
        env \
        HOME="$HERMES_USER_HOME" \
        HERMES_HOME="$HERMES_HOME" \
        "$HERMES_CLI" update --yes >>"$LOG_FILE" 2>&1 || update_rc=$?

    new_version="$(run_hermes --version 2>/dev/null || printf 'unknown')"

    if (( update_rc != 0 )); then
        # A very common partial failure: the new code IS pulled and installed,
        # but the updater's own gateway relaunch or dashboard cleanup crashed
        # (e.g. an ImportError from mixed sys.modules against the new
        # checkout). The checkout is fine; only the running processes are
        # stale. A bounded `hermes gateway restart` recovers this without
        # human intervention — retrying `hermes update` would not.
        if (( update_rc == 124 || update_rc == 137 )); then
            add_error "Hermes" "hermes update timed out after ${HERMES_UPDATE_TIMEOUT}s"
            log_error "Hermes update timed out"
            return 1
        fi

        log_warn "hermes update exited non-zero (rc=$update_rc) — attempting gateway recovery"
        if restart_hermes_gateway; then
            add_warning "Hermes" \
                "hermes update exited $update_rc but the code was pulled and the gateway restarted cleanly (recovered)"
            log_info "Recovered from partial Hermes update failure"
        else
            add_error "Hermes" "hermes update failed (rc=$update_rc) and gateway recovery did not succeed"
            log_error "Hermes update failed and could not be recovered"
            return 1
        fi
    fi

    log_info "Hermes version after update: $new_version"

    # `hermes doctor` can block on network probes — bound it.
    if ! run_hermes_with_timeout doctor >>"$LOG_FILE" 2>&1; then
        add_warning "Hermes" "hermes doctor reported problems after update"
    fi

    # Verify the gateway actually survived the update.
    if ! gateway_is_running; then
        log_warn "Gateway not running after update — restarting"
        if ! restart_hermes_gateway; then
            add_error "Hermes" "Gateway is not running after update and could not be restarted"
        fi
    fi
}

update_hermes_skills() {
    log_info "=== Hermes External Skills Update ==="

    if [[ ! -x "$HERMES_CLI" ]]; then
        add_warning \
            "Hermes Skills" \
            "Hermes CLI is not executable at $HERMES_CLI"
        return 0
    fi

    case "$HERMES_SKILLS_MODE" in
        off)
            log_info "External Hermes skill checks are disabled"
            return 0
            ;;

        check)
            log_info \
                "Checking all tracked unofficial and hub-installed skills"

            if ! run_hermes_with_timeout \
                skills check >>"$LOG_FILE" 2>&1; then
                add_warning \
                    "Hermes Skills" \
                    "Unable to check one or more external skills"
            fi
            ;;

        update)
            log_info \
                "Checking all tracked unofficial and hub-installed skills"

            if ! run_hermes_with_timeout \
                skills check >>"$LOG_FILE" 2>&1; then
                add_warning \
                    "Hermes Skills" \
                    "External skill update check reported an error"
            fi

            log_info \
                "Updating changed GitHub, URL, tap, and hub-installed skills"

            if ! run_hermes_with_timeout \
                skills update >>"$LOG_FILE" 2>&1; then
                add_warning \
                    "Hermes Skills" \
                    "One or more external skills could not be updated"
            fi
            ;;

        *)
            add_error \
                "Configuration" \
                "Invalid HERMES_SKILLS_MODE: $HERMES_SKILLS_MODE"
            return 1
            ;;
    esac

    if [[ "$HERMES_SKILLS_AUDIT" == "true" ]]; then
        log_info "Auditing all Hermes-managed external skills"

        if ! run_hermes_with_timeout \
            skills audit >>"$LOG_FILE" 2>&1; then
            add_warning \
                "Hermes Skills" \
                "External skill security audit reported an error"
        fi
    fi
}

verify_required_hermes_skills() {
    if [[ ${#HERMES_REQUIRED_GITHUB_SKILLS[@]} -eq 0 ]]; then
        return 0
    fi

    log_info "Verifying required Hermes skill inventory..."

    local inventory
    local identifier
    local missing=0

    if ! inventory="$(
        run_hermes skills list --source hub 2>>"$LOG_FILE"
    )"; then
        add_warning \
            "Hermes Skills" \
            "Unable to read the installed skill inventory"
        return 0
    fi

    for identifier in "${HERMES_REQUIRED_GITHUB_SKILLS[@]}"; do
        if ! grep -Fq -- "$identifier" <<<"$inventory"; then
            add_warning \
                "Hermes Skills" \
                "Required GitHub skill is not provenance-tracked: $identifier"
            missing=1
        fi
    done

    return "$missing"
}

update_python_packages() {
    log_info "=== Python Package Update ==="
    if [[ "$UPDATE_PYTHON" != "true" ]]; then
        log_info "Python updates disabled, skipping"
        return 0
    fi
    local uv_bin="${UV_BIN:-${HERMES_USER_HOME}/.local/bin/uv}"
    if [[ ! -x "$uv_bin" ]] && command -v uv &>/dev/null; then
        uv_bin="$(command -v uv)"
    fi
    if [[ ! -x "$uv_bin" ]]; then
        log_info "uv not found, skipping Python package updates"
        return 0
    fi

    # Update uv-managed tools if any (run as HERMES_USER — tools live in
    # the user's home, and root-owned files in a user home cause breakage)
    log_info "Updating uv-installed tools..."
    if hermes_privileged_cmd env HOME="$HERMES_USER_HOME" \
        "$uv_bin" tool list --format json 2>/dev/null | grep -q '"name"'; then
        local tools
        tools="$(hermes_privileged_cmd env HOME="$HERMES_USER_HOME" \
            "$uv_bin" tool list --format json 2>/dev/null | python3 -c "
import sys, json
try:
    for t in json.load(sys.stdin):
        print(t.get('name', ''))
except Exception:
    pass
" 2>/dev/null || true)"
        if [[ -n "$tools" ]]; then
            for tool in $tools; do
                log_info "Updating tool: $tool"
                hermes_privileged_cmd env HOME="$HERMES_USER_HOME" \
                    "$uv_bin" tool upgrade "$tool" >> "$LOG_FILE" 2>&1 || \
                    hermes_privileged_cmd env HOME="$HERMES_USER_HOME" \
                    "$uv_bin" tool install "$tool" >> "$LOG_FILE" 2>&1 || true
            done
        fi
    fi
    log_info "Python package update complete"
}

update_npm_packages() {
    log_info "=== npm Global Package Update ==="
    if ! command -v npm &>/dev/null; then
        log_info "npm not installed, skipping"
        return 0
    fi
    if [[ "$UPDATE_NPM" != "true" ]]; then
        log_info "npm updates disabled, skipping"
        return 0
    fi

    local outdated
    outdated="$(npm outdated -g --format=json 2>/dev/null || echo '{}')"
    if echo "$outdated" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d else 1)" 2>/dev/null; then
        log_info "Updating outdated global npm packages..."
        if ! npm update -g >> "$LOG_FILE" 2>&1; then
            add_warning "npm" "npm update -g had issues (non-fatal)"
            log_warn "npm update -g had issues"
        fi
    else
        log_info "All global npm packages up to date"
    fi
    log_info "npm package update complete"
}

# ─── Health checks ───────────────────────────────────────────────────────────

run_health_checks() {
    log_info "=== Post-Update Health Checks ==="
    local failures=0

    # Check systemd failed units
    local failed_units
    failed_units="$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$failed_units" ]]; then
        add_warning "Health" "Failed systemd units: $(echo "$failed_units" | tr '\n' ' ')"
        log_warn "Failed systemd units: $failed_units"
    fi

    # Check Docker containers
    if command -v docker &>/dev/null; then
        local exited_containers
        exited_containers="$(docker ps -a --filter 'status=exited' --filter 'status=dead' \
            --format '{{.Names}} ({{.Status}})' 2>/dev/null || true)"
        if [[ -n "$exited_containers" ]]; then
            add_warning "Health" "Stopped Docker containers: $(echo "$exited_containers" | tr '\n' ' ')"
            log_warn "Stopped containers: $exited_containers"
        fi
    fi

    # Check Hermes gateway
    if [[ -x "$HERMES_CLI" ]]; then
        if ! gateway_is_running; then
            add_error "Health" "Hermes gateway is not running"
            log_error "Hermes gateway DOWN"
            failures=$((failures + 1))
        fi
    fi

    # Check disk space
    local disk_usage
    disk_usage="$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')"
    if (( disk_usage > 90 )); then
        add_error "Health" "Disk usage at ${disk_usage}% on /"
        log_error "Critical disk usage: ${disk_usage}%"
        failures=$((failures + 1))
    elif (( disk_usage > 80 )); then
        add_warning "Health" "Disk usage at ${disk_usage}% on /"
    fi

    # Check memory
    local mem_avail
    mem_avail="$(free -m | awk '/^Mem:/ {print $7}')"
    if (( mem_avail < 256 )); then
        add_warning "Health" "Low available memory: ${mem_avail}MB"
    fi

    # Check load average
    local load1
    load1="$(awk '{print $1}' /proc/loadavg)"
    local load1_x100
    load1_x100="$(awk '{printf "%d", $1 * 100}' /proc/loadavg)"
    local cpu_count
    cpu_count="$(nproc)"
    if (( load1_x100 > cpu_count * 200 )); then
        add_warning "Health" "High load average: ${load1} (CPUs: ${cpu_count})"
    fi

    log_info "Health checks complete: $failures failures"
    return $failures
}

# ─── Diagnostic finding classification ───────────────────────────────────────

# Findings are split into two classes:
#   actionable — a concrete defect a remediation command can fix
#                (broken packages, failed units, dead containers, gateway down)
#   advisory   — informational pressure signals that a model should not try
#                to "fix" unattended (journal noise, memory, load, and any
#                category listed in DIAGNOSTIC_ADVISORY)
#
# Only actionable findings trigger LLM remediation when
# REMEDIATE_ON_ACTIONABLE_ONLY=true (the default). Advisory findings are
# always recorded in the report and the notification summary.
DIAG_ACTIONABLE=0
DIAG_ADVISORY=0

is_advisory_category() {
    local category="$1" entry
    for entry in $DIAGNOSTIC_ADVISORY; do
        [[ "$entry" == "$category" ]] && return 0
    done
    return 1
}

# diag_finding <category> <error|warning> <message>
diag_finding() {
    local category="$1" level="$2"; shift 2
    local msg="$*"

    if is_advisory_category "$category"; then
        DIAG_ADVISORY=$((DIAG_ADVISORY + 1))
        add_warning "Advisory" "$msg"
        log_warn "Advisory finding (${category}): $msg"
        return 0
    fi

    DIAG_ACTIONABLE=$((DIAG_ACTIONABLE + 1))
    if [[ "$level" == "error" ]]; then
        add_error "Diagnostic" "$msg"
        log_error "$msg"
    else
        add_warning "Diagnostic" "$msg"
        log_warn "$msg"
    fi
}

# ─── Full Diagnostic ────────────────────────────────────────────────────────

# Comprehensive post-update diagnostic. Goes beyond the basic health checks
# (systemd, Docker, Hermes gateway, disk/memory/load) to also cover:
#   - dpkg package integrity (dpkg --audit)
#   - Broken dependencies (apt-get check)
#   - systemd journal errors in the last 30 minutes
#   - Network reachability (default gateway + DNS resolution)
#   - Listening ports summary (unexpected services)
#   - Docker container health for all containers
#   - Hermes doctor (if available)
#   - Filesystem errors (dmesg)
#
# Writes a structured report to $DIAGNOSTIC_REPORT and returns 0 if clean,
# 1 if issues found.
run_full_diagnostic() {
    log_info "=== Full Post-Update Diagnostic ==="

    local report="$DIAGNOSTIC_REPORT"
    local issues=0
    : > "$report"

    {
        echo "=== Controlled System Update — Full Diagnostic ==="
        echo "Host: $HOSTNAME_LABEL"
        echo "Platform: ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME}) ${HOST_ARCH}/${DPKG_ARCH}"
        echo "apt: ${APT_MAJOR}.x   kernel: $(uname -r)"
        echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo ""
    } >> "$report"

    # 1. dpkg audit — checks for half-installed/broken packages
    local dpkg_audit
    dpkg_audit="$(dpkg --audit 2>&1 || true)"
    if [[ -n "$dpkg_audit" ]]; then
        echo "--- dpkg Audit (ISSUES) ---" >> "$report"
        echo "$dpkg_audit" >> "$report"
        echo "" >> "$report"
        issues=$((issues + 1))
        diag_finding dpkg warning "dpkg audit found issues"
    else
        echo "--- dpkg Audit: OK ---" >> "$report"
        echo "" >> "$report"
    fi

    # 2. Broken dependencies
    local apt_check
    apt_check="$(apt-get check 2>&1 || true)"
    if echo "$apt_check" | grep -qiE 'broken|error|problem'; then
        echo "--- apt-get check (ISSUES) ---" >> "$report"
        echo "$apt_check" >> "$report"
        echo "" >> "$report"
        issues=$((issues + 1))
        diag_finding apt error "apt-get check found broken dependencies"
    else
        echo "--- apt-get check: OK ---" >> "$report"
        echo "" >> "$report"
    fi

    # 3. systemd failed units (detailed)
    local failed_units
    failed_units="$(systemctl --failed --no-legend 2>/dev/null || true)"
    if [[ -n "$failed_units" ]]; then
        echo "--- Failed systemd Units ---" >> "$report"
        echo "$failed_units" >> "$report"
        echo "" >> "$report"
        issues=$((issues + 1))
        diag_finding systemd warning "Failed systemd units detected"
    else
        echo "--- systemd Failed Units: None ---" >> "$report"
        echo "" >> "$report"
    fi

    # 4. systemd journal errors in last 30 min
    local journal_errors
    journal_errors="$(journalctl --since '30 min ago' --no-pager \
        -p err 2>/dev/null | tail -50 || true)"
    if [[ -n "$journal_errors" ]]; then
        echo "--- Journal Errors (last 30 min, up to 50 lines) ---" >> "$report"
        echo "$journal_errors" >> "$report"
        echo "" >> "$report"
        issues=$((issues + 1))
        diag_finding journal warning "Journal errors in last 30 minutes"
    else
        echo "--- Journal Errors (last 30 min): None ---" >> "$report"
        echo "" >> "$report"
    fi

    # 5. Docker container health
    if command -v docker &>/dev/null; then
        local docker_ps
        docker_ps="$(docker ps -a --format \
            'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true)"
        echo "--- Docker Containers ---" >> "$report"
        echo "$docker_ps" >> "$report"
        echo "" >> "$report"

        # Check for unhealthy containers
        local unhealthy
        unhealthy="$(docker ps --filter 'health=unhealthy' \
            --format '{{.Names}}' 2>/dev/null || true)"
        if [[ -n "$unhealthy" ]]; then
            echo "--- Unhealthy Docker Containers ---" >> "$report"
            echo "$unhealthy" >> "$report"
            echo "" >> "$report"
            issues=$((issues + 1))
            diag_finding docker warning "Unhealthy Docker containers: $(echo "$unhealthy" | tr '\n' ' ')"
        fi

        # Check for exited containers that should be running
        local exited
        exited="$(docker ps -a --filter 'status=exited' --filter 'status=dead' \
            --format '{{.Names}} ({{.Status}})' 2>/dev/null || true)"
        if [[ -n "$exited" ]]; then
            echo "--- Exited/Dead Docker Containers ---" >> "$report"
            echo "$exited" >> "$report"
            echo "" >> "$report"
            issues=$((issues + 1))
            diag_finding docker warning "Exited/dead Docker containers detected"
        fi
    else
        echo "--- Docker: Not installed ---" >> "$report"
        echo "" >> "$report"
    fi

    # 6. Hermes gateway + doctor
    if [[ -x "$HERMES_CLI" ]]; then
        if gateway_is_running; then
            echo "--- Hermes Gateway: Running ---" >> "$report"
        else
            echo "--- Hermes Gateway: DOWN ---" >> "$report"
            issues=$((issues + 1))
            diag_finding hermes error "Hermes gateway is DOWN"
        fi

        local hermes_doctor
        hermes_doctor="$(run_hermes_with_timeout doctor 2>&1 || true)"
        echo "--- Hermes Doctor ---" >> "$report"
        echo "$hermes_doctor" >> "$report"
        echo "" >> "$report"
        if echo "$hermes_doctor" | grep -qiE 'fail|error|not found|missing'; then
            issues=$((issues + 1))
            diag_finding hermes warning "Hermes doctor reported problems"
        fi
    else
        echo "--- Hermes: CLI not found ---" >> "$report"
        echo "" >> "$report"
    fi

    # 7. Disk space (all mounts)
    echo "--- Disk Usage ---" >> "$report"
    df -h >> "$report" 2>&1
    echo "" >> "$report"
    local root_usage
    root_usage="$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')"
    if [[ -n "$root_usage" ]] && (( root_usage > 90 )); then
        issues=$((issues + 1))
        diag_finding disk error "Disk usage critical: ${root_usage}% on /"
    elif [[ -n "$root_usage" ]] && (( root_usage > 80 )); then
        issues=$((issues + 1))
        diag_finding disk warning "Disk usage high: ${root_usage}% on /"
    fi

    # 8. Memory
    echo "--- Memory ---" >> "$report"
    free -h >> "$report" 2>&1
    echo "" >> "$report"
    local mem_avail
    mem_avail="$(free -m | awk '/^Mem:/ {print $7}')"
    if [[ -n "$mem_avail" ]] && (( mem_avail < 256 )); then
        issues=$((issues + 1))
        diag_finding memory warning "Low available memory: ${mem_avail}MB"
    fi

    # 9. Network: default gateway reachability
    local default_gw
    default_gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}' || true)"
    if [[ -n "$default_gw" ]]; then
        echo "--- Network: Gateway ($default_gw) ---" >> "$report"
        if ping -c 1 -W 3 "$default_gw" >/dev/null 2>&1; then
            echo "Gateway reachable: YES" >> "$report"
        else
            echo "Gateway reachable: NO" >> "$report"
            issues=$((issues + 1))
            diag_finding network warning "Default gateway ($default_gw) unreachable"
        fi
    else
        echo "--- Network: No default gateway ---" >> "$report"
        issues=$((issues + 1))
        diag_finding network warning "No default gateway found"
    fi
    echo "" >> "$report"

    # 10. DNS resolution
    echo "--- DNS Resolution ---" >> "$report"
    if nslookup github.com >/dev/null 2>&1 || \
       getent hosts github.com >/dev/null 2>&1; then
        echo "DNS resolution: OK" >> "$report"
    else
        echo "DNS resolution: FAILED" >> "$report"
        issues=$((issues + 1))
        diag_finding dns warning "DNS resolution failed"
    fi
    echo "" >> "$report"

    # 11. Listening ports (for awareness)
    echo "--- Listening Ports (ss) ---" >> "$report"
    ss -tlnp 2>/dev/null | head -30 >> "$report" || true
    echo "" >> "$report"

    # 12. dmesg errors (filesystem, hardware)
    echo "--- dmesg Errors (last 20) ---" >> "$report"
    dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -20 >> "$report" || true
    echo "" >> "$report"

    # 13. Load average
    echo "--- Load Average ---" >> "$report"
    cat /proc/loadavg >> "$report"
    echo "" >> "$report"

    # Summary
    {
        echo "=== Diagnostic Summary ==="
        echo "Total findings:      $issues"
        echo "Actionable findings: $DIAG_ACTIONABLE"
        echo "Advisory findings:   $DIAG_ADVISORY"
    } >> "$report"
    log_info "Full diagnostic complete: $issues finding(s) — ${DIAG_ACTIONABLE} actionable, ${DIAG_ADVISORY} advisory"
    log_info "Diagnostic report: $report"

    if (( issues > 0 )); then
        return 1
    fi
    return 0
}

# ─── LLM Auto-Remediation ────────────────────────────────────────────────────

# Safety check for an LLM-suggested remediation command.
#
# Two gates, in order:
#   1. ALLOWLIST — the command's leading verb must match a known-safe
#      remediation form. Anything unrecognised is rejected. An allowlist is
#      the only defensible posture for shell text produced by a model.
#   2. BLOCKLIST — destructive, long-running or unbootable-making patterns
#      are rejected even if the leading verb looked acceptable.
#
# Shell metacharacters that chain or redirect (; | & ` $( ) > <) are rejected
# outright: they let a single "allowed" verb smuggle arbitrary commands.
#
# Returns 0 (safe) or 1 (blocked).
is_command_safe() {
    local cmd="$1"

    # Empty or whitespace-only
    if [[ -z "$(echo "$cmd" | tr -d '[:space:]')" ]]; then
        return 1
    fi

    # Reject anything that is not a plain single command invocation.
    # No chaining, piping, substitution, redirection or backgrounding.
    if [[ "$cmd" =~ [\;\|\&\`\<\>] || "$cmd" == *'$('* || "$cmd" == *'${'* ]]; then
        log_warn "Blocked command with shell metacharacters: $cmd"
        return 1
    fi

    # Reject log lines and other non-command text (defence in depth against
    # the 2026-09-16 class of bug where log output was parsed as a command).
    if [[ "$cmd" =~ ^\[[0-9]{4}- ]]; then
        log_warn "Blocked non-command text: $cmd"
        return 1
    fi

    # Gate 1 — allowlist of remediation forms
    local allowlist=(
        '^systemctl[[:space:]]+(restart|start|reload|reset-failed)[[:space:]]+[A-Za-z0-9@_.:\\-]+$'
        '^systemctl[[:space:]]+--user[[:space:]]+(restart|start|reload|reset-failed)[[:space:]]+[A-Za-z0-9@_.:\\-]+$'
        '^systemctl[[:space:]]+daemon-reload$'
        '^docker[[:space:]]+(restart|start)[[:space:]]+[A-Za-z0-9_.\\-]+$'
        '^docker[[:space:]]+compose([[:space:]]+-f[[:space:]]+[^[:space:]]+)?[[:space:]]+up[[:space:]]+-d([[:space:]]+[A-Za-z0-9_.\\-]+)*$'
        '^docker[[:space:]]+(image[[:space:]]+)?prune[[:space:]]+-f$'
        '^docker[[:space:]]+system[[:space:]]+prune[[:space:]]+-f$'
        '^apt-get[[:space:]]+(install[[:space:]]+-f|check|update|autoclean)([[:space:]]+-y)?$'
        '^apt-get[[:space:]]+-y[[:space:]]+install[[:space:]]+-f$'
        '^dpkg[[:space:]]+--configure[[:space:]]+-a$'
        '^journalctl[[:space:]]+--vacuum-(size|time)=[A-Za-z0-9]+$'
        '^hermes[[:space:]]+gateway[[:space:]]+(restart|status)$'
        '^hermes[[:space:]]+doctor$'
        '^needrestart[[:space:]]+-r[[:space:]]+a$'
        '^snap[[:space:]]+refresh$'
    )

    local allowed=false
    local allow_pattern
    for allow_pattern in "${allowlist[@]}"; do
        if echo "$cmd" | grep -qE "$allow_pattern"; then
            allowed=true
            break
        fi
    done

    if [[ "$allowed" != "true" ]]; then
        log_warn "Blocked command not on the remediation allowlist: $cmd"
        return 1
    fi

    # Gate 2 — blocklist, applied even to allowlisted verbs
    local blocklist=(
        'rm[[:space:]]+-rf[[:space:]]+/'
        'rm[[:space:]]+-rf[[:space:]]+/\*'
        'rm[[:space:]]+-fr[[:space:]]+/'
        'mkfs'
        'dd[[:space:]].*of=/dev/'
        'shutdown'
        'reboot'
        'halt'
        'poweroff'
        'init[[:space:]]+0'
        'init[[:space:]]+6'
        'systemctl[[:space:]]+poweroff'
        'systemctl[[:space:]]+reboot'
        'fdisk'
        'parted'
        'wipefs'
        'chmod[[:space:]]+-R[[:space:]]+777[[:space:]]+/'
        'chown[[:space:]]+-R[[:space:]].*[[:space:]]+/$'
        '>[[:space:]]*/dev/sd'
        '>[[:space:]]*/dev/nvme'
        '>[[:space:]]*/dev/vd'
        ':[[:space:]]*\(\)[[:space:]]*\{.*\};:'  # fork bomb
        'curl.*\|[[:space:]]*sh'
        'curl.*\|[[:space:]]*bash'
        'wget.*\|[[:space:]]*sh'
        'wget.*\|[[:space:]]*bash'
        'systemctl[[:space:]]+disable'
        'systemctl[[:space:]]+mask'
        'apt-get[[:space:]]+remove'
        'apt-get[[:space:]]+purge'
        'apt[[:space:]]+remove'
        'apt[[:space:]]+purge'
        'dpkg[[:space:]]+--remove'
        'dpkg[[:space:]]+--purge'
        'pip[[:space:]]+uninstall'
        'npm[[:space:]]+uninstall'
        # Never-ending commands: these block the update service until
        # TimeoutStartSec kills it. Root cause of the 2026-09-16 timeout
        # failure, where the LLM suggested `hermes gateway run --replace`
        # and the foreground gateway ran until systemd terminated the unit.
        # `hermes gateway restart` is the correct, bounded alternative and
        # is on the allowlist.
        'hermes[[:space:]]+gateway[[:space:]]+run'
        'hermes[[:space:]]+serve'
        'hermes[[:space:]]+dashboard'
        'tail[[:space:]]+-f'
        'journalctl[[:space:]]+-f'
        'docker[[:space:]]+logs[[:space:]]+-f'
        'docker[[:space:]]+(attach|exec[[:space:]]+-it)'
        'watch[[:space:]]'
        'sleep[[:space:]]+[0-9]{3,}'
    )

    local pattern
    for pattern in "${blocklist[@]}"; do
        if echo "$cmd" | grep -qiE "$pattern"; then
            log_warn "Blocked unsafe command: $cmd (matched: $pattern)"
            return 1
        fi
    done

    return 0
}

# Detect LLM API key from common locations if not set in config.
# Checks (in order): config/env value, ~/.hermes/.env OPENROUTER_API_KEY,
# ~/.hermes/.env OPENAI_API_KEY.
detect_llm_api_key() {
    if [[ -n "$LLM_API_KEY" ]]; then
        return 0
    fi

    local env_file="${HERMES_USER_HOME:-/root}/.hermes/.env"
    if [[ -f "$env_file" ]]; then
        # Try OPENROUTER_API_KEY first (matches default LLM_API_URL)
        local key
        key="$(grep -E '^OPENROUTER_API_KEY=' "$env_file" 2>/dev/null \
            | head -1 | cut -d= -f2- | tr -d '\"' | tr -d "'")" || true
        if [[ -n "$key" ]]; then
            LLM_API_KEY="$key"
            log_info "LLM API key detected from OPENROUTER_API_KEY in $env_file"
            return 0
        fi
        # Fall back to OPENAI_API_KEY
        key="$(grep -E '^OPENAI_API_KEY=' "$env_file" 2>/dev/null \
            | head -1 | cut -d= -f2- | tr -d '\"' | tr -d "'")" || true
        if [[ -n "$key" ]]; then
            LLM_API_KEY="$key"
            log_info "LLM API key detected from OPENAI_API_KEY in $env_file"
            return 0
        fi
    fi

    return 1
}

# Send the diagnostic report to an LLM and get remediation commands back.
# Writes suggested commands to stdout (one per line, prefixed with "CMD: ").
# Returns 0 on success, 1 on failure.
llm_get_remediation() {
    local report_content="$1"

    if ! detect_llm_api_key; then
        log_warn "LLM remediation skipped: no API key found (set LLM_API_KEY in config or OPENROUTER_API_KEY/OPENAI_API_KEY in ~/.hermes/.env)"
        add_warning "LLM Remediation" "No API key found — skipped"
        return 1
    fi

    local system_prompt
    system_prompt="You are a Linux SRE diagnostic assistant. You receive a system diagnostic report after an automatic update. Your job is to identify issues and suggest remediation commands. Rules:
1. Only suggest shell commands that fix the identified issues.
2. Each command must be on its own line, prefixed with 'CMD: '.
3. Every command must be a single, plain, non-interactive invocation that
   terminates on its own. No pipes, no ';', no '&&', no redirection, no
   command substitution, no backgrounding.
4. Commands are accepted only from this allowlist:
   systemctl restart|start|reload|reset-failed <unit>
   systemctl --user restart|start|reload|reset-failed <unit>
   systemctl daemon-reload
   docker restart|start <container>
   docker compose up -d
   docker image prune -f / docker system prune -f
   apt-get install -f -y / apt-get check / apt-get update / apt-get autoclean
   dpkg --configure -a
   journalctl --vacuum-size=<size> / journalctl --vacuum-time=<time>
   hermes gateway restart / hermes gateway status / hermes doctor
   needrestart -r a
   snap refresh
   Anything else is rejected automatically, so do not suggest it.
5. NEVER suggest a long-running or foreground command (hermes gateway run,
   hermes serve, tail -f, journalctl -f, watch, sleep). They hang the
   update service until systemd kills it. Use 'hermes gateway restart'.
6. Never suggest destructive commands (rm -rf, mkfs, dd, shutdown, reboot,
   apt remove/purge, systemctl disable/mask).
7. If no remediation is needed, output 'NO_REMEDIATION_NEEDED'.
8. Maximum 10 commands."

    local user_prompt
    user_prompt="Diagnostic report:\n\n${report_content}\n\nSuggest remediation commands:"

    # Build JSON payload using python3 for safe escaping
    local payload
    payload="$(python3 -c "
import json, sys
msg = {
    'model': sys.argv[1],
    'messages': [
        {'role': 'system', 'content': sys.argv[2]},
        {'role': 'user', 'content': sys.argv[3]}
    ],
    'temperature': 0.3,
    'max_tokens': 2000
}
print(json.dumps(msg))
" "$LLM_MODEL" "$system_prompt" "$user_prompt" 2>/dev/null)" || {
        log_error "Failed to build LLM API request payload"
        return 1
    }

    log_info "Requesting LLM remediation suggestions (model: $LLM_MODEL)..."

    local response_file
    response_file="$(mktemp)"

    local http_code
    http_code="$(curl -s -o "$response_file" -w '%{http_code}' \
        --max-time "$LLM_TIMEOUT" \
        -X POST "$LLM_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $LLM_API_KEY" \
        -d "$payload" 2>/dev/null || echo "000")"

    if [[ "$http_code" != "200" ]]; then
        log_error "LLM API returned HTTP $http_code"
        add_error "LLM Remediation" "API request failed (HTTP $http_code)"
        cat "$response_file" >> "$LOG_FILE" 2>/dev/null || true
        rm -f "$response_file"
        return 1
    fi

    # Extract the assistant's message content
    local llm_response
    llm_response="$(python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['choices'][0]['message']['content'])
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" < "$response_file" 2>>"$LOG_FILE")" || {
        log_error "Failed to parse LLM response"
        add_error "LLM Remediation" "Failed to parse API response"
        rm -f "$response_file"
        return 1
    }

    rm -f "$response_file"

    # Log the full LLM response
    log_info "LLM response:"
    echo "$llm_response" >> "$LOG_FILE"

    # Check if LLM says no remediation needed
    if echo "$llm_response" | grep -qi 'NO_REMEDIATION_NEEDED'; then
        log_info "LLM determined no remediation is needed"
        return 1
    fi

    # Extract CMD: lines
    local commands
    commands="$(echo "$llm_response" | grep '^CMD: ' | sed 's/^CMD: //' || true)"
    if [[ -z "$commands" ]]; then
        log_warn "LLM did not suggest any remediation commands"
        return 1
    fi

    echo "$commands"
    return 0
}

# Run the full diagnostic, then if issues are found, ask the LLM for
# remediation commands, safety-check each, execute safe ones, and
# re-run the diagnostic. Repeat up to LLM_MAX_REMEDIATION_ATTEMPTS times.
run_diagnostic_and_remediate() {
    if [[ "$DIAGNOSTIC_ENABLED" != "true" ]]; then
        log_info "Full diagnostic disabled, skipping"
        return 0
    fi

    local attempt=0
    local max_attempts="${LLM_MAX_REMEDIATION_ATTEMPTS:-3}"

    while (( attempt < max_attempts )); do
        attempt=$((attempt + 1))

        # Reset per-round classification counters
        DIAG_ACTIONABLE=0
        DIAG_ADVISORY=0

        # Run diagnostic
        if run_full_diagnostic; then
            log_info "Diagnostic passed — no issues found (attempt $attempt)"
            return 0
        fi

        # Issues found
        log_warn "Diagnostic found $DIAG_ACTIONABLE actionable / $DIAG_ADVISORY advisory finding(s) (attempt $attempt/$max_attempts)"

        # Advisory-only findings are reported but never auto-remediated:
        # a disk at 85% or journal noise is a human decision, and asking a
        # model to "fix" it produces churn, not repair.
        if [[ "$REMEDIATE_ON_ACTIONABLE_ONLY" == "true" ]] && (( DIAG_ACTIONABLE == 0 )); then
            log_info "Only advisory findings present — skipping LLM remediation"
            return 0
        fi

        if [[ "$LLM_REMEDIATION_ENABLED" != "true" ]]; then
            log_warn "LLM remediation is disabled — issues left unresolved"
            add_warning "Diagnostic" "Issues found but LLM remediation disabled"
            return 1
        fi

        if (( attempt == max_attempts )); then
            log_warn "Max remediation attempts reached ($max_attempts)"
            add_warning "Diagnostic" "Unresolved issues after $max_attempts remediation attempts"
            return 1
        fi

        # Read diagnostic report
        local report_content
        report_content="$(cat "$DIAGNOSTIC_REPORT" 2>/dev/null || true)"
        if [[ -z "$report_content" ]]; then
            log_error "Diagnostic report is empty"
            return 1
        fi

        # Ask LLM for remediation
        local remediation_cmds
        remediation_cmds="$(llm_get_remediation "$report_content")" || {
            log_warn "LLM remediation did not produce commands (attempt $attempt)"
            # If the LLM said no remediation needed, stop
            return 1
        }

        local cmd
        local executed=0
        local blocked=0

        while IFS= read -r cmd; do
            [[ -z "$cmd" ]] && continue
            # Strip leading/trailing whitespace
            cmd="$(echo "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [[ -z "$cmd" ]] && continue

            if ! is_command_safe "$cmd"; then
                blocked=$((blocked + 1))
                add_warning "LLM Remediation" "Blocked unsafe command: $cmd"
                continue
            fi

            # `hermes gateway restart` is allowlisted and bounded, but it
            # drains in-flight agent turns. Issued from inside an agent
            # session it deadlocks against this very process (see
            # restart_hermes_gateway). Route it through the guarded helper.
            if [[ "$cmd" == "hermes gateway restart" ]]; then
                if restart_hermes_gateway; then
                    executed=$((executed + 1))
                else
                    blocked=$((blocked + 1))
                fi
                continue
            fi

            log_info "Executing remediation command: $cmd"
            # No eval: commands are single plain invocations (metacharacters
            # are rejected by is_command_safe), so word-splitting via an
            # array is both sufficient and safer. A hard timeout guarantees
            # a misbehaving command cannot hang the systemd unit.
            local -a cmd_argv
            read -r -a cmd_argv <<<"$cmd"
            if timeout --signal=TERM --kill-after=15s \
                "$REMEDIATION_CMD_TIMEOUT" "${cmd_argv[@]}" >>"$LOG_FILE" 2>&1; then
                log_info "Remediation command succeeded: $cmd"
                executed=$((executed + 1))
            else
                local rc=$?
                if (( rc == 124 || rc == 137 )); then
                    log_warn "Remediation command timed out after ${REMEDIATION_CMD_TIMEOUT}s: $cmd"
                    add_warning "LLM Remediation" "Command timed out: $cmd"
                else
                    log_warn "Remediation command failed (exit $rc): $cmd"
                    add_warning "LLM Remediation" "Command failed: $cmd"
                fi
            fi
        done <<< "$remediation_cmds"

        log_info "Remediation round $attempt: $executed executed, $blocked blocked"

        if (( executed == 0 )); then
            log_warn "No safe remediation commands executed (attempt $attempt)"
            add_warning "LLM Remediation" "No safe commands to execute in round $attempt"
            return 1
        fi

        # Wait briefly for services to settle before re-diagnosing
        sleep 5
    done

    return 1
}

# ─── Reboot scheduling (deferred to end of run) ──────────────────────────────

schedule_reboot_if_required() {
    if [[ "$REBOOT_REQUIRED" != "true" ]]; then
        return 0
    fi

    if [[ "$AUTO_REBOOT" != "true" ]]; then
        add_warning "OS" "Reboot required; AUTO_REBOOT is disabled"
        return 0
    fi

    notify_telegram \
        "[${HOSTNAME_LABEL}] Reboot required; scheduled in ${REBOOT_DELAY} minutes."

    if ! shutdown -r "+${REBOOT_DELAY}" \
        "Automatic reboot after controlled system update"; then
        add_error "OS" "Failed to schedule reboot"
        return 1
    fi

    log_info "Reboot scheduled in ${REBOOT_DELAY} minutes"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    # Setup
    mkdir -p "$LOG_DIR"
    # Start fresh log file
    : > "$LOG_FILE"

    # Log rotation: delete old log files
    if [[ "${LOG_RETENTION_DAYS:-0}" -gt 0 ]]; then
        find "$LOG_DIR" -name "auto-update-*.log" -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
        log_info "Cleaned up log files older than ${LOG_RETENTION_DAYS} days"
    fi

    # Redirect all output to LOG_FILE (and create last-run.log as a symlink)
    ln -sfn "$(basename "$LOG_FILE")" "$LAST_LOG"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_info "========================================"
    log_info "Controlled System Update - $(date)"
    log_info "Host: $HOSTNAME_LABEL"
    log_info "Platform: ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME}) ${HOST_ARCH}/${DPKG_ARCH}, apt ${APT_MAJOR}.x, kernel $(uname -r)"
    log_info "========================================"

    if ! command -v apt-get &>/dev/null; then
        log_error "apt-get not found — this script supports Debian/Ubuntu only"
        notify_telegram "<b>[$HOSTNAME_LABEL] System Update ABORTED</b>\napt-get not found; Debian/Ubuntu required."
        exit 1
    fi

    acquire_lock

    # Run all update phases (each function handles its own errors via add_error/add_warning)
    update_os_packages
    update_snap_packages
    update_docker_images
    update_hermes_agent
    update_hermes_skills
    verify_required_hermes_skills || true
    update_python_packages
    update_npm_packages

    # Health checks
    run_health_checks

    # Full diagnostic + LLM auto-remediation
    run_diagnostic_and_remediate || true

    # Final assessment
    log_info "========================================"
    log_info "Update run completed at $(date)"
    log_info "========================================"

    # Build summary
    local has_errors=false
    local has_warnings=false

    if [[ -n "$ERRORS" ]]; then
        has_errors=true
    fi
    if [[ -n "$WARNINGS" ]]; then
        has_warnings=true
    fi

    # Schedule reboot only after all updates and health checks are done
    schedule_reboot_if_required

    local header
    header="\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    header+="\nPlatform: ${OS_ID} ${OS_VERSION_ID} ${DPKG_ARCH}"

    if $has_errors; then
        local message
        message="<b>[$HOSTNAME_LABEL] System Update FAILED</b>"
        message+="$header"
        message+="\n"
        message+="$ERRORS"
        if $has_warnings; then
            message+="\n<b>Warnings:</b>"
            message+="$WARNINGS"
        fi
        message+="\n\nLog: $LOG_FILE"
        log_error "Update completed with errors - sending Telegram notification"
        notify_telegram "$message"
        exit 1
    elif $has_warnings; then
        if [[ "$NOTIFY_LEVEL" == "error" ]]; then
            log_info "Update completed with warnings - suppressed (NOTIFY_LEVEL=error)"
            exit 0
        fi
        local message
        message="<b>[$HOSTNAME_LABEL] System Update Completed with Warnings</b>"
        message+="$header"
        message+="$WARNINGS"
        message+="\n\nLog: $LOG_FILE"
        log_warn "Update completed with warnings - sending Telegram notification"
        notify_telegram "$message"
        exit 0
    else
        if [[ "$NOTIFY_LEVEL" == "always" ]]; then
            notify_telegram "<b>[$HOSTNAME_LABEL] System Update OK</b>${header}\n\nNo issues found."
        fi
        log_info "Update completed successfully - no issues"
        exit 0
    fi
}


# Sourcing guard: `CSU_SOURCE_ONLY=1 source scripts/auto-update.sh` loads every
# function for unit testing without performing an update. Production paths are
# unaffected — the variable is never set by the systemd unit or the installer.
if [[ -z "${CSU_SOURCE_ONLY:-}" ]]; then
    main "$@"
fi
