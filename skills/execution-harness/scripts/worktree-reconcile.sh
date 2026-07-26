#!/usr/bin/env bash
# Reconcile a task against its ACTUAL WORKTREE state — the PRIMARY ground
# truth for "agent hung after doing real work but before either committing
# or writing its result file."
#
# Why this exists (and why task-reconcile.sh alone was not enough): this
# harness's own documented workflow forbids agents from running git commands
# — only master commits, and only AFTER the wait phase that triggers
# reconciliation. So a git-log-based check can only ever match a commit from
# a PRIOR run/session, never evidence from the CURRENTLY-timed-out attempt.
# The actual failure mode we need to detect — agent modified files in its
# isolated worktree and then went silent — leaves no git trace at all until
# master's own teardown commits it. This script looks at the worktree
# directly instead.
#
# IMPORTANT — this does NOT prove the gate passed. Unlike a git commit
# (which the Commit Convention guarantees only happens after gate PASS),
# uncommitted worktree changes are UNVERIFIED. Master must re-run the gate
# against the worktree (or ask a human) before treating this as done. NEVER
# silently auto-complete a WORK_FOUND_UNVERIFIED verdict — that would ship
# unverified work, exactly what this harness exists to prevent.
#
# Usage: worktree-reconcile.sh <project_root> <task_id>
#
# Verdict (stdout, JSON):
#   NO_CLAIM               — no active claim / worktree recorded for this
#                             task_id. Nothing to reconcile from worktree state.
#   WORKTREE_MISSING       — claim recorded but the worktree directory no
#                             longer exists on disk (already torn down).
#   NO_CHANGES              — worktree exists, clean (git status --porcelain
#                             empty). Agent produced nothing — genuinely stuck.
#   WORK_FOUND_UNVERIFIED   — worktree has uncommitted changes. Evidence of
#                             real work, but UNGATED. files_changed lists the
#                             porcelain paths. Master must re-verify, not
#                             auto-complete.
#
# Exit 0 = WORK_FOUND_UNVERIFIED, exit 1 = everything else (no usable evidence).

set -euo pipefail

PROJECT_ROOT="${1:?usage: worktree-reconcile.sh <project_root> <task_id>}"
TASK_ID="${2:?task_id required}"
CLAIMS_FILE="$PROJECT_ROOT/.harness/file-claims.json"

python3 - "$PROJECT_ROOT" "$TASK_ID" "$CLAIMS_FILE" <<'PYEOF'
import json, os, subprocess, sys

project_root, task_id, claims_path = sys.argv[1], sys.argv[2], sys.argv[3]

worktree = None
if os.path.exists(claims_path):
    try:
        claims = json.loads(open(claims_path).read())
        entry = claims.get("active", {}).get(task_id)
        if entry:
            worktree = entry.get("worktree")
    except Exception:
        pass

if worktree is None:
    print(json.dumps({"task_id": task_id, "verdict": "NO_CLAIM"}))
    sys.exit(1)

if not os.path.isdir(worktree):
    print(json.dumps({"task_id": task_id, "verdict": "WORKTREE_MISSING", "worktree": worktree}))
    sys.exit(1)

r = subprocess.run(
    ["git", "-C", worktree, "status", "--porcelain"],
    capture_output=True, text=True, check=False,
)
if r.returncode != 0:
    print(json.dumps({"task_id": task_id, "verdict": "WORKTREE_MISSING", "worktree": worktree, "error": r.stderr.strip()}))
    sys.exit(1)

changed = [
    line[3:] for line in r.stdout.splitlines()
    if line.strip() and line[3:] != ".harness-write.sh"
]  # .harness-write.sh is installed by worktree-setup.sh into EVERY fresh
   # worktree as an untracked helper — it always shows up in git status even
   # when the agent hasn't touched a single project file, so it must never
   # count as "evidence of work" on its own.
if not changed:
    print(json.dumps({"task_id": task_id, "verdict": "NO_CHANGES", "worktree": worktree}))
    sys.exit(1)

print(json.dumps({
    "task_id": task_id,
    "verdict": "WORK_FOUND_UNVERIFIED",
    "worktree": worktree,
    "files_changed": changed,
}))
sys.exit(0)
PYEOF
