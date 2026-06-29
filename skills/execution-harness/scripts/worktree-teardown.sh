#!/usr/bin/env bash
# Serialize a completed parallel task: copy changed files, commit, remove worktree.
#
# Usage:
#   worktree-teardown.sh <project_root> <run_id> <task_id> "<commit_msg>"
#   worktree-teardown.sh <project_root> <run_id> <task_id> "" --no-commit  (gate FAIL)
#
# Steps:
#   1. Read file claims from .harness/file-claims.json
#   2. Copy changed files from worktree to main project directory
#   3. git add + commit (unless --no-commit)
#   4. Remove worktree
#   5. Release file claims (atomic)
#
# Called SERIALLY by master — never two teardowns simultaneously.

set -euo pipefail

PROJECT_ROOT="$1"
RUN_ID="$2"
TASK_ID="$3"
COMMIT_MSG="${4:-}"
NO_COMMIT="${5:-}"

CLAIMS_FILE="$PROJECT_ROOT/.harness/file-claims.json"

log() { echo "[worktree-teardown] $*" >&2; }

# ── Read claims ────────────────────────────────────────────────────────────────
TASK_INFO=$(python3 -c "
import json
with open('$CLAIMS_FILE') as f:
    claims = json.load(f)
task = claims['active']['$TASK_ID']
print(task['worktree'])
print(json.dumps(task['files']))
")

WORKTREE_PATH=$(echo "$TASK_INFO" | head -1)
FILES_JSON=$(echo "$TASK_INFO" | tail -1)

log "task=$TASK_ID worktree=$WORKTREE_PATH no-commit=${NO_COMMIT:-false}"

# ── Copy changed files from worktree → main project ───────────────────────────
python3 << PYEOF
import json, shutil, os

files    = $FILES_JSON
src_root = "$WORKTREE_PATH"
dst_root = "$PROJECT_ROOT"

for rel_path in files:
    src = os.path.join(src_root, rel_path)
    dst = os.path.join(dst_root, rel_path)
    if os.path.exists(src):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        print(f"  copied: {rel_path}")
    else:
        print(f"  skip (not in worktree): {rel_path}", flush=True)
PYEOF

# ── Commit in main project (serialized by master) ─────────────────────────────
if [[ "$NO_COMMIT" != "--no-commit" && -n "$COMMIT_MSG" ]]; then
    FILES_SPACED=$(python3 -c "import json,sys; print(' '.join(json.loads(sys.argv[1])))" "$FILES_JSON")
    cd "$PROJECT_ROOT"
    # shellcheck disable=SC2086
    git add $FILES_SPACED
    git commit -m "$COMMIT_MSG"
    log "committed: ${COMMIT_MSG%%$'\n'*}"
else
    log "skip commit (--no-commit or empty message)"
fi

# ── Remove worktree ────────────────────────────────────────────────────────────
git -C "$PROJECT_ROOT" worktree remove "$WORKTREE_PATH" --force 2>/dev/null \
    && log "worktree removed" \
    || log "WARNING: worktree removal failed (may already be gone)"

# ── Release file claims (atomic) ──────────────────────────────────────────────
python3 << PYEOF
import json, os

path = "$CLAIMS_FILE"
with open(path) as f:
    claims = json.load(f)
claims.get("active", {}).pop("$TASK_ID", None)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(claims, f, indent=2)
os.replace(tmp, path)
print("[worktree-teardown] claims released for $TASK_ID")
PYEOF
