#!/usr/bin/env bash
# deploy-lock.sh — explicit deploy gate (never called automatically)
# Usage: ./deploy-lock.sh <target:staging|prod> <project_dir>
# Prod always blocked in autonomous loop. Staging requires --deploy=staging.

set -euo pipefail

TARGET="${1:-}"
PROJECT_DIR="${2:-.}"

[[ -z "$TARGET" ]] && echo "[deploy] usage: deploy-lock.sh <staging|prod> <dir>" && exit 1

if [[ "$TARGET" == "prod" ]]; then
  echo "[deploy] BLOCKED: prod deploy is always manual. Never runs in autonomous loop."
  exit 1
fi

echo "[deploy] Target: $TARGET  Project: $PROJECT_DIR"
echo "[deploy] This will deploy to $TARGET. Proceed? [y/N]"
read -n 1 -r; echo
[[ ! $REPLY =~ ^[Yy]$ ]] && echo "[deploy] aborted." && exit 0

echo "[deploy] deploying to $TARGET..."
# Project-specific deploy hook — must exist in project
if [[ -f "$PROJECT_DIR/scripts/deploy-$TARGET.sh" ]]; then
  bash "$PROJECT_DIR/scripts/deploy-$TARGET.sh"
elif [[ -f "$PROJECT_DIR/Makefile" ]] && grep -q "deploy-$TARGET" "$PROJECT_DIR/Makefile"; then
  (cd "$PROJECT_DIR" && make "deploy-$TARGET")
else
  echo "[deploy] no deploy script found. Add scripts/deploy-$TARGET.sh or make deploy-$TARGET."
  exit 1
fi

echo "[deploy] done."
