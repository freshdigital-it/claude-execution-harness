#!/usr/bin/env bash
# Run every harness unit test. Exit non-zero if any fails.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$DIR"/test-*.sh; do
  if bash "$t"; then :; else echo "  ^ FAILED: $t"; rc=1; fi
done
[ "$rc" -eq 0 ] && echo "ALL TESTS PASS" || echo "SOME TESTS FAILED"
exit "$rc"
