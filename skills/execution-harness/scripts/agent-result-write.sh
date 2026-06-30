#!/usr/bin/env bash
# Write agent completion result to a durable file that master can poll.
#
# Usage:
#   agent-result-write.sh <project_root> <task_id> <gate_result> <files_json> <summary>
#
#   gate_result: PASS | FAIL | BLOCKED
#   files_json:  JSON array string, e.g. '["src/pay.go","tests/pay_test.go"]'
#   summary:     one-line description of what was done
#
# Called by the subagent as the LAST step before returning.
# Master polls .harness/agent-results/<task_id>.json to detect completion.
# This is the durable completion signal — agent notifications may be lost.

set -euo pipefail

PROJECT_ROOT="$1"
TASK_ID="$2"
GATE_RESULT="$3"
FILES_JSON="$4"
SUMMARY="${5:-}"

RESULTS_DIR="$PROJECT_ROOT/.harness/agent-results"
mkdir -p "$RESULTS_DIR"

RESULT_FILE="$RESULTS_DIR/${TASK_ID}.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 - "$TASK_ID" "$GATE_RESULT" "$TIMESTAMP" "$RESULT_FILE" << PYEOF
import json, os, sys

task_id, gate_result, timestamp, result_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

result = {
    "task_id":             task_id,
    "gate_result":         gate_result,
    "files_changed_actual": $FILES_JSON,
    "summary":             """$SUMMARY""",
    "timestamp":           timestamp,
}

tmp = result_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(result, f, indent=2)
os.replace(tmp, result_file)
print(f"[agent-result-write] {task_id}: {gate_result} -> {result_file}")
PYEOF
