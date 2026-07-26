#!/usr/bin/env bash
# Regression test for the reported production incident: an agent (or the
# coordinator committing on its behalf) commits its work with the proper
# "Task: <id>" trailer, then hangs — no agent-results/<id>.json is ever
# written, no notification ever arrives. Without reconciliation, master
# would wait the full timeout and incorrectly report the task as stuck,
# even though `git log` proves it is done.
#
# This test proves parallel-wait.sh's TIMEOUT path now reconciles against
# git evidence and correctly classifies this as done, not stuck.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "  ok: $1"; }

WORK="$TMP/work"
mkdir -p "$WORK"
git init -q "$WORK"
git -C "$WORK" config user.email t@t.local; git -C "$WORK" config user.name t
echo "x" > "$WORK/f.txt"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m init
mkdir -p "$WORK/.harness"

# ── Simulate the incident: task-002 gets committed (the agent DID finish
#    the gate-passing work) but never reports — no result file, ever. ──────────
echo "y" > "$WORK/g.txt"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "$(printf 'chore: sa-sec-02\n\nsecurity hardening\n\nTask: task-002\nGate: PASS')"
COMMIT_SHA=$(git -C "$WORK" rev-parse HEAD)
# Deliberately do NOT write .harness/agent-results/task-002.json — this is the bug.

# task-001, for contrast, genuinely never started (no commit, no result file).

# ── parallel-wait.sh with a short timeout — must not hang the test suite ──────
POLL_INTERVAL=1 bash "$SCRIPTS/parallel-wait.sh" "$WORK" 2 "group-x" task-001 task-002 >/dev/null 2>&1
RC=$?
[ "$RC" -eq 1 ] || fail "expected exit 1 (task-001 still genuinely stuck), got $RC"
pass "parallel-wait exits 1 (task-001 has no evidence, correctly still stuck)"

# ── Read the reconciliation result ─────────────────────────────────────────────
WAIT_OUT="$WORK/.harness/parallel-wait-group-x.json"
[ -f "$WAIT_OUT" ] || fail "parallel-wait-group-x.json not written"

RECONCILED=$(python3 -c "import json; print(json.load(open('$WAIT_OUT')).get('reconciled', []))")
TIMED_OUT=$(python3 -c "import json; print(json.load(open('$WAIT_OUT')).get('timed_out', []))")

echo "$RECONCILED" | grep -q "task-002" || fail "task-002 should be RECONCILED (git evidence found), got: $RECONCILED"
pass "task-002 correctly RECONCILED via git evidence (the exact reported bug)"

echo "$TIMED_OUT" | grep -q "task-001" || fail "task-001 should still be timed_out (no evidence, no commit), got: $TIMED_OUT"
echo "$TIMED_OUT" | grep -q "task-002" && fail "task-002 must NOT appear in timed_out — it was reconciled"
pass "task-001 correctly remains genuinely stuck (no git evidence exists)"

# ── Verify task-reconcile.sh independently returns the exact commit sha ───────
RECON_JSON=$(bash "$SCRIPTS/task-reconcile.sh" "$WORK" "task-002")
FOUND_SHA=$(echo "$RECON_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['commit_sha'])")
[ "$FOUND_SHA" = "$COMMIT_SHA" ] || fail "reconcile found wrong commit: $FOUND_SHA != $COMMIT_SHA"
pass "task-reconcile.sh identifies the exact commit that proves completion"

echo "PASS: test-e2e-stuck-agent"
