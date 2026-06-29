#!/usr/bin/env bash
# Rollback — called automatically by deploy.sh on health check failure.
#
# Usage: rollback.sh <project_root> <health_check_url>
#
# Exit 0 = rolled back + healthy
# Exit 1 = rollback attempted, service still unhealthy (manual intervention needed)
# Exit 2 = no rollback mechanism configured

set -euo pipefail

PROJECT_ROOT="${1:-$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)}"
HEALTH_URL="${2:-}"
HARNESS_DIR="$PROJECT_ROOT/.harness"
CONFIG="$PROJECT_ROOT/deploy-config.sh"

log() { echo "[rollback] $*" >&2; }

ROLLBACK_CMD=""
if [[ -f "$CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
fi

# ── Try ROLLBACK_CMD from project config ──────────────────────────────────────
if [[ -n "${ROLLBACK_CMD:-}" ]]; then
    log "Running ROLLBACK_CMD from deploy-config.sh..."
    eval "$ROLLBACK_CMD" || log "WARNING: ROLLBACK_CMD exited non-zero."

elif git -C "$PROJECT_ROOT" rev-parse --git-dir &>/dev/null 2>&1; then
    log "No ROLLBACK_CMD — using git fallback."
    PREV_TAG=$(git -C "$PROJECT_ROOT" tag -l --sort=-version:refname 2>/dev/null | sed -n '2p' || echo "")
    if [[ -n "$PREV_TAG" ]]; then
        log "Checking out previous release tag: $PREV_TAG"
        git -C "$PROJECT_ROOT" checkout "$PREV_TAG" --
    else
        log "No previous tag — reverting HEAD commit."
        git -C "$PROJECT_ROOT" revert --no-commit HEAD || true
    fi

else
    log "No rollback mechanism. Set ROLLBACK_CMD in $CONFIG."
    python3 -c "
import json; from datetime import datetime
open('$HARNESS_DIR/rollback.json','w').write(json.dumps(
  {'status':'NO_MECHANISM','timestamp': datetime.utcnow().isoformat()+'Z'},indent=2))"
    exit 2
fi

# ── Health check post-rollback ────────────────────────────────────────────────
HEALTHY=false
if [[ -n "$HEALTH_URL" ]]; then
    for attempt in 1 2 3; do
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HEALTH_URL" 2>/dev/null || echo "000")
        [[ "$HTTP" == "200" ]] && { HEALTHY=true; break; }
        log "Attempt $attempt/3: HTTP $HTTP — retrying in 5s..."; sleep 5
    done
    [[ "$HEALTHY" == "true" ]] && log "Service healthy post-rollback." \
        || log "CRITICAL: service still unhealthy — manual intervention required."
fi

STATUS="DONE"
[[ "$HEALTHY" == "false" && -n "$HEALTH_URL" ]] && STATUS="UNHEALTHY_POST_ROLLBACK"

python3 -c "
import json; from datetime import datetime
open('$HARNESS_DIR/rollback.json','w').write(json.dumps(
  {'status':'$STATUS','health_url':'$HEALTH_URL',
   'timestamp':datetime.utcnow().isoformat()+'Z'},indent=2))" 2>/dev/null || true

[[ "$STATUS" == "DONE" ]] && exit 0 || exit 1
