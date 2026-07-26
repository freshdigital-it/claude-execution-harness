#!/usr/bin/env bash
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/agent-register.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

bash "$SCRIPT" "$TMP" "task-001" "agent-abc" "master" >/dev/null || fail "register task-001 failed"
bash "$SCRIPT" "$TMP" "task-002" "agent-xyz" "coordinator:agent-parent" >/dev/null || fail "register task-002 failed"

REGISTRY="$TMP/.harness/agent-registry.json"
[ -f "$REGISTRY" ] || fail "registry file not created"

AID=$(python3 -c "import json; print(json.load(open('$REGISTRY'))['task-001']['agent_id'])")
[ "$AID" = "agent-abc" ] || fail "task-001 agent_id mismatch: $AID"

SPAWNED_BY=$(python3 -c "import json; print(json.load(open('$REGISTRY'))['task-002']['spawned_by'])")
[ "$SPAWNED_BY" = "coordinator:agent-parent" ] || fail "task-002 spawned_by mismatch: $SPAWNED_BY"

# Both entries must coexist — registering task-002 must not clobber task-001.
COUNT=$(python3 -c "import json; print(len(json.load(open('$REGISTRY'))))")
[ "$COUNT" = "2" ] || fail "expected 2 registry entries, got $COUNT"

# Re-registering the same task_id updates in place (idempotent), doesn't duplicate.
bash "$SCRIPT" "$TMP" "task-001" "agent-abc-v2" "master" >/dev/null
AID2=$(python3 -c "import json; print(json.load(open('$REGISTRY'))['task-001']['agent_id'])")
[ "$AID2" = "agent-abc-v2" ] || fail "re-register did not update agent_id"
COUNT2=$(python3 -c "import json; print(len(json.load(open('$REGISTRY'))))")
[ "$COUNT2" = "2" ] || fail "re-register should not add a new entry, got $COUNT2 total"

echo "PASS test-agent-register"
