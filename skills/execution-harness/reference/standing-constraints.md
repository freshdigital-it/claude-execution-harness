# Standing constraints

Injected into every subagent prompt. Master folds these into each task block — not repeated verbatim, referenced as "apply standing-constraints.md".

## Decision ladder — before writing ANY new code [HARD]

Walk top to bottom. Stop at the first that applies. (YAGNI-first; borrowed from ponytail.)

1. **Does this need to exist?** → no: skip it. The cheapest code is unwritten.
2. **Does stdlib / language builtin do it?** → use it.
3. **Native platform / framework feature?** → use it (don't reinvent middleware, ORM scopes, router guards).
4. **Already-installed dependency does it?** → use it. No new dep for one function.
5. **Can it be one line?** → one line.
6. **Only then** → write the minimum that works.

Lazy, not negligent: trust-boundary validation, data-loss handling, security, and accessibility are NEVER skipped by this ladder. Note: when extracting a 30-line method (below), readability beats raw brevity — a named helper > a clever one-liner.

## Structural [HARD]
- File: max 300 lines (new) / 500 lines (edit). Split before writing if needed.
- Method/function: max 30 lines. Extract named helpers.
- One class = one reason to change. Can you name it in 3 words without "and"?

## Type safety [HARD]
- TS: no `any` — use `unknown` and narrow, or define the interface.
- PHP: no `mixed` except at library boundary.
- Python/Go: full type annotations on all exported functions.

## Security [HARD]
- No hardcoded secrets, API keys, passwords.
- SQL: parameterized queries only.
- Validate at system boundaries (HTTP, CLI args, events). Trust internal code.

## Soft (guidance, not hard block)
- Cyclomatic complexity ≤ 10 branches/method.
- Max 5 constructor dependencies.
- Max 7 public methods/class.
- Comments only when WHY is non-obvious.

## TDD by task class (pre-decided in plan.dag.json)

| class | TDD mode |
|---|---|
| security-core | test-first — tests must pass before "done" |
| business / bugfix | test-first |
| mechanical-fan / refactor | no test-first — compiler + linter IS the test |
| FE-ops / config | no test-first |

## Memory: plan-time (run once before first task)

1. `agentdb_pattern_search` for known gotchas in this module.
   Load top-3 by recency × relevance. **Verify each is still current** (grep the code).
   Stale entries (code no longer matches the gotcha) → skip; never act on unchecked assumptions.
2. Read user-memory for relevant project facts.
3. Decision-ledger reconciliation (procedure: `lifecycle.md §Decision-ledger reconciliation`).
4. Fold blockers + `DECISION-CONFLICT`s into DAG `standing-constraints` field.

## Memory: run-end (run once after last task)

0. **Per task close (during loop):** master appends a trajectory row via
   `scripts/trajectory-append.sh "$PROJECT_ROOT/.harness" '<row_json>'` using the
   subagent's returned `{status, summary, approach, reflection}`. Required fields:
   `task_id, class, status, gate_result`. This is enforced at Stop by `harness-runend-guard.sh`.
   **`tokens_est`:** fill from Agent tool's `subagent_tokens` field in result metadata (preferred),
   OR use class-based default if not available: `mechanical-fan=50000, business=60000,
   security-core=80000, refactor=40000`. Never omit — `avg_tokens` in frontier is dead without it.

1. `agentdb_pattern_store` any new gotcha. Schema:
   `{key: "<module>/<symptom>", module, gotcha, fix, confidence: high|medium}`
   Store only if: unexpected, reusable, not already in decision-ledger.
   Do NOT store: retry counts, port numbers, mid-run status, anything task-specific.
2. Append to `docs/decision-ledger.md` if a durable codebase decision was made.
3. Write project-memory only for facts likely to affect future runs.
4. **State → file. Lessons → semantic memory.** Never store transient state semantically.
5. **Update learned routing:** run `scripts/frontier-update.sh "$PROJECT_ROOT/.harness"` to recompute
   `frontier.json` from the full trajectory corpus. Data-only aggregation, no judgment required.
