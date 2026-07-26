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
# "stuck" heuristic: status=in_progress AND the registered agent's spawned_at
# is older than 2x that task's timeout_seconds (read from plan.dag.json when
# the task carries one — see task-class-timeout.sh — else the flat
# HARNESS_STUCK_THRESHOLD_SECONDS env default). This is a cheap signal, not
# a verdict: worktree-reconcile.sh / task-reconcile.sh + TaskOutput are the
# actual verdict sources. NOTE: tasks_in_flight/stuck_count/oldest_agent_age
# are only ever non-zero once master actually sets a task's DAG status to
# "in_progress" on spawn — see SKILL.md Step 8.

set -euo pipefail

HARNESS_DIR="${1:?usage: harness-metrics.sh <harness_dir>}"
DAG="$HARNESS_DIR/plan.dag.json"
AGENTS_DIR="$HARNESS_DIR/agents"
META="$HARNESS_DIR/run-meta.json"
DEFAULT_STUCK_THRESHOLD_SECONDS="${HARNESS_STUCK_THRESHOLD_SECONDS:-900}"

python3 - "$DAG" "$AGENTS_DIR" "$META" "$DEFAULT_STUCK_THRESHOLD_SECONDS" <<'PY'
import json, sys
from pathlib import Path
from datetime import datetime, timezone

dag_path, agents_dir, meta_path, default_threshold = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

by_status = {"pending": 0, "in_progress": 0, "done": 0, "blocked": 0, "failed": 0}
tasks = []
if Path(dag_path).exists():
    dag = json.loads(Path(dag_path).read_text())
    tasks = dag.get("tasks", [])
    for t in tasks:
        s = t.get("status", "pending")
        by_status[s] = by_status.get(s, 0) + 1

current_run_id = None
if Path(meta_path).exists():
    try:
        current_run_id = json.loads(Path(meta_path).read_text()).get("run_id")
    except Exception:
        pass

def load_registry_entry(task_id):
    p = Path(agents_dir) / f"{task_id}.json"
    if not p.exists():
        return None
    try:
        entry = json.loads(p.read_text())
    except Exception:
        return None
    # Defensive against a task_id reused on a LATER run (finding #14): a
    # registry file is stamped with the run_id active when it was written;
    # ignore it here if it doesn't match the run we're currently observing.
    if current_run_id and entry.get("run_id") not in (None, "unknown", current_run_id):
        return None
    return entry

now = datetime.now(timezone.utc)
in_flight_ages = []
stuck_count = 0
for t in tasks:
    if t.get("status") != "in_progress":
        continue
    entry = load_registry_entry(t["id"])
    if not entry:
        continue
    try:
        spawned = datetime.fromisoformat(entry["spawned_at"])
    except Exception:
        continue
    age = (now - spawned).total_seconds()
    in_flight_ages.append(age)
    task_threshold = t.get("timeout_seconds", default_threshold)
    if age > 2 * task_threshold:
        stuck_count += 1

result = {
    "tasks_in_flight": by_status["in_progress"],
    "stuck_count": stuck_count,
    "oldest_agent_age_seconds": int(max(in_flight_ages)) if in_flight_ages else 0,
    "by_status": by_status,
}
print(json.dumps(result, indent=2))
PY
