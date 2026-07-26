#!/usr/bin/env bash
# Regression test for finding #10: worktree-teardown.sh's --no-commit
# ("discard") path used to copy the worktree's files into the main project
# tree BEFORE checking the --no-commit flag, so a dead/hung agent's UNGATED
# work was silently imported anyway, only the git commit was skipped. A real
# discard must not touch the main tree at all.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'git -C "$TMP/work" worktree prune 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "  ok: $1"; }

WORK="$TMP/work"
mkdir -p "$WORK/src"; git init -q "$WORK"
git -C "$WORK" config user.email t@t.local; git -C "$WORK" config user.name t
echo 'export const x = 1;' > "$WORK/src/a.js"
git -C "$WORK" add -A; git -C "$WORK" commit -q -m init
mkdir -p "$WORK/.harness"
RUN="run-discard"

WP=$(bash "$SCRIPTS/worktree-setup.sh" "$WORK" "$RUN" "task-dead" "src/a.js" 2>/dev/null)
[ -d "$WP" ] || fail "worktree not created"

# Simulate: agent did (unverified, ungated) work, then died.
echo 'export const HACK = "should never reach main tree";' >> "$WP/src/a.js"
BEFORE_COMMITS=$(git -C "$WORK" rev-list --count HEAD)

bash "$SCRIPTS/worktree-teardown.sh" "$WORK" "$RUN" "task-dead" "" --no-commit >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] || fail "discard teardown exited $RC"

AFTER_COMMITS=$(git -C "$WORK" rev-list --count HEAD)
[ "$BEFORE_COMMITS" = "$AFTER_COMMITS" ] || fail "discard created a commit (expected none)"
pass "no commit created on discard"

grep -q "HACK" "$WORK/src/a.js" && fail "finding #10 NOT fixed: dead agent's ungated content was copied into the main tree despite --no-commit"
pass "finding #10 fixed: --no-commit is a REAL discard — worktree content never touched the main tree"

[ -d "$WP" ] && fail "worktree should have been removed"
pass "worktree removed"

COUNT=$(python3 -c "import json; print(len(json.load(open('$WORK/.harness/file-claims.json'))['active']))")
[ "$COUNT" = "0" ] || fail "claim not released after discard, active=$COUNT"
pass "claim released after discard"

echo "PASS test-worktree-teardown-discard"
