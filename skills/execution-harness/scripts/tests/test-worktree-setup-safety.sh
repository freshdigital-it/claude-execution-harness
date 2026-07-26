#!/usr/bin/env bash
# Regression tests for worktree-setup.sh:
#   - finding #5: bash 3.2 empty-array phantom-arg bug caused two tasks with
#     EMPTY files_touched to spuriously conflict with each other.
#   - finding #11: re-spawning the SAME task_id (after a crashed teardown left
#     a stale claim) must not self-conflict against its own prior claim.
#   - regression guard: a REAL cross-task conflict must still be rejected.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPTS/worktree-setup.sh"
TMP="$(mktemp -d)"
cleanup() {
  git -C "$TMP/work" worktree prune 2>/dev/null || true
  rm -rf /tmp/harness-run-safety-* 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "  ok: $1"; }

WORK="$TMP/work"
mkdir -p "$WORK/src"; git init -q "$WORK"
git -C "$WORK" config user.email t@t.local; git -C "$WORK" config user.name t
echo x > "$WORK/src/a.js"; echo y > "$WORK/src/b.js"
git -C "$WORK" add -A; git -C "$WORK" commit -q -m init
mkdir -p "$WORK/.harness"
RUN="run-safety"

# ── Finding #5: two tasks, BOTH with zero files_touched, must not conflict.
WP1=$(bash "$SCRIPT" "$WORK" "$RUN" "empty-a" 2>/dev/null)
[ -d "$WP1" ] || fail "empty-a worktree not created"
WP2=$(bash "$SCRIPT" "$WORK" "$RUN" "empty-b" 2>/dev/null)
[ -d "$WP2" ] || fail "empty-b worktree failed — likely the bash 3.2 phantom-empty-string-arg bug (empty files_touched spuriously conflicting)"
pass "finding #5 fixed: two tasks with empty files_touched do not spuriously conflict"

CLAIMS="$WORK/.harness/file-claims.json"
COUNT=$(python3 -c "import json; print(len(json.load(open('$CLAIMS'))['active']))")
[ "$COUNT" = "2" ] || fail "expected 2 active claims, got $COUNT"

# ── Finding #11: re-spawn the SAME task_id (simulating a crashed teardown
# that left the claim behind) with the SAME files — must succeed, not
# self-conflict.
git -C "$WORK" worktree remove "$WP1" --force 2>/dev/null || true
WP1_RESPAWN=$(bash "$SCRIPT" "$WORK" "$RUN" "empty-a" 2>/dev/null)
RC=$?
[ "$RC" -eq 0 ] && [ -d "$WP1_RESPAWN" ] || fail "finding #11 NOT fixed: re-spawning task_id 'empty-a' self-conflicted against its own stale claim (exit $RC)"
pass "finding #11 fixed: re-spawning the same task_id does not self-conflict against its own prior claim"

# ── Regression guard: a REAL cross-task conflict (different task_id, same
# file) must still be rejected — the self-conflict fix must not also make
# genuine conflicts silently pass.
bash "$SCRIPT" "$WORK" "$RUN" "claimer" "src/a.js" >/dev/null 2>&1
RC_CLAIM=$?
[ "$RC_CLAIM" -eq 0 ] || fail "setup for conflict-guard test itself failed"
bash "$SCRIPT" "$WORK" "$RUN" "conflicter" "src/a.js" >/dev/null 2>&1
RC_CONFLICT=$?
[ "$RC_CONFLICT" -ne 0 ] || fail "REAL cross-task file conflict was NOT rejected — self-conflict fix over-broadened to allow genuine conflicts"
pass "genuine cross-task file conflict is still correctly rejected"

echo "PASS test-worktree-setup-safety"
