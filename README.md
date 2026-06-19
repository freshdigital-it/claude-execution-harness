# claude-execution-harness

**Claude Code autopilot with self-healing memory: give it a plan, come back to a working localhost.**

Most Claude Code sessions look like this:

```
You: implement feature X
Claude: done — review security logic? [y/N]
You: y
Claude: done — approve this approach? [y/N]
You: y
Claude: one more thing — is this the right pattern? [y/N]
...
```

This skill eliminates every mid-run interruption. One command, it builds, tests,
runs security review in the background, and hands you a localhost URL to verify.
**You review once, at the end.**

```
/execution-harness
```

---

## Before / After

| Before | After |
|---|---|
| Interrupted every security task | Security review deferred — `review-ledger.md` at end |
| No enforcement on file size | 300-LOC hook blocks oversized writes in master + subagents |
| Context lost after compaction | `plan.dag.json` resumes deterministically |
| Ends at `git commit` | Ends at `localhost:PORT` — click to verify |
| Re-discovers same bugs each run | `agentdb` remembers gotchas across runs |
| No record of what ran or why | `trajectory.jsonl` — one row per task, append-only |
| Can finish without writing trajectory | Stop hook mechanically blocks early exit |
| Routing guesses model per task | `frontier.json` learns pass/fail rates across runs |

---

## Quick demo

```
$ /execution-harness

[harness] Reading plan: docs/plans/auth-refactor.md
[harness] Classified 5 tasks → plan.dag.json written
[harness] frontier.json: mechanical-fan safe_to_downgrade=false (6 samples, need 10)
[harness] Recalled 2 gotchas from previous runs

[task-001] security-core: add tenant isolation to /api/users — spawning Opus...
[task-001] done. Adversarial verifier: NEEDS_REVIEW (1 finding → review-ledger.md)
[task-001] trajectory appended (row 1/5)
[task-002] business: add export endpoint — spawning Sonnet...
[task-002] done. Tests: 4 passed.
[task-002] trajectory appended (row 2/5)
[task-003] mechanical-fan: add error return types (12 files) — spawning Sonnet...
[task-003] done. 12 files patched.
[task-003] trajectory appended (row 3/5)
[task-004] bugfix: fix TestHandleGetItem_Found — spawning Sonnet...
[task-004] done. Tests: all green.
[task-004] trajectory appended (row 4/5)
[task-005] FE-ops: update status page — spawning Sonnet...
[task-005] done.
[task-005] trajectory appended (row 5/5)

[harness] Simplify pass: no over-engineering detected.
[harness] frontier.json updated (mechanical-fan: 7 samples, pass_rate 1.0)
[harness] Starting local preview...
[preview] BE ready at http://localhost:54321
[preview] FE ready at http://localhost:54322

==============================
 PREVIEW READY
 FE: http://localhost:54322  ← verify here
 BE: http://localhost:54321
 Smoke: PASS
==============================

[harness] run-report-2026-06-17.md written.
[harness] review-ledger.md: 1 item needs human review before merge.
```

---

## Install

**Prerequisites:**

```bash
# 1. ECC — typed subagent specialists (the "muscle")
claude /plugin install affaan-m/ECC

# 2. Superpowers — skill routing
claude /plugin install obra/superpowers

# 3. claude-flow — agentdb cross-run memory (pattern_store / pattern_search)
claude /plugin install ruvnet/claude-flow
```

**Install the harness:**

```bash
git clone https://github.com/freshdigital-it/claude-execution-harness
cd claude-execution-harness
bash setup.sh
```

**Wire hooks** (once per project, in `.claude/settings.json`):

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Write|Edit",
      "hooks": [{ "type": "command",
        "command": "~/.claude/skills/execution-harness/scripts/hooks/pretooluse-filesize.sh"
      }]
    }],
    "Stop": [{
      "hooks": [{ "type": "command",
        "command": "~/.claude/skills/execution-harness/scripts/hooks/harness-runend-guard.sh"
      }]
    }]
  }
}
```

The **Stop hook** is new — it blocks Claude from ending a harness run until every
completed task has a trajectory row and a `run-report-*.md` exists. Mechanical
enforcement, not honor-system.

---

## How it works

Tasks are classified **once at plan-time** — no mid-run decisions:

| Class | Model | TDD | Review |
|---|---|---|---|
| `security-core` | Opus | test-first | adversarial verifier → `review-ledger.md` |
| `business` / `bugfix` | Sonnet | test-first | auto gate |
| `mechanical-fan` | Sonnet | none | pipeline (bulk) |
| `FE-ops` / `refactor` | Sonnet | none | auto gate |

Each task runs in an ephemeral subagent. The master holds only the DAG and
checkpoint log — subagents return bounded summaries, never raw output.

**Security without interruption:** security-core tasks get an independent adversarial
verifier (different model, mandatory negative tests). If it finds an issue, it's logged
to `review-ledger.md` — you read the ledger once at the end, not once per task.

**Resume after any interruption:** `plan.dag.json` tracks every task's status.
Restart the session, run `/execution-harness` again — it skips done tasks automatically.

---

## Self-healing memory (C1–C3)

Three mechanisms that make the harness learn from its own history:

### C1 — Trajectory (`trajectory.jsonl`)

Every task appends one row at close via `scripts/trajectory-append.sh`:

```json
{"ts":"2026-06-17T14:30:00Z","run_id":"run-20260617-143000",
 "task_id":"task-003","class":"mechanical-fan","model":"Sonnet",
 "status":"done","gate_result":"pass","tokens_est":51000,
 "approach":"sweep 12 files, add missing return types",
 "reflection":"bulk files: glob first, then single Edit per file"}
```

The `approach` and `reflection` fields make each run a lesson for the next.

### C2 — Stop hook (`harness-runend-guard.sh`)

A `Stop` hook that refuses to end the session if the trajectory is incomplete:

```
harness-runend-guard: trajectory incomplete: 4 rows for 5 done tasks —
append missing rows + run-end memory flush before finishing
```

No row = no exit. The machine enforces what the model might forget.

### C3 — Frontier routing (`frontier.json`)

Aggregates pass rates, revert rates, and token usage per task class across all runs.
Advisory only — suggests a model downgrade when the data justifies it:

```json
{
  "classes": {
    "mechanical-fan": {
      "samples": 21, "pass_rate": 0.95, "revert_rate": 0.0,
      "avg_tokens": 48200, "safe_to_downgrade": true
    }
  }
}
```

`safe_to_downgrade: true` requires `samples >= 10 AND revert_rate == 0 AND pass_rate >= 0.9`.
Master always decides — frontier injects data, never auto-applies.

---

## Key features

- **300-LOC enforcement** — PreToolUse hook blocks oversized writes in the master session
  *and* in all spawned subagents. Verified empirically (hook fires inside Agent tool spawns).

- **Local preview isolation** — each run gets its own port and throwaway database.
  Two parallel runs never collide.

- **Cross-run memory** — `agentdb_pattern_store` records gotchas at run-end.
  Next run's plan-time recalls them so the same mistake isn't made twice.

- **Trajectory tracking** — append-only per-task log with approach + reflection.
  Enforced by Stop hook. Powers frontier routing at plan-time.

- **Learned routing** — `frontier.json` accumulates pass/revert/token stats per class.
  Advisory model downgrade when confidence is high enough (10+ samples, zero reverts).

- **Decision-ledger reconciliation** — plan-time checks for conflicts with past
  architectural decisions (via `code-review-graph` impact radius + keyword match).
  Conflicts are surfaced *before* the first task, not mid-run.

- **Simplify pass** — after the loop, one agent checks for over-engineering in the
  diff (dead code, single-use abstractions). Safe removals applied automatically.

---

## What's in this repo

```
skills/execution-harness/
  SKILL.md                     — invoked by /execution-harness
  reference/
    lifecycle.md               — full phase sequence + isolation + learned routing
    autonomy.md                — budget ceiling, failure-breaker, adversarial verifier
    standing-constraints.md    — 300-LOC, 30-line methods, TDD-by-class, memory
    schemas.md                 — plan.dag.json, trajectory.jsonl, frontier.json schemas
    verification.md            — empirical test procedures + acceptance test (8 asserts)
  scripts/
    local-preview.sh           — isolated BE+FE local instance (auto port, throwaway DB)
    check_file_sizes.sh        — 300-LOC gate for CI / pre-commit
    deploy-lock.sh             — explicit deploy gate (never called automatically)
    trajectory-append.sh       — validate + append one trajectory row (C1)
    frontier-update.sh         — recompute frontier.json from full corpus (C3)
    frontier-route.sh          — advisory safe_to_downgrade readout (C3)
    hooks/
      pretooluse-filesize.sh   — PreToolUse: 300-LOC gate
      harness-runend-guard.sh  — Stop: block exit until trajectory complete (C2)
    tests/
      run-all.sh               — run all test-*.sh, exit non-zero on any fail
      test-trajectory-append.sh
      test-runend-guard.sh
      test-frontier-update.sh
      test-frontier-route.sh

rules/
  clean-architecture.md        — file/method size, single responsibility, type safety
  behavioral.md                — think-before-coding, simplicity-first, surgical changes

docs/design-decisions.md       — full reasoning behind every architectural choice
CLAUDE.md.template             — copy to your project root and customize
setup.sh                       — one-command install
```

---

## Run the tests

```bash
bash ~/.claude/skills/execution-harness/scripts/tests/run-all.sh
# → ALL PASS (4 test files: trajectory-append, runend-guard, frontier-update, frontier-route)
```

---

## Built on the shoulders of

This project synthesizes ideas from several open-source projects and research.
No code was copied — only patterns were adapted. Full credits: [ATTRIBUTION.md](ATTRIBUTION.md).

| Project | What was borrowed |
|---|---|
| [obra/superpowers](https://github.com/obra/superpowers) | Skill routing pattern |
| [affaan-m/ECC](https://github.com/affaan-m/ECC) | Typed subagent catalog ("the muscle") |
| [nousresearch/hermes-agent](https://github.com/nousresearch/hermes-agent) | Episodic memory + trajectory capture |
| [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) | YAGNI decision ladder |
| SWE-agent, OpenHands, Voyager, Reflexion | ACI output design, sandbox isolation, skill library, reflect-on-fail |

---

## License

MIT — see [LICENSE](LICENSE).
ECC and Superpowers have their own licenses; this repo contains only the harness layer.
