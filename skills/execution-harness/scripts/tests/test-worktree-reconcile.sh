#!/usr/bin/env bash
# Regression tests for worktree-reconcile.sh — the primary reconciliation
# ground truth (finding #6 redesign): does the task's isolated worktree have
# uncommitted evidence of real work? This is what actually happens under the
# harness's documented workflow (agents never run git) when an agent hangs
# after producing real output but before writing its result file.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPTS/worktree-reconcile.sh"
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

# ── NO_CLAIM: no file-claims.json entry at all for this task_id.
OUT_NOCLAIM=$(bash "$SCRIPT" "$WORK" "task-ghost"); RC_NOCLAIM=$?
[ "$RC_NOCLAIM" -eq 1 ] || fail "expected exit 1 for NO_CLAIM, got $RC_NOCLAIM"
echo "$OUT_NOCLAIM" | grep -q "NO_CLAIM" || fail "expected NO_CLAIM verdict, got: $OUT_NOCLAIM"
pass "no claim recorded -> NO_CLAIM"

# ── Real worktree via worktree-setup.sh, no changes made -> NO_CHANGES.
WP=$(bash "$SCRIPTS/worktree-setup.sh" "$WORK" "run-t" "task-clean" "src/a.js" 2>/dev/null)
[ -d "$WP" ] || fail "worktree not created"
OUT_CLEAN=$(bash "$SCRIPT" "$WORK" "task-clean"); RC_CLEAN=$?
[ "$RC_CLEAN" -eq 1 ] || fail "expected exit 1 for NO_CHANGES, got $RC_CLEAN"
echo "$OUT_CLEAN" | grep -q "NO_CHANGES" || fail "expected NO_CHANGES verdict, got: $OUT_CLEAN"
pass "worktree exists but clean -> NO_CHANGES (genuinely stuck, not evidence of work)"

# ── Modify a file in the worktree WITHOUT committing or writing a result
#    file — this is the realistic "agent did work, then went silent" case.
echo 'export const y = 2;' >> "$WP/src/a.js"
OUT_WORK=$(bash "$SCRIPT" "$WORK" "task-clean"); RC_WORK=$?
[ "$RC_WORK" -eq 0 ] || fail "expected exit 0 for WORK_FOUND_UNVERIFIED, got $RC_WORK: $OUT_WORK"
echo "$OUT_WORK" | grep -q "WORK_FOUND_UNVERIFIED" || fail "expected WORK_FOUND_UNVERIFIED verdict, got: $OUT_WORK"
echo "$OUT_WORK" | grep -q "src/a.js" || fail "expected files_changed to list src/a.js, got: $OUT_WORK"
pass "worktree has uncommitted changes -> WORK_FOUND_UNVERIFIED (evidence, NOT auto-completed)"

# ── The main project tree must be untouched by this check — it's read-only
#    observation, never a mutation.
grep -q "export const y" "$WORK/src/a.js" && fail "worktree-reconcile.sh must NOT copy/leak worktree changes into the main tree"
pass "worktree-reconcile.sh is read-only — main tree unaffected"

# ── WORKTREE_MISSING: claim recorded but directory since removed (crash mid-teardown).
rm -rf "$WP"
OUT_MISSING=$(bash "$SCRIPT" "$WORK" "task-clean"); RC_MISSING=$?
[ "$RC_MISSING" -eq 1 ] || fail "expected exit 1 for WORKTREE_MISSING, got $RC_MISSING"
echo "$OUT_MISSING" | grep -q "WORKTREE_MISSING" || fail "expected WORKTREE_MISSING verdict, got: $OUT_MISSING"
pass "worktree directory removed out from under a live claim -> WORKTREE_MISSING, not a crash"

echo "PASS test-worktree-reconcile"
