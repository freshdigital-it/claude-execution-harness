#!/usr/bin/env bash
# Reconcile a task's git-provable completion status — the ground truth that
# doesn't depend on a notification, a result file, or an agent still being
# alive to report.
#
# This answers ONE question: "does a commit with our Commit Convention's
# 'Task: <task_id>' trailer exist on THIS run's branch?" Such a commit is
# proof of a passed gate (Commit Convention: only gate PASS earns a commit),
# so finding one means the task is done even if its completion signal never
# arrived. It is NOT the primary recovery mechanism — under this harness's
# documented workflow, agents never run git commands, only master commits,
# and only after the wait phase. So this script mostly matters for RESUME
# scenarios (a prior session of this same run already committed the task)
# or a coordinator-commits-on-behalf-of-agents pattern. For "agent produced
# files but nothing was ever committed", see worktree-reconcile.sh instead —
# that is the primary check parallel-wait.sh now runs first.
#
# Usage: task-reconcile.sh <project_root> <task_id> [base_ref]
#   base_ref: optional explicit scope boundary (a commit-ish). If omitted,
#             resolved from .harness/run-meta.json's base_sha, else
#             origin/main, else origin/master. If none resolve, this script
#             REFUSES to search (never falls back to unscoped full history —
#             that was the exact bug that produced stale cross-run false
#             positives) and reports NOT_FOUND with a warning.
#
# Security note: every git invocation uses subprocess.run with argv lists
# (never shell=True, never string interpolation into a shell or into Python
# source). Commit subjects/messages are attacker/agent-influenceable content
# and are only ever handled as inert Python string values — never as code.
#
# Verdict (stdout, JSON):
#   DONE_UNREPORTED — a commit with an exact "Task: <task_id>" trailer line
#                      exists in base_ref..HEAD. Treat as done.
#   NOT_FOUND        — no such commit within the scoped range (or no base
#                      could be resolved). Task is either still genuinely
#                      running, never started, or died before committing —
#                      caller must check worktree state / runtime liveness.
#
# Exit 0 = DONE_UNREPORTED, exit 1 = NOT_FOUND, exit 2 = not a git repo.

set -euo pipefail

PROJECT_ROOT="${1:?usage: task-reconcile.sh <project_root> <task_id> [base_ref]}"
TASK_ID="${2:?task_id required}"
BASE_REF="${3:-}"

git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    python3 -c "import json,sys; print(json.dumps({'task_id': sys.argv[1], 'verdict': 'NOT_FOUND', 'error': 'not a git repo'}))" "$TASK_ID"
    exit 2
}

python3 - "$PROJECT_ROOT" "$TASK_ID" "$BASE_REF" <<'PYEOF'
import json, subprocess, sys, os

project_root, task_id, base_ref = sys.argv[1], sys.argv[2], sys.argv[3]

def git(*args):
    return subprocess.run(
        ["git", "-C", project_root, *args],
        capture_output=True, text=True, check=False,
    )

def resolves(ref):
    r = git("rev-parse", "--verify", "--quiet", ref)
    return r.returncode == 0 and r.stdout.strip()

base = None
if base_ref:
    if resolves(base_ref):
        base = base_ref
else:
    meta_path = os.path.join(project_root, ".harness", "run-meta.json")
    if os.path.exists(meta_path):
        try:
            meta = json.loads(open(meta_path).read())
            candidate = meta.get("base_sha")
            if candidate and resolves(candidate):
                base = candidate
        except Exception:
            pass
    if base is None:
        for ref in ("origin/main", "origin/master"):
            r = git("merge-base", ref, "HEAD")
            if r.returncode == 0 and r.stdout.strip():
                base = r.stdout.strip()
                break

if base is None:
    print(json.dumps({
        "task_id": task_id, "verdict": "NOT_FOUND",
        "warning": "no base_ref / run-meta.json base_sha / origin main-or-master reachable — "
                   "refused unscoped search",
    }))
    sys.exit(1)

r = git("rev-list", f"{base}..HEAD")
if r.returncode != 0:
    print(json.dumps({"task_id": task_id, "verdict": "NOT_FOUND", "error": "rev-list failed", "detail": r.stderr.strip()}))
    sys.exit(1)

shas = [s for s in r.stdout.splitlines() if s.strip()]

target_line = f"Task: {task_id}"
found_sha = None
for sha in shas:
    msg = git("log", "-1", "--format=%B", sha).stdout
    # Exact line comparison — no regex engine involved, so task_id content
    # (including regex metacharacters) can never cause a false match/error.
    if any(line.strip() == target_line for line in msg.splitlines()):
        found_sha = sha
        break

if found_sha is None:
    print(json.dumps({"task_id": task_id, "verdict": "NOT_FOUND"}))
    sys.exit(1)

subject = git("log", "-1", "--format=%s", found_sha).stdout.strip()
files = [f for f in git("show", "--name-only", "--format=", found_sha).stdout.splitlines() if f.strip()]

print(json.dumps({
    "task_id": task_id,
    "verdict": "DONE_UNREPORTED",
    "commit_sha": found_sha,
    "commit_subject": subject,
    "files_changed": files,
}))
sys.exit(0)
PYEOF
