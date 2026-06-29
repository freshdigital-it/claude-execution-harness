#!/usr/bin/env bash
# posttooluse-token-ceiling.sh — Opus #3: hard budget ceiling (PostToolUse hook)
#
# Fires after every tool use. Sums tokens_est from current run's trajectory rows.
# If sum >= HARNESS_TOKEN_CEILING → write ceiling-breached flag → master halts.
#
# Configure in .claude/settings.json:
#   "PostToolUse": [{ "hooks": [{ "type": "command",
#     "command": "HARNESS_TOKEN_CEILING=500000 ~/.claude/skills/execution-harness/scripts/hooks/posttooluse-token-ceiling.sh" }] }]
#
# Or set per-project in .harness/config.env:
#   HARNESS_TOKEN_CEILING=300000
#
# Exit 0 = under ceiling (normal)
# Exit 2 = ceiling breached — Claude Code will show the message and can halt the session

set -uo pipefail

# Load config
CONFIG_ENV="${HARNESS_DIR:-.harness}/config.env"
[[ -f "$CONFIG_ENV" ]] && source "$CONFIG_ENV"

CEILING="${HARNESS_TOKEN_CEILING:-}"
HARNESS_DIR="${HARNESS_DIR:-.harness}"
TRAJ="$HARNESS_DIR/trajectory.jsonl"
FLAG="$HARNESS_DIR/ceiling-breached"
RUN_ID="${RUN_ID:-}"

# No ceiling configured = skip silently
[[ -z "$CEILING" ]] && exit 0
# No trajectory yet = nothing to count
[[ ! -f "$TRAJ" ]] && exit 0
# Already breached this run = re-surface
[[ -f "$FLAG" ]] && {
  echo "HARNESS CEILING: token budget already exceeded. Stop the run, fix, then resume."
  exit 2
}

# Sum tokens_est for current run_id from trajectory
SPENT=$(python3 - "$TRAJ" "$RUN_ID" << 'PYEOF'
import json, sys
traj, run_id = sys.argv[1], sys.argv[2]
total = 0
with open(traj) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
            if run_id and row.get("run_id", "") != run_id:
                continue
            total += row.get("tokens_est", 0)
        except Exception:
            pass
print(total)
PYEOF
)

SPENT="${SPENT:-0}"

if [[ "$SPENT" -ge "$CEILING" ]]; then
  echo "$SPENT" > "$FLAG"
  echo "HARNESS CEILING BREACHED: ${SPENT} tokens used ≥ ${CEILING} ceiling."
  echo "Action: checkpoint the current run (ecc:checkpoint), then resume after review."
  echo "To override: delete $FLAG and set a higher HARNESS_TOKEN_CEILING."
  exit 2
fi

# Warn at 80% of ceiling
WARN_AT=$(( CEILING * 80 / 100 ))
if [[ "$SPENT" -ge "$WARN_AT" ]]; then
  echo "HARNESS TOKEN WARNING: ${SPENT}/${CEILING} tokens used ($(( SPENT * 100 / CEILING ))%). Ceiling approaching."
fi

exit 0
