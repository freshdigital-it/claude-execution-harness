#!/usr/bin/env bash
# pretooluse-filesize.sh — PreToolUse hook: block Write/Edit that exceed LOC limit
# Wire up in .claude/settings.json:
#   "hooks": { "PreToolUse": [{ "matcher": "Write|Edit", "hooks": [{ "type": "command",
#     "command": "~/.claude/skills/execution-harness/scripts/hooks/pretooluse-filesize.sh" }] }] }
#
# Input: JSON on stdin { "tool_name": "Write"|"Edit", "tool_input": { ... } }
# Exit 0 = allow. Exit 2 = block (stderr shown to Claude as feedback).

set -euo pipefail

INPUT=$(cat)
py() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" <<< "$INPUT" 2>/dev/null || echo ""; }

TOOL=$(py "print(d.get('tool_name',''))")
[[ "$TOOL" != "Write" && "$TOOL" != "Edit" ]] && exit 0

FILE_PATH=$(py "print(d.get('tool_input',{}).get('file_path',''))")
[[ -z "$FILE_PATH" ]] && exit 0

# Skip non-code and generated files
case "$FILE_PATH" in
  *.go|*.php|*.ts|*.tsx|*.vue|*.py) ;;
  *) exit 0 ;;
esac
case "$FILE_PATH" in
  */migrations/*|*/vendor/*|*/node_modules/*|*/dist/*|*/build/*) exit 0 ;;
  *_gen.go|*.pb.go|*_generated*) exit 0 ;;
esac

if [[ "$TOOL" == "Write" ]]; then
  # Write: check full content length
  CONTENT=$(py "print(d.get('tool_input',{}).get('content',''))")
  RESULT_LINES=$(echo "$CONTENT" | wc -l)
  [[ -f "$FILE_PATH" ]] && LIMIT=500 || LIMIT=300

  if (( RESULT_LINES > LIMIT )); then
    echo "BLOCKED: write '$FILE_PATH' = ${RESULT_LINES} lines (limit: ${LIMIT})." >&2
    echo "Split into smaller files. Rule: File Size [HARD] in clean-architecture.md." >&2
    exit 2
  fi

elif [[ "$TOOL" == "Edit" ]]; then
  # Edit: calculate RESULTING file size = current - removed + added
  [[ ! -f "$FILE_PATH" ]] && exit 0  # new file via Edit is unusual, skip
  CURRENT_LINES=$(wc -l < "$FILE_PATH" 2>/dev/null || echo 0)
  OLD_STRING=$(py "print(d.get('tool_input',{}).get('old_string',''))")
  NEW_STRING=$(py "print(d.get('tool_input',{}).get('new_string',''))")
  OLD_LINES=$(echo "$OLD_STRING" | wc -l)
  NEW_LINES=$(echo "$NEW_STRING" | wc -l)
  RESULT_LINES=$(( CURRENT_LINES - OLD_LINES + NEW_LINES ))

  if (( RESULT_LINES > 500 )); then
    echo "BLOCKED: edit '$FILE_PATH' would result in ${RESULT_LINES} lines (current: ${CURRENT_LINES}, limit: 500)." >&2
    echo "Split the file before editing. Rule: File Size [HARD] in clean-architecture.md." >&2
    exit 2
  fi
fi

exit 0
