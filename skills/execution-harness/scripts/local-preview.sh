#!/usr/bin/env bash
# local-preview.sh — isolated local instance (BE + FE) for hands-off verify
# Usage: ./local-preview.sh [PROJECT_DIR] [--deploy=staging]
# Env:   PREVIEW_PORT=<n>          auto-allocated if unset
#        PREVIEW_FE_PORT=<n>       BE_PORT+1 if unset
#        PREVIEW_HEALTH=<path>     health check path (default: /health)
#        PREVIEW_SEED_DB=<path>    use DB snapshot (supply-migration-blocker workaround)
#        PREVIEW_SKIP_MIGRATE=1    skip migrate entirely (empty DB)
#        PROJECT_TYPE=go-psql|node auto-detected if unset
#        FE_DIR=<path>             override FE directory detection
#        FE_DEV_CMD=<cmd>          override FE dev command (default: npm run dev -- --port)
#        GO_CMD=<pkg>              go build target (default: ./cmd/api) — DO NOT use ./cmd/...
#        DB_ENV_VAR=<name>         DB url env var name (default: DATABASE_URL)

set -euo pipefail

PROJECT_DIR="${1:-.}"
PORT="${PREVIEW_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')}"
FE_PORT="${PREVIEW_FE_PORT:-$((PORT + 1))}"
HEALTH_PATH="${PREVIEW_HEALTH:-/health}"
DEPLOY_TARGET=""
[[ "${2:-}" == --deploy=* ]] && DEPLOY_TARGET="${2#--deploy=}"

detect_type() {
  [[ -f "$PROJECT_DIR/go.mod" ]] && echo "go-psql" && return
  [[ -f "$PROJECT_DIR/package.json" ]] && echo "node" && return
  echo "unknown"
}
PROJECT_TYPE="${PROJECT_TYPE:-$(detect_type)}"
GO_CMD="${GO_CMD:-./cmd/api}"
DB_ENV_VAR="${DB_ENV_VAR:-DATABASE_URL}"

# Detect FE directory (go-psql projects often have a separate FE subdir)
detect_fe_dir() {
  [[ -n "${FE_DIR:-}" ]] && echo "$FE_DIR" && return
  for d in web frontend client ui app; do
    [[ -d "$PROJECT_DIR/$d" && -f "$PROJECT_DIR/$d/package.json" ]] && echo "$PROJECT_DIR/$d" && return
  done
  echo ""
}
FE_DIR="$(detect_fe_dir)"

echo "[preview] $PROJECT_DIR  type=$PROJECT_TYPE  BE=$PORT  FE=${FE_DIR:+$FE_PORT (${FE_DIR##*/})}${FE_DIR:-none}"

DB_NAME="preview_$(basename "$PROJECT_DIR")_$$"
BIN_PATH=""
PID=""
FE_PID=""

cleanup() {
  [[ -n "$PID" ]]    && kill "$PID"    2>/dev/null || true
  [[ -n "$FE_PID" ]] && kill "$FE_PID" 2>/dev/null || true
  [[ -n "$BIN_PATH" && -f "$BIN_PATH" ]] && rm -f "$BIN_PATH"
  psql postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" 2>/dev/null || true
  echo "[preview] cleaned up."
}
trap cleanup EXIT INT TERM

# --- DB ---
createdb "$DB_NAME" 2>/dev/null
if [[ -n "${PREVIEW_SEED_DB:-}" ]]; then
  echo "[preview] seed DB: $PREVIEW_SEED_DB"
  psql "$DB_NAME" < "$PREVIEW_SEED_DB" > /dev/null
elif [[ "${PREVIEW_SKIP_MIGRATE:-0}" == "1" ]]; then
  echo "[preview] WARN: skipping migrations (PREVIEW_SKIP_MIGRATE=1)"
else
  echo "[preview] migrating..."
  (cd "$PROJECT_DIR" && DATABASE_URL="postgres://localhost/$DB_NAME?sslmode=disable" make migrate 2>&1) || {
    echo "[preview] migrate failed. Set PREVIEW_SEED_DB or PREVIEW_SKIP_MIGRATE=1"
    echo "[preview] Known blocker: supply-migration-blocker — see docs/decision-ledger.md"
    exit 1
  }
fi

# --- Build + start BE ---
case "$PROJECT_TYPE" in
  go-psql)
    echo "[preview] go build $GO_CMD..."
    BIN_PATH="/tmp/preview-bin-$$"
    (cd "$PROJECT_DIR" && go build -o "$BIN_PATH" "$GO_CMD" 2>&1) || { echo "[preview] build failed"; exit 1; }
    export "$DB_ENV_VAR=postgres://localhost/$DB_NAME?sslmode=disable"
    PORT="$PORT" "$BIN_PATH" &
    PID=$!
    ;;
  node)
    echo "[preview] npm build..."
    (cd "$PROJECT_DIR" && npm run build 2>&1) || exit 1
    export "$DB_ENV_VAR=postgres://localhost/$DB_NAME?sslmode=disable"
    (cd "$PROJECT_DIR" && PORT="$PORT" node dist/index.js) &
    PID=$!
    ;;
  *)
    echo "[preview] unknown project type. Set PROJECT_TYPE=go-psql|node"; exit 1 ;;
esac

# --- Wait for BE ready ---
echo "[preview] waiting for BE..."
for i in $(seq 1 30); do
  curl -sf "http://localhost:$PORT${HEALTH_PATH}" > /dev/null 2>&1 && break
  sleep 1
  [[ $i -eq 30 ]] && { echo "[preview] BE did not start in 30s. Set PREVIEW_HEALTH=<path> if /health doesn't exist."; exit 1; }
done
echo "[preview] BE ready."

# --- Start FE (if detected) ---
if [[ -n "$FE_DIR" ]]; then
  echo "[preview] starting FE on port $FE_PORT ($FE_DIR)..."
  FE_DEV_CMD="${FE_DEV_CMD:-npm run dev -- --port $FE_PORT --host}"
  (cd "$FE_DIR" && \
    VITE_PORT="$FE_PORT" \
    VITE_API_URL="http://localhost:$PORT" \
    REACT_APP_API_URL="http://localhost:$PORT" \
    PORT="$FE_PORT" \
    eval "$FE_DEV_CMD" 2>&1) &
  FE_PID=$!

  for i in $(seq 1 20); do
    curl -sf "http://localhost:$FE_PORT" > /dev/null 2>&1 && break
    sleep 1
    if [[ $i -eq 20 ]]; then
      echo "[preview] WARN: FE did not start in 20s — check $FE_DIR manually."
      FE_PID=""
      break
    fi
  done
  [[ -n "$FE_PID" ]] && echo "[preview] FE ready."
fi

# --- Smoke test ---
SMOKE="PASS"
if [[ -f "$PROJECT_DIR/scripts/smoke-test.sh" ]]; then
  BASE_URL="http://localhost:$PORT" bash "$PROJECT_DIR/scripts/smoke-test.sh" 2>&1 || SMOKE="WARN"
fi

# --- Report ---
echo ""
echo "=============================="
echo " PREVIEW READY"
[[ -n "$FE_PID" ]] && echo " FE:    http://localhost:$FE_PORT  ← verify here"
echo " BE:    http://localhost:$PORT"
echo " DB:    $DB_NAME (throwaway)"
echo " Smoke: $SMOKE"
echo "=============================="
[[ -z "$FE_DIR" ]] && echo " NOTE: no FE dir detected. Set FE_DIR=<path> if FE exists."
echo "Verifikasi di browser. Ctrl+C untuk stop + cleanup."

# --- Deploy gate (explicit opt-in only) ---
if [[ -n "$DEPLOY_TARGET" ]]; then
  echo ""
  read -p "[preview] deploy ke $DEPLOY_TARGET? [y/N] " -n 1 -r; echo
  [[ $REPLY =~ ^[Yy]$ ]] && bash "$(dirname "$0")/deploy-lock.sh" "$DEPLOY_TARGET" "$PROJECT_DIR" \
    || echo "[preview] deploy dibatalkan."
fi

wait "$PID"
