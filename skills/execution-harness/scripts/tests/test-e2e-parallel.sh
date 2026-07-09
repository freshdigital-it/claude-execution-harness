#!/usr/bin/env bash
# Integration test: full parallel worktree flow, no LLM required.
# Simulates two agents by writing files directly into their worktrees.
# Exercises: DAG → parallel-group-plan → worktree-setup → agent-result-write →
#            parallel-wait → conflict-check → worktree-teardown → qa-gate.
# Regression-guards the "git worktree add stdout leaks into captured path" bug.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
WORK="$TMP/work"
trap 'git -C "$WORK" worktree prune 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "  ok: $1"; }

command -v git >/dev/null || { echo "SKIP: git not found"; exit 0; }

# ── Seed throwaway repo + bare remote ─────────────────────────────────────────
BARE="$TMP/remote.git"; RUN="run-selftest"
git init -q --bare "$BARE"
mkdir -p "$WORK/src"; git init -q "$WORK"
git -C "$WORK" config user.email t@t.local; git -C "$WORK" config user.name t
printf '# P\n' > "$WORK/README.md"
printf 'export function add(a,b){return a+b;}\n' > "$WORK/src/math.js"
git -C "$WORK" add -A; git -C "$WORK" commit -q -m init; git -C "$WORK" branch -M main
git -C "$WORK" remote add origin "$BARE"; git -C "$WORK" push -q -u origin main
mkdir -p "$WORK/.harness"

# ── P0f branch guard ──────────────────────────────────────────────────────────
git -C "$WORK" checkout -q -b feature/selftest origin/main
[ "$(git -C "$WORK" branch --show-current)" = "feature/selftest" ] || fail "branch setup"
pass "P0f branch setup"

# ── DAG + parallel grouping ───────────────────────────────────────────────────
cat > "$WORK/.harness/plan.dag.json" <<JSON
{"run_id":"$RUN","tasks":[
 {"id":"t1","class":"mechanical-fan","model":"haiku","effort":"low","files_touched":["src/math.js"],"deps":[],"status":"pending"},
 {"id":"t2","class":"mechanical-fan","model":"haiku","effort":"low","files_touched":["README.md"],"deps":[],"status":"pending"}]}
JSON
python3 "$SCRIPTS/parallel-group-plan.py" "$WORK/.harness/plan.dag.json" "$WORK/.harness/parallel-groups.json" >/dev/null || fail "group-plan run"
MAXP=$(python3 -c "import json;print(json.load(open('$WORK/.harness/parallel-groups.json'))['stats']['max_parallelism'])")
[ "$MAXP" = "2" ] || fail "expected max_parallelism=2, got $MAXP"
pass "parallel grouping (2 disjoint → parallel)"

# ── worktree-setup ×2 + REGRESSION: stdout must be a single clean path ────────
WP1=$(bash "$SCRIPTS/worktree-setup.sh" "$WORK" "$RUN" "t1" "src/math.js" 2>/dev/null)
WP2=$(bash "$SCRIPTS/worktree-setup.sh" "$WORK" "$RUN" "t2" "README.md" 2>/dev/null)
[ "$(printf '%s' "$WP1" | wc -l | tr -d ' ')" = "0" ] || fail "WP1 not single-line (stdout leak regression): [$WP1]"
[ -d "$WP1" ] && [ -d "$WP2" ] || fail "worktrees not created"
[ -x "$WP1/.harness-write.sh" ] && [ -x "$WP2/.harness-write.sh" ] || fail ".harness-write.sh not installed"
pass "worktree-setup ×2 (clean path + write-script installed)"

# ── Simulate agents (no LLM): write files + result ────────────────────────────
printf 'export function subtract(a,b){return a-b;}\n' >> "$WP1/src/math.js"
printf '\n## Functions\n- add\n- subtract\n' >> "$WP2/README.md"
bash "$WP1/.harness-write.sh" "$WORK" "t1" "PASS" '["src/math.js"]' "add subtract"
bash "$WP2/.harness-write.sh" "$WORK" "t2" "PASS" '["README.md"]' "docs"

# ── parallel-wait (result files already present → exit 0 fast) ────────────────
POLL_INTERVAL=1 bash "$SCRIPTS/parallel-wait.sh" "$WORK" 30 "group-001" t1 t2 >/dev/null 2>&1 || fail "parallel-wait exit!=0"
pass "parallel-wait detected completion via result files"

# ── conflict check ────────────────────────────────────────────────────────────
python3 - "$WORK" <<'PY' || fail "conflict check flagged a false conflict"
import json,sys
from pathlib import Path
W=Path(sys.argv[1]); seen=set()
for t in ("t1","t2"):
    for f in json.loads((W/".harness/agent-results"/f"{t}.json").read_text())["files_changed_actual"]:
        assert f not in seen, f; seen.add(f)
PY
pass "conflict check (disjoint files)"

# ── teardown ×2 (serialized copy+commit+remove+release) ───────────────────────
bash "$SCRIPTS/worktree-teardown.sh" "$WORK" "$RUN" "t1" "$(printf 'chore: t1\n\nx\n\nTask: t1\nGate: PASS')" >/dev/null 2>&1 || fail "teardown t1"
bash "$SCRIPTS/worktree-teardown.sh" "$WORK" "$RUN" "t2" "$(printf 'chore: t2\n\nx\n\nTask: t2\nGate: PASS')" >/dev/null 2>&1 || fail "teardown t2"
[ "$(git -C "$WORK" rev-list --count HEAD)" = "3" ] || fail "expected 3 commits, got $(git -C "$WORK" rev-list --count HEAD)"
grep -q "subtract" "$WORK/src/math.js" || fail "subtract not copied to main"
[ "$(python3 -c "import json;print(len(json.load(open('$WORK/.harness/file-claims.json'))['active']))")" = "0" ] || fail "claims not released"
git -C "$WORK" worktree list | grep -q "harness-$RUN" && fail "worktrees not removed" || true
pass "teardown ×2 (commits + copy + cleanup + claims released)"

# ── qa-gate --fast → GO ───────────────────────────────────────────────────────
bash "$SCRIPTS/qa-gate.sh" "$WORK" "http://localhost:1" --fast >/dev/null 2>&1
V=$(python3 -c "import json;print(json.load(open('$WORK/.harness/qa-gate.json'))['verdict'])")
[ "$V" = "GO" ] || fail "qa-gate verdict $V (expected GO)"
pass "qa-gate GO"

echo "PASS: test-e2e-parallel"
