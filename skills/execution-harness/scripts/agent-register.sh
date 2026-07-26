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
# Usage: agent-register.sh <project_root> <task_id> <agent_id> [spawned_by]
#   spawned_by: "master" (default) or "coordinator:<coordinator_agent_id>"

set -euo pipefail

PROJECT_ROOT="${1:?usage: agent-register.sh <project_root> <task_id> <agent_id> [spawned_by]}"
TASK_ID="${2:?task_id required}"
AGENT_ID="${3:?agent_id required}"
SPAWNED_BY="${4:-master}"

HARNESS_DIR="$PROJECT_ROOT/.harness"
REGISTRY="$HARNESS_DIR/agent-registry.json"
mkdir -p "$HARNESS_DIR"

python3 - "$REGISTRY" "$TASK_ID" "$AGENT_ID" "$SPAWNED_BY" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

registry_path, task_id, agent_id, spawned_by = sys.argv[1:5]

registry = {}
if os.path.exists(registry_path):
    with open(registry_path) as f:
        registry = json.load(f)

registry[task_id] = {
    "agent_id":    agent_id,
    "spawned_by":  spawned_by,
    "spawned_at":  datetime.now(timezone.utc).isoformat(),
    "status":      "running",
}

tmp = registry_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(registry, f, indent=2)
os.replace(tmp, registry_path)
print(f"[agent-register] {task_id} -> agent_id={agent_id} (spawned_by={spawned_by})")
PYEOF
