#!/usr/bin/env bash
# setup.sh — install claude-execution-harness into ~/.claude/
# Run once: bash setup.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "=== claude-execution-harness setup ==="
echo ""

# 1. Symlink skill
mkdir -p "$CLAUDE_DIR/skills"
if [[ -L "$CLAUDE_DIR/skills/execution-harness" ]]; then
  echo "ok skills/execution-harness already linked"
elif [[ -d "$CLAUDE_DIR/skills/execution-harness" ]]; then
  echo "WARN $CLAUDE_DIR/skills/execution-harness exists as a directory — skipping (remove manually to replace)"
else
  ln -s "$REPO_DIR/skills/execution-harness" "$CLAUDE_DIR/skills/execution-harness"
  echo "ok linked skills/execution-harness → ~/.claude/skills/execution-harness"
fi

# 2. Copy rules (don't overwrite if customized)
mkdir -p "$CLAUDE_DIR/rules"
for rule in clean-architecture.md behavioral.md; do
  if [[ -f "$CLAUDE_DIR/rules/$rule" ]]; then
    echo "ok rules/$rule already exists — skipping (edit manually to merge)"
  else
    cp "$REPO_DIR/rules/$rule" "$CLAUDE_DIR/rules/$rule"
    echo "ok installed rules/$rule"
  fi
done

# 3. Make all scripts executable
chmod +x "$REPO_DIR/skills/execution-harness/scripts/"*.sh
chmod +x "$REPO_DIR/skills/execution-harness/scripts/hooks/"*.sh
chmod +x "$REPO_DIR/skills/execution-harness/scripts/tests/"*.sh
echo "ok scripts are executable"

echo ""
echo "=== Next steps ==="
echo ""
echo "1. Install ECC (typed subagent specialists):"
echo "   claude /plugin install affaan-m/ECC"
echo ""
echo "2. Install Superpowers (skill routing):"
echo "   claude /plugin install obra/superpowers"
echo ""
echo "3. Install claude-flow (agentdb cross-run memory):"
echo "   claude /plugin install ruvnet/claude-flow"
echo ""
echo "4. Add BOTH hooks to your project's .claude/settings.json:"
echo ""
echo '   {'
echo '     "hooks": {'
echo '       "PreToolUse": [{'
echo '         "matcher": "Write|Edit",'
echo '         "hooks": [{ "type": "command",'
echo '           "command": "~/.claude/skills/execution-harness/scripts/hooks/pretooluse-filesize.sh"'
echo '         }]'
echo '       }],'
echo '       "Stop": [{'
echo '         "hooks": [{ "type": "command",'
echo '           "command": "~/.claude/skills/execution-harness/scripts/hooks/harness-runend-guard.sh"'
echo '         }]'
echo '       }]'
echo '     }'
echo '   }'
echo ""
echo "   PreToolUse: blocks oversized file writes (300-LOC gate)"
echo "   Stop:       blocks session end until trajectory is complete (self-healing memory)"
echo ""
echo "5. Copy CLAUDE.md.template to your project root as CLAUDE.md and customize."
echo ""
echo "6. Verify the test suite:"
echo "   bash ~/.claude/skills/execution-harness/scripts/tests/run-all.sh"
echo ""
echo "Done. Run /execution-harness in any Claude Code session to start."
