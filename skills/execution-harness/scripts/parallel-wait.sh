#!/usr/bin/env bash
# Poll for parallel agent completion via durable result files.
#
# Usage: parallel-wait.sh <project_root> <timeout_seconds> <group_id> <task_id...>
#
# Polls .harness/agent-results/<task_id>.json every POLL_INTERVAL seconds.
# Does NOT rely on agent notifications — those can be lost due to context
# compaction, hook interference, or parallel completion race conditions.
#
# Exit 0: all tasks have result files (all agents completed)
# Exit 1: timeout — partial results; caller reads .harness/parallel-wait-<group>.json
# Exit 2: no task IDs provided

set -euo pipefail

PROJECT_ROOT="$1"
TIMEOUT="${2:-600}"
GROUP_ID="${3:-group-000}"
shift 3
TASK_IDS=("$@")

[[ ${#TASK_IDS[@]} -eq 0 ]] && { echo "[parallel-wait] ERROR: no task IDs" >&2; exit 2; }

RESULTS_DIR="$PROJECT_ROOT/.harness/agent-results"
WAIT_OUT="$PROJECT_ROOT/.harness/parallel-wait-${GROUP_ID}.json"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

log() { echo "[parallel-wait] $*" >&2; }
log "Waiting for ${#TASK_IDS[@]} tasks (timeout=${TIMEOUT}s, poll=${POLL_INTERVAL}s): ${TASK_IDS[*]}"

mkdir -p "$RESULTS_DIR"
START=$(date +%s)

while true; do
    ELAPSED=$(( $(date +%s) - START ))
    COMPLETED=(); PENDING=()
    for tid in "${TASK_IDS[@]}"; do
        [[ -f "$RESULTS_DIR/${tid}.json" ]] && COMPLETED+=("$tid") || PENDING+=("$tid")
    done

    log "Elapsed ${ELAPSED}s — ${#COMPLETED[@]}/${#TASK_IDS[@]} done — pending: ${PENDING[*]:-none}"

    if [[ ${#PENDING[@]} -eq 0 ]]; then
        log "All tasks completed in ${ELAPSED}s."
        python3 -c "
import json,os,sys
data={'completed':sys.argv[1:],'timed_out':[],'elapsed_seconds':$ELAPSED}
tmp='$WAIT_OUT.tmp'
open(tmp,'w').write(json.dumps(data,indent=2)); os.replace(tmp,'$WAIT_OUT')
" "${COMPLETED[@]}"
        exit 0
    fi

    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        log "TIMEOUT ${ELAPSED}s. done=${COMPLETED[*]:-none}  checking git evidence for: ${PENDING[*]}"

        # Before declaring these stuck, reconcile against git — a task whose
        # agent committed (Task: <id> trailer) but never wrote a result file
        # or whose notification was lost is NOT stuck, it's DONE_UNREPORTED.
        RECONCILED=(); STILL_STUCK=()
        for tid in "${PENDING[@]}"; do
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if bash "$SCRIPT_DIR/task-reconcile.sh" "$PROJECT_ROOT" "$tid" >/dev/null 2>&1; then
                log "  $tid: RECONCILED via git evidence (commit found) — treating as completed"
                RECONCILED+=("$tid")
            else
                STILL_STUCK+=("$tid")
            fi
        done

        log "Final: completed=${#COMPLETED[@]}  reconciled=${#RECONCILED[@]}  still_stuck=${#STILL_STUCK[@]}"

        # bash 3.2 (macOS default) note: "${arr[@]:-}" on an EMPTY array injects
        # one phantom empty-string argument (not zero args) — it shifts every
        # subsequent positional argv and silently corrupts the categorization.
        # "${arr[@]}" on an empty array instead throws "unbound variable" under
        # set -u. The only form that is correct in BOTH cases (0 args for empty,
        # N args for non-empty, no error) is `${arr[@]+"${arr[@]}"}`.
        # Each category is JSON-encoded to exactly ONE argv string, so there is
        # no positional splicing to get wrong regardless of how many are empty.
        COMPLETED_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" ${COMPLETED[@]+"${COMPLETED[@]}"})
        RECONCILED_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" ${RECONCILED[@]+"${RECONCILED[@]}"})
        STUCK_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" ${STILL_STUCK[@]+"${STILL_STUCK[@]}"})

        python3 -c "
import json,os,sys
completed=json.loads(sys.argv[1])
reconciled=json.loads(sys.argv[2])
timed_out=json.loads(sys.argv[3])
data={'completed':completed,'reconciled':reconciled,'timed_out':timed_out,'elapsed_seconds':$ELAPSED}
tmp='$WAIT_OUT.tmp'
open(tmp,'w').write(json.dumps(data,indent=2)); os.replace(tmp,'$WAIT_OUT')
" "$COMPLETED_JSON" "$RECONCILED_JSON" "$STUCK_JSON"

        [[ ${#STILL_STUCK[@]} -eq 0 ]] && exit 0
        exit 1
    fi

    sleep "$POLL_INTERVAL"
done
