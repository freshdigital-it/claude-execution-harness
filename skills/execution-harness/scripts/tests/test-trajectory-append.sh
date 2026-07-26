#!/usr/bin/env bash
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/trajectory-append.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# valid row appends one line
bash "$SCRIPT" "$TMP" '{"task_id":"task-001","class":"business","status":"done","gate_result":"pass"}' >/dev/null \
  || fail "valid row rejected"
[ -f "$TMP/trajectory.jsonl" ] || fail "trajectory.jsonl not created"
[ "$(wc -l < "$TMP/trajectory.jsonl")" -eq 1 ] || fail "expected 1 line"

# second valid row appends (not overwrites)
bash "$SCRIPT" "$TMP" '{"task_id":"task-002","class":"bugfix","status":"done","gate_result":"pass"}' >/dev/null
[ "$(wc -l < "$TMP/trajectory.jsonl")" -eq 2 ] || fail "expected 2 lines after second append"

# malformed JSON rejected, file unchanged
if bash "$SCRIPT" "$TMP" '{not json' 2>/dev/null; then fail "malformed JSON accepted"; fi
[ "$(wc -l < "$TMP/trajectory.jsonl")" -eq 2 ] || fail "malformed append mutated file"

# missing required field rejected
if bash "$SCRIPT" "$TMP" '{"task_id":"x","class":"business"}' 2>/dev/null; then fail "missing-field row accepted"; fi

echo "PASS test-trajectory-append"
