#!/usr/bin/env bash
# Regression tests for task-reconcile.sh's redesign:
#   - finding #1 (RCE): commit subject was interpolated into Python SOURCE text.
#   - finding #3 (stale cross-run false positive): unscoped git-log search matched
#     commits from before this run's branch even existed.
#   - finding #4 (regex injection): task_id was interpolated into a --grep pattern.
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/task-reconcile.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "  ok: $1"; }

BARE="$TMP/remote.git"; WORK="$TMP/work"
git init -q --bare "$BARE"
mkdir -p "$WORK"; git init -q "$WORK"
git -C "$WORK" config user.email t@t.local; git -C "$WORK" config user.name t
echo x > "$WORK/f.txt"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m init
git -C "$WORK" branch -M main
git -C "$WORK" remote add origin "$BARE"; git -C "$WORK" push -q -u origin main

# ── Finding #3 regression: a "Task: task-old" commit exists BEFORE the new
# run's branch is cut (simulating a prior run's leftover trailer already
# merged to main). It must NOT be found once we branch off from here —
# it's in the base, not in base..HEAD.
echo y > "$WORK/old.txt"; git -C "$WORK" add -A
git -C "$WORK" commit -q -m "$(printf 'chore: prior run\n\nTask: task-old\nGate: PASS')"
git -C "$WORK" push -q origin main

git -C "$WORK" checkout -q -b feature/newrun origin/main

OUT_OLD=$(bash "$SCRIPT" "$WORK" "task-old"); RC_OLD=$?
[ "$RC_OLD" -eq 1 ] || fail "task-old (pre-branch commit) should be NOT_FOUND when scoped, got exit $RC_OLD: $OUT_OLD"
echo "$OUT_OLD" | grep -q "NOT_FOUND" || fail "expected NOT_FOUND verdict for stale pre-branch commit, got: $OUT_OLD"
pass "finding #3 fixed: commit predating this run's branch is correctly NOT matched (no stale cross-run false positive)"

# ── Now commit "Task: task-001" ON this new branch — must be found, scoped correctly.
echo z > "$WORK/new.txt"; git -C "$WORK" add -A
git -C "$WORK" commit -q -m "$(printf 'chore: this run\n\nreal work\n\nTask: task-001\nGate: PASS')"
COMMIT_SHA=$(git -C "$WORK" rev-parse HEAD)

OUT=$(bash "$SCRIPT" "$WORK" "task-001"); RC=$?
[ "$RC" -eq 0 ] || fail "expected exit 0 (DONE_UNREPORTED) for task-001, got $RC: $OUT"
FOUND_SHA=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['commit_sha'])")
[ "$FOUND_SHA" = "$COMMIT_SHA" ] || fail "found wrong commit: $FOUND_SHA != $COMMIT_SHA"
pass "commit on THIS run's branch is correctly found and scoped"

# ── Finding #4 regression: task_id containing regex metacharacters must not
# crash or false-match — exact line comparison, no regex engine involved.
echo w > "$WORK/meta.txt"; git -C "$WORK" add -A
git -C "$WORK" commit -q -m "$(printf 'chore: metachar task\n\nTask: task[weird].x\nGate: PASS')"
OUT_META=$(bash "$SCRIPT" "$WORK" 'task[weird].x'); RC_META=$?
[ "$RC_META" -eq 0 ] || fail "expected metachar task_id to be found (not crash on regex chars), got $RC_META: $OUT_META"
echo "$OUT_META" | grep -q "DONE_UNREPORTED" || fail "expected DONE_UNREPORTED for metachar task_id"
pass "finding #4 fixed: task_id with regex metacharacters matches exactly, no crash/false-positive"

# A DIFFERENT task_id that only differs by what would be regex-significant
# chars must NOT false-match (proves it's exact-line, not substring/regex).
OUT_NOMATCH=$(bash "$SCRIPT" "$WORK" 'task.weird.x'); RC_NOMATCH=$?
[ "$RC_NOMATCH" -eq 1 ] || fail "task.weird.x (different id) should NOT match task[weird].x's commit, got $RC_NOMATCH"
pass "no false-positive from regex-metachar confusion between distinct task_ids"

# ── Finding #1 regression: a crafted commit subject attempting Python source
# injection must be handled as inert data, never executed. subprocess.run is
# used with argv lists throughout (never shell=True, never string-interpolated
# into Python source) — this proves it end-to-end via a real crafted commit.
PWNED_MARKER="$TMP/pwned_marker"
rm -f "$PWNED_MARKER"
PAYLOAD="'''+__import__('os').system('touch $PWNED_MARKER')+'''"
echo v > "$WORK/inj.txt"; git -C "$WORK" add -A
git -C "$WORK" commit -q -m "$(printf 'chore: %s\n\nTask: task-inject\nGate: PASS' "$PAYLOAD")"

OUT_INJ=$(bash "$SCRIPT" "$WORK" "task-inject"); RC_INJ=$?
[ -f "$PWNED_MARKER" ] && fail "RCE: injected payload EXECUTED (marker file was created) — task-reconcile.sh is vulnerable"
[ "$RC_INJ" -eq 0 ] || fail "expected exit 0 (DONE_UNREPORTED) even with a hostile commit subject, got $RC_INJ: $OUT_INJ"
echo "$OUT_INJ" | python3 -c "import json,sys; json.load(sys.stdin)" || fail "output is not valid JSON: $OUT_INJ"
pass "finding #1 fixed: hostile commit subject handled as inert data, never executed, output still valid JSON"

# ── not a git repo → exit 2, no crash
NOTGIT="$TMP/notgit"; mkdir -p "$NOTGIT"
bash "$SCRIPT" "$NOTGIT" "task-001" >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "expected exit 2 for non-git-repo"
pass "non-git-repo path exits 2 cleanly"

echo "PASS test-task-reconcile"
