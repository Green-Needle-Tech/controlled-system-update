#!/usr/bin/env bash
#
# gateway-guard-test.sh — Unit tests for the gateway restart deadlock guard
#
# Sources auto-update.sh in a sandboxed mode (CSU_SOURCE_ONLY=1 prevents
# main() from running) and asserts that restart_hermes_gateway() bails
# immediately when called from inside a Hermes agent session, instead of
# deadlocking against the in-flight turn.
#
# Usage: bash tests/gateway-guard-test.sh
# License: MIT
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
FAILURES=""

# Source the script without executing main()
export CSU_SOURCE_ONLY=1
export CSU_CONFIG=/nonexistent
export LOG_DIR=/tmp
# shellcheck source=/dev/null
source "${REPO}/scripts/auto-update.sh"

echo "=== gateway restart deadlock guard ==="

# `hermes gateway restart` drains in-flight agent turns. Called from inside an
# agent session it waits for the very process that called it. The guard must
# bail immediately rather than hang until an outer timeout fires.
(
    export HERMES_AGENT=true
    start=$(date +%s)
    restart_hermes_gateway >/dev/null 2>&1
    rc=$?
    end=$(date +%s)
    elapsed=$((end - start))
    if (( rc != 0 && elapsed < 10 )); then
        echo "PASS  guard returns immediately inside an agent session (rc=$rc, ${elapsed}s)"
        exit 0
    fi
    echo "FAIL  guard did not bail inside an agent session (rc=$rc, ${elapsed}s)"
    exit 1
)
if (( $? == 0 )); then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILURES+=$'\n  - gateway restart guard'; fi

# The restart must use its own budget, not the (smaller) skills timeout.
if [[ "${HERMES_GATEWAY_RESTART_TIMEOUT:-}" == "600" ]]; then
    echo "PASS  gateway restart has a dedicated timeout budget (600s)"
    PASS=$((PASS + 1))
else
    echo "FAIL  HERMES_GATEWAY_RESTART_TIMEOUT not set as expected"
    FAIL=$((FAIL + 1))
    FAILURES+=$'\n  - gateway restart timeout budget'
fi

echo ""
echo "=========================================="
echo "Passed: $PASS   Failed: $FAIL"
if (( FAIL > 0 )); then
    echo -e "Failures:${FAILURES}"
    exit 1
fi
echo "All gateway guard tests passed."
exit 0
