#!/usr/bin/env bash
#
# controlled-system-update: Automatic system update script
# Updates: OS packages, Snap, Docker images, Hermes Agent, Python/npm globals
# Notifies Telegram ONLY on failure (silent on success)
#
# Part of: https://github.com/Green-Needle-Tech/controlled-system-update
# License: MIT
# Author: Liew Wei Sung (Green-Needle-Tech)
#
set -uo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

CONFIG_FILE="${CSU_CONFIG:-/etc/controlled-system-update/auto-update.conf}"

# Load config if it exists (re-export so functions and subshells can see them)
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "$CONFIG_FILE"
    set +a
fi

# Telegram settings (can be overridden in config or env)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
HOSTNAME_LABEL="${HOSTNAME_LABEL:-$(hostname -s)}"

# Paths (Hermes deployment profile)
HERMES_DIR="${HERMES_DIR:-/usr/local/lib/hermes-agent}"
HERMES_VENV="${HERMES_VENV:-${HERMES_DIR}/venv}"
UV_BIN="${UV_BIN:-${HOME}/.local/bin/uv}"
HERMES_CLI="${HERMES_CLI:-/usr/local/bin/hermes}"
HERMES_WEB_DIR="${HERMES_WEB_DIR:-${HERMES_DIR}/web}"

# Logging
LOG_DIR="${LOG_DIR:-/var/log/controlled-system-update}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/auto-update-$(date +%Y%m%d-%H%M%S).log}"
LAST_LOG="${LOG_DIR}/last-run.log"

# Package holds (space-separated list to exclude from upgrades)
PKG_HOLDS="${PKG_HOLDS:-}"

# Whether to reboot if required (auto-reboot)
AUTO_REBOOT="${AUTO_REBOOT:-true}"

# Delay (in minutes) before auto-reboot — gives time for notification and graceful shutdown
REBOOT_DELAY="${REBOOT_DELAY:-5}"

# Whether to run dist-upgrade (can remove packages — riskier than upgrade)
# Default: false for safety in automatic mode; set true for manual/maintenance runs
DIST_UPGRADE="${DIST_UPGRADE:-false}"

# Log retention: delete log files older than N days (0 = disable cleanup)
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# Whether to update Docker images
UPDATE_DOCKER="${UPDATE_DOCKER:-true}"

# Whether to update Hermes Agent
UPDATE_HERMES="${UPDATE_HERMES:-true}"

# Whether to update Snap packages
UPDATE_SNAP="${UPDATE_SNAP:-true}"

# Whether to update npm global packages
UPDATE_NPM="${UPDATE_NPM:-true}"

# Whether to update Python/uv packages
UPDATE_PYTHON="${UPDATE_PYTHON:-true}"

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
        local lock_pid
        lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo 'unknown')"
        log_error "Another update is already running (PID: ${lock_pid})"
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
        -o Dpkg::Options::="--force-confmiss" \
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
            -o Dpkg::Options::="--force-confmiss" \
            >> "$LOG_FILE" 2>&1; then
            add_error "OS" "apt-get dist-upgrade failed"
            log_error "apt-get dist-upgrade failed"
            return 1
        fi
    else
        log_info "Skipping dist-upgrade (DIST_UPGRADE=false) — use manual mode for dist-upgrade"
    fi

    log_info "Running apt-get autoremove..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >> "$LOG_FILE" 2>&1; then
        add_warning "OS" "apt-get autoremove had issues (non-fatal)"
        log_warn "apt-get autoremove had issues"
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

    # Check if reboot is required
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "System reboot is required"
        if [[ "$AUTO_REBOOT" == "true" ]]; then
            log_info "AUTO_REBOOT=true, scheduling reboot in ${REBOOT_DELAY} minutes..."
            add_warning "OS" "Reboot required — auto-reboot scheduled in ${REBOOT_DELAY} minutes"
            # Send immediate Telegram notification about pending reboot
            local reboot_msg
            reboot_msg="<b>[${HOSTNAME_LABEL}] Reboot Scheduled</b>"
            reboot_msg+="\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
            reboot_msg+="\n<b>[OS]</b> Reboot required after system update — auto-rebooting in ${REBOOT_DELAY} minutes."
            reboot_msg+="\nServices will restart automatically after reboot."
            notify_telegram "$reboot_msg"
            # Gracefully stop services before reboot
            log_info "Gracefully stopping Docker containers before reboot..."
            if command -v docker &>/dev/null; then
                docker stop "$(docker ps -q 2>/dev/null)" 2>/dev/null >> "$LOG_FILE" 2>&1 || true
            fi
            log_info "Gracefully stopping Hermes gateway before reboot..."
            local gw_pid
            gw_pid="$(pgrep -f 'hermes.*gateway run' 2>/dev/null || true)"
            if [[ -n "$gw_pid" ]]; then
                kill -TERM "$gw_pid" 2>/dev/null || true
                sleep 2
            fi
            shutdown -r "+${REBOOT_DELAY}" "Automatic reboot after system update" 2>/dev/null || true
        else
            add_warning "OS" "Reboot required but AUTO_REBOOT=false - manual reboot needed"
        fi
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

    while IFS='|' read -r name image; do
        # Skip images that are locally built (image IDs, local names without registry prefix)
        # Image IDs are 12-char hex strings; local images don't contain '/' or '.'
        if [[ "$image" =~ ^[a-f0-9]{12}$ ]]; then
            log_info "Skipping locally-built image (ID): $image (container: $name)"
            continue
        fi
        # Skip if image name has no '/' (not a registry reference)
        # e.g. "llm-smart-router:1.0" or "david-digital-hub-app" are local images
        # Strip tag suffix to check the repository part only
        local repo_part="${image%%:*}"
        if [[ "$repo_part" != *"/"* ]]; then
            log_info "Skipping local image (no registry): $image (container: $name)"
            continue
        fi
        log_info "Pulling image: $image (container: $name)"
        if docker pull "$image" >> "$LOG_FILE" 2>&1; then
            # Check if the pulled image is different from the running one
            local new_id old_id
            new_id="$(docker inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")"
            old_id="$(docker inspect --format '{{.Image}}' "$name" 2>/dev/null || echo "")"
            if [[ -n "$new_id" && -n "$old_id" && "$new_id" != "$old_id" ]]; then
                log_info "Image updated for $name, recreating container..."
                # Try to recreate using docker compose if a compose file exists
                local compose_dir=""
                compose_dir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2>/dev/null || echo "")"
                if [[ -n "$compose_dir" ]]; then
                    local compose_file=""
                    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
                        if [[ -f "${compose_dir}/${f}" ]]; then
                            compose_file="${compose_dir}/${f}"
                            break
                        fi
                    done
                    if [[ -n "$compose_file" ]]; then
                        log_info "Using docker compose at $compose_file"
                        if ! (cd "$compose_dir" && docker compose -f "$compose_file" up -d --force-recreate "$name" >> "$LOG_FILE" 2>&1); then
                            add_error "Docker" "Failed to recreate container $name via compose"
                            failed=$((failed + 1))
                        else
                            updated=$((updated + 1))
                        fi
                    else
                        # No compose file found — just note that a restart is needed
                        add_warning "Docker" "Image updated for $name but no compose file found - manual recreate needed"
                        log_warn "No compose file for $name, manual recreate needed"
                    fi
                fi
            fi
        else
            add_error "Docker" "Failed to pull image $image for container $name"
            log_error "Failed to pull $image"
            failed=$((failed + 1))
        fi
    done <<< "$containers"

    # Prune dangling images
    log_info "Pruning dangling images..."
    docker image prune -f >> "$LOG_FILE" 2>&1 || true

    log_info "Docker update complete: $updated updated, $failed failed"
}

update_hermes_agent() {
    log_info "=== Hermes Agent Update ==="
    if [[ ! -d "$HERMES_DIR/.git" ]]; then
        log_info "Hermes not installed as git clone at $HERMES_DIR, skipping"
        return 0
    fi
    if [[ "$UPDATE_HERMES" != "true" ]]; then
        log_info "Hermes updates disabled, skipping"
        return 0
    fi

    cd "$HERMES_DIR" || return 1

    # Record current commit
    local old_commit
    old_commit="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
    log_info "Current Hermes commit: $old_commit"

    # Stash local changes
    local stash_needed=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        stash_needed=true
        log_info "Stashing local changes..."
        if ! git stash push -m "auto-update-$(date +%Y%m%d-%H%M%S)" >> "$LOG_FILE" 2>&1; then
            add_error "Hermes" "Failed to git stash local changes"
            log_error "git stash failed"
            return 1
        fi
    fi

    # Pull upstream
    log_info "Pulling upstream changes..."
    if ! git pull origin main >> "$LOG_FILE" 2>&1; then
        add_error "Hermes" "git pull origin main failed"
        log_error "git pull failed"
        # Try to restore stashed changes
        if $stash_needed; then
            git stash pop >> "$LOG_FILE" 2>&1 || true
        fi
        return 1
    fi

    # Restore local changes
    if $stash_needed; then
        log_info "Restoring stashed changes..."
        if ! git stash pop >> "$LOG_FILE" 2>&1; then
            add_warning "Hermes" "git stash pop conflict - manual resolution needed"
            log_warn "git stash pop conflict"
        fi
    fi

    local new_commit
    new_commit="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
    log_info "New Hermes commit: $new_commit"

    if [[ "$old_commit" == "$new_commit" ]]; then
        log_info "Hermes already up to date"
        return 0
    fi

    log_info "Hermes updated: $old_commit -> $new_commit"

    # Rebuild venv if pyproject/lockfile changed
    if [[ -f "${HERMES_DIR}/pyproject.toml" ]]; then
        log_info "Rebuilding venv with uv..."
        if [[ -x "$UV_BIN" ]]; then
            if ! "$UV_BIN" sync >> "$LOG_FILE" 2>&1; then
                add_warning "Hermes" "uv sync had issues (non-fatal)"
                log_warn "uv sync had issues"
            fi
            if ! "$UV_BIN" pip install -e . >> "$LOG_FILE" 2>&1; then
                add_warning "Hermes" "uv pip install -e . had issues (non-fatal)"
                log_warn "uv pip install had issues"
            fi
        else
            add_warning "Hermes" "uv not found at $UV_BIN - venv not rebuilt"
        fi
    fi

    # Restart gateway
    log_info "Restarting Hermes gateway..."
    local gateway_pid
    gateway_pid="$(pgrep -f 'hermes.*gateway run' 2>/dev/null || true)"
    if [[ -n "$gateway_pid" ]]; then
        kill -TERM "$gateway_pid" 2>/dev/null || true
        sleep 3
    fi

    if [[ -x "$HERMES_CLI" ]]; then
        nohup "$HERMES_CLI" gateway run --replace >> "${HOME}/.hermes/logs/gateway-stdout.log" 2>&1 &
        sleep 5
        if pgrep -f 'hermes.*gateway run' >/dev/null 2>&1; then
            log_info "Gateway restarted successfully"
        else
            add_error "Hermes" "Gateway failed to restart after update"
            log_error "Gateway DOWN after restart"
        fi
    fi

    # Rebuild dashboard
    if [[ -d "$HERMES_WEB_DIR" ]]; then
        log_info "Rebuilding Hermes dashboard..."
        if (cd "$HERMES_WEB_DIR" && npm run build >> "$LOG_FILE" 2>&1); then
            if systemctl restart hermes-dashboard 2>/dev/null; then
                log_info "Dashboard rebuilt and restarted"
            else
                add_warning "Hermes" "Dashboard rebuilt but systemctl restart failed"
            fi
        else
            add_warning "Hermes" "Dashboard npm run build failed"
            log_warn "Dashboard build failed"
        fi
    fi
}

update_python_packages() {
    log_info "=== Python Package Update ==="
    if [[ "$UPDATE_PYTHON" != "true" ]]; then
        log_info "Python updates disabled, skipping"
        return 0
    fi
    if [[ ! -x "$UV_BIN" ]]; then
        log_info "uv not found, skipping Python package updates"
        return 0
    fi

    # Update uv-managed tools if any
    log_info "Updating uv-installed tools..."
    if "$UV_BIN" tool list --format json 2>/dev/null | grep -q '"name"'; then
        local tools
        tools="$("$UV_BIN" tool list --format json 2>/dev/null | python3 -c "
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
                "$UV_BIN" tool upgrade "$tool" >> "$LOG_FILE" 2>&1 || \
                    "$UV_BIN" tool install "$tool" >> "$LOG_FILE" 2>&1 || true
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

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    # Setup
    mkdir -p "$LOG_DIR"
    # Start fresh log file
    : > "$LOG_FILE"
    : > "$LAST_LOG"

    # Log rotation: delete old log files
    if [[ "${LOG_RETENTION_DAYS:-0}" -gt 0 ]]; then
        find "$LOG_DIR" -name "auto-update-*.log" -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
        log_info "Cleaned up log files older than ${LOG_RETENTION_DAYS} days"
    fi

    # Redirect all output to both LOG_FILE and LAST_LOG via tee
    exec > >(tee -a "$LOG_FILE" "$LAST_LOG") 2>&1

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
        # Warnings only — still notify so David is aware
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
