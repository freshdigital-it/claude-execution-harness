#!/usr/bin/env bash
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/task-class-timeout.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP"

# No trajectory at all -> falls back to the builtin per-class default.
V=$(bash "$SCRIPT" "$TMP" "security-core")
[ "$V" = "900" ] || fail "expected builtin default 900 for security-core, got $V"

# Unknown class with no history -> generic fallback (600).
V2=$(bash "$SCRIPT" "$TMP" "totally-unknown-class")
[ "$V2" = "600" ] || fail "expected generic fallback 600, got $V2"

# Explicit override default respected when no history.
V3=$(bash "$SCRIPT" "$TMP" "business" "42")
[ "$V3" = "42" ] || fail "expected override default 42, got $V3"

# With history (>=3 samples of the right class) -> p95 * 1.2, ignoring other classes.
for d in 100 100 100 100 500; do
  echo "{\"task_id\":\"x\",\"class\":\"business\",\"status\":\"done\",\"gate_result\":\"pass\",\"duration_seconds\":$d}" >> "$TMP/trajectory.jsonl"
done
echo '{"task_id":"y","class":"fe-page","status":"done","gate_result":"pass","duration_seconds":9999}' >> "$TMP/trajectory.jsonl"

V4=$(bash "$SCRIPT" "$TMP" "business")
# sorted [100,100,100,100,500], idx=int(5*0.95)-1=3 -> p95=100 -> *1.2=120
[ "$V4" = "120" ] || fail "expected p95-derived 120 for business, got $V4"

echo "PASS test-task-class-timeout"
