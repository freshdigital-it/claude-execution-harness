#!/usr/bin/env bash
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/agent-register.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "  ok: $1"; }

bash "$SCRIPT" "$TMP" "task-001" "agent-abc" "master" "run-x" >/dev/null || fail "register task-001 failed"
bash "$SCRIPT" "$TMP" "task-002" "agent-xyz" "coordinator:agent-parent" "run-x" >/dev/null || fail "register task-002 failed"

AGENTS_DIR="$TMP/.harness/agents"
[ -f "$AGENTS_DIR/task-001.json" ] || fail "task-001.json not created"
[ -f "$AGENTS_DIR/task-002.json" ] || fail "task-002.json not created"

AID=$(python3 -c "import json; print(json.load(open('$AGENTS_DIR/task-001.json'))['agent_id'])")
[ "$AID" = "agent-abc" ] || fail "task-001 agent_id mismatch: $AID"

SPAWNED_BY=$(python3 -c "import json; print(json.load(open('$AGENTS_DIR/task-002.json'))['spawned_by'])")
[ "$SPAWNED_BY" = "coordinator:agent-parent" ] || fail "task-002 spawned_by mismatch: $SPAWNED_BY"

RUN_ID=$(python3 -c "import json; print(json.load(open('$AGENTS_DIR/task-001.json'))['run_id'])")
[ "$RUN_ID" = "run-x" ] || fail "task-001 run_id mismatch: $RUN_ID"
pass "two distinct task_ids register as two distinct files, run_id stamped"

# Re-registering the same task_id updates in place (idempotent), doesn't duplicate.
bash "$SCRIPT" "$TMP" "task-001" "agent-abc-v2" "master" "run-x" >/dev/null
AID2=$(python3 -c "import json; print(json.load(open('$AGENTS_DIR/task-001.json'))['agent_id'])")
[ "$AID2" = "agent-abc-v2" ] || fail "re-register did not update agent_id"
COUNT2=$(ls "$AGENTS_DIR" | wc -l | tr -d ' ')
[ "$COUNT2" = "2" ] || fail "re-register should not add a new file, got $COUNT2 total"
pass "re-registering the same task_id updates in place, no duplicate file"

# run_id defaults from .harness/run-meta.json when not passed explicitly.
mkdir -p "$TMP/.harness"
echo '{"run_id":"run-from-meta","base_sha":"deadbeef"}' > "$TMP/.harness/run-meta.json"
bash "$SCRIPT" "$TMP" "task-003" "agent-def" "master" >/dev/null
RUN_ID3=$(python3 -c "import json; print(json.load(open('$AGENTS_DIR/task-003.json'))['run_id'])")
[ "$RUN_ID3" = "run-from-meta" ] || fail "expected run_id to default from run-meta.json, got $RUN_ID3"
pass "run_id defaults from run-meta.json when omitted"

# ── Concurrency race (finding #2): the old single-shared-JSON design lost
# registrations under concurrent writes (12-19/30 observed in testing). The
# new per-task-file design must land ALL of N concurrent DIFFERENT task_ids
# with no loss, since there is no shared read-modify-write state.
CTMP="$(mktemp -d)"
N=30
pids=()
for i in $(seq 1 "$N"); do
  bash "$SCRIPT" "$CTMP" "ctask-$i" "cagent-$i" "master" "run-c" >/dev/null 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done

LANDED=$(ls "$CTMP/.harness/agents" 2>/dev/null | wc -l | tr -d ' ')
[ "$LANDED" = "$N" ] || fail "concurrency race: expected $N registry files, got $LANDED (data loss under concurrent registration)"
pass "concurrency: $N concurrent registrations of DIFFERENT task_ids, 0 lost (race fixed)"
rm -rf "$CTMP"

echo "PASS test-agent-register"
