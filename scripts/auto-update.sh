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

# Paths (Hermes deployment profile)
# Hermes may be installed for root or for a regular user (e.g. /home/ubuntu).
# All three paths are auto-detected at runtime; any value set in the config
# file or environment takes precedence over detection.
#
# Detection order:
#   HERMES_CLI:       config/env -> `hermes` on PATH -> common install locations
#   HERMES_USER_HOME: config/env -> user owning the running gateway process
#                     -> user owning the CLI binary -> /root
#   HERMES_HOME:      config/env -> ${HERMES_USER_HOME}/.hermes
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

# ─── Helpers ─────────────────────────────────────────────────────────────────

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] ${msg}"
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

    log_info "Running apt-get upgrade..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        >> "$LOG_FILE" 2>&1; then
        add_error "OS" "apt-get upgrade failed"
        log_error "apt-get upgrade failed"
        return 1
    fi

    if [[ "$DIST_UPGRADE" == "true" ]]; then
        log_info "Running apt-get dist-upgrade (DIST_UPGRADE=true)..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
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
    if [[ -f /var/run/reboot-required ]]; then
        REBOOT_REQUIRED=true
        log_warn "System reboot is required"
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
        log_info "Pulling image: $image (container: $name)"
        if docker pull "$image" >> "$LOG_FILE" 2>&1; then
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
    env \
        HOME="$HERMES_USER_HOME" \
        HERMES_HOME="$HERMES_HOME" \
        "$HERMES_CLI" "$@"
}

run_hermes_with_timeout() {
    timeout \
        --signal=TERM \
        --kill-after=30s \
        "$HERMES_SKILLS_TIMEOUT" \
        env \
        HOME="$HERMES_USER_HOME" \
        HERMES_HOME="$HERMES_HOME" \
        "$HERMES_CLI" "$@"
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

    log_info "Running supported Hermes updater..."
    if ! timeout \
        --signal=TERM \
        --kill-after=30s \
        "$HERMES_UPDATE_TIMEOUT" \
        env HOME="$HERMES_USER_HOME" HERMES_HOME="$HERMES_HOME" \
        "$HERMES_CLI" update --yes >>"$LOG_FILE" 2>&1; then
        add_error "Hermes" "hermes update failed or timed out"
        log_error "Hermes update failed"
        return 1
    fi

    new_version="$(run_hermes --version 2>/dev/null || printf 'unknown')"
    log_info "Hermes version after update: $new_version"

    if ! run_hermes doctor >>"$LOG_FILE" 2>&1; then
        add_warning "Hermes" "hermes doctor reported problems after update"
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

    # Update uv-managed tools if any
    log_info "Updating uv-installed tools..."
    if "$uv_bin" tool list --format json 2>/dev/null | grep -q '"name"'; then
        local tools
        tools="$("$uv_bin" tool list --format json 2>/dev/null | python3 -c "
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
                "$uv_bin" tool upgrade "$tool" >> "$LOG_FILE" 2>&1 || \
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
        if ! pgrep -f 'hermes.*gateway run' >/dev/null 2>&1; then
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
    log_info "========================================"

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

    if $has_errors; then
        local message
        message="<b>[$HOSTNAME_LABEL] System Update FAILED</b>"
        message+="\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
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
        # Warnings only — still notify so user is aware
        local message
        message="<b>[$HOSTNAME_LABEL] System Update Completed with Warnings</b>"
        message+="\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        message+="$WARNINGS"
        message+="\n\nLog: $LOG_FILE"
        log_warn "Update completed with warnings - sending Telegram notification"
        notify_telegram "$message"
        exit 0
    else
        log_info "Update completed successfully - no notification sent (silent on success)"
        exit 0
    fi
}

main "$@"
