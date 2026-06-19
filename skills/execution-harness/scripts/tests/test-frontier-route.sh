#!/usr/bin/env bash
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/frontier-route.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/.harness"
cat > "$TMP/.harness/frontier.json" <<'JSON'
{"updated":"2026-06-19T11:00:00Z","classes":{
  "business":{"model":"Sonnet","samples":12,"pass_rate":0.95,"revert_rate":0.0,"avg_tokens":14000},
  "bugfix":{"model":"Sonnet","samples":4,"pass_rate":1.0,"revert_rate":0.0,"avg_tokens":9000},
  "security-core":{"model":"Opus","samples":15,"pass_rate":0.9,"revert_rate":0.07,"avg_tokens":22000}
}}
JSON

# business: 12 samples, 0 reverts, 0.95 pass → safe_to_downgrade true
out="$(bash "$SCRIPT" "$TMP/.harness" business)"
echo "$out" | grep -q '"safe_to_downgrade": *true' || fail "business should be safe_to_downgrade=true ($out)"

# bugfix: only 4 samples (<10) → false
out="$(bash "$SCRIPT" "$TMP/.harness" bugfix)"
echo "$out" | grep -q '"safe_to_downgrade": *false' || fail "bugfix (low samples) should be false ($out)"

# security-core: revert_rate>0 → false
out="$(bash "$SCRIPT" "$TMP/.harness" security-core)"
echo "$out" | grep -q '"safe_to_downgrade": *false' || fail "security-core (reverts) should be false ($out)"

# unknown class → false, no crash
out="$(bash "$SCRIPT" "$TMP/.harness" nonexistent)"
echo "$out" | grep -q '"safe_to_downgrade": *false' || fail "unknown class should be false ($out)"

echo "PASS test-frontier-route"
