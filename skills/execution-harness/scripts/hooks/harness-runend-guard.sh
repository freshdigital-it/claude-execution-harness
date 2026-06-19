#!/usr/bin/env bash
# Stop hook: refuse to end a harness run until trajectory is complete and a run-report exists.
# Reads hook JSON on stdin (ignored). Operates on $CLAUDE_PROJECT_DIR or cwd.
set -uo pipefail
cat >/dev/null 2>&1 || true   # drain stdin

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
HARNESS="$ROOT/.harness"

# Opt-out / not-a-harness-run → allow stop.
[ "${HARNESS_NO_TRAJECTORY:-0}" = "1" ] && exit 0
[ -d "$HARNESS" ] || exit 0

block() { printf '{"decision":"block","reason":"harness-runend-guard: %s"}\n' "$1"; exit 0; }

DAG="$HARNESS/plan.dag.json"
TRAJ="$HARNESS/trajectory.jsonl"

done_count=0
if [ -f "$DAG" ]; then
  done_count="$(python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(0); sys.exit()
print(sum(1 for t in d.get("tasks",[]) if t.get("status")=="done"))
' "$DAG")"
fi

rows=0
[ -f "$TRAJ" ] && rows="$(grep -c . "$TRAJ" 2>/dev/null || echo 0)"

if [ "$rows" -lt "$done_count" ]; then
  block "trajectory incomplete: $rows rows for $done_count done tasks — append missing rows + run-end memory flush (pattern_store + decision-ledger) before finishing"
fi

if ! ls "$ROOT"/run-report-*.md >/dev/null 2>&1; then
  block "no run-report-*.md found — write run-report before finishing"
fi

exit 0
