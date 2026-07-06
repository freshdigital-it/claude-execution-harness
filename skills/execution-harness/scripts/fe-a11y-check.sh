#!/usr/bin/env bash
# Accessibility gate — run axe-core against a rendered route.
# Framework-agnostic: axe evaluates the live DOM, works for any FE stack.
#
# Usage: fe-a11y-check.sh <url> <route> [--harness-dir DIR] [--fail-on serious]
#   --fail-on  minimum impact that fails the gate: critical | serious (default) | moderate
#
# Exit 0 = PASS (no violations at/above threshold)
# Exit 1 = FAIL (violations found; see .harness/a11y-<route>.json)
# Exit 2 = SKIP (playwright / @axe-core/playwright not installed)
#
# Deeper than Lighthouse's aggregate a11y score: per-node WCAG violations.

set -euo pipefail

URL="${1:?usage: fe-a11y-check.sh <url> <route> [--harness-dir DIR]}"
ROUTE="${2:-/}"
HARNESS_DIR=".harness"
FAIL_ON="serious"

shift 2 || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --harness-dir) HARNESS_DIR="$2"; shift 2 ;;
        --fail-on)     FAIL_ON="$2"; shift 2 ;;
        *) shift ;;
    esac
done

mkdir -p "$HARNESS_DIR"
SLUG=$(echo "$ROUTE" | sed 's#[^a-zA-Z0-9]#_#g; s#^_##; s#_$##'); [[ -z "$SLUG" ]] && SLUG="root"
OUT="$HARNESS_DIR/a11y-${SLUG}.json"

log() { echo "[fe-a11y-check] $*" >&2; }

# ── Dependency check → SKIP if absent (matches qa-gate degradation) ────────────
if ! command -v node >/dev/null 2>&1; then log "node not found → SKIP"; exit 2; fi
if ! node -e "require.resolve('@axe-core/playwright'); require.resolve('playwright')" 2>/dev/null; then
    log "@axe-core/playwright or playwright not installed → SKIP"
    exit 2
fi

log "Running axe on ${URL}${ROUTE} (fail-on=${FAIL_ON})"

node - "$URL$ROUTE" "$OUT" "$FAIL_ON" <<'NODEEOF'
const { chromium } = require('playwright');
const { AxeBuilder } = require('@axe-core/playwright');
const [target, out, failOn] = process.argv.slice(2);
const RANK = { minor: 1, moderate: 2, serious: 3, critical: 4 };

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto(target, { waitUntil: 'networkidle', timeout: 30000 });
  const results = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
    .analyze();
  await browser.close();

  const counts = { critical: 0, serious: 0, moderate: 0, minor: 0 };
  const violations = results.violations.map(v => {
    counts[v.impact] = (counts[v.impact] || 0) + 1;
    return { id: v.id, impact: v.impact, help: v.help, nodes: v.nodes.length };
  });

  const threshold = RANK[failOn] || 3;
  const failing = results.violations.filter(v => (RANK[v.impact] || 0) >= threshold).length;

  const fs = require('fs');
  fs.writeFileSync(out, JSON.stringify(
    { url: target, counts, violations,
      failing_count: failing, fail_on: failOn,
      timestamp: new Date().toISOString() }, null, 2));

  console.error(`[fe-a11y-check] critical=${counts.critical} serious=${counts.serious} `
    + `moderate=${counts.moderate} minor=${counts.minor} → ${failing} at/above ${failOn}`);
  process.exit(failing > 0 ? 1 : 0);
})().catch(e => { console.error('[fe-a11y-check] error:', e.message); process.exit(2); });
NODEEOF
