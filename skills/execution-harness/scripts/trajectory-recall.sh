#!/usr/bin/env bash
# Ranked lexical recall over past task trajectories.
#
# This is the DETERMINISTIC FALLBACK for plan-time learning recall. The master
# should FIRST try semantic recall via agentdb_pattern_search (MCP). Only when
# that MCP is unavailable does it run this script — which still beats a blind grep
# by ranking past rows on keyword overlap with the query (title + reflection).
#
# Usage: trajectory-recall.sh <harness_dir> "<query text>" [top_k]
# Stdout: JSON array of up to top_k most-relevant past rows (score-ordered).

set -euo pipefail

HARNESS_DIR="${1:?usage: trajectory-recall.sh <harness_dir> \"<query>\" [top_k]}"
QUERY="${2:?query required}"
TOP_K="${3:-3}"
TRAJ="$HARNESS_DIR/trajectory.jsonl"

[[ -f "$TRAJ" ]] || { echo "[]"; exit 0; }

python3 - "$TRAJ" "$QUERY" "$TOP_K" <<'PY'
import json, re, sys
from pathlib import Path

traj, query, top_k = sys.argv[1], sys.argv[2], int(sys.argv[3])

STOP = set("the a an of to in on for and or is with by at from into task add fix".split())
def toks(s):
    return {w for w in re.findall(r"[a-z0-9]+", (s or "").lower()) if w not in STOP and len(w) > 2}

q = toks(query)
rows = []
for line in Path(traj).read_text().splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
    except Exception:
        continue
    text = " ".join(str(r.get(k, "")) for k in ("title", "reflection", "note", "class"))
    overlap = q & toks(text)
    if not overlap:
        continue
    # score: overlap size, tie-broken by whether it was a failure (failures more instructive)
    score = len(overlap) + (0.5 if r.get("gate_result") not in ("pass", "PASS") else 0)
    rows.append((score, {
        "task_id": r.get("task_id"),
        "class": r.get("class"),
        "gate_result": r.get("gate_result"),
        "reflection": (r.get("reflection") or r.get("note") or "")[:200],
        "matched": sorted(overlap),
    }))

rows.sort(key=lambda x: x[0], reverse=True)
print(json.dumps([r for _, r in rows[:top_k]], indent=2))
PY
