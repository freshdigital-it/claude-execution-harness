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
plan-time → [ambiguity check → ask user] → classify tasks → plan.dag.json → recall
loop      → spawn typed subagent → gate → checkpoint
post-loop → simplify pass → local-preview (isolated DB) → run-report → review-ledger
```

→ `reference/lifecycle.md` for isolation details, migration workaround, deploy gate.

## Deferred review (no mid-run interruption)

security-core → independent verifier (≠ implementer, Opus, negative tests, security-scan) → commit → append to `review-ledger.md`. Human reads ledger **once** at end, not per-task.

## Autonomy guards

Budget ceiling → failure-breaker (K=3 → `/harness-audit` → halt) → model escalation (DIFFICULTY only, never rate-limit) → stop-on-destructive.

→ `reference/autonomy.md` for full guard specs + run-report template.

## Standing constraints (injected into every subagent)

300-LOC [HARD], 30-line methods [HARD], type safety [HARD], TDD-by-class, never-assume [HARD], clean-arch soft rules.

→ `reference/standing-constraints.md` for full constraint list + memory plan-time/run-end.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/local-preview.sh` | Isolated local instance (auto port + throwaway DB) |
| `scripts/check_file_sizes.sh` | 300-LOC gate (run in CI or pre-commit) |
| `scripts/hooks/pretooluse-filesize.sh` | PreToolUse hook — blocks Write/Edit >300/500 lines |
| `scripts/deploy-lock.sh` | Explicit deploy gate (never called automatically) |
| `scripts/trajectory-append.sh` | Append one task trajectory row to `.harness/trajectory.jsonl` (C1) |
| `scripts/frontier-update.sh` | Recompute learned-routing `frontier.json` from full corpus at run-end (C3) |
| `scripts/hooks/harness-runend-guard.sh` | Stop hook — blocks stop until trajectory complete + run-report exists (C2) |

## Wire the hook (one-time setup per project)

Add to project `.claude/settings.json`:
```json
"hooks": {
  "PreToolUse": [{ "matcher": "Write|Edit", "hooks": [
    { "type": "command", "command": "~/.claude/skills/execution-harness/scripts/hooks/pretooluse-filesize.sh" }
  ]}],
  "Stop": [{ "hooks": [
    { "type": "command", "command": "~/.claude/skills/execution-harness/scripts/hooks/harness-runend-guard.sh" }
  ]}]
}
```

## Step-0: execution opening moves

When `/execution-harness` is invoked, master runs these in order before the first task:

```
1. Read plan file (offset/limit — never whole file at once)
2. Bash: PROJECT_ROOT=$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || pwd) && mkdir -p "$PROJECT_ROOT/.harness" && echo "$PROJECT_ROOT"
   → store result as PROJECT_ROOT; use absolute paths for ALL subsequent writes
2b. Set `RUN_ID="run-$(date +%Y%m%d-%H%M%S)"`. Use it as the `run_id` field in every trajectory row this run.

[AMBIGUITY CHECK — run before writing DAG]
2c. Scan the plan for anything unclear: missing acceptance criteria, ambiguous scope,
    conflicting interpretations, unknown env/config values, or unresolved "TBD".
    Build a numbered list of questions. If list is non-empty → STOP. Show the list
    to the user and wait for answers before continuing. Only proceed when all questions
    are answered or explicitly waived by the user.

    Format:
    ---
    Sebelum mulai, saya perlu klarifikasi N hal:
    1. [pertanyaan konkret — bukan "apakah sudah benar?" tapi "X berarti A atau B?"]
    2. ...
    ---

    Trigger words that always require a question (never assume):
    - "sesuaikan dengan X" tanpa X yang jelas
    - "seperti biasa" / "seperti yang lama"
    - "cukup" / "saja" / "minimal" tanpa ukuran
    - nama file/path yang tidak ada di codebase
    - env var yang tidak ada di .env.example

3. Write $PROJECT_ROOT/.harness/plan.dag.json: classify each task (class/model/tdd/gate/split/status=pending).
   For each class, consult `scripts/frontier-route.sh "$PROJECT_ROOT/.harness" <class>`.
   If `safe_to_downgrade: true`, you MAY pick the cheaper tier — record the reason in DAG `note` field.
   The static task-class table remains the default; frontier is advisory only.
4. agentdb_pattern_search for known gotchas in plan's modules
5. Read user-memory for relevant project decisions
6. Query decision-ledger.md overlapping plan scope (code-review-graph get_impact_radius)
7. Fold blockers + DECISION-CONFLICTs into DAG standing-constraints
8. Start loop: pick first unblocked pending task, spawn typed subagent
```

If Step 3 already exists (resume): load it, skip pending tasks already `done`.

## Mid-run blocked tasks

If a subagent returns `status: blocked`:
1. Update DAG `status` → `blocked`, copy `blocked_reason` from subagent return
2. **STOP the loop** — do not continue to the next task
3. Surface the blocked reason to the user:
   ```
   [task-00N] BLOCKED: <blocked_reason>
   Asumsi default jika dilanjutkan: <assumption_if_unblocked>
   Jawab untuk melanjutkan, atau ketik "gunakan asumsi default".
   ```
4. After user answers → update task spec in DAG `note` field → re-spawn subagent
5. Resume loop from this task

## Anti-patterns

- Loading whole plan into master context (→ thrash).
- Long-lived domain agents (→ idle context bloat).
- Opus on rate-limit (→ same cap, burns faster).
- Parallel writers to one shared file (→ merge conflict).
- Deploy in autonomous loop without `--deploy=staging` flag.
- Two orchestrators running simultaneously.
- **Assuming instead of asking** — any ambiguity not surfaced at Step-0 or mid-run is a harness bug.
