#!/usr/bin/env bash
# Regression test for the reported production incident (SA-SEC-02) AND the
# subsequent independent review's finding #6: the original version of this
# test manufactured a "Task: <id>" commit directly on the main working tree
# via `git commit` — but SKILL.md explicitly forbids parallel agents from
# running ANY git commands, and only master commits, only AFTER the wait
# phase that triggers reconciliation. So that scenario can only legitimately
# arise from a RESUMED prior session (or a coordinator committing on an
# agent's behalf) — never from the currently-timed-out attempt itself.
#
# This rewrite covers THREE distinct outcomes in one parallel-wait.sh run:
#   task-committed — a "Task: <id>" trailer commit already exists on this
#                    run's branch (simulating: resumed prior session /
#                    coordinator-commit fallback) -> RECONCILED (git-proven,
#                    safe to treat as done).
#   task-worktree  — the REALISTIC failure mode: agent modified files in its
#                    isolated worktree (via worktree-setup.sh, exactly like
#                    a real parallel task) and then went silent — no commit,
#                    no result file -> UNVERIFIED (evidence, but NOT
#                    auto-completed; master must re-verify).
#   task-nothing   — no worktree, no commit, nothing at all -> still
#                    genuinely TIMED_OUT.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
RUN="run-stuck-test"
# worktree-setup.sh creates worktrees at a FIXED path (/tmp/harness-<run_id>-
# <task_id>) OUTSIDE $TMP — since this test deliberately never tears the
# worktree down (that's the point: simulating a hang before teardown), it
# must be cleaned up explicitly or it collides with the next run.
trap 'git -C "$TMP/work" worktree prune 2>/dev/null || true; rm -rf "/tmp/harness-${RUN}-task-worktree"; rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "  ok: $1"; }

BARE="$TMP/remote.git"; WORK="$TMP/work"
git init -q --bare "$BARE"
mkdir -p "$WORK/src"; git init -q "$WORK"
git -C "$WORK" config user.email t@t.local; git -C "$WORK" config user.name t
echo x > "$WORK/f.txt"; echo 'export const a = 1;' > "$WORK/src/a.js"
git -C "$WORK" add -A; git -C "$WORK" commit -q -m init
git -C "$WORK" branch -M main
git -C "$WORK" remote add origin "$BARE"; git -C "$WORK" push -q -u origin main
mkdir -p "$WORK/.harness"
git -C "$WORK" checkout -q -b feature/stuck-test origin/main

# ── task-committed: a commit with the trailer already exists on THIS run's
#    branch (resumed-session / coordinator-commit scenario). No result file.
echo y > "$WORK/g.txt"; git -C "$WORK" add -A
git -C "$WORK" commit -q -m "$(printf 'chore: sa-sec-02\n\nsecurity hardening\n\nTask: task-committed\nGate: PASS')"
COMMIT_SHA=$(git -C "$WORK" rev-parse HEAD)

# ── task-worktree: a REAL isolated worktree, agent-style file modification,
#    deliberately no commit and no result file — the realistic hang.
WP=$(bash "$SCRIPTS/worktree-setup.sh" "$WORK" "$RUN" "task-worktree" "src/a.js" 2>/dev/null)
[ -d "$WP" ] || fail "task-worktree's worktree not created"
echo 'export const b = 2;' >> "$WP/src/a.js"

# ── task-nothing: genuinely never started. No setup at all.

# ── parallel-wait.sh with a short timeout — must not hang the test suite ──────
POLL_INTERVAL=1 bash "$SCRIPTS/parallel-wait.sh" "$WORK" 2 "group-x" task-committed task-worktree task-nothing >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] || fail "expected exit 1 (task-nothing still genuinely stuck, task-worktree unverified), got $RC"
pass "parallel-wait exits 1 (not everything is trustworthy-resolved)"

WAIT_OUT="$WORK/.harness/parallel-wait-group-x.json"
[ -f "$WAIT_OUT" ] || fail "parallel-wait-group-x.json not written"

RECONCILED=$(python3 -c "import json; print(json.load(open('$WAIT_OUT')).get('reconciled', []))")
UNVERIFIED=$(python3 -c "import json; print(json.load(open('$WAIT_OUT')).get('unverified', []))")
TIMED_OUT=$(python3 -c "import json; print(json.load(open('$WAIT_OUT')).get('timed_out', []))")

echo "$RECONCILED" | grep -q "task-committed" || fail "task-committed should be RECONCILED, got: $RECONCILED"
echo "$RECONCILED" | grep -q "task-worktree" && fail "task-worktree must NOT be in reconciled (no commit exists for it)"
pass "task-committed correctly RECONCILED via git evidence"

echo "$UNVERIFIED" | grep -q "task-worktree" || fail "task-worktree should be UNVERIFIED (worktree has uncommitted changes), got: $UNVERIFIED"
echo "$UNVERIFIED" | grep -q "task-committed" && fail "task-committed must NOT be in unverified — it's already git-proven done"
pass "task-worktree correctly UNVERIFIED (real work found, not auto-completed — the realistic hang scenario)"

echo "$TIMED_OUT" | grep -q "task-nothing" || fail "task-nothing should still be timed_out (no evidence anywhere), got: $TIMED_OUT"
echo "$TIMED_OUT" | grep -qE "task-committed|task-worktree" && fail "task-committed/task-worktree must NOT appear in timed_out"
pass "task-nothing correctly remains genuinely stuck (no evidence exists anywhere)"

# ── Verify task-reconcile.sh independently returns the exact commit sha ───────
RECON_JSON=$(bash "$SCRIPTS/task-reconcile.sh" "$WORK" "task-committed")
FOUND_SHA=$(echo "$RECON_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['commit_sha'])")
[ "$FOUND_SHA" = "$COMMIT_SHA" ] || fail "reconcile found wrong commit: $FOUND_SHA != $COMMIT_SHA"
pass "task-reconcile.sh identifies the exact commit that proves completion"

# ── Verify worktree-reconcile.sh independently flags the uncommitted evidence ──
WREC_JSON=$(bash "$SCRIPTS/worktree-reconcile.sh" "$WORK" "task-worktree")
echo "$WREC_JSON" | grep -q "WORK_FOUND_UNVERIFIED" || fail "worktree-reconcile.sh did not flag task-worktree's evidence: $WREC_JSON"
pass "worktree-reconcile.sh independently confirms the uncommitted evidence"

echo "PASS: test-e2e-stuck-agent"
