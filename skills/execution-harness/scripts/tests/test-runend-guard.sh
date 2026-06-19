#!/usr/bin/env bash
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/../hooks" && pwd)/harness-runend-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# Helper: run hook with CLAUDE_PROJECT_DIR=$TMP
run_hook() { echo '{}' | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK"; }

# Case A: no .harness/ → exit 0, no block
out="$(run_hook)"; rc=$?
[ "$rc" -eq 0 ] || fail "no-harness should exit 0"
echo "$out" | grep -q '"decision":"block"' && fail "no-harness should not block"

# Case B: 2 done tasks, 0 trajectory rows → block
mkdir -p "$TMP/.harness"
cat > "$TMP/.harness/plan.dag.json" <<'JSON'
{"tasks":[{"id":"t1","status":"done"},{"id":"t2","status":"done"}]}
JSON
out="$(run_hook)"
echo "$out" | grep -q '"decision":"block"' || fail "incomplete trajectory should block"

# Case C: 2 done tasks, 2 rows, but no run-report → block
printf '%s\n%s\n' '{"task_id":"t1"}' '{"task_id":"t2"}' > "$TMP/.harness/trajectory.jsonl"
out="$(run_hook)"
echo "$out" | grep -q '"decision":"block"' || fail "missing run-report should block"

# Case D: 2 done, 2 rows, run-report present → exit 0, no block
touch "$TMP/run-report-20260619.md"
out="$(run_hook)"; rc=$?
[ "$rc" -eq 0 ] || fail "complete run should exit 0"
echo "$out" | grep -q '"decision":"block"' && fail "complete run should not block"

echo "PASS test-runend-guard"
