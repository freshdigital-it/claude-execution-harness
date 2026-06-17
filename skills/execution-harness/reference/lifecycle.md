# Lifecycle: build → evaluate → local-preview → (deploy)

## Phase sequence

```
plan-time  → load plan.dag.json → agentdb recall → decision-ledger reconcile
loop       → classify task → spawn subagent → gate → checkpoint
post-loop  → simplify pass → local-preview (eval) → run-report → review-ledger
deploy     → manual opt-in only (--deploy=staging)
```

## Local isolation (per-worktree, zero shared state)

Each run allocates:
- **Port**: auto (ephemeral), never shared between worktrees
- **DB**: throwaway `preview_<project>_<pid>` — migrated fresh, dropped on exit
- **Binary**: `/tmp/preview-bin-<pid>` — removed on exit

Two parallel runs never touch the same DB or port. No clobber, no migration race.

## supply-migration-blocker workaround (reksa-erp)

Fresh-DB migration fails on reksa-erp (conflicting schema paths). Until resolved:

```bash
# Option A: seed snapshot (preferred)
PREVIEW_SEED_DB=scripts/seed/preview.sql \
  ~/.claude/skills/execution-harness/scripts/local-preview.sh

# Option B: skip migrate (empty DB, limited smoke coverage)
PREVIEW_SKIP_MIGRATE=1 \
  ~/.claude/skills/execution-harness/scripts/local-preview.sh
```

Track blocker status in `docs/decision-ledger.md`.

## Simplify pass (over-engineering gate)

After the loop, before local-preview, run ONE bloat check on the run's diff. Catches what the decision-ladder (standing-constraints.md) missed during writing.

- **Scope:** the cumulative diff this run produced — NOT the whole repo (token discipline).
- **Mechanism:** spawn one subagent typed `ecc:refactor-clean` (or `ecc:code-simplifier`). No plugin install — already in ECC.
- **Output contract (ACI):** returns a delete-list `{file, lines, why}` — bounded summary, not raw diff.
- **Action:** master applies only SAFE removals (dead code, unused abstraction the run introduced, single-use indirection). Anything touching behavior → defer to `review-ledger.md`, don't auto-apply.
- **Skip when:** run was pure mechanical-fan or refactor class (already minimal by construction), or diff < ~50 lines.

Only removes orphans THIS run created. Never deletes pre-existing code (behavioral.md surgical-changes rule).

## Decision-ledger reconciliation (plan-time)

Run once after writing `plan.dag.json`, before first task.

1. For each task, identify files it will touch (from title + acceptance criteria).
2. `code-review-graph get_impact_radius` on those files → get overlapping modules.
3. Read `docs/decision-ledger.md` entries where `module` overlaps (budget: ~1k tokens — not full ledger).
4. Keyword-match: extract 3 key terms from task `title`; compare against each entry's `decision` field.
   → Flag `DECISION-CONFLICT` if ≥2/3 terms match AND `status=open`.
5. Per conflict:
   - **Verify first** — grep/read current code to confirm the decision still holds (stale-memory check).
   - Still valid → inject as hard constraint into that task's subagent prompt.
   - Superseded by code → append supersession to ledger, clear conflict.
   - Ambiguous → surface to user BEFORE run starts (not mid-run).
6. Run-end: append new durable decisions to `docs/decision-ledger.md`.

Heuristic: false-negative safer than false-positive — miss a subtle conflict rather than flood noise.

## Context governance

**Compaction timing:** invoke `/strategic-compact` at phase gates only — after plan-time, after loop end, after simplify pass. Never reactively mid-task (disrupts subagent context).

**Pre-run audit:** if run has >10 tasks, check `/context-budget` first. If context >50% full before loop starts, compact before first spawn.

**Batch mechanical fan-out:** if plan has ≥3 `mechanical-fan` tasks touching non-overlapping files, fold into ONE subagent with an explicit task-list. Prevents N cold-spawn overhead for trivial work.

**Pointer-not-corpus:** DAG, ledger, and repo-map live in files. Master holds path + slice (~1k token budget), never the full content.

## Smoke tests

If `scripts/smoke-test.sh` exists in project → run against `BASE_URL=http://localhost:$PORT`.
Failure = WARN (localhost stays up for manual inspection), not hard exit.

## Deploy gate (three locks)

1. `--deploy=staging` must be passed explicitly to `local-preview.sh`
2. `deploy-lock.sh` prompts for y/N confirmation
3. Prod = always BLOCKED in loop — never in `deploy-lock.sh`

## run-report (written at loop end)

Master writes `run-report-<timestamp>.md`:

```
## Summary
- Completed: N / Failed: N / Blocked: [list + reason]

## Preview
- URL: http://localhost:<port>
- Smoke: PASS | WARN | FAIL

## Security review required
- File: review-ledger.md
- Items: N — read before merging

## Token usage
- Total: N / budget: M

## Next actions
- [ ] Review security items in review-ledger.md
- [ ] Verify localhost
- [ ] Resolve blocked: [list]
```
