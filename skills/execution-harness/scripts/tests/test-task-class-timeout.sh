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
# Nearest-rank p95: sorted [100,100,100,100,500], rank=ceil(5*0.95)=5, idx=4 -> p95=500 -> *1.2=600.
# (The old `int(n*0.95)-1` formula gave idx=3 -> p95=100 -> 120, which was actually the
# MEDIAN, not p95 — this value regression-guards the off-by-one fix.)
[ "$V4" = "600" ] || fail "expected p95-derived 600 for business, got $V4"

# A second, more discriminating dataset — old formula and correct formula disagree at n=4
# with DISTINCT values (both landed on "100" above only because 4 of 5 samples happened
# to be equal). Values kept above the 60s floor so the floor clamp can't mask the fix.
rm -f "$TMP/trajectory.jsonl"
for d in 100 200 300 400; do
  echo "{\"task_id\":\"z\",\"class\":\"bugfix\",\"status\":\"done\",\"gate_result\":\"pass\",\"duration_seconds\":$d}" >> "$TMP/trajectory.jsonl"
done
V5=$(bash "$SCRIPT" "$TMP" "bugfix")
# sorted [100,200,300,400], rank=ceil(4*0.95)=4, idx=3 -> p95=400 -> *1.2=480
# (old buggy formula: idx=int(4*0.95)-1=2 -> p95=300 -> *1.2=360 — the median-leaning wrong answer)
[ "$V5" = "480" ] || fail "expected p95-derived 480 (not the old buggy 360) for bugfix, got $V5"

echo "PASS test-task-class-timeout"
