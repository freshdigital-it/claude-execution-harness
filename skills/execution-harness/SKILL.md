---
name: execution-harness
description: "End-to-end executor: one sentence → PRD → Spec → Plan → implement → QA → GitHub PR + staging deploy. No manual steps, no assumptions. Master controller with interactive planning, typed subagents, durable DAG, and CI-integrated delivery."
user-invokable: true
---

# Execution Harness

From idea to GitHub PR. One command. No assumptions. No bolak-balik.

## Activate when

- Any feature, bugfix, or workstream — from one-liner idea OR existing plan file.
- When you need PRD + Spec + Plan generated before implementation.
- Any job too big for one context window that needs one controller.

## Three invariants (non-negotiable)

**1. Thin master** — master holds only: DAG, gate states, checkpoint log, plan checkboxes. All raw output (test logs, diffs, file bodies) lives and dies inside subagents. Subagent returns short summary + gate verdict, nothing raw.

**2. Durable state in files** — `plan.dag.json` (per-task class/model/effort/tdd/gate/status) + plan checkboxes + git commit per phase. Resume from files, not context. One controller + durable resume is the invariant, not one session.

**3. One loop-owner** — harness is the single orchestrator. Never invoke a second loop (SDD, orch-pipeline, etc.) inside it. Borrow their *techniques*, not their *invocation*.

## Task classes (set at plan-time in plan.dag.json)

| Class | Model | Effort | TDD | Gate |
|---|---|---|---|---|
| security-core | Sonnet (Opus on 2× gate fail) | high | test-first | deferred-verify |
| business / bugfix | Sonnet | medium | test-first | auto |
| mechanical-fan | Haiku | low | no | pipeline |
| refactor | Haiku | low | no | auto |
| **fe-mechanical** | Haiku | low | no | pipeline (tsc + linter) |
| **fe-component** | Sonnet | medium | no | conformance |
| **fe-page** | Sonnet | medium | no | conformance + fe-journey |
| **fe-api-wiring** | Sonnet | medium | no | auto + fixtures |
| **fe-visual** | Sonnet | high | no | GAN K≤3 (escalation only) |

`fe-mechanical`: renames, import swaps, text changes, trivial token value swaps — compiler is the oracle.
`fe-component` through `fe-api-wiring`: failure-attribution across CSS/component/state/API → Sonnet.
`fe-visual`: activated only when conformance gate fails on pixel fidelity. Never default.
Opus is reserved as difficulty escalation only — never as a class default.

→ `reference/fe-execution.md` for FE sub-class playbook, UX contract schema, GAN prompts, rubric.
→ `reference/backend-execution.md` for API contract discipline, error semantics, idempotency, tenancy, backend testing layers (business / security-core / bugfix tasks touching endpoints or data).

## Lifecycle

```
PHASE 0: Planning (interactive — no assumptions)
  → detect existing PRD/Spec/Plan → ask: resume / restart / buat baru
  → fresh: batch questions → PRD (approve) → Spec (approve) → Plan (approve)
  → HARD GATE: Phase 1 tidak dimulai sampai Plan di-approve user

PHASE 1: Implementation
  → classify tasks → plan.dag.json → recall patterns
  → loop: spawn typed subagent → gate → checkpoint
  → [at phase boundary]: phase-integration-gate (BLOCKING)

PHASE 2: Quality
  → delivery-metrics → qa-gate (GO/NO-GO, BLOCKING)

PHASE 3: Delivery
  → git branch + commit + push
  → gh pr create (body: qa-gate verdict + security summary + test results)
  → CI (harness-generated workflow) auto-deploys staging on PR open
  → Production: ALWAYS explicit — gh workflow run deploy-production (never in loop)
```

→ `reference/planning.md` for Phase 0 question protocol (incl. idea-refine P0-pre for vague ideas), PRD/Spec/Plan schemas, approval gates.
→ `reference/adr-migration.md` for ADR format + migration-safety (expand-contract, rollback-required) — used at Spec Data-Model + decision-ledger reconciliation.
```

→ `reference/lifecycle.md` for isolation details, migration workaround, deploy gate.

## Deferred review (no mid-run interruption)

security-core gate = **Sub-step A** (SAST/SCA via `scripts/security-scan.sh`, zero LLM tokens) → **Sub-step B** (adversarial LLM verifier, negative tests) → commit → append to `review-ledger.md`.
Human reads ledger **once** at end, not per-task.

**Verifier model is resolved relative to the implementer** — not hardcoded:
`V=$(scripts/verify-model.sh <impl_model> <task_class>)`. Default policy `one-below` →
Opus implementer verified by Sonnet, with a Sonnet floor for security/business.
Configure via `HARNESS_VERIFY_POLICY` (`one-below` | `equal` | `fixed:<model>`).
Escalate verifier to Opus only if the gate already failed once at the resolved tier.
→ full policy + floor rules: `reference/autonomy.md` § Verification model policy.

## Phase integration gate (BLOCKING — Opus #1)

After completing a phase (group of tasks), before starting the next:
```bash
scripts/phase-integration-gate.sh $PROJECT_ROOT $PREVIEW_URL --phase <phase-name>
```
Re-runs ALL security-core negative tests + ALL Playwright journey specs in `tests/e2e/ux-contracts/`.
Exit 1 → loop halts. Not WARN — this is a hard gate. Fixes the "tasks verified in isolation break each other" gap.

## Autonomy guards

Budget ceiling → failure-breaker (K=3 → `/harness-audit` → halt) → model escalation (DIFFICULTY only after 2× fail, never rate-limit) → stop-on-destructive.

→ `reference/autonomy.md` for full guard specs + model+effort routing table + verification model policy + multimodal/browser routing.

## Multimodal & browser routing (quick rule)

Vision/browser I/O = Sonnet tier, never burn Opus/Fable on it:
- **Image extraction** (user sends an image) → always Sonnet. Not overridable.
- **Screenshot / web surf** → Sonnet by default; only "pakai opus" (or `HARNESS_BROWSER_MODEL=opus`) upgrades it.
- **Master on Opus/Fable needs a screenshot/vision op** → summon a Sonnet sub-agent for that op, don't do it inline.

→ full rules: `reference/autonomy.md` § Multimodal & browser routing.

## Standing constraints (injected into every subagent)

300-LOC [HARD], 30-line methods [HARD], type safety [HARD], TDD-by-class, never-assume [HARD], clean-arch soft rules.

→ `reference/standing-constraints.md` for full constraint list + memory plan-time/run-end.
→ `reference/rationalizations.md` — anti-rationalization tables (excuse → rebuttal); injected alongside constraints so subagents don't talk themselves into corner-cutting.
→ `reference/observability.md` — structured logging + RED metrics + tracing as build-time gate criteria (business / fe-api-wiring / backend tasks).

## Commit Convention

Type derived from task class:

| Class | Type |
|---|---|
| business / fe-* | `feat` |
| bugfix | `fix` |
| refactor | `refactor` |
| mechanical-fan | `chore` |
| security-core | `fix` |

**Per-task commit** — master runs immediately after gate PASS, before moving to next task:

```bash
# Add only files this task touched (from DAG files_touched field — never git add -A)
git add <files_touched_by_this_task>

git commit -m "$(cat <<'EOF'
type(scope): what changed — one line ≤72 chars

WHY this was needed (1–2 sentences from task spec, not WHAT the code does).

Task: task-00N
Gate: PASS
EOF
)"
```

**Pre-commit hook failure**: if the hook rejects the commit (lint, typecheck, etc.):
1. Fix the underlying error — do NOT use `--no-verify`
2. Re-stage the fix with the same task files
3. Retry the commit

**Gate-fail protection** — NEVER commit if gate status is `FAIL` or `BLOCKED`:
- `FAIL`: task is not done. Committing broken state corrupts `git bisect`.
- `BLOCKED`: task needs user input. Commit after user unblocks and gate re-runs as PASS.

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
| `scripts/ux-contract-generate.py` | **FE** Parse `design/*.html` → generate UX contract YAML drafts + `design-tokens.json` per screen |
| `scripts/fe-atdd-generate.py` | **FE/ATDD** Generate failing Playwright tests from approved UX contract (ATDD gap fix) |
| `scripts/fe-behavior-test-generate.py` | **FE/Trophy** Generate Vue Test Utils behavior tests — find by role, not class (Testing Trophy gap fix) |
| `scripts/fe-vrt-baseline.sh` | **FE/VRT** Visual regression baseline capture + diff (Gap 2: no VRT baseline) |
| `scripts/fe-server-check.sh` | **FE** Health check: Vite/FE server serving latest build (prerequisite for all FE verification) |
| `scripts/security-scan.sh` | **Security** SAST (semgrep) + SCA (npm audit/govulncheck) — zero LLM tokens, runs per security-core task |
| `scripts/phase-integration-gate.sh` | **Integration** Re-run all negative tests + Playwright journeys at phase boundary (Opus #1, BLOCKING) |
| `scripts/delivery-metrics.sh` | **Metrics** DORA-aligned metrics from trajectory.jsonl — CFR, gate pass rate, tokens by class |
| `scripts/hooks/posttooluse-token-ceiling.sh` | **Safety** PostToolUse hook: hard token ceiling (Opus #3, replaces soft self-monitoring) |
| `scripts/verify-model.sh` | **QA policy** Resolve verifier model from implementer model + `HARNESS_VERIFY_POLICY` (default: Opus→Sonnet, Sonnet floor for security/business). |
| `scripts/qa-gate.sh` | **Release gate** Aggregate evidence + system checks (incl. axe a11y + perf budget) → GO/NO-GO before PR/deploy. |
| `scripts/trajectory-recall.sh` | **Learning** Ranked keyword-overlap recall over past trajectories — deterministic fallback when agentdb (semantic) unavailable. |
| `scripts/tests/run-all.sh` | **Self-test** Unit + integration suite for the harness itself (run in CI via `.github/workflows/harness-selftest.yml`). |
| `scripts/fe-a11y-check.sh` | **FE/a11y** axe-core WCAG 2.1 AA per route — deeper than Lighthouse score. FAIL on serious/critical. |
| `scripts/fe-perf-budget.sh` | **FE/perf** Bundle-size (gzip) + Core Web Vitals (LCP/CLS/TBT) vs `performance-budget.json`. |
| `scripts/parallel-group-plan.py` | **Parallel** Build parallel execution groups from plan.dag.json — groups tasks with disjoint files_touched + no DAG deps. |
| `scripts/worktree-setup.sh` | **Parallel** Create detached-HEAD git worktree + register file claims + install `.harness-write.sh` in worktree. |
| `scripts/worktree-teardown.sh` | **Parallel** Copy agent output to main project + commit (serialized) + remove worktree + release claims. |
| `scripts/agent-result-write.sh` | **Parallel** Agent calls this when done — writes durable result file master polls for completion. |
| `scripts/parallel-wait.sh` | **Parallel** Poll `.harness/agent-results/` for completion — timeout-safe, notification-independent. |
| `scripts/ci-generate.sh` | **CI** Generate `.github/workflows/harness-ci.yml` — runs harness scripts in CI, auto-deploys staging on PR. |
| `scripts/deploy.sh` | **Deploy** Pluggable staging/production deploy via project `deploy-config.sh`. Staging auto, production explicit. |
| `scripts/rollback.sh` | **Rollback** Auto-triggered by `deploy.sh` on health check failure. |

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

## Project Setup Detection (runs FIRST, before Phase 0, on every invocation)

```
Check: .github/workflows/harness-ci.yml exists?
Check: deploy-config.sh exists AND DEPLOY_STAGING_CMD is non-empty?

If BOTH exist → skip setup, proceed to Phase 0.

If EITHER missing → PROJECT SETUP (one-time, master does everything):

  Master asks in ONE batch:
  ---
  Saya perlu beberapa info untuk setup project ini sekali saja.
  Jawab semua — tidak ada yang bisa dilewati:

  1. STAGING URL — URL deployment staging?
     (contoh: https://staging.example.com)

  2. STAGING DEPLOY COMMAND — command untuk deploy ke staging?
     (contoh: rsync -av dist/ user@host:/var/www/app/
      atau: docker push registry/app:staging && ssh user@host 'docker compose pull && docker compose up -d'
      atau: vercel --prod --token=$VERCEL_TOKEN)

  3. PRODUCTION DEPLOY COMMAND — command untuk deploy ke production?
     (sama seperti staging tapi endpoint berbeda, atau beda strategy)

  4. HEALTH CHECK ENDPOINT — path untuk cek server sehat setelah deploy?
     (default: /api/health — tekan Enter untuk pakai default)

  5. BUILD COMMAND — command build frontend?
     (default: npm run build — tekan Enter untuk pakai default)

  6. PREVIEW COMMAND — command serve hasil build untuk testing lokal/CI?
     (default: npx serve dist -p 4173 — tekan Enter untuk pakai default)

  7. ROLLBACK COMMAND — cara revert kalau deploy gagal? (opsional)
     (contoh: ssh user@host 'cd /app && git checkout $(git tag -l | tail -2 | head -1)')
     Kosongkan jika ingin pakai git fallback otomatis.

  8. SECRET NAMES yang dibutuhkan deploy command?
     (contoh: SSH_PRIVATE_KEY, VERCEL_TOKEN — ini yang akan kamu tambah di GitHub)
  ---

  After user answers — master does ALL of this automatically:

  A. Generate deploy-config.sh + protect it from accidental commit:
     Write file with DEPLOY_STAGING_CMD, DEPLOY_PROD_CMD, HEALTH_CHECK_URL, ROLLBACK_CMD
     echo "deploy-config.sh" >> .gitignore
     (deploy-config.sh may contain credentials or inline secrets — never commit it)

  B. Generate CI workflow:
     Bash: ~/.claude/skills/execution-harness/scripts/ci-generate.sh \
       "$PROJECT_ROOT" "<staging-url-from-answer-1>"
     Also replace build/preview commands in generated workflow with answers 5+6.

  C. Commit setup files (only CI workflow + .gitignore, NOT deploy-config.sh):
     git add .gitignore .github/workflows/harness-ci.yml
     git commit -m "ci: harness project setup (CI workflow + gitignore)"

  D. Show ONE manual step (the only thing that genuinely requires GitHub UI access):
     ---
     Setup selesai. Satu langkah yang perlu kamu lakukan di GitHub:

     GitHub → Settings → Environments → buat dua environment: "staging" dan "production"
     Tambah secrets berikut di masing-masing:
       <secret names dari jawaban 8>

     Ini adalah satu-satunya langkah yang tidak bisa dilakukan otomatis
     karena menyentuh credentials yang tidak boleh ada di dalam harness.

     Setelah selesai, ketik 'lanjut'.
     ---

  E. After user responds → proceed to Phase 0.
```

## Phase 0: Planning (runs before Step-0 if no approved plan exists)

```
P0a. Detect existing artifacts:
     find docs/prds/ docs/specs/ docs/plans/ -name "*.md" 2>/dev/null | sort -r | head -10

P0b. If found → surface to user + ask: A (resume) / B (restart) / C (buat baru)
     A → skip to Step-0 with existing plan
     B → skip to Step-0, reset all task status → pending
     C → proceed to P0c

P0c0. Idea-refine check (only if idea is vague/exploratory — see reference/planning.md):
      Concrete feature → skip. Vague ("bikin fitur loyalty", "kurangi churn") →
      run ONE divergent→convergent round (offer 2-3 directions + trade-offs, user picks)
      BEFORE the PRD. Do not invent the direction; offer options.

P0c. PRD generation (no plan at all, OR user chose C):
     Ask BATCH 1 + BATCH 2 in ONE message (see reference/planning.md for exact questions).
     Wait for all 10 answers. Generate PRD. Show draft. Wait for 'approved'.
     Save: docs/prds/YYYY-MM-DD-<feature>.md (status: approved)

P0d. Spec generation (after PRD approved):
     Ask Spec questions in ONE message (5 questions). Generate Spec. Wait for 'approved'.
     Save: docs/specs/YYYY-MM-DD-<feature>.md (status: approved)

P0e. Plan generation (after Spec approved):
     Generate plan (writing-plans protocol). Show task classification preview + token estimate.
     Wait for user to type 'mulai'. Save: docs/plans/YYYY-MM-DD-<feature>.md

P0f. Feature branch setup (after user types 'mulai', before any implementation):

     # 1. Derive branch prefix from PRD type:
     #    new capability  → feature/
     #    bug / regression → fix/
     #    tooling / deps   → chore/
     #    urgent prod fix  → hotfix/
     PREFIX=<derived from PRD type>
     KEBAB=$(python3 -c "import re; print(re.sub(r'[^a-z0-9]+','-','<feature-name-from-PRD>'.lower()).strip('-'))")
     BRANCH_NAME="$PREFIX/$KEBAB"

     # 2. Fetch latest remote state before branching
     git fetch origin --prune

     # 3. Resume or create
     if git show-ref --verify --quiet refs/heads/$BRANCH_NAME; then
         git checkout $BRANCH_NAME          # resume: branch already exists
     else
         git checkout -b $BRANCH_NAME origin/main   # fresh: base off remote main
     fi

     # 4. HARD GUARD — never run on main/master
     CURRENT=$(git branch --show-current)
     if [[ "$CURRENT" == "main" || "$CURRENT" == "master" ]]; then
         HALT: "harness must not run on main/master — branch setup failed. Investigate."
     fi

     # Note: branch cleanup after PR merge:
     #   git push origin --delete $BRANCH_NAME && git branch -d $BRANCH_NAME

→ HARD GATE: Phase 1 TIDAK dimulai sampai user confirm plan.
→ full question protocol + document schemas: reference/planning.md
```

## Step-0: execution opening moves

When plan is confirmed (Phase 0 complete or plan already existed), master runs:

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

3a. [FE plan-time — MASTER RUNS THIS AUTOMATICALLY when plan has any fe-* tasks]

    STEP A (master, no user action needed):
      Bash: python3 ~/.claude/skills/execution-harness/scripts/ux-contract-generate.py \
        "$PROJECT_ROOT"/design/*.html --output "$PROJECT_ROOT/ux-contracts/"
      → produces ux-contracts/<screen>.yaml (status: draft) + design-tokens.json
      Also build component inventory:
        find "$PROJECT_ROOT/src/components" -name "*.vue" | head -50
      If no design/*.html exists: generate minimal contract stubs from plan spec,
      set status: draft — user can approve after reviewing.

    STEP B (ONE human gate — the only user pause in the FE loop):
      Master shows user:
        "[N] UX contract drafts at ux-contracts/. Review dan set status: approved
        untuk screen yang akan diimplementasi. Ketik 'lanjut' setelah selesai."
      Loop WAITS until user responds. This is the only time user touches contracts.

    STEP C (master, immediately after user responds — no user action):
      Bash: python3 ~/.claude/skills/execution-harness/scripts/fe-atdd-generate.py \
        "$PROJECT_ROOT/ux-contracts/" --output "$PROJECT_ROOT/tests/e2e/ux-contracts/"
      Bash: python3 ~/.claude/skills/execution-harness/scripts/fe-behavior-test-generate.py \
        "$PROJECT_ROOT/ux-contracts/" --output "$PROJECT_ROOT/tests/unit/ux-contracts/"
      → All generated tests FAIL (no implementation yet). This is intentional.
      → Master stores test file paths in each task's DAG fe_contract field.
      User does NOT run any of these — master injects them into subagent context at loop time.

3b. Write $PROJECT_ROOT/.harness/plan.dag.json: classify each task (class/model/effort/tdd/gate/split/status=pending/files_touched/deps).
   `files_touched` is critical for parallel grouping — estimate from task spec + plan file paths.
   `deps` is explicit dependency list (task IDs that must complete first).

   After DAG is written, build parallel execution groups:
     Bash: python3 ~/.claude/skills/execution-harness/scripts/parallel-group-plan.py \
       "$PROJECT_ROOT/.harness/plan.dag.json" \
       "$PROJECT_ROOT/.harness/parallel-groups.json"
   Log: "[group-001: task-001, task-002 can parallel] [group-002: task-003 sequential]"
   For each class, consult `scripts/frontier-route.sh "$PROJECT_ROOT/.harness" <class>`.
   If `safe_to_downgrade: true`, you MAY pick the cheaper tier — record the reason in DAG `note` field.
   If frontier reports `downgrade_note` (Haiku cold-start warning), record it explicitly in DAG `note`.
   The static task-class table remains the default; frontier is advisory only.
4. Learning recall (semantic-first, deterministic fallback):
   a. Try `agentdb_pattern_search` for known gotchas in plan's modules (semantic).
   b. If agentdb unavailable → `scripts/trajectory-recall.sh "$PROJECT_ROOT/.harness" "<task title + key terms>" 3`
      → ranked keyword-overlap over past trajectories (failures weighted higher).
   Fold the top hits' reflections into the relevant task's DAG `note` as priors
   ("similar task last failed on X"). Budget: top-3, summaries only.
5. Read user-memory for relevant project decisions
6. Query decision-ledger.md overlapping plan scope (code-review-graph get_impact_radius)
7. Fold blockers + DECISION-CONFLICTs into DAG standing-constraints
8. Parallel loop — master iterates over groups from parallel-groups.json:

   Model/effort routing table (ALWAYS set BOTH explicitly):
   | class | model | effort |
   |---|---|---|
   | security-core | "sonnet" | "high" |
   | business / bugfix | "sonnet" | "medium" |
   | mechanical-fan | "haiku" | "low" |
   | refactor | "haiku" | "low" |
   | fe-mechanical | "haiku" | "low" |
   | fe-component | "sonnet" | "medium" |
   | fe-page | "sonnet" | "medium" |
   | fe-api-wiring | "sonnet" | "medium" |
   | fe-visual | "sonnet" | "high" |

   For each group in parallel-groups.json:

     Skip group if ALL its tasks are already status=done.

     ── SPAWN PHASE ─────────────────────────────────────────────────────
     For each pending task in group — ALL AT ONCE (multiple Agent calls in one message):

       a. Create isolated worktree:
          WPATH=$(bash ~/.claude/skills/execution-harness/scripts/worktree-setup.sh \
            "$PROJECT_ROOT" "$RUN_ID" "$TASK_ID" <files_touched from DAG...>)
          If worktree-setup exits non-zero (file conflict detected) → skip parallel,
          move conflicting task to next sequential group.

       b. Build agent context:
          - task spec from plan file
          - standing constraints (reference/standing-constraints.md)
          - For fe-* tasks: ux-contract YAML + design-tokens.json + failing test paths
          - CRITICAL INSTRUCTION injected into every parallel agent prompt:
            "Your isolated working directory is: $WPATH
             ALL project file operations MUST use absolute paths under $WPATH/
             Do NOT read or write project files outside $WPATH/
             Do NOT run any git commands (add, commit, push, checkout).

             When your work is complete and gate is checked, write your result:
               bash $WPATH/.harness-write.sh \
                 '$PROJECT_ROOT' '$TASK_ID' '<PASS|FAIL|BLOCKED>' \
                 '<json_array_of_files_changed>' \
                 '<one_line_summary>'
             This is MANDATORY — master polls this file for completion.
             Write it even if gate FAIL or BLOCKED.
             Then return normally."

       c. Spawn Agent(model=<from table>, effort=<from table>, prompt=<above>)

     ── WAIT PHASE ──────────────────────────────────────────────────────
     # Do NOT rely solely on agent return notifications — they can be lost
     # due to context compaction, hook interference, or parallel race conditions.
     # Poll durable result files instead. Notifications are a bonus, not a guarantee.

     bash ~/.claude/skills/execution-harness/scripts/parallel-wait.sh \
       "$PROJECT_ROOT" 600 "$GROUP_ID" <task_ids in group...>

     # Polls .harness/agent-results/<task_id>.json every 5s (up to 600s).
     # Exit 0: all done. Read each result file for gate_result + files_changed_actual.
     # Exit 1: timeout. Read .harness/parallel-wait-<group_id>.json:
     #   {completed:[...], timed_out:[...], elapsed_seconds: N}
     #   Surface timed-out tasks to user: re-run, extend timeout, or skip.

     ── CONFLICT CHECK (safety net) ─────────────────────────────────────
     Collect files_changed_actual from .harness/agent-results/<task_id>.json.
     If any two agents report touching the same file:
       HALT. Surface conflict to user. Do not commit either task.
       User decides: re-run one sequentially, or merge manually.

     ── COMMIT PHASE (serialized — one at a time) ────────────────────────
     For each agent with gate PASS (in task-id order, not parallel):
       bash ~/.claude/skills/execution-harness/scripts/worktree-teardown.sh \
         "$PROJECT_ROOT" "$RUN_ID" "$TASK_ID" \
         "$(printf 'type(scope): description\n\nWhy...\n\nTask: %s\nGate: PASS' $TASK_ID)"
       → copies files from worktree to main project → git add → git commit → removes worktree

       If pre-commit hook fails during teardown:
         Fix the error (lint, typecheck). Re-run teardown. NEVER --no-verify.

     For each agent with gate FAIL:
       bash ~/.claude/skills/execution-harness/scripts/worktree-teardown.sh \
         "$PROJECT_ROOT" "$RUN_ID" "$TASK_ID" "" --no-commit
       Update DAG: status=failed. Surface to user.

     ── FE-SPECIFIC (master, per task, after commit) ─────────────────────
     Before any FE verification:
       Bash: scripts/fe-server-check.sh $PREVIEW_URL
       Exit 1 → rebuild + retry 1x.
     After fe-visual PASS (first time per screen):
       Bash: scripts/fe-vrt-baseline.sh capture $PREVIEW_URL <route> <screen_id> \
         --harness-dir "$PROJECT_ROOT/.harness"
       Subsequent: run diff first. diff PASS → skip GAN entirely.

     ── PHASE BOUNDARY (after group that completes a phase) ─────────────
     Bash: scripts/phase-integration-gate.sh $PROJECT_ROOT $PREVIEW_URL --phase <name>
     Exit 1 → halt loop. Not WARN-only.

   Security-core gate fails twice → escalate model: "opus", effort: "high" for that task only.
   Record escalation in DAG `note` field.

   Omitting model: or effort: is the #1 token-spend bug — subagent inherits parent session values.
   ALWAYS set both explicitly per the table above.
```

Post-loop — Phase 2 + Phase 3 (master runs in sequence):

  PHASE 2: Quality
  1. delivery-metrics:  scripts/delivery-metrics.sh $PROJECT_ROOT
  2. qa-gate:           scripts/qa-gate.sh $PROJECT_ROOT $PREVIEW_URL [--fast]
     NO-GO → surface reasons, halt. User fixes tasks, re-run.
     GO    → proceed to Phase 3.

  PHASE 3: Delivery (automatic after GO)
  3. Branch and per-task commits already done during loop (P0f + Step 8).
     Just push:
     git push -u origin HEAD

  4. gh pr create with body:
     ```
     gh pr create \
       --title "<feature name>" \
       --body "$(cat <<'EOF'
     ## Summary
     [1-3 bullet points from plan.dag.json done tasks]

     ## QA Gate: GO ✓
     $(cat .harness/qa-gate.json | python3 -c "
     import json,sys
     d=json.load(sys.stdin)
     for c in d['checks']:
         icon = '✓' if c['status']=='PASS' else ('~' if c['status']=='SKIP' else '✗')
         print(f\"- {icon} {c['check']}: {c['detail']}\")
     ")

     ## Security Review
     [Summary from review-ledger.md — approved/needs-review count]

     ## Test Coverage
     - ATDD (Playwright): [N tests, all pass]
     - Behavior (Vitest): [N tests, all pass]
     - VRT: [N screens, no regression]

     🤖 Generated with execution-harness
     EOF
     )"
     ```

  5. run-report: write .harness/run-report.md (trajectory + qa-gate + PR URL)

  CI (from .github/workflows/harness-ci.yml, generated by harness) automatically:
  - Runs qa-gate.sh --fast on PR
  - Posts qa-gate results as PR comment
  - Deploys to staging on PR open
  - Post-deploy: verify GOLDEN SIGNALS, not just HTTP 200 (reference/observability.md §4):
    readiness (deps reachable) + critical-journey smoke + error-rate + p95 latency.
    Any signal red → failed deploy → rollback. Green build ≠ green prod.
  - Posts staging URL as PR comment

  Production: NEVER automatic.
  Trigger via: gh workflow run deploy-production --field confirm=true

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
- Opus as class default (→ unnecessarily expensive; use Sonnet + escalate only on 2× fail).
- Opus on rate-limit (→ same quota, burns faster; use checkpoint+backoff instead).
- Parallel writers to one shared file (→ merge conflict).
- Deploy in autonomous loop without `--deploy=staging` flag.
- Two orchestrators running simultaneously.
- **Omitting `model:` when spawning Agent** — subagent inherits parent session model.
- **Omitting `effort:` when spawning Agent** — subagent inherits parent session effort.
- **Assuming instead of asking** — any ambiguity not surfaced at Step-0 or mid-run is a harness bug.
- **Classifying all FE tasks as `refactor`** — use FE sub-classes (fe-mechanical through fe-visual). Wrong class = wrong model = Haiku trying to do failure attribution.
- **Skipping fe-server-check.sh** — FE verification without health check is unreliable (Vite may serve stale build, producing false positives that cost iteration cycles).
- **Running `ux-contract-generate.py` but skipping human approval** — only `status: approved` contracts enter the loop. Draft contracts are skipped silently.
- **Screenshotting in fe-component/fe-page** — image tokens only in `fe-visual`. Text-based conformance gate first.
- **Server data di state manual (Gap A)** — response API disimpan di `useState`/`ref`/store global sebagai sumber kebenaran → gate FAIL. Server state WAJIB lewat server-state library (TanStack/Vue Query). Store global hanya untuk UI state asli. Lihat `reference/fe-execution.md` § State Architecture.
- **Komponen tebal berisi business logic (Gap B)** — API call / logic non-trivial / transformasi kompleks di dalam komponen. Ekstrak ke hook/composable + unit-test terpisah. Komponen = presentasi tipis. Lihat § Logic/Presentation Separation.
- **Introduksi server-state library diam-diam** — kalau codebase belum punya, jangan asumsikan; itu keputusan lintas-cutting → `status: blocked` + surface ke user, jangan taruh server data di store manual sebagai jalan pintas.
- **a11y hanya mengandalkan skor Lighthouse** — Lighthouse a11y ~35% coverage, sekali di release. Best-practice: a11y lint per-commit + axe-core (`fe-a11y-check.sh`) per komponen di conformance gate. Lihat `reference/fe-execution.md` § Accessibility.
- **Perf hanya skor Lighthouse localhost** — skor agregat di localhost sembunyikan biaya network + regresi bundle. Wajib `performance-budget.json` + `fe-perf-budget.sh` (bundle-size gzip + CWV per-metrik).
- **Verifikasi FE cuma satu viewport** — layout wajib dicek min mobile (375) + desktop (1280) dari `breakpoints` di UX contract. Table→cards di mobile, no horizontal scroll.
- **Optimistic update tanpa rollback** — UI berbohong saat server tolak. Setiap mutation optimistic wajib snapshot + rollback on error + invalidate on settle. Lihat § Forms & Mutations.
- **Validasi form if-else manual** — pakai schema (zod/yup) + adapter, satu sumber kebenaran. Server 422 dipetakan ke field, bukan toast generik.
- **Memberikan instruksi setup manual ke user** — semua file (deploy-config.sh, harness-ci.yml) di-generate dan di-commit oleh master. Satu-satunya yang user lakukan manual adalah menambah GitHub secrets, karena itu menyentuh credentials.
- **Skip Project Setup Detection** — wajib cek di setiap invocation. Kalau CI belum ada, setup dulu sebelum Phase 0.
- **Skip Phase 0 karena "plan sudah ada di kepala"** — tanpa PRD/Spec/Plan yang di-approve, tidak ada SSOT. Subagent akan buat asumsi berbeda-beda.
- **Tanya satu pertanyaan sekaligus di Phase 0** — batch semua pertanyaan dalam satu pesan.
- **Generate Spec sebelum PRD di-approve** — urutan wajib: PRD → approve → Spec → approve → Plan → approve → Phase 1.
- **Asumsikan scope dari nama feature** — "build payment" bisa berarti 10 hal berbeda. Tanya.
- **Giving user manual commands to run** — ALL scripts run inside the loop by master. The ONLY human action is setting `status: approved` on UX contracts. If you find yourself writing "run this command before starting," it belongs in Step 3a or Step 8, not in user-facing text.
- **Skipping VRT baseline capture after fe-visual PASS** — master must run `fe-vrt-baseline.sh capture` automatically the first time a screen passes fe-visual. Without a baseline, every subsequent run does full GAN (expensive).
- **Skipping phase-integration-gate.sh** — must run automatically at every phase boundary, not manually triggered. If forgotten, tasks that pass individually may break each other undetected.
- **Deploying without qa-gate.sh** — deploy.sh requires qa-gate.json with verdict=GO. No gate = no deploy.
- **Auto-deploying to production** — production deploy is NEVER in the loop. Always requires explicit `deploy.sh production --confirm`. Any attempt to auto-trigger it is a harness bug.
- **Skipping rollback on health check failure** — deploy.sh calls rollback.sh automatically. Never just log the failure and leave a broken deploy in place.
- **Creating feature branch in Phase 3** — branch is created in P0f (after plan confirmed, before first task). Implementation commits must land on the feature branch from the start, not on main.
- **`git add -A` for per-task commits** — add only `files_touched` from the DAG. `git add -A` includes unrelated files (generated artifacts, .harness/ state, untracked temp files) and obscures what each task actually changed. Use specific file paths.
- **Committing a task with gate FAIL or BLOCKED** — only gate PASS earns a commit. FAIL = task not done; BLOCKED = needs user decision. Committing broken state breaks `git bisect` and corrupts the feature branch history.
- **Using `--no-verify` on pre-commit hook failure** — hooks exist for a reason (lint, typecheck, secret detection). Fix the underlying error. `--no-verify` is never acceptable inside the harness.
- **One big squash commit at Phase 3** — per-task granularity is intentional. Each commit maps to one task, one gate verdict, one traceable change. PR reviewers see the work history; `git bisect` works; blame is accurate.
- **Running git commands inside a parallel subagent** — agents in worktrees must NOT run git add/commit/push/checkout. Master owns all git operations. Agent git commands corrupt the detached-HEAD worktree and cause teardown failures.
- **Branching from stale local HEAD** — always `git fetch origin --prune` then `git checkout -b feature/X origin/main`. Without fetch, branch starts N commits behind remote, causing rebase conflicts at PR time.
- **Hardcoding `feature/` prefix** — derive from PRD type: fix/ for bugs, chore/ for tooling, hotfix/ for urgent production issues. Wrong prefix obscures intent in the PR list.
- **Skipping branch existence check** — on resume, `git checkout -b` fails if branch exists. Always: `git show-ref --verify` → checkout if exists, create if not.
- **Skipping guard against main/master** — if branch creation silently fails, per-task commits land directly on main. Always verify `git branch --show-current` after P0f before any implementation.
- **Leaving worktrees after crash** — if harness crashes mid-run, stale worktrees accumulate in /tmp. Run `git worktree list` and `git worktree remove --force` on cleanup.
- **Relying solely on agent notifications for completion** — notifications can be lost (context compaction, hook interference, parallel race). Always poll `.harness/agent-results/<task_id>.json` via `parallel-wait.sh`. Result files are the source of truth.
- **Agent not writing result file** — every parallel agent MUST call `.harness-write.sh` before returning, even on FAIL or BLOCKED. Without it, `parallel-wait.sh` will timeout waiting indefinitely.
- **Master blocking on notification with no timeout** — always use `parallel-wait.sh` with an explicit timeout. Without it, a stalled agent makes the entire group hang forever.
- **Extracting an image inline on Opus/Fable** — image extraction is always Sonnet. On a pricey master, delegate to a Sonnet sub-agent. Never OCR/read an image on Opus.
- **Taking a screenshot / surfing web inline on Opus/Fable** — summon a Sonnet sub-agent for the op and continue reasoning on the main model. Don't burn Opus tokens on browser I/O.
- **Upgrading a browser/screenshot task above Sonnet without "pakai opus"** — Sonnet is the default and ceiling for browser ops unless the user explicitly overrides.
