#!/usr/bin/env bash
# fe-server-check.sh — Prerequisite health check before ANY FE verification.
# Ensures Vite/FE server is running and serving the latest build.
# Run this before conformance gate, Playwright, or screenshot.
#
# Usage: fe-server-check.sh <url> [<src_dir>]
# Exit 0 = server healthy, serving latest build
# Exit 1 = server not ready (master should trigger rebuild then retry once)
#
# Example: fe-server-check.sh http://localhost:5173 apps/admin/src

set -uo pipefail

URL="${1:?usage: fe-server-check.sh <url> [<src_dir>]}"
SRC_DIR="${2:-src}"

fail() { printf '[fe-server-check] FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '[fe-server-check] OK: %s\n' "$1"; }

# 1. Server responds
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "000" ]]; then
  fail "Server not reachable at $URL — start dev server first (e.g. vite dev)"
fi
if [[ "$HTTP_CODE" != "200" ]]; then
  fail "Server at $URL returned HTTP $HTTP_CODE (expected 200)"
fi
ok "server responding at $URL (HTTP $HTTP_CODE)"

# 2. Response is not a cached/stale build
# Check that response contains <script> or <link> tags (real Vite output, not an old cached page)
RESPONSE=$(curl -s --connect-timeout 5 "$URL" 2>/dev/null)
if ! echo "$RESPONSE" | grep -q -E '<script|<link'; then
  fail "Response from $URL looks like a cached or incomplete build (no script/link tags)"
fi
ok "response contains build assets"

# 3. If src dir provided, check that server has been started after last source edit
if [[ -d "$SRC_DIR" ]]; then
  # Find most recently modified source file
  NEWEST_SRC=$(find "$SRC_DIR" -type f \( -name "*.ts" -o -name "*.vue" -o -name "*.tsx" \) \
    -newer /dev/null -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | awk '{print $2}')

  if [[ -n "$NEWEST_SRC" ]]; then
    # Check if dist/build dir exists and is newer than newest source
    BUILD_DIR=""
    for d in dist .vite/cache; do
      [[ -d "$d" ]] && BUILD_DIR="$d" && break
    done

    if [[ -n "$BUILD_DIR" ]]; then
      if [[ "$NEWEST_SRC" -nt "$BUILD_DIR" ]]; then
        fail "Source files newer than build in $BUILD_DIR — server may be serving stale build. Run: vite build or restart vite dev"
      fi
      ok "build is fresh (newer than or equal to source)"
    fi
  fi
fi

ok "FE server health check PASSED — safe to run verification"
exit 0
