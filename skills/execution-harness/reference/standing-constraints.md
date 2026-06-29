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

## Never assume silently [HARD]

Berlaku untuk master DAN semua subagent.

**Master (plan-time, Step-0 2c):**
- Jika ada ketidakjelasan dalam plan → STOP, tanya user, tunggu jawaban sebelum DAG ditulis.
- Jangan pernah menginterpretasi diam-diam lalu jalan. Tanya dulu.

**Subagent (mid-task):**
- Jika menemukan ambiguitas dalam spec task → return `status: blocked` dengan `blocked_reason`.
- Jangan pernah pilih satu interpretasi dan lanjutkan tanpa lapor.
- Kalau asumsi tidak bisa dihindari (scope sangat kecil, dampak reversibel): catat di field `assumptions` trajectory row. Field ini tidak boleh kosong jika ada yang diasumsikan.

**Trigger yang SELALU harus jadi pertanyaan (tidak boleh diasumsikan):**
- Referensi ke sesuatu yang tidak ada: file, path, env var, fungsi yang tidak ketemu di codebase
- Instruksi ambigu: "sesuaikan dengan X", "seperti biasa", "yang lama", tanpa referensi konkret
- Ukuran tidak jelas: "cukup", "minimal", "sedikit" tanpa angka atau batas yang bisa diverifikasi
- Konflik antara dua bagian plan yang kontradiktif
- Dependency pada task lain yang statusnya belum `done`

**Yang TIDAK perlu ditanya (lanjut saja):**
- Konvensi kode yang sudah jelas dari codebase (ikuti saja)
- Detail implementasi teknis yang tidak mempengaruhi perilaku eksternal
- Urutan eksekusi internal yang tidak disebutkan di plan

## Soft (guidance, not hard block)
- Cyclomatic complexity ≤ 10 branches/method.
- Max 5 constructor dependencies.
- Max 7 public methods/class.
- Comments only when WHY is non-obvious.

## TDD by task class (pre-decided in plan.dag.json)

| class | Model | Effort | TDD mode |
|---|---|---|---|
| security-core | Sonnet (Opus on 2× fail) | high | test-first — tests must pass before "done" |
| business / bugfix | Sonnet | medium | test-first |
| mechanical-fan | Haiku | low | no test-first — compiler + linter IS the test |
| refactor | Haiku | low | no test-first |
| fe-mechanical | Haiku | low | no test-first — tsc + linter IS the oracle |
| fe-component | Sonnet | medium | no test-first — conformance gate IS the oracle |
| fe-page | Sonnet | medium | no test-first — conformance + journey gate IS the oracle |
| fe-api-wiring | Sonnet | medium | no test-first — Playwright fixtures IS the oracle |
| fe-visual | Sonnet | high | no test-first — GAN evaluator IS the oracle |

FE sub-class prerequisite: **fe-server-check.sh must pass** before any FE gate runs.
Conformance gate tests against approved `ux-contracts/<screen>.yaml`. Gate fails if rubric score < 12/14.
Screenshot / image tokens: ONLY in `fe-visual`. Never in `fe-mechanical` through `fe-api-wiring`.

Both `model:` and `effort:` MUST be passed explicitly on every Agent spawn (see SKILL.md Step-8).
Omitting either causes subagent to inherit parent session defaults — breaking cost control.

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
   **`tokens_est`:** try Agent result metadata field `subagent_tokens` first (unverified — may not
   exist in all runtime versions). If absent or zero, fall back to class constant:
   `mechanical-fan=50000, business=60000, security-core=80000, refactor=40000`. Label the value as
   "estimated" in that case. Never omit — `avg_tokens` in frontier is dead without it. Note:
   if `subagent_tokens` is systematically absent, `avg_tokens` becomes a floor estimate, not a measurement.
   **`assumptions`:** list setiap asumsi yang dibuat subagent. Kosongkan array `[]` hanya jika
   benar-benar tidak ada asumsi. Jangan omit field ini.

1. `agentdb_pattern_store` any new gotcha. Schema:
   `{key: "<module>/<symptom>", module, gotcha, fix, confidence: high|medium}`
   Store only if: unexpected, reusable, not already in decision-ledger.
   Do NOT store: retry counts, port numbers, mid-run status, anything task-specific.
2. Append to `docs/decision-ledger.md` if a durable codebase decision was made.
3. Write project-memory only for facts likely to affect future runs.
4. **State → file. Lessons → semantic memory.** Never store transient state semantically.
5. **Update learned routing:** run `scripts/frontier-update.sh "$PROJECT_ROOT/.harness"` to recompute
   `frontier.json` from the full trajectory corpus. Data-only aggregation, no judgment required.
