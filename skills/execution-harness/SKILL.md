---
name: execution-harness
description: "Hands-off coding executor: one command → build → evaluate → localhost ready. Master controller, ephemeral ECC subagents, durable plan.dag.json state, deferred security review, local-preview isolation. Use for multi-task plans, production launches, or large coding workstreams."
user-invokable: true
---

# Execution Harness

Policy layer over ECC muscle. Drives plan to localhost-ready without mid-run interruptions.

## Activate when

- Executing a multi-task plan (`docs/**/plans/*.md`).
- Production launch or large workstream spanning backend, frontend, security, ops.
- Any job too big for one context window that needs one controller.

## Three invariants (non-negotiable)

**1. Thin master** — master holds only: DAG, gate states, checkpoint log, plan checkboxes. All raw output (test logs, diffs, file bodies) lives and dies inside subagents. Subagent returns short summary + gate verdict, nothing raw.

**2. Durable state in files** — `plan.dag.json` (per-task class/model/tdd/gate/status) + plan checkboxes + git commit per phase. Resume from files, not context. One controller + durable resume is the invariant, not one session.

**3. One loop-owner** — harness is the single orchestrator. Never invoke a second loop (SDD, orch-pipeline, etc.) inside it. Borrow their *techniques*, not their *invocation*.

## Task classes (set at plan-time in plan.dag.json)

| Class | Model | TDD | Gate |
|---|---|---|---|
| security-core | Opus | test-first | deferred-verify |
| business / bugfix | Sonnet | test-first | auto |
| mechanical-fan | Sonnet/Haiku | no | pipeline |
| refactor / FE-ops | Sonnet | no | auto |

## Lifecycle

```
plan-time → classify tasks → plan.dag.json → recall (agentdb + decision-ledger)
loop      → spawn typed subagent → gate → checkpoint
post-loop → simplify pass → local-preview (isolated DB) → run-report → review-ledger
```

→ `reference/lifecycle.md` for isolation details, supply-migration-blocker workaround, deploy gate.

## Deferred review (no mid-run interruption)

security-core → independent verifier (≠ implementer, Opus, negative tests, security-scan) → commit → append to `review-ledger.md`. Human reads ledger **once** at end, not per-task.

## Autonomy guards

Budget ceiling → failure-breaker (K=3 → `/harness-audit` → halt) → model escalation (DIFFICULTY only, never rate-limit) → stop-on-destructive.

→ `reference/autonomy.md` for full guard specs + run-report template.

## Standing constraints (injected into every subagent)

300-LOC [HARD], 30-line methods [HARD], type safety [HARD], TDD-by-class, clean-arch soft rules.

→ `reference/standing-constraints.md` for full constraint list + memory plan-time/run-end.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/local-preview.sh` | Isolated local instance (auto port + throwaway DB) |
| `scripts/check_file_sizes.sh` | 300-LOC gate (run in CI or pre-commit) |
| `scripts/hooks/pretooluse-filesize.sh` | PreToolUse hook — blocks Write/Edit >300/500 lines |
| `scripts/deploy-lock.sh` | Explicit deploy gate (never called automatically) |

## Wire the hook (one-time setup per project)

Add to project `.claude/settings.json`:
```json
"hooks": { "PreToolUse": [{ "matcher": "Write|Edit", "hooks": [
  { "type": "command", "command": "~/.claude/skills/execution-harness/scripts/hooks/pretooluse-filesize.sh" }
]}]}
```

## Step-0: execution opening moves

When `/execution-harness` is invoked, master runs these in order before the first task:

```
1. Read plan file (offset/limit — never whole file at once)
2. Write plan.dag.json: classify each task (class/model/tdd/gate/split/status=pending)
3. agentdb_pattern_search for known gotchas in plan's modules
4. Read user-memory for relevant project decisions
5. Query decision-ledger.md overlapping plan scope (code-review-graph get_impact_radius)
6. Fold blockers + DECISION-CONFLICTs into DAG standing-constraints
7. Start loop: pick first unblocked pending task, spawn typed subagent
```

If Step 2 already exists (resume): load it, skip pending tasks already `done`.

## Anti-patterns

- Loading whole plan into master context (→ thrash).
- Long-lived domain agents (→ idle context bloat).
- Opus on rate-limit (→ same cap, burns faster).
- Parallel writers to one shared file (→ merge conflict).
- Deploy in autonomous loop without `--deploy=staging` flag.
- Two orchestrators running simultaneously.
