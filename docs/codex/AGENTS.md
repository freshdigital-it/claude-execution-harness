# Execution Harness — Codex Edition
# Governs ALL Codex tasks in this repository.
# Place this file at the repo root as AGENTS.md.
# 100% lifecycle parity with claude-execution-harness (Claude Code skill).

---

## Execution model

Codex runs as a **single agent per invocation**. For parallel tasks, launch separate Codex
instances with non-overlapping file scopes. The master DAG (`plan.dag.json`) is the single
source of truth — update status there after each task, not in memory.

---

## Step-0: Opening moves (run at every session start)

```bash
# 1. Establish absolute project root — never use relative paths for state files
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
mkdir -p "$PROJECT_ROOT/.harness"

# 2. Resume check
if [ -f "$PROJECT_ROOT/.harness/plan.dag.json" ]; then
  echo "Resuming — load DAG, skip done tasks"
else
  echo "Fresh run — classify tasks, write DAG"
fi

# 3. File-based memory recall (replaces agentdb)
[ -f "$PROJECT_ROOT/docs/harness-memory.json" ] && \
  echo "Recall top-3 gotchas by recency — grep code to verify still current before using"

# 4. Decision-ledger reconciliation (see §Decision-ledger below)

# 5. LOC enforcement (replaces PreToolUse hook — run before EVERY file write)
# bash scripts/hooks/check-filesize.sh <file_path>
```

---

## Task classification (set in plan.dag.json at plan-time, never mid-run)

| class | model | TDD | gate | notes |
|---|---|---|---|---|
| security-core | o3 | test-first | adversarial-verify | deferred to review-ledger.md |
| business / bugfix | o4-mini (high) | test-first | auto | tests must pass |
| mechanical-fan | o4-mini | none | compiler+linter | batch ≥3 non-overlapping into one instance |
| FE-ops / refactor | o4-mini | none | auto | |

**Never change task class mid-run.** If a task turns out harder → escalate model only (DIFFICULTY),
mark `escalated: true` in DAG.

---

## plan.dag.json schema

```json
{
  "meta": {
    "plan": "docs/plans/your-plan.md",
    "branch": "feature/your-branch",
    "created": "YYYY-MM-DD",
    "decisions": ["decision-id-1", "decision-id-2"]
  },
  "tasks": {
    "T0.1": {
      "class": "bugfix",
      "model": "o4-mini",
      "tdd": true,
      "gate": "auto",
      "status": "pending",
      "title": "What this task does",
      "blockedBy": [],
      "files": ["path/to/affected/file.go"]
    }
  }
}
```

`status` values: `pending` → `in_progress` → `done` | `blocked` | `needs_review`

---

## Execution loop

For each unblocked `pending` task (in dependency order):

1. Set `status: in_progress` in plan.dag.json
2. Run LOC check before every Write: `bash scripts/hooks/check-filesize.sh <file>`
3. Apply **decision ladder** (standing-constraints §Decision ladder) before writing ANY code
4. Execute with TDD if required by class
5. Gate check (see §Gates)
6. On pass → set `status: done`, git commit with task ID in message
7. On fail ≤ K=3 → Reflexion: write 5-line root-cause, change strategy, retry
8. On fail > K → set `status: blocked`, write reason, continue to next task

---

## Gates

**auto gate** (business/bugfix/FE-ops)
- Tests pass (if tdd: true)
- Compiler + linter clean
- No file exceeds LOC limit (scripts/hooks/check-filesize.sh)

**adversarial-verify gate** (security-core)
- Run independent verification pass with adversarial framing:
  *"Attempt to break this implementation. Try cross-tenant access, privilege escalation,
  boundary violations. Default to NEEDS_REVIEW unless certain constraint holds under ALL inputs."*
- Use a DIFFERENT model instance than the implementer (never self-review)
- Must include negative tests: cross-tenant read, escalation attempt, invalid token
- Verdict: `{verdict: APPROVED|NEEDS_REVIEW|BLOCKED, findings: [{issue, severity, proof}]}`
- `APPROVED` → commit. `NEEDS_REVIEW` / `BLOCKED` → append to review-ledger.md, do NOT commit
- Human reads review-ledger.md ONCE at run-end, not per-task

---

## Standing constraints (apply to every task — no exceptions)

**Decision ladder — before writing ANY new code**
1. Does this need to exist? → no: skip it
2. Stdlib / language builtin? → use it
3. Native platform/framework feature? → use it
4. Already-installed dependency? → use it
5. One line? → one line
6. Only then → write minimum that works

Security, data-loss handling, and accessibility are NEVER skipped by this ladder.

**Structural [HARD]**
- File: max 300 lines (new) / 500 lines (edit). Run `check-filesize.sh` before writing.
- Method/function: max 30 lines. Extract named helpers.
- One class = one reason to change.

**Type safety [HARD]**
- TS: no `any`. Go: full type annotations. Python: type hints on all exported functions.

**Security [HARD]**
- No hardcoded secrets. SQL: parameterized queries only. Validate at system boundaries only.

**Surgical changes [HARD]**
- Touch only what the task requires. Do NOT improve adjacent code.
- Remove imports/vars/functions YOUR changes made unused. Leave pre-existing dead code alone.

---

## Memory (file-based — replaces agentdb)

### Plan-time recall

Read `docs/harness-memory.json`, load top-3 entries by `confidence` + `updated` for modules
this run will touch. **Grep the code to verify each gotcha is still current** before acting on it.

### Run-end store

Append to `docs/harness-memory.json`:
```json
{
  "key": "<module>/<symptom>",
  "module": "string",
  "gotcha": "what went wrong",
  "fix": "what resolved it",
  "confidence": "high|medium",
  "updated": "YYYY-MM-DD"
}
```

Store only if: unexpected, reusable, not already in decision-ledger.
Do NOT store: retry counts, port numbers, mid-run status, task-specific one-offs.

---

## Decision-ledger reconciliation (plan-time)

```bash
# 1. For each task, list files it will touch (from title + files[] in DAG)
# 2. grep docs/decision-ledger.md for entries whose module matches
# 3. Extract 3 key terms from task title; check if ≥2/3 appear in matching entries
# 4. If match AND status=open → flag DECISION-CONFLICT
# 5. Verify: grep the code — does the decision still hold?
#    Still valid → inject as hard constraint in task execution
#    Superseded → append supersession to decision-ledger.md
#    Ambiguous → surface to user BEFORE starting the run
# 6. Run-end: append new durable decisions to docs/decision-ledger.md
```

---

## Autonomy guards

**Failure-breaker**: K=3 consecutive gate failures on same task → mark BLOCKED + reason + halt

**Reflexion on gate fail**: before retry, write ≤5 lines:
- What failed and why
- What strategy changes next attempt

**Model escalation** (difficulty only, never rate-limit):
- Sonnet stuck → o3 (DIFFICULTY escalation). Mark `escalated: true` in DAG.
- o3 stuck → BLOCKED. Halt + write run-report.

**Stop-on-destructive**: `rm -rf`, force-push, drop table, deploy, `git reset --hard`
→ STOP immediately + write run-report + wait for human. No exceptions, even if plan authorizes it.

---

## Context governance

- Compact at phase boundaries (after plan-time, after loop, after simplify pass). Never mid-task.
- If >10 tasks: check context usage before first task. If >50% full → compact first.
- Batch ≥3 `mechanical-fan` tasks with non-overlapping files into ONE Codex invocation.
- DAG + ledger live in files. Never load full content — read by slice (offset/limit).

---

## Simplify pass (run after loop, before preview)

After all tasks complete, run ONE bloat check on the run's diff:

```bash
git diff main...HEAD --stat  # scope: only this run's diff
```

Remove: dead code, unused abstractions, single-use indirections introduced THIS run.
Defer to review-ledger.md: anything touching behavior.
Skip if: run was pure mechanical-fan/refactor, or diff < 50 lines.

---

## Local preview

```bash
bash scripts/local-preview.sh  # auto port, throwaway DB, dropped on exit
# Run smoke tests if scripts/smoke-test.sh exists
bash scripts/smoke-test.sh BASE_URL=http://localhost:$PORT
```

Two parallel runs never share port or DB.

---

## run-report (written at loop end)

Write `.harness/run-report-<YYYY-MM-DD>.md`:

```markdown
## Summary
- Completed: N / Failed: N / Blocked: [list + reason]

## Preview
- URL: http://localhost:<port>
- Smoke: PASS | WARN | FAIL

## Security review required
- File: .harness/review-ledger.md
- Items: N — read before merging

## Next actions
- [ ] Review .harness/review-ledger.md
- [ ] Verify localhost
- [ ] Resolve blocked: [list]
```

---

## Anti-patterns (never do these)

- Loading whole plan into context (read by offset/limit)
- Long-lived domain agents (finish task, return bounded summary, exit)
- Parallel writers to the same file (use non-overlapping file scopes)
- Deploy in autonomous loop without explicit `--deploy=staging`
- Two orchestrators running simultaneously on the same DAG
- Faking blocked tasks (external dependency = BLOCKED with reason, not a stub)
