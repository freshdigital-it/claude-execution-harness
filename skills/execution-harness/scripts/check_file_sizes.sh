#!/usr/bin/env bash
# check_file_sizes.sh — enforce 300-line max per clean-architecture.md [HARD]
# Usage: ./check_file_sizes.sh [DIR] [--warn-only]
# Exit 0 = clean. Exit 1 = violations (blocks commit gate).

set -euo pipefail

TARGET="${1:-.}"
WARN_ONLY="${2:-}"
LIMIT=300
VIOLATIONS=()

while IFS= read -r file; do
  lines=$(wc -l < "$file" 2>/dev/null || echo 0)
  if (( lines > LIMIT )); then
    VIOLATIONS+=("${lines}  ${file}")
  fi
done < <(find "$TARGET" -type f \
  \( -name "*.go" -o -name "*.php" -o -name "*.ts" -o -name "*.tsx" \
     -o -name "*.vue" -o -name "*.py" \) \
  -not -path "*/vendor/*" \
  -not -path "*/node_modules/*" \
  -not -path "*/migrations/*" \
  -not -path "*/dist/*" \
  -not -path "*/build/*" \
  -not -name "*_gen.go" \
  -not -name "*.pb.go" \
  -not -name "*_generated*" \
  2>/dev/null | sort)

if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
  echo "[size-check] PASS — no files over ${LIMIT} lines."
  exit 0
fi

echo "[size-check] VIOLATIONS (>${LIMIT} lines):"
for v in "${VIOLATIONS[@]}"; do
  echo "  $v"
done
echo ""
echo "[size-check] Fix: split each file before writing. Rule: File Size [HARD]"

[[ -n "$WARN_ONLY" ]] && echo "[size-check] warn-only mode — not blocking." && exit 0
exit 1
