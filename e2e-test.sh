#!/usr/bin/env bash
#
# e2e-test.sh — End-to-end test for controlled-system-update v2.0.0
# Tests: file layout, config, systemd units, script execution, Telegram,
# lock file, logging, health checks, failure notification path
#
set -euo pipefail

PASS=0
FAIL=0
WARN=0
FAILURES=""

pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL + 1)); FAILURES+="\n  - $1"; }
warn() { echo "WARN  $1"; WARN=$((WARN + 1)); }

echo "=========================================="
echo "E2E Test: controlled-system-update v2.0.0"
echo "Host: $(hostname -s)"
echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=========================================="
echo ""

# ─── 1. File Layout ──────────────────────────────────────────────────────────

echo "--- 1. File Layout ---"

# Script installed
if [[ -x /usr/local/bin/auto-update.sh ]]; then
    pass "auto-update.sh installed and executable at /usr/local/bin/"
else
    fail "auto-update.sh missing or not executable"
fi

# Config installed
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

# GitHub repo files
echo ""
echo "--- 2. GitHub Repo File Structure ---"
REPO=/root/csu-repo
for f in SKILL.md README.md LICENSE install.sh scripts/auto-update.sh config/auto-update.conf systemd/controlled-system-update.service systemd/controlled-system-update.timer; do
    if [[ -f "$REPO/$f" ]]; then
        pass "Repo file exists: $f"
    else
        fail "Repo file missing: $f"
    fi
done

# SKILL.md version
skill_version=$(grep '^version:' "$REPO/SKILL.md" | sed 's/version: *//' | tr -d '"')
if [[ "$skill_version" == "2.0.0" ]]; then
    pass "SKILL.md version is 2.0.0"
else
    fail "SKILL.md version is '$skill_version' (expected 2.0.0)"
fi

# ─── 3. Config Content ───────────────────────────────────────────────────────

echo ""
echo "--- 3. Config Content ---"

source /etc/controlled-system-update/auto-update.conf

if [[ -n "$TG_BOT_TOKEN" && ${#TG_BOT_TOKEN} -gt 30 ]]; then
    pass "TG_BOT_TOKEN is set (length: ${#TG_BOT_TOKEN})"
else
    fail "TG_BOT_TOKEN is empty or too short"
fi

if [[ -n "$TG_CHAT_ID" ]]; then
    pass "TG_CHAT_ID is set: $TG_CHAT_ID"
else
    fail "TG_CHAT_ID is empty"
fi

for var in UPDATE_DOCKER UPDATE_HERMES UPDATE_SNAP UPDATE_NPM UPDATE_PYTHON; do
    val="${!var}"
    if [[ "$val" == "true" || "$val" == "false" ]]; then
        pass "$var = $val"
    else
        fail "$var = '$val' (expected true/false)"
    fi
done

if [[ -n "$HERMES_DIR" && -d "$HERMES_DIR" ]]; then
    pass "HERMES_DIR exists: $HERMES_DIR"
else
    fail "HERMES_DIR missing or dir doesn't exist: $HERMES_DIR"
fi

if [[ -n "$UV_BIN" && -x "$UV_BIN" ]]; then
    pass "UV_BIN exists and is executable: $UV_BIN"
else
    warn "UV_BIN not found: $UV_BIN (may not be installed yet)"
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

# ─── 5. Script Syntax & Shellcheck ───────────────────────────────────────────

echo ""
echo "--- 5. Script Syntax ---"

if bash -n /usr/local/bin/auto-update.sh 2>/dev/null; then
    pass "auto-update.sh passes bash syntax check"
else
    fail "auto-update.sh has syntax errors"
fi

if bash -n /root/csu-repo/install.sh 2>/dev/null; then
    pass "install.sh passes bash syntax check"
else
    fail "install.sh has syntax errors"
fi

# ─── 6. Telegram Notification (live test) ────────────────────────────────────

echo ""
echo "--- 6. Telegram Notification (live) ---"

TG_TOKEN="$TG_BOT_TOKEN"
TG_CHAT="$TG_CHAT_ID"

# Test 6a: Success message
test_msg="[E2E TEST] controlled-system-update v2.0.0 — test notification from $(hostname -s)"
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

# ─── 7. Lock File Mechanism ──────────────────────────────────────────────────

echo ""
echo "--- 7. Lock File Mechanism ---"

LOCK_FILE="/var/lock/controlled-system-update.lock"

# Clean any existing lock
rm -f "$LOCK_FILE" 2>/dev/null || true

# Create a fake lock and verify the script detects it
echo "99999" > "$LOCK_FILE"
# Run script — it should detect the lock and exit 1
# Output goes to log file, not stdout, so check exit code + log
lock_test_exit=0
timeout 5 /usr/local/bin/auto-update.sh >/dev/null 2>&1 || lock_test_exit=$?
# Check the most recent log for "already running"
latest_lock_log=$(ls -t /var/log/controlled-system-update/auto-update-*.log 2>/dev/null | head -1)
if [[ $lock_test_exit -ne 0 ]] && grep -q "already running" "$latest_lock_log" 2>/dev/null; then
    pass "Lock file detection works (script refused with active lock, exit=$lock_test_exit)"
else
    fail "Lock file detection failed (exit=$lock_test_exit, log=$latest_lock_log)"
fi

# Test stale lock cleanup (old timestamp)
# Set lock file modification time to 2 hours ago
touch -d "2 hours ago" "$LOCK_FILE"
stale_exit=0
timeout 10 /usr/local/bin/auto-update.sh >/dev/null 2>&1 || stale_exit=$?
stale_log=$(ls -t /var/log/controlled-system-update/auto-update-*.log 2>/dev/null | head -1)
if grep -q "Stale lock" "$stale_log" 2>/dev/null; then
    pass "Stale lock detection works (script removed stale lock and proceeded)"
else
    warn "Stale lock detection — could not confirm in log (exit=$stale_exit)"
fi

# Clean up
rm -f "$LOCK_FILE" 2>/dev/null || true

# ─── 8. Actual Update Run (real execution) ───────────────────────────────────

echo ""
echo "--- 8. Real Update Execution ---"

# Run the actual script — this will update OS, Docker, Hermes, etc.
# Capture exit code and output
echo "Running /usr/local/bin/auto-update.sh (this may take several minutes)..."
UPDATE_OUTPUT=$(timeout 600 /usr/local/bin/auto-update.sh 2>&1 || true)
UPDATE_EXIT=$?

# Check it produced a log file
latest_log=$(ls -t /var/log/controlled-system-update/auto-update-*.log 2>/dev/null | head -1)
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

# Check last-run.log exists
if [[ -f /var/log/controlled-system-update/last-run.log ]]; then
    pass "last-run.log exists"
    last_run_size=$(stat -c '%s' /var/log/controlled-system-update/last-run.log 2>/dev/null || echo 0)
    if (( last_run_size > 100 )); then
        pass "last-run.log has content (${last_run_size} bytes)"
    else
        fail "last-run.log is too small (${last_run_size} bytes)"
    fi
else
    fail "last-run.log missing"
fi

# Check the log contains expected phase markers
if [[ -n "$latest_log" ]]; then
    for phase in "OS Package Update" "Docker Image Update" "Hermes Agent Update" "Post-Update Health Checks"; do
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
    # Exit 1 means errors — check if Telegram was notified
    if echo "$UPDATE_OUTPUT" | grep -qi "sending Telegram notification"; then
        pass "Script exited 1 (errors) and sent Telegram notification"
    else
        warn "Script exited 1 but Telegram notification not confirmed in output"
    fi
else
    fail "Script exited with code $UPDATE_EXIT (expected 0 or 1)"
fi

# ─── 9. Post-Run Health Verification ─────────────────────────────────────────

echo ""
echo "--- 9. Post-Run Health Verification ---"

# Lock file should be cleaned up after run
if [[ ! -f "$LOCK_FILE" ]]; then
    pass "Lock file cleaned up after run"
else
    fail "Lock file still exists after run completion"
fi

# Hermes gateway should be running (if Hermes is installed)
if [[ -x /usr/local/bin/hermes ]]; then
    if pgrep -f 'hermes.*gateway run' >/dev/null 2>&1; then
        pass "Hermes gateway is running"
    else
        fail "Hermes gateway is not running after update"
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

# Send a simulated failure message to verify the notification format works
fail_msg="<b>[$(hostname -s)] E2E TEST: Simulated Failure</b>"
fail_msg+="\nTime: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
fail_msg+="\n<b>[OS]</b> Simulated apt-get upgrade failure (E2E test)"
fail_msg+="\n<b>[Docker]</b> Simulated image pull failure (E2E test)"
fail_msg+="\n\nLog: /var/log/controlled-system-update/e2e-test.log"

fail_http=$(curl -s -o /tmp/tg_fail_response.json -w '%{http_code}' \
    -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" \
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

# ─── 11. GitHub Repo Sync ────────────────────────────────────────────────────

echo ""
echo "--- 11. GitHub Repo Sync ---"

cd /root/csu-repo
local_commit=$(git rev-parse HEAD 2>/dev/null || echo "none")
remote_commit=$(git rev-parse origin/main 2>/dev/null || echo "none")

if [[ "$local_commit" == "$remote_commit" ]]; then
    pass "Local repo synced with origin/main ($local_commit)"
else
    fail "Local ($local_commit) != remote ($remote_commit)"
fi

# Verify the push actually landed
github_check=$(curl -s -o /dev/null -w '%{http_code}' \
    "https://api.github.com/repos/Green-Needle-Tech/controlled-system-update/commits/main" \
    2>/dev/null || echo "000")
if [[ "$github_check" == "200" ]]; then
    pass "GitHub API confirms repo is accessible"
else
    fail "GitHub API returned $github_check for repo check"
fi

# ─── 12. Local Skill Updated ─────────────────────────────────────────────────

echo ""
echo "--- 12. Local Skill Updated ---"

local_skill="/root/.hermes/skills/devops/controlled-system-update/SKILL.md"
if [[ -f "$local_skill" ]]; then
    local_skill_version=$(grep '^version:' "$local_skill" | sed 's/version: *//' | tr -d '"')
    if [[ "$local_skill_version" == "2.0.0" ]]; then
        pass "Local skill updated to v2.0.0"
    else
        fail "Local skill version is '$local_skill_version' (expected 2.0.0)"
    fi
else
    fail "Local skill file missing at $local_skill"
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
