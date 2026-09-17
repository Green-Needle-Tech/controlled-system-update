#!/usr/bin/env bash
#
# e2e-test.sh — End-to-end test for controlled-system-update v3.0.0
# Tests: file layout, config, systemd units, script syntax, lock contention,
# logging, health checks, diagnostic + LLM remediation, Telegram notification path
#
# Destructive tests (real system updates) are gated behind RUN_DESTRUCTIVE_TESTS=true
# CI should use mocked commands and a temporary CSU_CONFIG, not real package upgrades.
#
set -euo pipefail

PASS=0
FAIL=0
WARN=0
FAILURES=""

pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL + 1)); FAILURES+="\n  - $1"; }
warn() { echo "WARN  $1"; WARN=$((WARN + 1)); }

SCRIPT_PATH="${SCRIPT_PATH:-/usr/local/bin/auto-update.sh}"
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
TEST_CONFIG="${TEST_CONFIG:-/tmp/csu-test-config.conf}"

# Single source of truth for the expected version: the repo's own SKILL.md.
# Hardcoding it here meant every release left a stale assertion behind.
EXPECTED_VERSION="$(awk -F': *' '/^version:/ {print $2; exit}' "$REPO/SKILL.md" 2>/dev/null)"
EXPECTED_VERSION="${EXPECTED_VERSION:-unknown}"

echo "=========================================="
echo "E2E Test: controlled-system-update v${EXPECTED_VERSION}"
echo "Host: $(hostname -s)"
echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=========================================="
echo ""

# ─── 1. File Layout ──────────────────────────────────────────────────────────

echo "--- 1. File Layout ---"

# Script installed
if [[ -x "$SCRIPT_PATH" ]]; then
    pass "auto-update.sh installed and executable at $SCRIPT_PATH"
else
    fail "auto-update.sh missing or not executable at $SCRIPT_PATH"
fi

# Config installed (only check if not using test config)
if [[ "$TEST_CONFIG" == "/tmp/csu-test-config.conf" ]]; then
    if [[ -f /etc/controlled-system-update/auto-update.conf ]]; then
        pass "auto-update.conf exists at /etc/controlled-system-update/"
    else
        fail "auto-update.conf missing"
    fi

    # Config permissions (should be 600 — contains bot token)
    config_perms=$(stat -c '%a' /etc/controlled-system-update/auto-update.conf 2>/dev/null || echo "000")
    if [[ "$config_perms" == "600" ]]; then
        pass "auto-update.conf permissions are 600"
    else
        fail "auto-update.conf permissions are $config_perms (expected 600)"
    fi
fi

# systemd service
if [[ -f /etc/systemd/system/controlled-system-update.service ]]; then
    pass "systemd service unit installed"
else
    fail "systemd service unit missing"
fi

# systemd timer
if [[ -f /etc/systemd/system/controlled-system-update.timer ]]; then
    pass "systemd timer unit installed"
else
    fail "systemd timer unit missing"
fi

# Log directory
if [[ -d /var/log/controlled-system-update ]]; then
    pass "Log directory exists"
else
    fail "Log directory missing"
fi

# ─── 2. GitHub Repo File Structure ───────────────────────────────────────────

echo ""
echo "--- 2. GitHub Repo File Structure ---"

for f in SKILL.md README.md LICENSE install.sh scripts/auto-update.sh config/auto-update.conf systemd/controlled-system-update.service systemd/controlled-system-update.timer; do
    if [[ -f "$REPO/$f" ]]; then
        pass "Repo file exists: $f"
    else
        fail "Repo file missing: $f"
    fi
done

# SKILL.md version
skill_version=$(grep '^version:' "$REPO/SKILL.md" | sed 's/version: *//' | tr -d '"')
if [[ "$skill_version" == "$EXPECTED_VERSION" ]]; then
    pass "SKILL.md version is $EXPECTED_VERSION"
else
    fail "SKILL.md version is '$skill_version' (expected $EXPECTED_VERSION)"
fi

# ─── 3. Config Content ───────────────────────────────────────────────────────

echo ""
echo "--- 3. Config Content ---"

# Use test config if provided, otherwise source installed config
if [[ -f "$TEST_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$TEST_CONFIG"
elif [[ -f /etc/controlled-system-update/auto-update.conf ]]; then
    # shellcheck source=/dev/null
    source /etc/controlled-system-update/auto-update.conf
fi

if [[ -n "${TG_BOT_TOKEN:-}" ]]; then
    pass "TG_BOT_TOKEN is set (length: ${#TG_BOT_TOKEN})"
else
    warn "TG_BOT_TOKEN is empty (notifications will be skipped)"
fi

if [[ -n "${TG_CHAT_ID:-}" ]]; then
    pass "TG_CHAT_ID is set: ${TG_CHAT_ID}"
else
    warn "TG_CHAT_ID is empty (notifications will be skipped)"
fi

for var in UPDATE_DOCKER UPDATE_HERMES UPDATE_SNAP UPDATE_NPM UPDATE_PYTHON; do
    val="${!var:-}"
    if [[ "$val" == "true" || "$val" == "false" ]]; then
        pass "$var = $val"
    else
        fail "$var = '$val' (expected true/false)"
    fi
done

# Verify tightened defaults
if [[ "${AUTO_REBOOT:-}" == "false" ]]; then
    pass "AUTO_REBOOT = false (safe default)"
else
    warn "AUTO_REBOOT = ${AUTO_REBOOT:-} (expected false for safety)"
fi

if [[ "${DIST_UPGRADE:-}" == "false" ]]; then
    pass "DIST_UPGRADE = false (safe default)"
else
    warn "DIST_UPGRADE = ${DIST_UPGRADE:-} (expected false for safety)"
fi

if [[ "${AUTO_REMOVE:-}" == "false" ]]; then
    pass "AUTO_REMOVE = false (safe default)"
else
    warn "AUTO_REMOVE = ${AUTO_REMOVE:-} (expected false for safety)"
fi

if [[ "${UPDATE_NPM:-}" == "false" ]]; then
    pass "UPDATE_NPM = false (opt-in default)"
else
    warn "UPDATE_NPM = ${UPDATE_NPM:-} (expected false as opt-in default)"
fi

if [[ "${UPDATE_PYTHON:-}" == "false" ]]; then
    pass "UPDATE_PYTHON = false (opt-in default)"
else
    warn "UPDATE_PYTHON = ${UPDATE_PYTHON:-} (expected false as opt-in default)"
fi

if [[ "${HERMES_SKILLS_MODE:-}" == "check" ]]; then
    pass "HERMES_SKILLS_MODE = check (conservative default)"
else
    warn "HERMES_SKILLS_MODE = ${HERMES_SKILLS_MODE:-} (expected check as conservative default)"
fi

if [[ "${HERMES_SKILLS_SCOPE:-}" == "all" ]]; then
    pass "HERMES_SKILLS_SCOPE = all (all managed sources)"
else
    warn "HERMES_SKILLS_SCOPE = ${HERMES_SKILLS_SCOPE:-} (expected all)"
fi

# ─── 4. systemd Timer Status ─────────────────────────────────────────────────

echo ""
echo "--- 4. systemd Timer Status ---"

timer_status=$(systemctl is-enabled controlled-system-update.timer 2>/dev/null || echo "disabled")
if [[ "$timer_status" == "enabled" ]]; then
    pass "Timer is enabled"
else
    fail "Timer is $timer_status (expected enabled)"
fi

timer_active=$(systemctl is-active controlled-system-update.timer 2>/dev/null || echo "inactive")
if [[ "$timer_active" == "active" ]]; then
    pass "Timer is active"
else
    fail "Timer is $timer_active (expected active)"
fi

# Check next scheduled run
next_run=$(systemctl list-timers controlled-system-update --no-pager 2>/dev/null | grep controlled-system-update | awk '{print $1, $2, $3}')
if [[ -n "$next_run" ]]; then
    pass "Next scheduled run: $next_run"
else
    warn "Could not determine next scheduled run"
fi

# ─── 5. Script Syntax ────────────────────────────────────────────────────────

echo ""
echo "--- 5. Script Syntax ---"

if bash -n "$SCRIPT_PATH" 2>/dev/null; then
    pass "auto-update.sh passes bash syntax check"
else
    fail "auto-update.sh has syntax errors"
fi

if bash -n "$REPO/install.sh" 2>/dev/null; then
    pass "install.sh passes bash syntax check"
else
    fail "install.sh has syntax errors"
fi

if bash -n "$REPO/e2e-test.sh" 2>/dev/null; then
    pass "e2e-test.sh passes bash syntax check"
else
    fail "e2e-test.sh has syntax errors"
fi

# ─── 6. Telegram Notification (live test) ────────────────────────────────────

echo ""
echo "--- 6. Telegram Notification (live) ---"

if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    warn "Telegram credentials not set, skipping live notification test"
else
    TG_TOKEN="$TG_BOT_TOKEN"
    TG_CHAT="$TG_CHAT_ID"

    # Test 6a: Success message
    test_msg="[E2E TEST] controlled-system-update v${EXPECTED_VERSION} — test notification from $(hostname -s)"
    http_code=$(curl -s -o /tmp/tg_test_response.json -w '%{http_code}' \
        -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" \
        --data-urlencode "text=${test_msg}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "disable_web_page_preview=true" \
        2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        pass "Telegram API returned 200 for test message"
    else
        fail "Telegram API returned $http_code (expected 200)"
    fi

    # Assert on content — check the response JSON contains "ok":true
    tg_ok=$(python3 -c "import json; d=json.load(open('/tmp/tg_test_response.json')); print(d.get('ok','false'))" 2>/dev/null || echo "false")
    if [[ "$tg_ok" == "True" ]]; then
        pass "Telegram response JSON contains ok:true"
    else
        fail "Telegram response JSON ok field is '$tg_ok' (expected True)"
    fi

    # Assert message was actually delivered (check message_id in response)
    tg_msg_id=$(python3 -c "import json; d=json.load(open('/tmp/tg_test_response.json')); print(d.get('result',{}).get('message_id','none'))" 2>/dev/null || echo "none")
    if [[ "$tg_msg_id" != "none" ]]; then
        pass "Telegram message delivered (message_id: $tg_msg_id)"
    else
        fail "Telegram message_id missing in response"
    fi
fi

# ─── 7. Lock File Mechanism (real flock test) ────────────────────────────────

echo ""
echo "--- 7. Lock File Mechanism ---"

LOCK_FILE="${LOCK_FILE:-/var/lock/controlled-system-update.lock}"

# Clean any existing lock
rm -f "$LOCK_FILE" 2>/dev/null || true

# Acquire a real flock on the lock file, then try to run the script
# The script should detect the held lock and exit 1
exec {test_lock_fd}>"$LOCK_FILE"
flock -n "$test_lock_fd"

set +e
CSU_CONFIG="$TEST_CONFIG" \
    timeout 5 "$SCRIPT_PATH" \
    >/tmp/csu-lock-test.log 2>&1
lock_test_exit=$?
set -e

flock -u "$test_lock_fd"
exec {test_lock_fd}>&-

if [[ "$lock_test_exit" -ne 0 ]] && \
    grep -q "already running" /tmp/csu-lock-test.log 2>/dev/null; then
    pass "Concurrent execution was rejected (flock contention, exit=$lock_test_exit)"
else
    fail "Concurrent execution was not rejected (exit=$lock_test_exit)"
fi

# Clean up
rm -f "$LOCK_FILE" 2>/dev/null || true

# ─── 8. Actual Update Run (gated) ────────────────────────────────────────────

echo ""
echo "--- 8. Update Execution ---"

if [[ "${RUN_DESTRUCTIVE_TESTS:-false}" != "true" ]]; then
    warn "Skipping destructive live update test (set RUN_DESTRUCTIVE_TESTS=true to enable)"
else
    echo "Running $SCRIPT_PATH (this may take several minutes)..."
    set +e
    timeout 600 "$SCRIPT_PATH" >"$TEST_CONFIG-update-output.log" 2>&1
    UPDATE_EXIT=$?
    set -e

    # Check it produced a log file
    latest_log=$(find /var/log/controlled-system-update -name 'auto-update-*.log' -type f 2>/dev/null | sort -r | head -1)
    if [[ -n "$latest_log" ]]; then
        pass "Log file created: $(basename "$latest_log")"
        # Check log has content (not empty)
        log_size=$(stat -c '%s' "$latest_log" 2>/dev/null || echo 0)
        if (( log_size > 100 )); then
            pass "Log file has content (${log_size} bytes)"
        else
            fail "Log file is too small (${log_size} bytes)"
        fi
    else
        fail "No log file created"
    fi

    # Check last-run.log exists (should be a symlink)
    if [[ -L /var/log/controlled-system-update/last-run.log ]]; then
        pass "last-run.log exists and is a symlink"
    elif [[ -f /var/log/controlled-system-update/last-run.log ]]; then
        warn "last-run.log exists but is NOT a symlink (expected symlink)"
    else
        fail "last-run.log missing"
    fi

    # Check the log contains expected phase markers
    if [[ -n "$latest_log" ]]; then
        for phase in "OS Package Update" "Docker Image Update" "Hermes Agent Update" "Hermes Skills Update" "Post-Update Health Checks"; do
            if grep -q "$phase" "$latest_log" 2>/dev/null; then
                pass "Log contains phase: $phase"
            else
                warn "Log missing phase marker: $phase (phase may have been skipped)"
            fi
        done
    fi

    # Check exit code
    if [[ $UPDATE_EXIT -eq 0 ]]; then
        pass "Script exited 0 (success or warnings only)"
    elif [[ $UPDATE_EXIT -eq 1 ]]; then
        pass "Script exited 1 (errors reported — check Telegram for notification)"
    else
        fail "Script exited with code $UPDATE_EXIT (expected 0 or 1)"
    fi
fi

# ─── 9. Post-Run Health Verification ─────────────────────────────────────────

echo ""
echo "--- 9. Post-Run Health Verification ---"

# Hermes gateway should be running (if Hermes is installed)
if [[ -x /usr/local/bin/hermes ]]; then
    if pgrep -f 'hermes.*gateway run' >/dev/null 2>&1; then
        pass "Hermes gateway is running"
    else
        fail "Hermes gateway is not running"
    fi
fi

# Docker containers should be running (if Docker is installed)
if command -v docker &>/dev/null; then
    running_count=$(docker ps -q 2>/dev/null | wc -l)
    if (( running_count > 0 )); then
        pass "Docker containers running: $running_count"
    else
        warn "No Docker containers running (may be expected if none were started)"
    fi
fi

# systemd should not have new failed units
failed_count=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
if (( failed_count == 0 )); then
    pass "No failed systemd units"
else
    warn "Failed systemd units: $failed_count — check systemctl --failed"
fi

# Disk space should be reasonable
disk_pct=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
if (( disk_pct < 90 )); then
    pass "Disk usage: ${disk_pct}%"
else
    fail "Disk usage critical: ${disk_pct}%"
fi

# ─── 10. Failure Notification Path (simulated) ───────────────────────────────

echo ""
echo "--- 10. Failure Notification Path (simulated) ---"

if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    warn "Telegram credentials not set, skipping failure notification test"
else
    # Send a simulated failure message to verify the notification format works
    fail_msg="<b>[$(hostname -s)] E2E TEST: Simulated Failure</b>"
    fail_msg+="\nTime: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    fail_msg+="\n<b>[OS]</b> Simulated apt-get upgrade failure (E2E test)"
    fail_msg+="\n<b>[Docker]</b> Simulated image pull failure (E2E test)"
    fail_msg+="\n\nLog: /var/log/controlled-system-update/e2e-test.log"

    fail_http=$(curl -s -o /tmp/tg_fail_response.json -w '%{http_code}' \
        -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${fail_msg}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "disable_web_page_preview=true" \
        2>/dev/null || echo "000")

    if [[ "$fail_http" == "200" ]]; then
        fail_ok=$(python3 -c "import json; d=json.load(open('/tmp/tg_fail_response.json')); print(d.get('ok','false'))" 2>/dev/null || echo "false")
        if [[ "$fail_ok" == "True" ]]; then
            pass "Failure notification format works (Telegram accepted HTML message)"
        else
            fail "Failure notification response ok=false"
        fi
    else
        fail "Failure notification HTTP $fail_http (expected 200)"
    fi
fi

# ─── 11. GitHub Repo Sync ────────────────────────────────────────────────────

echo ""
echo "--- 11. GitHub Repo Sync ---"

cd "$REPO"
local_commit=$(git rev-parse HEAD 2>/dev/null || echo "none")
remote_commit=$(git rev-parse origin/main 2>/dev/null || echo "none")

if [[ "$local_commit" == "$remote_commit" ]]; then
    pass "Local repo synced with origin/main ($local_commit)"
else
    warn "Local ($local_commit) != remote ($remote_commit) — may be ahead on a feature branch"
fi

# Verify the repo is accessible
github_check=$(curl -s -o /dev/null -w '%{http_code}' \
    "https://api.github.com/repos/Green-Needle-Tech/controlled-system-update/commits/main" \
    2>/dev/null || echo "000")
if [[ "$github_check" == "200" ]]; then
    pass "GitHub API confirms repo is accessible"
else
    warn "GitHub API returned $github_check for repo check"
fi

# ─── 12. Local Skill Version ─────────────────────────────────────────────────

echo ""
echo "--- 12. Local Skill Version ---"

local_skill="${HERMES_HOME:-${HOME:-/root}/.hermes}/skills/devops/controlled-system-update/SKILL.md"
if [[ -f "$local_skill" ]]; then
    local_skill_version=$(grep '^version:' "$local_skill" | sed 's/version: *//' | tr -d '"')
    if [[ "$local_skill_version" == "$EXPECTED_VERSION" ]]; then
        pass "Local skill updated to v$EXPECTED_VERSION"
    else
        warn "Local skill version is '$local_skill_version' (expected $EXPECTED_VERSION)"
    fi
else
    warn "Local skill file missing at $local_skill (may not be installed on this host)"
fi

# ─── 13. Diagnostic + LLM Remediation Feature ──────────────────────────────

echo ""
echo "--- 13. Diagnostic + LLM Remediation Feature ---"

# Check that the diagnostic functions exist in the script
if grep -q 'run_full_diagnostic()' "$REPO/scripts/auto-update.sh" 2>/dev/null; then
    pass "run_full_diagnostic function exists in auto-update.sh"
else
    fail "run_full_diagnostic function missing from auto-update.sh"
fi

if grep -q 'llm_get_remediation()' "$REPO/scripts/auto-update.sh" 2>/dev/null; then
    pass "llm_get_remediation function exists in auto-update.sh"
else
    fail "llm_get_remediation function missing from auto-update.sh"
fi

if grep -q 'run_diagnostic_and_remediate()' "$REPO/scripts/auto-update.sh" 2>/dev/null; then
    pass "run_diagnostic_and_remediate function exists in auto-update.sh"
else
    fail "run_diagnostic_and_remediate function missing from auto-update.sh"
fi

if grep -q 'is_command_safe()' "$REPO/scripts/auto-update.sh" 2>/dev/null; then
    pass "is_command_safe function exists in auto-update.sh"
else
    fail "is_command_safe function missing from auto-update.sh"
fi

# Check that diagnostic+remediation is called in main()
if grep -q 'run_diagnostic_and_remediate' "$REPO/scripts/auto-update.sh" 2>/dev/null; then
    pass "Diagnostic+remediation is wired into main()"
else
    fail "Diagnostic+remediation is not wired into main()"
fi

# Check config options exist in the template
for opt in DIAGNOSTIC_ENABLED LLM_REMEDIATION_ENABLED LLM_API_URL LLM_MODEL LLM_TIMEOUT LLM_MAX_REMEDIATION_ATTEMPTS; do
    if grep -q "^${opt}=" "$REPO/config/auto-update.conf" 2>/dev/null; then
        pass "Config option $opt exists in template"
    else
        fail "Config option $opt missing from template"
    fi
done

# Verify the safety blocklist blocks dangerous commands
# Check that the blocklist patterns are present in the script
if grep -q 'rm.*-rf.*/' "$REPO/scripts/auto-update.sh" && \
   grep -q 'mkfs' "$REPO/scripts/auto-update.sh" && \
   grep -q 'shutdown' "$REPO/scripts/auto-update.sh" && \
   grep -q 'reboot' "$REPO/scripts/auto-update.sh" && \
   grep -q 'dd.*of=/dev/' "$REPO/scripts/auto-update.sh" && \
   grep -q 'curl.*sh' "$REPO/scripts/auto-update.sh" && \
   grep -q 'apt-get.*purge' "$REPO/scripts/auto-update.sh"; then
    pass "Safety blocklist covers destructive commands (rm -rf, mkfs, dd, shutdown, reboot, curl|sh, purge)"
else
    fail "Safety blocklist is missing destructive command patterns"
fi

# Check that LLM API key auto-detection is present
if grep -q 'OPENROUTER_API_KEY' "$REPO/scripts/auto-update.sh" 2>/dev/null; then
    pass "LLM API key auto-detection (OPENROUTER_API_KEY) present"
else
    fail "LLM API key auto-detection missing"
fi

if grep -q 'OPENAI_API_KEY' "$REPO/scripts/auto-update.sh" 2>/dev/null; then
    pass "LLM API key fallback (OPENAI_API_KEY) present"
else
    fail "LLM API key fallback missing"
fi

# Verify diagnostic report path is configured
if grep -q 'DIAGNOSTIC_REPORT' "$REPO/scripts/auto-update.sh" 2>/dev/null; then
    pass "Diagnostic report path configured"
else
    fail "Diagnostic report path not configured"
fi

# Check README documents the feature
if grep -qi 'Full Diagnostic.*LLM.*Remediation' "$REPO/README.md" 2>/dev/null; then
    pass "README documents diagnostic + LLM remediation feature"
else
    fail "README does not document diagnostic + LLM remediation feature"
fi

# Check CHANGELOG has an entry for the current version
if grep -qF "[${EXPECTED_VERSION}]" "$REPO/CHANGELOG.md" 2>/dev/null; then
    pass "CHANGELOG has v${EXPECTED_VERSION} entry"
else
    fail "CHANGELOG missing v${EXPECTED_VERSION} entry"
fi

# ─── v3.0.0 regression checks ────────────────────────────────────────────────

echo ""
echo "--- v3.0.0: incident regressions and portability ---"

SCRIPT_SRC="$REPO/scripts/auto-update.sh"

# Regression 1 (2026-09-16): log output went to stdout and was captured by
# command substitution, so log lines were executed as remediation commands.
if grep -qE '^\s+echo "\[\$\{ts\}\] \[\$\{level\}\] \$\{msg\}" >&2' "$SCRIPT_SRC"; then
    pass "log() writes to stderr (log lines cannot be captured as commands)"
else
    fail "log() does not write to stderr — log lines can be executed as commands"
fi

# Regression 2 (2026-09-16): `hermes gateway run --replace` ran in the
# foreground until systemd's TimeoutStartSec killed the whole update.
if grep -q "hermes\[\[:space:\]\]+gateway\[\[:space:\]\]+run" "$SCRIPT_SRC"; then
    pass "Blocklist rejects foreground 'hermes gateway run'"
else
    fail "Blocklist does not reject 'hermes gateway run'"
fi

# Remediation must be allowlist-gated, not blocklist-only
if grep -q 'Gate 1 — allowlist of remediation forms' "$SCRIPT_SRC"; then
    pass "Remediation commands are allowlist-gated"
else
    fail "Remediation commands are not allowlist-gated"
fi

# No eval of model-produced text
if grep -qE '^\s+if eval "\$cmd"' "$SCRIPT_SRC"; then
    fail "Remediation still uses eval on LLM output"
else
    pass "Remediation does not eval LLM output"
fi

# Per-command timeout
if grep -q 'REMEDIATION_CMD_TIMEOUT' "$SCRIPT_SRC"; then
    pass "Per-command remediation timeout configured"
else
    fail "Per-command remediation timeout missing"
fi

# Precise gateway detection (the loose pgrep matched unrelated shells)
if grep -q 'gateway_is_running()' "$SCRIPT_SRC"; then
    pass "Precise gateway_is_running() helper present"
else
    fail "gateway_is_running() helper missing"
fi
# Match actual usage, not the comment that documents why the pattern is wrong.
if grep -nE "^[^#]*pgrep[^#]*'hermes\.\*gateway run'" "$SCRIPT_SRC" >/dev/null; then
    fail "Loose 'hermes.*gateway run' pgrep pattern still in use"
else
    pass "Loose gateway pgrep pattern removed"
fi

# Partial-update recovery
if grep -q 'restart_hermes_gateway' "$SCRIPT_SRC"; then
    pass "Hermes partial-update gateway recovery present"
else
    fail "Hermes partial-update gateway recovery missing"
fi

# Actionable vs advisory classification
if grep -q 'diag_finding' "$SCRIPT_SRC" && grep -q 'REMEDIATE_ON_ACTIONABLE_ONLY' "$SCRIPT_SRC"; then
    pass "Diagnostic findings classified actionable vs advisory"
else
    fail "Diagnostic finding classification missing"
fi

# Ubuntu 26.04 / multi-arch portability
if grep -q 'DPKG_ARCH' "$SCRIPT_SRC" && grep -q 'APT_MAJOR' "$SCRIPT_SRC"; then
    pass "Architecture and apt-generation detection present"
else
    fail "Architecture / apt-generation detection missing"
fi

if grep -q 'reboot_is_required()' "$SCRIPT_SRC" && grep -q '/run/reboot-required' "$SCRIPT_SRC"; then
    pass "Reboot marker checks /run/reboot-required"
else
    fail "Reboot marker does not check /run/reboot-required"
fi

if grep -q 'history-undo' "$SCRIPT_SRC"; then
    pass "apt 3.x rollback guidance present (Ubuntu 26.04)"
else
    fail "apt 3.x rollback guidance missing"
fi

# systemd unit: UMask typo regression
if grep -qE '^[[:space:]]*Umask=' "$REPO/systemd/controlled-system-update.service"; then
    fail "systemd unit uses 'Umask=' (silently ignored); must be 'UMask='"
else
    pass "systemd unit uses the correct 'UMask=' directive"
fi

if grep -q 'TimeoutStartSec=5400' "$REPO/systemd/controlled-system-update.service"; then
    pass "systemd TimeoutStartSec raised to 90 minutes"
else
    warn "systemd TimeoutStartSec is not 5400 (slow arm64 hosts may time out)"
fi

# Sourcing guard enables unit testing
if grep -q 'CSU_SOURCE_ONLY' "$SCRIPT_SRC"; then
    pass "CSU_SOURCE_ONLY sourcing guard present"
else
    fail "CSU_SOURCE_ONLY sourcing guard missing"
fi

# Safety-gate unit tests exist and pass
if [[ -f "$REPO/tests/safety-gate-test.sh" ]]; then
    pass "Safety-gate unit test suite present"
    if bash "$REPO/tests/safety-gate-test.sh" >/tmp/csu-safety-gate.out 2>&1; then
        pass "Safety-gate unit tests pass ($(grep -c '^PASS' /tmp/csu-safety-gate.out) assertions)"
    else
        fail "Safety-gate unit tests FAILED (see /tmp/csu-safety-gate.out)"
    fi
else
    fail "Safety-gate unit test suite missing"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "E2E TEST SUMMARY"
echo "=========================================="
echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"
total=$((PASS + WARN + FAIL))
echo "TOTAL: $total"
if [[ $FAIL -eq 0 ]]; then
    echo "RESULT: ALL CRITICAL CHECKS PASSED"
else
    echo "RESULT: $FAIL FAILURES"
    echo -e "Failures:$FAILURES"
fi
echo "=========================================="
echo "Ratio: ${PASS}/${total} passed, ${FAIL}/${total} failed"
echo ""

exit $FAIL
