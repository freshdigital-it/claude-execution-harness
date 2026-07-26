#!/usr/bin/env bash
# Compute a per-task-class timeout budget from historical trajectory data,
# instead of one flat global timeout for every task regardless of size.
#
# Usage: task-class-timeout.sh <harness_dir> <class> [default_seconds]
# Stdout: a single integer (seconds).
#
# Method: p95 of past duration_seconds for this class (rows must have a
# duration_seconds field — trajectory-append.sh doesn't require it, master
# SHOULD include it when appending; see SKILL.md Step 8). +20% buffer.
# Falls back to <default_seconds> (or the built-in default table) when there
# isn't enough history (< 3 samples) or no rows carry duration_seconds.

set -euo pipefail

HARNESS_DIR="${1:?usage: task-class-timeout.sh <harness_dir> <class> [default_seconds]}"
CLASS="${2:?class required}"
OVERRIDE_DEFAULT="${3:-}"
TRAJ="$HARNESS_DIR/trajectory.jsonl"

python3 - "$TRAJ" "$CLASS" "$OVERRIDE_DEFAULT" <<'PY'
import json, sys
from pathlib import Path

traj_path, cls, override_default = sys.argv[1], sys.argv[2], sys.argv[3]

# Sane built-in defaults per class (seconds) — used when there's no history yet.
# Roughly aligned with the effort tiers already in the model/effort routing table.
BUILTIN_DEFAULTS = {
    "security-core":   900,
    "business":        600,
    "bugfix":          600,
    "mechanical-fan":  180,
    "refactor":        300,
    "fe-mechanical":   180,
    "fe-component":    600,
    "fe-page":         900,
    "fe-api-wiring":   600,
    "fe-visual":       900,
}
default = int(override_default) if override_default else BUILTIN_DEFAULTS.get(cls, 600)

durations = []
p = Path(traj_path)
if p.exists():
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("class") != cls:
            continue
        d = row.get("duration_seconds")
        if isinstance(d, (int, float)) and d > 0:
            durations.append(d)

if len(durations) < 3:
    print(default)
    sys.exit(0)

durations.sort()
idx = max(0, int(len(durations) * 0.95) - 1)
p95 = durations[idx]
budget = int(p95 * 1.2)
# Never let history push the budget below a sane floor or absurdly high.
budget = max(budget, 60)
budget = min(budget, 3600)
print(budget)
PY
