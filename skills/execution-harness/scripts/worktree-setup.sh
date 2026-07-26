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
# bash 3.2 (macOS default) note: "${arr[@]:-}" on an EMPTY array injects one
# phantom empty-string argument (not zero args) instead of expanding to
# nothing — it silently corrupted this exact call before (two tasks with
# empty files_touched produced phantom [''] claims that falsely conflicted
# with each other). The only form correct in both cases (0 args for empty,
# N args for non-empty, no error under set -u) is `${arr[@]+"${arr[@]}"}`.
FILES_JSON=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" ${FILES_CLAIMED[@]+"${FILES_CLAIMED[@]}"})

# FILES_JSON is passed via argv and parsed with json.loads — never
# interpolated into Python source text. (A prior version embedded it
# directly as `set($FILES_JSON)`, relying on JSON/Python list-literal syntax
# happening to coincide; that's the same class of risk as the RCE fixed in
# task-reconcile.sh, avoided here on principle even though no concrete
# exploit was demonstrated for this specific call site.)
python3 - "$CLAIMS_FILE" "$TASK_ID" "$WORKTREE_PATH" "$FILES_JSON" <<'PYEOF'
import json, os, sys, tempfile

claims_path, task_id, worktree, files_json = sys.argv[1:5]
new_files = set(json.loads(files_json))

claims = {}
if os.path.exists(claims_path):
    with open(claims_path) as f:
        claims = json.load(f)
claims.setdefault("active", {})

for active_id, info in claims["active"].items():
    if active_id == task_id:
        # Re-spawning the SAME task_id (e.g. after a crashed teardown left a
        # stale claim behind) must not self-conflict against its own prior
        # claim — only cross-task overlaps are real conflicts.
        continue
    overlap = new_files & set(info.get("files", []))
    if overlap:
        print(f"ERROR: file conflict: {task_id} vs {active_id}: {sorted(overlap)}", file=sys.stderr)
        sys.exit(1)

claims["active"][task_id] = {
    "files":    sorted(new_files),
    "worktree": worktree,
    "status":   "running",
}

claims_dir = os.path.dirname(claims_path) or "."
fd, tmp = tempfile.mkstemp(dir=claims_dir, prefix=".file-claims.", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(claims, f, indent=2)
os.replace(tmp, claims_path)
print(f"[worktree-setup] claimed {len(new_files)} files for {task_id}", file=sys.stderr)
PYEOF

# ── Create detached-HEAD worktree ──────────────────────────────────────────────
COMMIT=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
log "Creating worktree at $WORKTREE_PATH (detached @ ${COMMIT:0:8})"
# stdout of `git worktree add` ("HEAD is now at ...") must NOT pollute this script's
# stdout — the only stdout line is the worktree path the master captures. Send git → stderr.
git -C "$PROJECT_ROOT" worktree add --detach "$WORKTREE_PATH" "$COMMIT" >&2

# Copy agent-result-write.sh into worktree so agent can call it without knowing harness path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/agent-result-write.sh" "$WORKTREE_PATH/.harness-write.sh"
chmod +x "$WORKTREE_PATH/.harness-write.sh"
log "Installed .harness-write.sh in worktree"

echo "$WORKTREE_PATH"
