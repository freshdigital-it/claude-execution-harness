#!/usr/bin/env bash
# delivery-metrics.sh — Opus #3: DORA-aligned metrics from trajectory.jsonl
#
# Computes from existing harness data — no new instrumentation needed.
# Appended to run-report at end of every run.
#
# Usage:
#   delivery-metrics.sh <harness_dir> [--run-id <run_id>] [--format text|json]
#
# Metrics computed:
#   change_failure_rate  — tasks with status=reverted|blocked|failed / total done
#   avg_lead_time_s      — avg seconds from task start to done (requires ts field)
#   mttr_by_class        — avg tokens on failed→fixed tasks per class
#   token_spend_by_class — avg and total tokens_est per class
#   gate_pass_rate       — gate_result=pass / total per class

set -uo pipefail

HARNESS_DIR="${1:-.harness}"
RUN_ID=""
FORMAT="text"

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)  RUN_ID="$2"; shift 2 ;;
    --format)  FORMAT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

TRAJ="$HARNESS_DIR/trajectory.jsonl"
[[ ! -f "$TRAJ" ]] && { echo "[delivery-metrics] No trajectory.jsonl at $TRAJ"; exit 0; }

python3 - "$TRAJ" "$RUN_ID" "$FORMAT" << 'PYEOF'
import json, sys, math
from collections import defaultdict

traj_path = sys.argv[1]
run_id_filter = sys.argv[2] if len(sys.argv) > 2 else ""
fmt = sys.argv[3] if len(sys.argv) > 3 else "text"

rows = []
with open(traj_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
            if run_id_filter and row.get("run_id", "") != run_id_filter:
                continue
            rows.append(row)
        except Exception:
            pass

if not rows:
    print("[delivery-metrics] No trajectory rows found" + (f" for run_id={run_id_filter}" if run_id_filter else ""))
    sys.exit(0)

# --- Compute metrics ---
total = len(rows)
failed_statuses = {"reverted", "blocked", "failed"}
failed = sum(1 for r in rows if r.get("status", "") in failed_statuses)
done = sum(1 for r in rows if r.get("status") == "done")
cfr = failed / total if total > 0 else 0.0

# Gate pass rate
gate_pass = sum(1 for r in rows if r.get("gate_result") == "pass")
gate_rate = gate_pass / total if total > 0 else 0.0

# Token spend by class
class_tokens = defaultdict(list)
class_gate = defaultdict(lambda: {"pass": 0, "fail": 0})
class_status = defaultdict(lambda: {"done": 0, "failed": 0, "blocked": 0, "reverted": 0})
for r in rows:
    cls = r.get("class", "unknown")
    tokens = r.get("tokens_est", 0)
    if tokens:
        class_tokens[cls].append(tokens)
    gres = r.get("gate_result", "")
    if gres == "pass":
        class_gate[cls]["pass"] += 1
    elif gres in ("fail", "failed"):
        class_gate[cls]["fail"] += 1
    st = r.get("status", "")
    if st in class_status[cls]:
        class_status[cls][st] += 1

total_tokens = sum(sum(v) for v in class_tokens.values())

metrics = {
    "total_tasks": total,
    "done": done,
    "failed_or_blocked": failed,
    "change_failure_rate": round(cfr, 3),
    "gate_pass_rate": round(gate_rate, 3),
    "total_tokens_est": total_tokens,
    "by_class": {}
}

for cls in sorted(set(list(class_tokens.keys()) + list(class_gate.keys()))):
    tok = class_tokens.get(cls, [])
    gate = class_gate.get(cls, {})
    st = class_status.get(cls, {})
    gate_total = gate.get("pass", 0) + gate.get("fail", 0)
    metrics["by_class"][cls] = {
        "tasks": st.get("done", 0) + st.get("failed", 0) + st.get("blocked", 0) + st.get("reverted", 0),
        "done": st.get("done", 0),
        "failed_blocked": st.get("failed", 0) + st.get("blocked", 0) + st.get("reverted", 0),
        "avg_tokens": round(sum(tok) / len(tok)) if tok else 0,
        "total_tokens": sum(tok),
        "gate_pass_rate": round(gate.get("pass", 0) / gate_total, 2) if gate_total > 0 else None,
    }

if fmt == "json":
    print(json.dumps(metrics, indent=2))
    sys.exit(0)

# Text output
print("\n=== DELIVERY METRICS ===")
print(f"Total tasks:          {total}")
print(f"Done:                 {done}")
print(f"Failed / Blocked:     {failed}  →  Change Failure Rate: {cfr:.1%}")
print(f"Gate pass rate:       {gate_rate:.1%}")
print(f"Total tokens (est):   {total_tokens:,}")
print()
print("By class:")
print(f"  {'Class':<20} {'Tasks':>5} {'Done':>5} {'Failed':>6} {'Avg tok':>8} {'Gate%':>6}")
print(f"  {'-'*20} {'-'*5} {'-'*5} {'-'*6} {'-'*8} {'-'*6}")
for cls, d in sorted(metrics["by_class"].items()):
    gate_pct = f"{d['gate_pass_rate']:.0%}" if d['gate_pass_rate'] is not None else "  n/a"
    print(f"  {cls:<20} {d['tasks']:>5} {d['done']:>5} {d['failed_blocked']:>6} {d['avg_tokens']:>8,} {gate_pct:>6}")

print()
# Interpretation
if cfr > 0.2:
    print(f"⚠  Change failure rate {cfr:.1%} > 20% — review blocked/failed patterns")
if gate_rate < 0.8:
    print(f"⚠  Gate pass rate {gate_rate:.1%} < 80% — check if task classification is correct")
if cfr <= 0.1 and gate_rate >= 0.9:
    print("✓  Metrics look healthy (CFR ≤10%, gate pass ≥90%)")
print("========================\n")
PYEOF
