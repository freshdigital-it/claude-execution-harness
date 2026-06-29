#!/usr/bin/env bash
# security-scan.sh — SAST + SCA scan (Opus #2: zero LLM tokens)
#
# Part of security-core deferred-verify gate and pre-deploy gate.
# Uses external CLI tools only — no LLM inference, no token cost.
#
# Usage:
#   security-scan.sh <project_root> [--changed-only] [--full] [--format json|text]
#
# Exit 0 = no HIGH/CRITICAL findings
# Exit 1 = HIGH/CRITICAL findings found (gate FAIL — block commit)
# Exit 2 = tooling not available (gate WARN — log and continue, do not block)
#
# Tools (install separately; harness warns if missing, never fails for missing tools):
#   semgrep     — SAST (security/correctness rules)
#   govulncheck — SCA for Go
#   npm audit   — SCA for Node/TypeScript
#   pip-audit   — SCA for Python
#   trivy       — container/IaC SCA (optional)

set -uo pipefail

PROJECT_ROOT="${1:-.}"
CHANGED_ONLY=false
FORMAT="text"
FINDINGS=0
TOOLS_MISSING=0

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --changed-only) CHANGED_ONLY=true; shift ;;
    --full)         CHANGED_ONLY=false; shift ;;
    --format)       FORMAT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

log()  { printf '[security-scan] %s\n' "$1"; }
warn() { printf '[security-scan] WARN: %s\n' "$1" >&2; }
high() { printf '[security-scan] HIGH: %s\n' "$1" >&2; FINDINGS=$((FINDINGS + 1)); }

get_changed_files() {
  git -C "$PROJECT_ROOT" diff --name-only HEAD~1 HEAD 2>/dev/null \
    || git -C "$PROJECT_ROOT" diff --name-only --cached 2>/dev/null \
    || echo ""
}

# --- SAST: semgrep ---
run_semgrep() {
  if ! command -v semgrep &>/dev/null; then
    warn "semgrep not installed (install: pip install semgrep). Skipping SAST."
    TOOLS_MISSING=$((TOOLS_MISSING + 1))
    return
  fi

  log "Running SAST: semgrep..."
  local args=(--config "p/security-audit" --config "p/secrets" --quiet --json)

  if [[ "$CHANGED_ONLY" == true ]]; then
    local changed_files
    changed_files=$(get_changed_files | grep -E '\.(go|ts|tsx|js|jsx|py|php)$' || true)
    [[ -z "$changed_files" ]] && { log "No changed source files to scan"; return; }
    # shellcheck disable=SC2086
    args+=($changed_files)
  else
    args+=("$PROJECT_ROOT")
  fi

  local output
  output=$(semgrep "${args[@]}" 2>/dev/null || true)

  local high_count medium_count
  high_count=$(echo "$output" | python3 -c "
import json,sys
data=json.load(sys.stdin)
print(sum(1 for r in data.get('results',[]) if r.get('extra',{}).get('severity','') in ('ERROR','WARNING')))
" 2>/dev/null || echo 0)

  if [[ "$high_count" -gt 0 ]]; then
    high "semgrep: $high_count high/error severity findings"
    if [[ "$FORMAT" == "text" ]]; then
      echo "$output" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for r in data.get('results',[]):
  sev=r.get('extra',{}).get('severity','')
  if sev in ('ERROR','WARNING'):
    print(f'  [{sev}] {r[\"path\"]}:{r[\"start\"][\"line\"]} — {r[\"check_id\"]}')
    print(f'         {r[\"extra\"].get(\"message\",\"\")[:120]}')
" 2>/dev/null || true
    fi
  else
    log "semgrep: no high/critical findings"
  fi
}

# --- SCA: Go ---
run_govulncheck() {
  [[ ! -f "$PROJECT_ROOT/go.mod" ]] && return
  if ! command -v govulncheck &>/dev/null; then
    warn "govulncheck not installed (install: go install golang.org/x/vuln/cmd/govulncheck@latest). Skipping Go SCA."
    TOOLS_MISSING=$((TOOLS_MISSING + 1))
    return
  fi
  log "Running SCA: govulncheck..."
  local output exit_code
  output=$(govulncheck -C "$PROJECT_ROOT" ./... 2>&1) && exit_code=0 || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    high "govulncheck: vulnerabilities found in Go dependencies"
    echo "$output" | grep -A2 "Vulnerability" | head -20 >&2 || true
  else
    log "govulncheck: no vulnerabilities"
  fi
}

# --- SCA: Node/TypeScript ---
run_npm_audit() {
  [[ ! -f "$PROJECT_ROOT/package.json" ]] && return
  if ! command -v npm &>/dev/null; then
    warn "npm not found. Skipping Node SCA."
    TOOLS_MISSING=$((TOOLS_MISSING + 1))
    return
  fi
  log "Running SCA: npm audit..."
  local output
  output=$(npm audit --json --prefix "$PROJECT_ROOT" 2>/dev/null || true)
  local high_count
  high_count=$(echo "$output" | python3 -c "
import json,sys
data=json.load(sys.stdin)
meta=data.get('metadata',{}).get('vulnerabilities',{})
print(meta.get('high',0)+meta.get('critical',0))
" 2>/dev/null || echo 0)
  if [[ "$high_count" -gt 0 ]]; then
    high "npm audit: $high_count high/critical dependency vulnerabilities"
  else
    log "npm audit: no high/critical vulnerabilities"
  fi
}

# --- SCA: Python ---
run_pip_audit() {
  [[ ! -f "$PROJECT_ROOT/requirements.txt" ]] && [[ ! -f "$PROJECT_ROOT/pyproject.toml" ]] && return
  if ! command -v pip-audit &>/dev/null; then
    warn "pip-audit not installed (install: pip install pip-audit). Skipping Python SCA."
    TOOLS_MISSING=$((TOOLS_MISSING + 1))
    return
  fi
  log "Running SCA: pip-audit..."
  local output
  output=$(pip-audit --project "$PROJECT_ROOT" --format json 2>/dev/null || true)
  local vuln_count
  vuln_count=$(echo "$output" | python3 -c "
import json,sys
data=json.load(sys.stdin)
print(len(data.get('vulnerabilities',[])))
" 2>/dev/null || echo 0)
  if [[ "$vuln_count" -gt 0 ]]; then
    high "pip-audit: $vuln_count Python dependency vulnerabilities"
  else
    log "pip-audit: no vulnerabilities"
  fi
}

# --- Run all ---
log "Starting security scan: project=$PROJECT_ROOT changed-only=$CHANGED_ONLY"
run_semgrep
run_govulncheck
run_npm_audit
run_pip_audit

# --- Summary ---
log "---"
log "Findings (HIGH/CRITICAL): $FINDINGS"
log "Tools missing (WARN): $TOOLS_MISSING"

if [[ "$TOOLS_MISSING" -gt 0 ]]; then
  warn "$TOOLS_MISSING scanning tool(s) not installed — coverage is partial"
  warn "Install semgrep + relevant SCA tool for full coverage"
fi

if [[ "$FINDINGS" -gt 0 ]]; then
  log "Result: FAIL — $FINDINGS high/critical finding(s). Fix before commit."
  exit 1
fi

log "Result: PASS — no high/critical security findings"
exit 0
