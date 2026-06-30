#!/usr/bin/env bash
# Create an isolated git worktree for one parallel subagent task.
#
# Usage: worktree-setup.sh <project_root> <run_id> <task_id> [file1 file2 ...]
# Stdout: worktree path (capture with WPATH=$(worktree-setup.sh ...))
#
# Registers file claims in .harness/file-claims.json (atomic write).
# Exits non-zero if another active task already claims any of these files.
#
# Worktree uses detached HEAD — avoids git's "branch checked out twice" constraint.
# Agents write files in the worktree; master commits from the main project dir.

set -euo pipefail

PROJECT_ROOT="$1"
RUN_ID="$2"
TASK_ID="$3"
shift 3
FILES_CLAIMED=("$@")

WORKTREE_PATH="/tmp/harness-${RUN_ID}-${TASK_ID}"
CLAIMS_FILE="$PROJECT_ROOT/.harness/file-claims.json"

log() { echo "[worktree-setup] $*" >&2; }

mkdir -p "$PROJECT_ROOT/.harness"

# ── Register file claims (atomic) ─────────────────────────────────────────────
FILES_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "${FILES_CLAIMED[@]:-}")

python3 << PYEOF
import json, os, sys

claims_path = "$CLAIMS_FILE"
task_id     = "$TASK_ID"
worktree    = "$WORKTREE_PATH"
new_files   = set($FILES_JSON)

claims = {}
if os.path.exists(claims_path):
    with open(claims_path) as f:
        claims = json.load(f)
claims.setdefault("active", {})

for active_id, info in claims["active"].items():
    overlap = new_files & set(info.get("files", []))
    if overlap:
        print(f"ERROR: file conflict: {task_id} vs {active_id}: {sorted(overlap)}", file=sys.stderr)
        sys.exit(1)

claims["active"][task_id] = {
    "files":    sorted(new_files),
    "worktree": worktree,
    "status":   "running",
}

tmp = claims_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(claims, f, indent=2)
os.replace(tmp, claims_path)
print(f"[worktree-setup] claimed {len(new_files)} files for {task_id}", file=sys.stderr)
PYEOF

# ── Create detached-HEAD worktree ──────────────────────────────────────────────
COMMIT=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
log "Creating worktree at $WORKTREE_PATH (detached @ ${COMMIT:0:8})"
git -C "$PROJECT_ROOT" worktree add --detach "$WORKTREE_PATH" "$COMMIT"

# Copy agent-result-write.sh into worktree so agent can call it without knowing harness path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/agent-result-write.sh" "$WORKTREE_PATH/.harness-write.sh"
chmod +x "$WORKTREE_PATH/.harness-write.sh"
log "Installed .harness-write.sh in worktree"

echo "$WORKTREE_PATH"
