#!/usr/bin/env bash
# Advisory routing readout for one class. Prints JSON with stats + safe_to_downgrade flag.
# Master still decides — this never changes routing on its own.
# Usage: frontier-route.sh <harness_dir> <class>
set -euo pipefail
HARNESS_DIR="${1:?usage: frontier-route.sh <harness_dir> <class>}"
CLASS="${2:?usage: frontier-route.sh <harness_dir> <class>}"
FRONTIER="$HARNESS_DIR/frontier.json"

MIN_SAMPLES="${FRONTIER_MIN_SAMPLES:-10}"
MIN_PASS="${FRONTIER_MIN_PASS:-0.9}"

if [ ! -f "$FRONTIER" ]; then
  printf '{"class":"%s","known":false,"safe_to_downgrade":false}\n' "$CLASS"
  exit 0
fi

python3 - "$FRONTIER" "$CLASS" "$MIN_SAMPLES" "$MIN_PASS" <<'PY'
import json, sys
frontier, cls, min_n, min_pass = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
data = json.load(open(frontier)).get("classes", {})
c = data.get(cls)
if not c:
    print(json.dumps({"class": cls, "known": False, "safe_to_downgrade": False}))
    sys.exit()
safe = (c.get("samples", 0) >= min_n
        and c.get("revert_rate", 1.0) == 0.0
        and c.get("pass_rate", 0.0) >= min_pass)
print(json.dumps({"class": cls, "known": True, "model": c.get("model"),
                  "samples": c.get("samples"), "pass_rate": c.get("pass_rate"),
                  "revert_rate": c.get("revert_rate"), "avg_tokens": c.get("avg_tokens"),
                  "safe_to_downgrade": bool(safe)}))
PY
