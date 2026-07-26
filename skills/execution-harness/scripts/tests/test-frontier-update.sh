#!/usr/bin/env bash
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/frontier-update.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/.harness"
cat > "$TMP/.harness/trajectory.jsonl" <<'JSONL'
{"task_id":"t1","class":"business","model":"Sonnet","status":"done","gate_result":"pass","tokens_est":10000}
{"task_id":"t2","class":"business","model":"Sonnet","status":"failed","gate_result":"fail","tokens_est":12000}
{"task_id":"t3","class":"security-core","model":"Opus","status":"done","gate_result":"pass","tokens_est":20000}
JSONL

bash "$SCRIPT" "$TMP/.harness" >/dev/null || fail "update failed"
[ -f "$TMP/.harness/frontier.json" ] || fail "frontier.json not created"

pr="$(python3 -c 'import json;print(json.load(open("'"$TMP"'/.harness/frontier.json"))["classes"]["business"]["pass_rate"])')"
[ "$pr" = "0.5" ] || fail "business pass_rate expected 0.5 got $pr"
sm="$(python3 -c 'import json;print(json.load(open("'"$TMP"'/.harness/frontier.json"))["classes"]["business"]["samples"])')"
[ "$sm" = "2" ] || fail "business samples expected 2 got $sm"

# idempotent: add one more business pass → samples 3
echo '{"task_id":"t4","class":"business","model":"Sonnet","status":"done","gate_result":"pass","tokens_est":9000}' >> "$TMP/.harness/trajectory.jsonl"
bash "$SCRIPT" "$TMP/.harness" >/dev/null
sm2="$(python3 -c 'import json;print(json.load(open("'"$TMP"'/.harness/frontier.json"))["classes"]["business"]["samples"])')"
[ "$sm2" = "3" ] || fail "after second update business samples expected 3 got $sm2"

echo "PASS test-frontier-update"
