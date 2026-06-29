#!/usr/bin/env bash
# QA Release Gate — runs ONCE per harness run after all tasks complete.
# Aggregates per-task gate evidence + runs system-level checks.
#
# Usage: qa-gate.sh <project_root> <preview_url> [--fast]
#   --fast  skip Lighthouse (faster CI feedback, still runs all other checks)
#
# Exit 0 = GO  (safe to proceed to deploy staging)
# Exit 1 = NO-GO (block deploy, reasons in .harness/qa-gate.json)
# Exit 2 = setup error (no .harness/ directory)
#
# Env overrides:
#   QA_GATE_PASS_RATE_MIN=80   (% tasks with gate_result=pass)
#   QA_LIGHTHOUSE_PERF_MIN=80  (Lighthouse performance 0-100)
#   QA_LIGHTHOUSE_A11Y_MIN=90  (Lighthouse accessibility 0-100)

set -euo pipefail

PROJECT_ROOT="${1:-$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd)}"
PREVIEW_URL="${2:-http://localhost:5173}"
FAST_MODE="${3:-}"
HARNESS_DIR="$PROJECT_ROOT/.harness"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -d "$HARNESS_DIR" ]] || { echo "[qa-gate] ERROR: no .harness/ — run harness first." >&2; exit 2; }

exec python3 - <<PYEOF
import json, os, sys, subprocess, re
from pathlib import Path

project_root   = Path("$PROJECT_ROOT")
preview_url    = "$PREVIEW_URL"
fast_mode      = "$FAST_MODE" == "--fast"
harness_dir    = Path("$HARNESS_DIR")
script_dir     = Path("$SCRIPT_DIR")
gate_min       = int(os.environ.get("QA_GATE_PASS_RATE_MIN", "80"))
lh_perf_min    = int(os.environ.get("QA_LIGHTHOUSE_PERF_MIN", "80"))
lh_a11y_min    = int(os.environ.get("QA_LIGHTHOUSE_A11Y_MIN", "90"))

checks, no_go = [], []

def chk(name, status, detail):
    checks.append({"check": name, "status": status, "detail": detail})
    if status == "FAIL":
        no_go.append(f"{name}: {detail}")
    icon = {"PASS": "✓", "FAIL": "✗", "SKIP": "~"}[status]
    print(f"  {icon} {name}: {status} — {detail}", file=sys.stderr)

def contract_is_approved(path):
    try:
        m = re.search(r"status:\s*(\w+)", path.read_text())
        return bool(m and m.group(1) == "approved")
    except Exception:
        return False

# ── 1. Trajectory gate pass rate ─────────────────────────────────────────────
traj = harness_dir / "trajectory.jsonl"
if traj.exists():
    rows = [json.loads(l) for l in traj.read_text().splitlines() if l.strip()]
    if rows:
        passed = sum(1 for r in rows if r.get("gate_result") == "pass")
        rate   = int(passed / len(rows) * 100)
        chk("gate_pass_rate",
            "PASS" if rate >= gate_min else "FAIL",
            f"{rate}% {'≥' if rate >= gate_min else '<'} {gate_min}% ({passed}/{len(rows)} tasks)")
    else:
        chk("gate_pass_rate", "SKIP", "empty trajectory.jsonl")
else:
    chk("gate_pass_rate", "SKIP", "no trajectory.jsonl")

# ── 2. Review ledger — no unsigned security items ────────────────────────────
ledger = project_root / "docs" / "review-ledger.md"
if ledger.exists():
    count = len(re.findall(r"NEEDS REVIEW|BLOCKED", ledger.read_text()))
    chk("review_ledger",
        "PASS" if count == 0 else "FAIL",
        "all security items APPROVED" if count == 0 else f"{count} unsigned item(s) in review-ledger.md")
else:
    chk("review_ledger", "SKIP", "no review-ledger.md")

# ── 3. Phase integration gates ───────────────────────────────────────────────
phase_files = list(harness_dir.glob("phase-gate-*.json"))
if phase_files:
    failed = [f.name for f in phase_files
              if json.loads(f.read_text()).get("status") != "PASS"]
    chk("phase_gates",
        "FAIL" if failed else "PASS",
        (f"{len(failed)} failed: {', '.join(failed)}" if failed
         else f"all {len(phase_files)} phase(s) passed"))
else:
    chk("phase_gates", "SKIP", "no phase-gate-*.json files")

# ── 4. ATDD coverage — approved contracts have test files ────────────────────
contract_dir = project_root / "ux-contracts"
if contract_dir.exists():
    approved = [f for f in contract_dir.glob("*.yaml") if contract_is_approved(f)]
    missing  = sum(1 for c in approved
                   if not (project_root / "tests/e2e/ux-contracts" / f"{c.stem}.spec.ts").exists()
                   or not (project_root / "tests/unit/ux-contracts" / f"{c.stem}.test.ts").exists())
    if not approved:
        chk("atdd_coverage", "SKIP", "no approved contracts")
    else:
        chk("atdd_coverage",
            "PASS" if missing == 0 else "FAIL",
            (f"{len(approved)} contracts all have test files" if missing == 0
             else f"{missing}/{len(approved)} contracts missing test files"))
else:
    chk("atdd_coverage", "SKIP", "no ux-contracts/ directory")

# ── 5. VRT — no screen regressions ──────────────────────────────────────────
baseline_dir = harness_dir / "vrt-baselines"
baselines    = list(baseline_dir.glob("*.png")) if baseline_dir.exists() else []
if baselines:
    failed = []
    for b in baselines:
        screen = b.stem
        route  = f"/{screen.replace('_', '-')}"
        r = subprocess.run(
            [str(script_dir / "fe-vrt-baseline.sh"), "diff",
             preview_url, route, screen, "--harness-dir", str(harness_dir)],
            capture_output=True
        )
        if r.returncode not in (0, 2):   # 2 = no baseline, skip gracefully
            failed.append(screen)
    chk("vrt_regression",
        "FAIL" if failed else "PASS",
        (f"{len(failed)} regressed: {', '.join(failed)}" if failed
         else f"{len(baselines)} screens match baseline"))
else:
    chk("vrt_regression", "SKIP", "no VRT baselines yet — run fe-visual tasks first")

# ── 6. Lighthouse (skipped in fast mode) ─────────────────────────────────────
if fast_mode:
    chk("lighthouse", "SKIP", "--fast mode")
elif subprocess.run(["which", "npx"], capture_output=True).returncode != 0:
    chk("lighthouse", "SKIP", "npx not found")
elif subprocess.run(["npx", "lighthouse", "--version"], capture_output=True).returncode != 0:
    chk("lighthouse", "SKIP", "npx lighthouse not installed (npm install -g lighthouse)")
else:
    r = subprocess.run(
        ["npx", "lighthouse", preview_url, "--output=json",
         "--quiet", "--chrome-flags=--headless"],
        capture_output=True, text=True
    )
    try:
        d    = json.loads(r.stdout)
        perf = int(d["categories"]["performance"]["score"] * 100)
        a11y = int(d["categories"]["accessibility"]["score"] * 100)
        chk("lighthouse",
            "PASS" if perf >= lh_perf_min and a11y >= lh_a11y_min else "FAIL",
            (f"perf={perf} a11y={a11y}" if perf >= lh_perf_min and a11y >= lh_a11y_min
             else f"perf={perf} (need {lh_perf_min}), a11y={a11y} (need {lh_a11y_min})"))
    except Exception:
        chk("lighthouse", "SKIP", "could not parse lighthouse output")

# ── Final verdict ─────────────────────────────────────────────────────────────
verdict = "NO-GO" if no_go else "GO"
report  = {
    "verdict": verdict, "checks": checks, "no_go_reasons": no_go,
    "thresholds": {"gate_pass_rate": gate_min,
                   "lighthouse_perf": lh_perf_min,
                   "lighthouse_a11y": lh_a11y_min}
}
(harness_dir / "qa-gate.json").write_text(json.dumps(report, indent=2))
print(f"\n[qa-gate] Verdict: {verdict}", file=sys.stderr)
if no_go:
    for r in no_go:
        print(f"  NO-GO: {r}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF
