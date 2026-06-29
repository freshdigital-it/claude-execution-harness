#!/usr/bin/env bash
# phase-integration-gate.sh — Opus #1: inter-task integration gate at phase boundary.
#
# Re-runs ALL security-core negative tests + ALL approved Playwright journey specs
# against the live local-preview. Makes smoke test BLOCKING (not WARN-only).
#
# Called by master at phase boundary (after a group of tasks, before next phase).
# A failure here means tasks verified in isolation have broken each other's contracts.
#
# Usage:
#   phase-integration-gate.sh <project_root> <preview_url> [--phase <name>] [--harness-dir <dir>]
#
# Exit 0 = all integration checks pass
# Exit 1 = integration failure (gate FAIL — halt loop, surface to human)

set -uo pipefail

PROJECT_ROOT="${1:?usage: phase-integration-gate.sh <project_root> <preview_url>}"
PREVIEW_URL="${2:?usage: phase-integration-gate.sh <project_root> <preview_url>}"
PHASE=""
HARNESS_DIR=".harness"

shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)       PHASE="$2"; shift 2 ;;
    --harness-dir) HARNESS_DIR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

PHASE_LABEL="${PHASE:-unnamed}"
RESULT_FILE="$HARNESS_DIR/phase-gate-${PHASE_LABEL}.json"

log()  { printf '[phase-gate:%s] %s\n' "$PHASE_LABEL" "$1"; }
fail() { printf '[phase-gate:%s] FAIL: %s\n' "$PHASE_LABEL" "$1" >&2; exit 1; }

FAILURES=0
CHECKS=0

# --- 1. Server health check (mandatory) ---
log "Checking preview server..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$PREVIEW_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "200" ]]; then
  fail "Preview server at $PREVIEW_URL returned $HTTP_CODE. Cannot run integration gate without live app."
fi
log "Preview server OK (HTTP $HTTP_CODE)"

# --- 2. Re-run security-core negative tests ---
SECURITY_TESTS_DIR="${PROJECT_ROOT}/tests/security"
if [[ -d "$SECURITY_TESTS_DIR" ]]; then
  log "Running security-core negative tests..."
  CHECKS=$((CHECKS + 1))
  if command -v go &>/dev/null && [[ -f "$PROJECT_ROOT/go.mod" ]]; then
    if ! go test "$PROJECT_ROOT/..." -run "TestNegative|TestCrossTenant|TestPrivilege|TestAuth" \
        -count=1 -timeout 60s 2>&1 | tee /tmp/security-gate.log | grep -q "^ok"; then
      log "FAIL: security negative tests did not all pass"
      FAILURES=$((FAILURES + 1))
    else
      log "PASS: security negative tests"
    fi
  fi
else
  log "No tests/security/ dir — skipping security re-run (add negative tests to enable this gate)"
fi

# --- 3. Re-run ALL approved Playwright journey specs ---
JOURNEY_DIR="${PROJECT_ROOT}/tests/e2e/ux-contracts"
if [[ -d "$JOURNEY_DIR" ]]; then
  SPEC_COUNT=$(find "$JOURNEY_DIR" -name "*.spec.ts" | wc -l | tr -d ' ')
  log "Running $SPEC_COUNT Playwright journey specs against $PREVIEW_URL..."
  CHECKS=$((CHECKS + 1))
  if command -v npx &>/dev/null; then
    if ! npx playwright test "$JOURNEY_DIR" \
        --reporter=line \
        --timeout=30000 \
        2>&1 | tee /tmp/playwright-gate.log | tail -5; then
      log "FAIL: one or more Playwright journey specs failed"
      log "Check /tmp/playwright-gate.log for details"
      FAILURES=$((FAILURES + 1))
    else
      log "PASS: all Playwright journey specs"
    fi
  else
    log "WARN: npx not found — skipping Playwright re-run"
  fi
else
  log "No tests/e2e/ux-contracts/ dir — generate with fe-atdd-generate.py to enable this gate"
fi

# --- 4. SAST on all files changed this phase ---
if command -v scripts/security-scan.sh &>/dev/null || [[ -f "scripts/security-scan.sh" ]]; then
  log "Running SAST on changed files..."
  CHECKS=$((CHECKS + 1))
  if ! bash "${PROJECT_ROOT}/scripts/security-scan.sh" "$PROJECT_ROOT" --changed-only 2>&1; then
    log "FAIL: security-scan found HIGH/CRITICAL findings"
    FAILURES=$((FAILURES + 1))
  else
    log "PASS: security-scan"
  fi
fi

# --- Write result ---
python3 - "$RESULT_FILE" "$PHASE_LABEL" "$CHECKS" "$FAILURES" << 'PYEOF'
import json, sys
path, phase, checks, failures = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
result = {
    "phase": phase,
    "checks": checks,
    "failures": failures,
    "verdict": "PASS" if failures == 0 else "FAIL"
}
with open(path, 'w') as f:
    json.dump(result, f, indent=2)
print(json.dumps(result))
PYEOF

log "---"
log "Checks run: $CHECKS | Failures: $FAILURES"

if [[ "$FAILURES" -gt 0 ]]; then
  fail "Phase integration gate FAILED ($FAILURES of $CHECKS checks failed). Loop halted. Fix integration before continuing."
fi

log "Phase integration gate PASSED — all $CHECKS checks green"
exit 0
