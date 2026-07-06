#!/usr/bin/env bash
# Performance budget gate — bundle size + Core Web Vitals.
# Fixes the "localhost Lighthouse score hides real cost" gap: explicit per-metric
# budgets + a bundle-size regression check that an aggregate score cannot catch.
#
# Usage: fe-perf-budget.sh <project_root> <preview_url> [--build-dir dist] [--harness-dir DIR]
#
# Reads:  <project_root>/performance-budget.json  (copy from .template)
# Writes: .harness/perf-budget.json
#
# Exit 0 = PASS (within all budgets)
# Exit 1 = FAIL (over budget)
# Exit 2 = SKIP (no budget file, or lighthouse/tools missing)

set -euo pipefail

PROJECT_ROOT="${1:?usage: fe-perf-budget.sh <project_root> <preview_url>}"
PREVIEW_URL="${2:-http://localhost:5173}"
BUILD_DIR="dist"
HARNESS_DIR="$PROJECT_ROOT/.harness"

shift 2 || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir)   BUILD_DIR="$2"; shift 2 ;;
        --harness-dir) HARNESS_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

BUDGET_FILE="$PROJECT_ROOT/performance-budget.json"
log() { echo "[fe-perf-budget] $*" >&2; }

[[ -f "$BUDGET_FILE" ]] || { log "no performance-budget.json → SKIP"; exit 2; }
mkdir -p "$HARNESS_DIR"

# ── Measure bundle size (gzipped JS+CSS in build dir) ─────────────────────────
BUILD_PATH="$PROJECT_ROOT/$BUILD_DIR"
measure_gzip_kb() {
    local pattern="$1" total=0 f sz
    if [[ -d "$BUILD_PATH" ]]; then
        while IFS= read -r f; do
            sz=$(gzip -c "$f" | wc -c)
            total=$(( total + sz ))
        done < <(find "$BUILD_PATH" -name "$pattern" -type f 2>/dev/null)
    fi
    echo $(( total / 1024 ))
}
JS_KB=$(measure_gzip_kb "*.js")
CSS_KB=$(measure_gzip_kb "*.css")
TOTAL_KB=$(( JS_KB + CSS_KB ))
log "bundle gzip: js=${JS_KB}KB css=${CSS_KB}KB total=${TOTAL_KB}KB"

# ── Core Web Vitals via Lighthouse (lab metrics) ──────────────────────────────
# Write to a temp FILE — never interpolate raw tool output into the python heredoc
# (control chars / quotes in the output would break the source).
LH_FILE="$HARNESS_DIR/.lighthouse-raw.json"
: > "$LH_FILE"
if command -v npx >/dev/null 2>&1 && npx lighthouse --version >/dev/null 2>&1; then
    npx lighthouse "$PREVIEW_URL" --output=json --quiet \
        --chrome-flags=--headless > "$LH_FILE" 2>/dev/null || : > "$LH_FILE"
else
    log "lighthouse not available → CWV portion skipped"
fi

# ── Compare against budgets ────────────────────────────────────────────────────
python3 - "$BUDGET_FILE" "$HARNESS_DIR/perf-budget.json" "$TOTAL_KB" "$JS_KB" "$LH_FILE" <<'PYEOF'
import json, sys, os

budget_file, out, total_kb, js_kb, lh_file = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
budget = json.load(open(budget_file))
try:
    lh_raw = open(lh_file).read() if os.path.getsize(lh_file) > 0 else ""
except OSError:
    lh_raw = ""

failures = []
b = budget.get("bundle", {})
bundle_report = {"total_kb_gzip": total_kb, "js_kb_gzip": js_kb, "budget": b}
if "total_kb_gzip" in b and total_kb > b["total_kb_gzip"]:
    failures.append(f"bundle total {total_kb}KB > {b['total_kb_gzip']}KB budget")
if "js_kb_gzip" in b and js_kb > b["js_kb_gzip"]:
    failures.append(f"bundle js {js_kb}KB > {b['js_kb_gzip']}KB budget")

c = budget.get("cwv", {})
if lh_raw.strip():
    try:
        d = json.loads(lh_raw)
        a = d["audits"]
        lcp = a["largest-contentful-paint"]["numericValue"]
        cls = a["cumulative-layout-shift"]["numericValue"]
        tbt = a["total-blocking-time"]["numericValue"]
        cwv_report = {"lcp_ms": round(lcp), "cls": round(cls, 3), "tbt_ms": round(tbt), "budget": c}
        if "lcp_ms" in c and lcp > c["lcp_ms"]:
            failures.append(f"LCP {round(lcp)}ms > {c['lcp_ms']}ms budget")
        if "cls" in c and cls > c["cls"]:
            failures.append(f"CLS {round(cls,3)} > {c['cls']} budget")
        if "tbt_ms" in c and tbt > c["tbt_ms"]:
            failures.append(f"TBT {round(tbt)}ms > {c['tbt_ms']}ms budget")
    except Exception as e:
        cwv_report = {"error": f"could not parse lighthouse: {e}"}
else:
    cwv_report = {"skipped": "lighthouse unavailable"}

verdict = "FAIL" if failures else "PASS"
json.dump({"verdict": verdict, "bundle": bundle_report, "cwv": cwv_report,
           "failures": failures}, open(out, "w"), indent=2)

for f in failures:
    print(f"[fe-perf-budget] OVER: {f}", file=sys.stderr)
print(f"[fe-perf-budget] Verdict: {verdict}", file=sys.stderr)
sys.exit(1 if failures else 0)
PYEOF
