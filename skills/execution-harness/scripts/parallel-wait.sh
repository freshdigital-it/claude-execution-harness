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
        log "TIMEOUT ${ELAPSED}s. done=${COMPLETED[*]:-none}  stuck=${PENDING[*]}"
        python3 -c "
import json,os,sys
completed=list(sys.argv[1:1+${#COMPLETED[@]}]) if ${#COMPLETED[@]} else []
timed_out=list(sys.argv[1+${#COMPLETED[@]}:]) if ${#PENDING[@]} else []
data={'completed':completed,'timed_out':timed_out,'elapsed_seconds':$ELAPSED}
tmp='$WAIT_OUT.tmp'
open(tmp,'w').write(json.dumps(data,indent=2)); os.replace(tmp,'$WAIT_OUT')
" "${COMPLETED[@]:-__none__}" "${PENDING[@]}"
        exit 1
    fi

    sleep "$POLL_INTERVAL"
done
