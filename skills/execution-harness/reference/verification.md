# Verification

## 1. Hook reach — PreToolUse fires in subagents

**Status: VERIFIED** (confirmed via session testing).

The `pretooluse-filesize.sh` hook fires inside subagents spawned via the Agent tool, not just in the master session. This means file-size enforcement reaches all subagents automatically — no extra wiring needed per subagent.

**Test:** spawn a subagent via the Agent tool, have it attempt to Write a file exceeding 300 lines. Hook should block. If it doesn't, check that `hooks.PreToolUse` is wired in project `.claude/settings.json` (not just `settings.local.json`).

---

## 2. Project prerequisite verification

Run these checks before using `local-preview.sh` on your project. Each UNKNOWN in the
plan's prerequisite table must be resolved here.

```bash
PROJECT_DIR="<path-to-your-project>"

# a. Does a health endpoint exist?
grep -r "health" "$PROJECT_DIR" --include="*.go" -l | head -5
# Expected: at least one file. If empty → set PREVIEW_HEALTH=<actual-path> or add /health

# b. Does `make migrate` work?
cd "$PROJECT_DIR" && make -n migrate  # dry-run, don't execute
# Expected: shows migrate command. If "no rule for migrate" → use PREVIEW_SKIP_MIGRATE=1
# and create a seed snapshot first.

# c. Does the backend build?
cd "$PROJECT_DIR" && go build ./... 2>&1 | head -5
# Expected: exit 0. If fail → fix build errors first.
# NOTE: if multiple cmd packages exist, target the specific entrypoint:
#   GO_CMD=./cmd/api  (not ./cmd/... — multiple cmd with -o fails)

# d. Where is the frontend?
ls "$PROJECT_DIR"/web "$PROJECT_DIR"/frontend "$PROJECT_DIR"/client 2>/dev/null
# Expected: one directory with package.json inside. If elsewhere: set FE_DIR=<actual-path>

# e. Does frontend have `npm run dev`?
cat "$FE_DIR/package.json" | python3 -c "import json,sys; s=json.load(sys.stdin); print(s.get('scripts',{}).get('dev','MISSING'))"
# Expected: a vite/react-scripts/etc. command. If MISSING → set FE_DEV_CMD manually.
```

**Document your findings** in a table like this, then set the env vars in your local-preview invocation:

| Check | Status | Env var override |
|---|---|---|
| Health endpoint | ✅ / ❌ / ⚠️ | `PREVIEW_HEALTH=<path>` if non-default |
| make migrate | ✅ / ❌ | `PREVIEW_SKIP_MIGRATE=1` if broken |
| Backend build | ✅ / ❌ | `GO_CMD=<specific-entrypoint>` |
| FE directory | ✅ / ❌ | `FE_DIR=<path>` if non-default |
| FE dev cmd | ✅ / ❌ | `FE_DEV_CMD=<cmd>` if non-standard |
| DB env var | ✅ / ⚠️ | `DB_ENV_VAR=<YOUR_DB_VAR>` if not `DATABASE_URL` |

**Minimal local-preview.sh invocation (adapt to your findings):**
```bash
GO_CMD=./cmd/api \
DB_ENV_VAR=DATABASE_URL \
FE_DIR=frontend \
  ~/.claude/skills/execution-harness/scripts/local-preview.sh \
  /path/to/your/project
```

---

## 3. Acceptance test (gate P1 → P2)

**Two run types — different applicable asserts:**

| Run type | Asserts | Notes |
|---|---|---|
| **Build-app run** (harness drives a real project) | 1-8 all apply | Normal: subagent coding + localhost preview |
| **Meta-harness run** (changes to the skill itself) | 3, 5, 6-8 | Asserts 1-2 N/A (no localhost); Assert 4 N/A (no single token budget scope) |

For build-app runs: Run ONCE after P0+P1 artifacts are wired. All applicable assertions must pass.

**Setup:**
```bash
# Ensure hook is wired:
cat .claude/settings.json | python3 -c "import json,sys; h=json.load(sys.stdin).get('hooks',{}); print('OK' if 'PreToolUse' in h else 'MISSING')"
```

**Scenario:** give `/execution-harness` a plan with 5 tasks:
- task-001: security-core (auth/tenant binding on one endpoint)
- task-002: business (add a form field end-to-end)
- task-003: mechanical-fan (sweep files, add missing type annotations)
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
| **6** | `trajectory.jsonl` has 1 row per `done` task | `[ "$(grep -c . .harness/trajectory.jsonl)" -eq <done_count> ]` |
| **7** | Stop-hook blocks when trajectory incomplete | Delete 1 row → trigger Stop → hook returns `{"decision":"block",...}` |
| **8** | `frontier.json` updated at run-end | `python3 -c 'import json;print(json.load(open(".harness/frontier.json"))["classes"])'` non-empty |

**If any assertion fails → DO NOT proceed to P2. Fix P0/P1 first.**

Record result in `docs/decision-ledger.md`:
```
{date, decision: "harness acceptance gate passed", reason: "all 5+3 assertions green",
 module: "infra/harness", status: open}
```
