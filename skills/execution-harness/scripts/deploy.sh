#!/usr/bin/env bash
# Deploy orchestrator — pluggable, project-agnostic.
#
# Usage:
#   deploy.sh staging   <project_root>              # auto after qa-gate PASS
#   deploy.sh production <project_root> --confirm   # always explicit, never in loop
#
# Exit 0 = deployed + healthy
# Exit 1 = deploy failed or health check failed (rollback attempted)
# Exit 2 = NO-GO (qa-gate not passed)
# Exit 3 = setup error (missing deploy-config.sh)
#
# Project provides: <project_root>/deploy-config.sh
# Required vars:
#   DEPLOY_STAGING_CMD   shell command to deploy to staging
#   DEPLOY_PROD_CMD      shell command to deploy to production
#   HEALTH_CHECK_URL     URL GET after deploy — 200 = healthy
#   ROLLBACK_CMD         command to revert (optional)
#
# Env overrides:
#   DEPLOY_HEALTH_RETRIES=3    number of health check retries
#   DEPLOY_HEALTH_WAIT=5       seconds between retries

set -euo pipefail

MODE="${1:-}"
PROJECT_ROOT="${2:-$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONFIRM="${3:-}"

HARNESS_DIR="$PROJECT_ROOT/.harness"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$PROJECT_ROOT/deploy-config.sh"

HEALTH_RETRIES="${DEPLOY_HEALTH_RETRIES:-3}"
HEALTH_WAIT="${DEPLOY_HEALTH_WAIT:-5}"

log() { echo "[deploy] $*" >&2; }
die() { log "ERROR: $1"; exit "${2:-1}"; }

# ── Validate input ────────────────────────────────────────────────────────────
[[ "$MODE" == "staging" || "$MODE" == "production" ]] \
    || die "Usage: deploy.sh [staging|production] <project_root> [--confirm]"

if [[ "$MODE" == "production" && "$CONFIRM" != "--confirm" ]]; then
    die "Production deploy requires --confirm. Intentional — never auto-deploy production."
fi

# ── QA gate check ────────────────────────────────────────────────────────────
QA_GATE="$HARNESS_DIR/qa-gate.json"
if [[ -f "$QA_GATE" ]]; then
    VERDICT=$(python3 -c "import json; print(json.load(open('$QA_GATE'))['verdict'])" 2>/dev/null || echo "UNKNOWN")
    if [[ "$VERDICT" != "GO" ]]; then
        log "QA gate verdict: $VERDICT — deploy blocked."
        log "Fix NO-GO reasons in .harness/qa-gate.json first."
        exit 2
    fi
    log "QA gate: GO"
else
    if [[ "$MODE" == "production" ]]; then
        die "No qa-gate.json — run qa-gate.sh before deploying production." 2
    fi
    log "WARNING: no qa-gate.json found (staging deploy — proceeding without it)"
fi

# ── Source project deploy config ──────────────────────────────────────────────
[[ -f "$CONFIG" ]] || die "Missing $CONFIG. See scripts/deploy.sh header for required vars." 3
# shellcheck source=/dev/null
source "$CONFIG"

DEPLOY_CMD="${DEPLOY_STAGING_CMD:-}"
[[ "$MODE" == "production" ]] && DEPLOY_CMD="${DEPLOY_PROD_CMD:-}"
[[ -n "$DEPLOY_CMD" ]] || die "deploy-config.sh missing $(echo "$MODE" | tr 'a-z' 'A-Z')_CMD" 3

HEALTH_URL="${HEALTH_CHECK_URL:-}"

# ── Deploy ────────────────────────────────────────────────────────────────────
log "Deploying to $MODE..."
if ! eval "$DEPLOY_CMD"; then
    die "Deploy command failed."
fi
log "Deploy command completed."

# ── Health check ──────────────────────────────────────────────────────────────
if [[ -n "$HEALTH_URL" ]]; then
    log "Health check: $HEALTH_URL (${HEALTH_RETRIES} attempts)"
    HEALTHY=false
    for attempt in $(seq 1 "$HEALTH_RETRIES"); do
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HEALTH_URL" 2>/dev/null || echo "000")
        if [[ "$HTTP" == "200" ]]; then
            HEALTHY=true; break
        fi
        log "Attempt $attempt/$HEALTH_RETRIES: HTTP $HTTP — waiting ${HEALTH_WAIT}s..."
        sleep "$HEALTH_WAIT"
    done

    if [[ "$HEALTHY" == "false" ]]; then
        log "Health check failed. Running rollback..."
        "$SCRIPT_DIR/rollback.sh" "$PROJECT_ROOT" "$HEALTH_URL" || true
        die "Deploy rolled back due to health check failure."
    fi
    log "Health check passed (HTTP 200)."
fi

# ── Write deploy record ───────────────────────────────────────────────────────
python3 -c "
import json
from datetime import datetime
record = {
    'mode': '$MODE',
    'status': 'PASS',
    'health_url': '$HEALTH_URL',
    'timestamp': datetime.utcnow().isoformat() + 'Z'
}
open('$HARNESS_DIR/deploy.json', 'w').write(json.dumps(record, indent=2))
"
log "Deploy $MODE: SUCCESS"
