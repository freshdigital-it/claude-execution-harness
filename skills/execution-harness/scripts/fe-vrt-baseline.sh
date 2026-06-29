#!/usr/bin/env bash
# fe-vrt-baseline.sh — Visual Regression Testing baseline management (Gap 2)
#
# Usage:
#   fe-vrt-baseline.sh capture <url> <route> <screen_id> [--harness-dir <dir>]
#   fe-vrt-baseline.sh diff    <url> <route> <screen_id> [--threshold <0-100>] [--harness-dir <dir>]
#   fe-vrt-baseline.sh status  [--harness-dir <dir>]
#
# Exit 0 = pass / captured
# Exit 1 = diff exceeds threshold (gate FAIL)
# Exit 2 = no baseline exists yet (run capture first)
# Exit 3 = tooling missing (Playwright or ImageMagick not found)
#
# Baselines stored in: <harness-dir>/vrt-baselines/<screen_id>.png
# Diffs stored in:     <harness-dir>/vrt-diffs/<screen_id>-diff.png
#
# IMPORTANT: screenshot only in fe-visual. Other FE sub-classes use DOM/CSS text checks.

set -uo pipefail

ACTION="${1:?usage: fe-vrt-baseline.sh <capture|diff|status> ...}"
shift

URL=""
ROUTE=""
SCREEN_ID=""
THRESHOLD=5   # % pixel difference allowed before FAIL
HARNESS_DIR=".harness"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold)    THRESHOLD="$2"; shift 2 ;;
    --harness-dir)  HARNESS_DIR="$2"; shift 2 ;;
    -*)             echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      if   [[ -z "$URL" ]];       then URL="$1"
      elif [[ -z "$ROUTE" ]];     then ROUTE="$1"
      elif [[ -z "$SCREEN_ID" ]]; then SCREEN_ID="$1"
      fi
      shift ;;
  esac
done

BASELINE_DIR="$HARNESS_DIR/vrt-baselines"
DIFF_DIR="$HARNESS_DIR/vrt-diffs"
CURRENT_DIR="$HARNESS_DIR/vrt-current"

log()  { printf '[fe-vrt] %s\n' "$1"; }
fail() { printf '[fe-vrt] FAIL: %s\n' "$1" >&2; exit 1; }
warn() { printf '[fe-vrt] WARN: %s\n' "$1" >&2; }

check_playwright() {
  if ! command -v npx &>/dev/null; then
    warn "npx not found — cannot take screenshots. Install Node.js."
    exit 3
  fi
}

take_screenshot() {
  local url="$1" route="$2" out="$3"
  local full_url="${url}${route}"
  # Use Playwright CLI for screenshot (zero-config)
  npx playwright screenshot \
    --browser chromium \
    --full-page \
    "$full_url" "$out" 2>/dev/null \
  || { warn "Playwright screenshot failed for $full_url"; return 1; }
}

compare_images() {
  local baseline="$1" current="$2" diff_out="$3"
  # ImageMagick compare (preferred)
  if command -v compare &>/dev/null; then
    local result
    result=$(compare -metric PHASH "$baseline" "$current" "$diff_out" 2>&1 || true)
    # PHASH returns a float; lower is more similar
    echo "$result"
    return 0
  fi
  # Fallback: Playwright pixel diff via inline script
  warn "ImageMagick not found — falling back to basic file comparison"
  if cmp -s "$baseline" "$current"; then echo "0"; else echo "100"; fi
}

case "$ACTION" in

  capture)
    [[ -z "$SCREEN_ID" ]] && fail "usage: fe-vrt-baseline.sh capture <url> <route> <screen_id>"
    check_playwright
    mkdir -p "$BASELINE_DIR"
    OUT="$BASELINE_DIR/${SCREEN_ID}.png"
    log "Capturing baseline: $URL$ROUTE → $OUT"
    take_screenshot "$URL" "$ROUTE" "$OUT" || fail "Screenshot failed"
    log "Baseline saved: $OUT"
    log "Next diff runs will compare against this baseline"
    ;;

  diff)
    [[ -z "$SCREEN_ID" ]] && fail "usage: fe-vrt-baseline.sh diff <url> <route> <screen_id>"
    BASELINE="$BASELINE_DIR/${SCREEN_ID}.png"
    [[ ! -f "$BASELINE" ]] && { warn "No baseline for $SCREEN_ID — run 'capture' first"; exit 2; }
    check_playwright
    mkdir -p "$CURRENT_DIR" "$DIFF_DIR"
    CURRENT="$CURRENT_DIR/${SCREEN_ID}.png"
    DIFF="$DIFF_DIR/${SCREEN_ID}-diff.png"
    log "Taking current screenshot: $URL$ROUTE"
    take_screenshot "$URL" "$ROUTE" "$CURRENT" || fail "Screenshot failed"
    log "Comparing against baseline..."
    DIFF_VALUE=$(compare_images "$BASELINE" "$CURRENT" "$DIFF")
    log "Pixel diff value: $DIFF_VALUE (threshold: $THRESHOLD)"
    # Convert to integer for comparison (PHASH values < threshold = pass)
    DIFF_INT=$(python3 -c "print(int(float('${DIFF_VALUE:-0}')))" 2>/dev/null || echo 999)
    if [[ "$DIFF_INT" -le "$THRESHOLD" ]]; then
      log "PASS: diff $DIFF_INT ≤ threshold $THRESHOLD"
    else
      fail "Visual regression detected: diff $DIFF_INT > threshold $THRESHOLD. Diff image: $DIFF"
    fi
    ;;

  status)
    mkdir -p "$BASELINE_DIR"
    BASELINES=$(find "$BASELINE_DIR" -name "*.png" 2>/dev/null | wc -l | tr -d ' ')
    log "VRT baselines: $BASELINES files in $BASELINE_DIR"
    find "$BASELINE_DIR" -name "*.png" 2>/dev/null | while read -r f; do
      SIZE=$(du -sh "$f" 2>/dev/null | cut -f1)
      MODIFIED=$(stat -f "%Sm" -t "%Y-%m-%d" "$f" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d' ' -f1)
      printf '  %s (%s, %s)\n' "$(basename "$f" .png)" "$SIZE" "$MODIFIED"
    done
    ;;

  *)
    fail "Unknown action: $ACTION. Use: capture | diff | status"
    ;;
esac
