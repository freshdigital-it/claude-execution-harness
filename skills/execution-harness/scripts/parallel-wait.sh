#!/usr/bin/env bash
# Poll for parallel agent completion via durable result files.
#
# Usage: parallel-wait.sh <project_root> <timeout_seconds> <group_id> <task_id...>
#
# Polls .harness/agent-results/<task_id>.json every POLL_INTERVAL seconds.
# Does NOT rely on agent notifications — those can be lost due to context
# compaction, hook interference, or parallel completion race conditions.
#
# On timeout, each still-pending task is reconciled in two stages:
#   1. worktree-reconcile.sh (PRIMARY) — does the task's isolated worktree
#      have uncommitted changes? This is the actual failure mode this
#      harness produces (agents never run git; only master commits, and
#      only after this wait phase) — evidence of real work with NO gate
#      verification yet. -> bucket "unverified". NEVER auto-completed.
#   2. task-reconcile.sh (SECONDARY) — does a "Task: <id>" commit already
#      exist on this run's branch? Gate-PASS-proven (Commit Convention).
#      Mainly fires on RESUME (a prior session already committed this task)
#      or a coordinator-commits-on-behalf-of-agents pattern. -> "reconciled".
#   Neither -> "timed_out": no evidence at all, genuinely stuck/dead.
#
# Exit 0: every task is TRUSTWORTHY-resolved — has a result file
#         (completed) or a git-proven commit (reconciled). Nothing pending.
# Exit 1: at least one task is NOT trustworthy-resolved — either
#         "unverified" (worktree has unproven work; master must re-verify
#         the gate or ask a human before treating it as done) or
#         "timed_out" (no evidence at all; follow the recovery procedure
#         in reference/autonomy.md). Caller reads
#         .harness/parallel-wait-<group>.json to see which.
# Exit 2: no task IDs provided.

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

# bash 3.2 (macOS default) note, applies to every array-to-argv expansion
# below: "${arr[@]:-}" on an EMPTY array injects one phantom empty-string
# argument (not zero args), silently corrupting downstream argv-index-based
# logic. "${arr[@]}" alone throws "unbound variable" under set -u on an
# empty array. The only form correct in both cases (0 args for empty, N for
# non-empty, no error) is `${arr[@]+"${arr[@]}"}` — used throughout.

write_output() {
    local completed_json="$1" reconciled_json="$2" unverified_json="$3" timed_out_json="$4" elapsed="$5"
    python3 - "$completed_json" "$reconciled_json" "$unverified_json" "$timed_out_json" "$elapsed" "$WAIT_OUT" <<'PYEOF'
import json, os, sys
completed, reconciled, unverified, timed_out, elapsed, out_path = sys.argv[1:7]
data = {
    "completed": json.loads(completed),
    "reconciled": json.loads(reconciled),
    "unverified": json.loads(unverified),
    "timed_out": json.loads(timed_out),
    "elapsed_seconds": int(elapsed),
}
tmp = out_path + ".tmp"
with open(tmp, "w") as f:
    f.write(json.dumps(data, indent=2))
os.replace(tmp, out_path)
PYEOF
}

to_json_arg() {
    # Encode the given args to exactly one JSON-array argv string — sidesteps
    # all positional-splicing arithmetic regardless of how many elements.
    # NOTE: deliberately takes args via "$@", NOT a nameref (`local -n`) —
    # namerefs require bash 4.3+ and macOS ships bash 3.2 by default. Call
    # as: to_json_arg ${ARR[@]+"${ARR[@]}"}
    python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "$@"
}

while true; do
    ELAPSED=$(( $(date +%s) - START ))
    COMPLETED=(); PENDING=()
    for tid in "${TASK_IDS[@]}"; do
        [[ -f "$RESULTS_DIR/${tid}.json" ]] && COMPLETED+=("$tid") || PENDING+=("$tid")
    done

    log "Elapsed ${ELAPSED}s — ${#COMPLETED[@]}/${#TASK_IDS[@]} done — pending: ${PENDING[*]:-none}"

    if [[ ${#PENDING[@]} -eq 0 ]]; then
        log "All tasks completed in ${ELAPSED}s."
        COMPLETED_JSON=$(to_json_arg ${COMPLETED[@]+"${COMPLETED[@]}"})
        write_output "$COMPLETED_JSON" "[]" "[]" "[]" "$ELAPSED"
        exit 0
    fi

    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        log "TIMEOUT ${ELAPSED}s. done=${COMPLETED[*]:-none}  reconciling: ${PENDING[*]}"

        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        RECONCILED=(); UNVERIFIED=(); STILL_STUCK=()
        for tid in "${PENDING[@]}"; do
            if bash "$SCRIPT_DIR/worktree-reconcile.sh" "$PROJECT_ROOT" "$tid" >/dev/null 2>&1; then
                log "  $tid: WORK_FOUND_UNVERIFIED (worktree has uncommitted changes) — master must re-verify, NOT auto-completed"
                UNVERIFIED+=("$tid")
            elif bash "$SCRIPT_DIR/task-reconcile.sh" "$PROJECT_ROOT" "$tid" >/dev/null 2>&1; then
                log "  $tid: RECONCILED via git evidence (commit found) — treating as completed"
                RECONCILED+=("$tid")
            else
                STILL_STUCK+=("$tid")
            fi
        done

        log "Final: completed=${#COMPLETED[@]}  reconciled=${#RECONCILED[@]}  unverified=${#UNVERIFIED[@]}  still_stuck=${#STILL_STUCK[@]}"

        COMPLETED_JSON=$(to_json_arg ${COMPLETED[@]+"${COMPLETED[@]}"})
        RECONCILED_JSON=$(to_json_arg ${RECONCILED[@]+"${RECONCILED[@]}"})
        UNVERIFIED_JSON=$(to_json_arg ${UNVERIFIED[@]+"${UNVERIFIED[@]}"})
        STUCK_JSON=$(to_json_arg ${STILL_STUCK[@]+"${STILL_STUCK[@]}"})
        write_output "$COMPLETED_JSON" "$RECONCILED_JSON" "$UNVERIFIED_JSON" "$STUCK_JSON" "$ELAPSED"

        [[ ${#UNVERIFIED[@]} -eq 0 && ${#STILL_STUCK[@]} -eq 0 ]] && exit 0
        exit 1
    fi

    sleep "$POLL_INTERVAL"
done
