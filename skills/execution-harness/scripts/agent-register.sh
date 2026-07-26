#!/usr/bin/env bash
# Register a spawned agent's runtime ID durably — the missing link that lets
# master (or a coordinator's supervisor) query real liveness via TaskOutput
# and kill a hung agent via TaskStop, even across context compaction or
# when the spawner itself is a coordinator subagent that later exits.
#
# MANDATORY: call this immediately after EVERY Agent(...) spawn returns its
# agentId — whoever does the spawning (master OR a coordinator). A spawn
# whose agent_id is never registered is invisible to the supervision tree.
#
# One file per task_id (.harness/agents/<task_id>.json), NOT one shared JSON.
# Concurrent registration of DIFFERENT tasks is inherently race-free this way
# — there is no shared state to read-modify-write. (The old single-file
# design lost registrations under concurrent spawns: 30 concurrent calls
# landed as few as 12/30 entries in testing.) Even repeated/concurrent calls
# for the SAME task_id are safe: each call writes to its own unique temp file
# then atomically renames onto the target (os.replace) — last writer wins,
# no partial/corrupt state ever observable.
#
# Usage: agent-register.sh <project_root> <task_id> <agent_id> [spawned_by] [run_id]
#   spawned_by: "master" (default) or "coordinator:<coordinator_agent_id>"
#   run_id:     defaults to .harness/run-meta.json's run_id, else "unknown".
#               Stamped into the entry so readers can filter out stale
#               entries from a PREVIOUS run that happened to reuse a task_id.

set -euo pipefail

PROJECT_ROOT="${1:?usage: agent-register.sh <project_root> <task_id> <agent_id> [spawned_by] [run_id]}"
TASK_ID="${2:?task_id required}"
AGENT_ID="${3:?agent_id required}"
SPAWNED_BY="${4:-master}"
RUN_ID="${5:-}"

HARNESS_DIR="$PROJECT_ROOT/.harness"
AGENTS_DIR="$HARNESS_DIR/agents"
META="$HARNESS_DIR/run-meta.json"
mkdir -p "$AGENTS_DIR"

python3 - "$AGENTS_DIR" "$TASK_ID" "$AGENT_ID" "$SPAWNED_BY" "$RUN_ID" "$META" <<'PYEOF'
import json, os, sys, tempfile
from datetime import datetime, timezone

agents_dir, task_id, agent_id, spawned_by, run_id, meta_path = sys.argv[1:7]

if not run_id:
    run_id = "unknown"
    if os.path.exists(meta_path):
        try:
            run_id = json.loads(open(meta_path).read()).get("run_id", "unknown")
        except Exception:
            pass

if "/" in task_id or task_id in ("", ".", ".."):
    print(f"ERROR: unsafe task_id for filename: {task_id!r}", file=sys.stderr)
    sys.exit(1)

entry = {
    "task_id":    task_id,
    "agent_id":   agent_id,
    "spawned_by": spawned_by,
    "spawned_at": datetime.now(timezone.utc).isoformat(),
    "run_id":     run_id,
    "status":     "running",
}

target = os.path.join(agents_dir, f"{task_id}.json")
fd, tmp = tempfile.mkstemp(dir=agents_dir, prefix=f".{task_id}.", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(entry, f, indent=2)
os.replace(tmp, target)
print(f"[agent-register] {task_id} -> agent_id={agent_id} (spawned_by={spawned_by}, run_id={run_id})")
PYEOF
