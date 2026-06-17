# Verification procedures

Three things that must be verified empirically before trusting the harness.

---

## 1. Hook → subagent reach ✅ VERIFIED 2026-06-17

**Result:** PreToolUse hook fires in subagents spawned via Agent tool. File is never written.

**Test performed:**
- Master session tried Write 310-line file → BLOCKED (confirmed hook active)
- Subagent (Agent tool spawn) tried Write 350-line file to `/tmp/hook-test-subagent.py` → BLOCKED
- `ls /tmp/hook-test-subagent.py` → "No such file or directory"
- Hook error: `BLOCKED: write '/tmp/hook-test-subagent.py' = 350 lines (limit: 300). Split into smaller files.`

**Conclusion:** 300-LOC enforcement is mechanical end-to-end — master and all spawned subagents.
Fallback (honor-system via check_file_sizes.sh in prompt) is no longer needed.

---

## 2. Project prerequisite verification

Run these checks before using `local-preview.sh` on your project. Fill in each UNKNOWN in the plan's prerequisite table before the first run.

```bash
PROJECT_DIR="<path-to-your-project>"

# a. Does a health endpoint exist?
# Go: grep -r "health" "$PROJECT_DIR/cmd" "$PROJECT_DIR/internal" --include="*.go" -l
# Node: grep -r "health" "$PROJECT_DIR/src" --include="*.ts" -l
# Expected: at least one file. If empty → add /health or set PREVIEW_HEALTH=<actual-path>

# b. Does `make migrate` work?
cd "$PROJECT_DIR" && make -n migrate  # dry-run, don't execute
# Expected: shows migrate command.
# If "no rule for migrate" → set PREVIEW_SKIP_MIGRATE=1 and create a seed snapshot.

# c. Does the build command work? (Go example)
cd "$PROJECT_DIR" && go build -o /tmp/test-bin ./cmd/api && rm /tmp/test-bin
# Expected: exit 0.
# NOTE (Go): if your repo has multiple cmd/ packages, use GO_CMD=./cmd/<main-package>
# (not ./cmd/... — multiple packages fail with a single -o flag)

# d. Where is the FE?
ls "$PROJECT_DIR"/web "$PROJECT_DIR"/frontend "$PROJECT_DIR"/client 2>/dev/null
# Expected: one directory with package.json.
# If elsewhere: set FE_DIR=<actual-path>

# e. Does FE have `npm run dev`?
cat "$FE_DIR/package.json" | python3 -c "import json,sys; s=json.load(sys.stdin); print(s.get('scripts',{}).get('dev','MISSING'))"
# Expected: a vite/react-scripts/etc. command. If MISSING → set FE_DEV_CMD manually.

# f. What is the DB env var?
grep -r "DATABASE_URL\|DB_URL\|POSTGRES" "$PROJECT_DIR" --include="*.go" --include="*.env*" -l | head -5
# Expected: find the variable name your app reads. Set DB_ENV_VAR=<name> if not DATABASE_URL.
```

### Findings table (fill in for your project)

| Check | Status | Env var override needed |
|---|---|---|
| Health endpoint | ❓ | `PREVIEW_HEALTH=<path>` if not `/health` |
| make migrate | ❓ | `PREVIEW_SKIP_MIGRATE=1` if no Makefile target |
| go build | ❓ | `GO_CMD=./cmd/<pkg>` if multiple cmd packages |
| FE directory | ❓ | `FE_DIR=<path>` if not auto-detected |
| FE dev cmd | ❓ | `FE_DEV_CMD=<cmd>` if not `npm run dev` |
| DB env var | ❓ | `DB_ENV_VAR=<name>` if not `DATABASE_URL` |

Document your findings in `docs/decision-ledger.md` under module `infra/local-preview`.

---

## 3. Acceptance test (gate P1 → P2)

Run ONCE after P0+P1 artifacts are wired. All 5 assertions must pass.

**Setup:**
```bash
# Ensure hook is wired:
cat .claude/settings.json | python3 -c "import json,sys; h=json.load(sys.stdin).get('hooks',{}); print('OK' if 'PreToolUse' in h else 'MISSING')"

# Ensure code-review-graph is active (session restart required after settings.local.json edit):
# Check ~/.claude/projects/.../settings.local.json does NOT list code-review-graph in disabledMcpjsonServers
```

**Scenario:** give `/execution-harness` a plan with 5 tasks:
- task-001: security-core (tenant binding on one endpoint)
- task-002: business (add a form field end-to-end)
- task-003: mechanical-fan (sweep 5 files, add missing type annotation)
- task-004: bugfix (fix a known broken test)
- task-005: FE-ops (update one component style)

**Assertions:**

| # | Assert | How to verify |
|---|---|---|
| 1 | Zero mid-run human prompts | Watch session — no `[y/N]` or "please confirm" except deploy gate |
| 2 | Localhost opens at end | `run-report` shows URL, `curl localhost:PORT` returns 200 |
| 3 | `run-report` + `review-ledger` both exist | `ls run-report-*.md review-ledger.md` |
| 4 | Token total < budget ceiling | Check `/context-budget` at run end vs `HARNESS_TOKEN_BUDGET` |
| 5 | No new file > 300 lines | `bash scripts/check_file_sizes.sh <project> --warn-only` shows PASS |

**If any assertion fails → DO NOT proceed to P2. Fix P0/P1 first.**

Record result in `docs/decision-ledger.md`:
```
| <date> | acceptance test P1 result: PASS/FAIL | <which asserts failed> | infra/harness | — | open/closed |
```
