#!/usr/bin/env bash
# Run-level observability for the harness itself — the golden-signal gap:
# we wrote observability.md for the apps the harness ships, but a run of
# the harness had no signals of its own. This gives master (and the user,
# via run-report) a snapshot instead of discovering a stuck run manually.
#
# Usage: harness-metrics.sh <harness_dir>
# Stdout: JSON snapshot — {tasks_in_flight, stuck_count, oldest_agent_age_seconds,
#                           by_status: {pending, in_progress, done, blocked, failed}}
#
# "stuck" heuristic: status=in_progress AND registered agent's spawned_at is
# older than 2x the DEFAULT_STUCK_THRESHOLD (env-overridable) — a cheap signal,
# not a verdict. task-reconcile.sh + TaskOutput are the actual verdict sources.

set -euo pipefail

HARNESS_DIR="${1:?usage: harness-metrics.sh <harness_dir>}"
DAG="$HARNESS_DIR/plan.dag.json"
REGISTRY="$HARNESS_DIR/agent-registry.json"
STUCK_THRESHOLD="${HARNESS_STUCK_THRESHOLD_SECONDS:-900}"

python3 - "$DAG" "$REGISTRY" "$STUCK_THRESHOLD" <<'PY'
import json, sys
from pathlib import Path
from datetime import datetime, timezone

dag_path, registry_path, stuck_threshold = sys.argv[1], sys.argv[2], int(sys.argv[3])

by_status = {"pending": 0, "in_progress": 0, "done": 0, "blocked": 0, "failed": 0}
tasks = []
if Path(dag_path).exists():
    dag = json.loads(Path(dag_path).read_text())
    tasks = dag.get("tasks", [])
    for t in tasks:
        s = t.get("status", "pending")
        by_status[s] = by_status.get(s, 0) + 1

registry = {}
if Path(registry_path).exists():
    registry = json.loads(Path(registry_path).read_text())

now = datetime.now(timezone.utc)
in_flight_ages = []
stuck_count = 0
for t in tasks:
    if t.get("status") != "in_progress":
        continue
    entry = registry.get(t["id"])
    if not entry:
        continue
    try:
        spawned = datetime.fromisoformat(entry["spawned_at"])
    except Exception:
        continue
    age = (now - spawned).total_seconds()
    in_flight_ages.append(age)
    if age > stuck_threshold:
        stuck_count += 1

result = {
    "tasks_in_flight": by_status["in_progress"],
    "stuck_count": stuck_count,
    "oldest_agent_age_seconds": int(max(in_flight_ages)) if in_flight_ages else 0,
    "by_status": by_status,
}
print(json.dumps(result, indent=2))
PY
