#!/usr/bin/env bash
# Reconcile a task's TRUE status from git evidence — the ground truth that
# doesn't depend on a notification, a result file, or an agent still being
# alive to report.
#
# This is the fix for "agent finished and committed, but the completion
# signal never arrived (hang / lost notification / lost result file)":
# a commit on the branch with our Commit Convention's "Task: <task_id>"
# trailer IS proof of a passed gate — that's the only way our harness ever
# produces such a commit (Commit Convention: only gate PASS earns a commit).
#
# Usage: task-reconcile.sh <project_root> <task_id>
#
# Verdict (stdout, JSON):
#   DONE_UNREPORTED — a commit with "Task: <task_id>" trailer exists on the
#                      current branch. Treat as done; no result file needed.
#   NOT_FOUND        — no such commit. Task is either still genuinely running,
#                      never started, or died before committing. Caller must
#                      check runtime liveness (TaskOutput) separately — this
#                      script only answers "is there a git-proven completion?"
#
# Exit 0 = DONE_UNREPORTED, exit 1 = NOT_FOUND, exit 2 = not a git repo.

set -euo pipefail

PROJECT_ROOT="${1:?usage: task-reconcile.sh <project_root> <task_id>}"
TASK_ID="${2:?task_id required}"

git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "{\"task_id\":\"$TASK_ID\",\"verdict\":\"NOT_FOUND\",\"error\":\"not a git repo\"}"
    exit 2
}

# Search current branch history for a commit whose message has an exact
# "Task: <task_id>" line (our Commit Convention footer).
COMMIT_SHA=$(git -C "$PROJECT_ROOT" log --format="%H" --grep="^Task: ${TASK_ID}\$" -n 1 2>/dev/null || true)

if [[ -z "$COMMIT_SHA" ]]; then
    python3 -c "import json; print(json.dumps({'task_id': '$TASK_ID', 'verdict': 'NOT_FOUND'}))"
    exit 1
fi

SUBJECT=$(git -C "$PROJECT_ROOT" log -1 --format="%s" "$COMMIT_SHA")
FILES=$(git -C "$PROJECT_ROOT" show --name-only --format="" "$COMMIT_SHA")

python3 -c "
import json, sys
files = '''$FILES'''.strip().splitlines()
print(json.dumps({
    'task_id': '$TASK_ID',
    'verdict': 'DONE_UNREPORTED',
    'commit_sha': '$COMMIT_SHA',
    'commit_subject': '''$SUBJECT''',
    'files_changed': files,
}))
"
