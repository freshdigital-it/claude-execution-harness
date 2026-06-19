#!/usr/bin/env bash
# Append one validated task-trajectory row to <harness_dir>/trajectory.jsonl
# Usage: trajectory-append.sh <harness_dir> <row_json>
set -euo pipefail

HARNESS_DIR="${1:?usage: trajectory-append.sh <harness_dir> <row_json>}"
ROW_JSON="${2:?usage: trajectory-append.sh <harness_dir> <row_json>}"
TRAJ="$HARNESS_DIR/trajectory.jsonl"

printf '%s' "$ROW_JSON" | python3 -c '
import json, sys
try:
    row = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write("trajectory-append: invalid JSON: %s\n" % e); sys.exit(1)
if not isinstance(row, dict):
    sys.stderr.write("trajectory-append: row must be a JSON object\n"); sys.exit(1)
required = ["task_id", "class", "status", "gate_result"]
missing = [k for k in required if k not in row]
if missing:
    sys.stderr.write("trajectory-append: missing fields: %s\n" % missing); sys.exit(1)
'

mkdir -p "$HARNESS_DIR"
printf '%s' "$ROW_JSON" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), separators=(",",":")))' >> "$TRAJ"
echo "trajectory-append: appended $(printf '%s' "$ROW_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["task_id"])')"
