#!/usr/bin/env bash
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/trajectory-recall.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# empty / missing trajectory → empty array
[ "$(bash "$SCRIPT" "$TMP" "anything" 3)" = "[]" ] || fail "missing trajectory should return []"

cat > "$TMP/trajectory.jsonl" <<'JSONL'
{"task_id":"t-100","class":"security-core","status":"done","gate_result":"pass","title":"invoice payment schedule","reflection":"payment installment split rounding"}
{"task_id":"t-101","class":"business","status":"done","gate_result":"fail","title":"invoice discount lineage","reflection":"discount credit off"}
{"task_id":"t-102","class":"mechanical-fan","status":"done","gate_result":"pass","title":"rename util","reflection":"trivial rename widget"}
JSONL

OUT="$(bash "$SCRIPT" "$TMP" "invoice payment rounding" 3)"

# highest overlap (t-100: invoice+payment+rounding) must rank first
FIRST="$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["task_id"])')"
[ "$FIRST" = "t-100" ] || fail "expected t-100 first, got $FIRST"

# unrelated row (t-102) must be excluded (no keyword overlap)
printf '%s' "$OUT" | python3 -c 'import json,sys; ids=[r["task_id"] for r in json.load(sys.stdin)]; sys.exit(0 if "t-102" not in ids else 1)' \
  || fail "t-102 (no overlap) should be excluded"

# top_k respected
N="$(bash "$SCRIPT" "$TMP" "invoice" 1 | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
[ "$N" = "1" ] || fail "top_k=1 not respected, got $N"

echo "PASS test-trajectory-recall"
