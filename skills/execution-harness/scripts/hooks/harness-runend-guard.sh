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

# Extract done task_ids from DAG
done_tasks=""
done_count=0
if [ -f "$DAG" ]; then
  result=$(python3 - "$DAG" <<'PY'
import json, sys
try:
  d = json.load(open(sys.argv[1]))
except Exception:
  print("0|")
  sys.exit()
done = [t["id"] for t in d.get("tasks", []) if t.get("status") == "done"]
print(f"{len(done)}|{','.join(done)}")
PY
)
  done_count="${result%%|*}"
  done_tasks="${result#*|}"
fi

# Check row count first (fast path)
rows=0
[ -f "$TRAJ" ] && rows="$(grep -c . "$TRAJ" 2>/dev/null || echo 0)"

if [ "$rows" -lt "$done_count" ]; then
  block "trajectory incomplete: $rows rows for $done_count done tasks — append missing rows + run-end memory flush (pattern_store + decision-ledger) before finishing"
fi

# Check that trajectory task_ids match done task_ids (not just count)
if [ -n "$done_tasks" ] && [ -f "$TRAJ" ]; then
  mismatch=$(python3 - "$TRAJ" "$done_tasks" <<'PY'
import json, sys
traj_path, done_str = sys.argv[1], sys.argv[2]
done_ids = set(done_str.split(",")) if done_str else set()
traj_ids = set()
with open(traj_path) as f:
  for line in f:
    line = line.strip()
    if not line: continue
    try:
      row = json.loads(line)
      tid = row.get("task_id", "")
      if tid: traj_ids.add(tid)
    except Exception:
      pass
missing = done_ids - traj_ids
if missing:
  print("missing: " + ", ".join(sorted(missing)))
else:
  print("")
PY
)
  if [ -n "$mismatch" ]; then
    block "trajectory task_id mismatch — $mismatch — append rows for each missing task before finishing"
  fi
fi

if ! ls "$ROOT"/run-report-*.md >/dev/null 2>&1; then
  block "no run-report-*.md found — write run-report before finishing"
fi

exit 0
