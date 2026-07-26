#!/usr/bin/env bash
# Serialize a completed parallel task: copy changed files, commit, remove worktree.
#
# Usage:
#   worktree-teardown.sh <project_root> <run_id> <task_id> "<commit_msg>"
#   worktree-teardown.sh <project_root> <run_id> <task_id> "" --no-commit  (DISCARD — hung-agent recovery / gate FAIL)
#
# Steps:
#   1. Read file claims from .harness/file-claims.json
#   2. If --no-commit: DISCARD. The copy step is SKIPPED ENTIRELY — the
#      worktree's uncommitted changes never touch PROJECT_ROOT. (A prior
#      version ran the copy loop unconditionally before checking this flag,
#      so "discard" actually imported a dead/hung agent's ungated files into
#      the main tree, only skipping the git commit — contradicting the
#      documented claim that discarding "loses no validated work". This is
#      the fix: nothing not already gate-PASSed and committed ever reaches
#      the main working tree.)
#      Else: copy changed files from worktree to main project dir, then
#      git add + commit.
#   3. Remove worktree
#   4. Release file claims (atomic)
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

DISCARD=0
[[ "$NO_COMMIT" == "--no-commit" ]] && DISCARD=1

# ── Read claims (argv-based — task_id/paths never interpolated into Python
#    source text, only ever handled as inert string values) ─────────────────
TASK_INFO=$(python3 - "$CLAIMS_FILE" "$TASK_ID" <<'PYEOF'
import json, sys
claims_path, task_id = sys.argv[1], sys.argv[2]
with open(claims_path) as f:
    claims = json.load(f)
task = claims["active"][task_id]
print(task["worktree"])
print(json.dumps(task["files"]))
PYEOF
)

WORKTREE_PATH=$(echo "$TASK_INFO" | head -1)
FILES_JSON=$(echo "$TASK_INFO" | tail -1)

log "task=$TASK_ID worktree=$WORKTREE_PATH discard=${DISCARD}"

if [[ "$DISCARD" -eq 1 ]]; then
    log "DISCARD — worktree changes are NOT copied into $PROJECT_ROOT (nothing gate-PASSed is lost; anything else was never validated)"
else
    # ── Copy changed files from worktree → main project ───────────────────────
    python3 - "$FILES_JSON" "$WORKTREE_PATH" "$PROJECT_ROOT" <<'PYEOF'
import json, shutil, os, sys

files_json, src_root, dst_root = sys.argv[1], sys.argv[2], sys.argv[3]
files = json.loads(files_json)

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

    # ── Commit in main project (serialized by master) ──────────────────────────
    if [[ -n "$COMMIT_MSG" ]]; then
        cd "$PROJECT_ROOT"
        # NUL-delimited so filenames containing spaces survive intact
        # (the prior space-joined+unquoted form word-split on such names).
        python3 -c "import json,sys; sys.stdout.write('\0'.join(json.loads(sys.argv[1])))" "$FILES_JSON" | xargs -0 git add --
        git commit -m "$COMMIT_MSG"
        log "committed: ${COMMIT_MSG%%$'\n'*}"
    else
        log "skip commit (empty message)"
    fi
fi

# ── Remove worktree ────────────────────────────────────────────────────────────
git -C "$PROJECT_ROOT" worktree remove "$WORKTREE_PATH" --force 2>/dev/null \
    && log "worktree removed" \
    || log "WARNING: worktree removal failed (may already be gone)"

# ── Release file claims (atomic) ──────────────────────────────────────────────
python3 - "$CLAIMS_FILE" "$TASK_ID" <<'PYEOF'
import json, os, sys, tempfile

path, task_id = sys.argv[1], sys.argv[2]
with open(path) as f:
    claims = json.load(f)
claims.get("active", {}).pop(task_id, None)
d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".file-claims.", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(claims, f, indent=2)
os.replace(tmp, path)
print(f"[worktree-teardown] claims released for {task_id}")
PYEOF
