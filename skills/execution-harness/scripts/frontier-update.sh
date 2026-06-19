#!/usr/bin/env bash
# Recompute frontier.json from the FULL trajectory.jsonl (idempotent over the corpus).
# Usage: frontier-update.sh <harness_dir>
set -euo pipefail
HARNESS_DIR="${1:?usage: frontier-update.sh <harness_dir>}"
TRAJ="$HARNESS_DIR/trajectory.jsonl"
OUT="$HARNESS_DIR/frontier.json"
[ -f "$TRAJ" ] || { echo "frontier-update: no trajectory.jsonl, nothing to do"; exit 0; }

python3 - "$TRAJ" "$OUT" <<'PY'
import json, sys, datetime
traj, out = sys.argv[1], sys.argv[2]
agg = {}
with open(traj) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        cls = r.get("class")
        if not cls:
            continue
        a = agg.setdefault(cls, {"model": r.get("model"), "samples": 0,
                                 "passes": 0, "reverts": 0, "tok": 0})
        a["samples"] += 1
        if r.get("gate_result") == "pass":
            a["passes"] += 1
        if r.get("status") in ("reverted", "blocked"):
            a["reverts"] += 1
        a["tok"] += int(r.get("tokens_est") or 0)
        a["model"] = r.get("model") or a["model"]

classes = {}
for cls, a in agg.items():
    n = a["samples"]
    classes[cls] = {
        "model": a["model"],
        "samples": n,
        "pass_rate": round(a["passes"] / n, 3) if n else 0.0,
        "revert_rate": round(a["reverts"] / n, 3) if n else 0.0,
        "avg_tokens": int(a["tok"] / n) if n else 0,
    }
json.dump({"updated": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
           "classes": classes}, open(out, "w"), indent=2)
print("frontier-update: %d classes" % len(classes))
PY
