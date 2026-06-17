# Attribution

This project synthesizes ideas from several open-source projects and research papers.
No code was copied — only patterns, concepts, and methodologies were adapted.

---

## Direct inspirations

### obra/superpowers
- **Repo:** https://github.com/obra/superpowers
- **What was borrowed:** The skill-based routing system — `/using-superpowers` pattern for
  dispatching Claude Code to the right skill before any action. The concept of skills as
  composable policy layers on top of Claude's capabilities.
- **This project adds:** The execution-harness skill that sits on top of the superpowers
  routing layer, adding a full task-loop with DAG state, deferred review, and local preview.

### affaan-m/ECC (Everything Claude Code)
- **Repo:** https://github.com/affaan-m/ECC
- **What was borrowed:** The typed subagent catalog (security-reviewer, go-reviewer, tdd-guide,
  refactor-cleaner, etc.) as callable specialists. The concept of "muscle vs. policy":
  ECC provides the implementation muscle, the harness provides the orchestration policy.
- **This project adds:** The master controller loop, task classification at plan-time,
  deferred-review gate, and local-preview isolation.

### nousresearch/hermes-agent
- **Repo:** https://github.com/nousresearch/hermes-agent
- **What was borrowed:** FTS5 episodic recall pattern (adapted to `agentdb_pattern_search`),
  trajectory capture to files, and the idea of a durable memory store that persists across
  agent runs to prevent re-discovering known gotchas.
- **This project adds:** Integration into the harness plan-time/run-end lifecycle steps.

### DietrichGebert/ponytail
- **Repo:** https://github.com/DietrichGebert/ponytail
- **What was borrowed:** The 6-step YAGNI-first decision ladder — a checklist that runs
  before any new code is written to prevent over-engineering. Also the principle of
  "readability beats raw brevity" (named helper > clever one-liner).
- **This project adds:** The ladder is injected as a standing constraint into every subagent
  prompt so it applies to all AI-written code, not just human-reviewed code.

---

## Research papers (patterns adapted, no code)

| Paper / Project | Pattern borrowed | Where used |
|---|---|---|
| **SWE-agent** (Princeton) | ACI / observation design — bounded, filtered subagent output contract `{status, summary, next_actions, artifacts}` | `reference/standing-constraints.md` subagent return format |
| **OpenHands** (AllHands-AI) | Event-stream loop + sandboxed runtime isolation | `reference/lifecycle.md` per-worktree isolation |
| **Voyager** (MineDojo) | Skill library that grows + self-verify on use | `agentdb_pattern_store` at run-end |
| **Reflexion** (Shinn et al.) | Reflect-on-failure before retry, cap retries at K | `reference/autonomy.md` reflexion pattern |

---

## Rules adaptation

### Karpathy CLAUDE.md
- **Source:** https://twitter.com/karpathy (various posts on Claude Code configuration)
- **What was adapted:** The behavioral rules in `rules/behavioral.md` — think-before-coding,
  simplicity-first, surgical changes, goal-driven execution. These were extended and
  reformulated as enforceable rules injected into every subagent.

---

## What is original in this project

The following are original contributions not derived from any of the above:

1. **execution-harness skill** (`skills/execution-harness/`) — the master-controller pattern
   with `plan.dag.json` durable state, task-class gradient (security-core → FE-ops),
   deferred adversarial review, and the simplify pass.

2. **Adversarial verifier contract** — the specific framing ("attempt to break this, default
   to REFUTED"), mandatory negative tests, and `{verdict, findings, confidence}` schema.

3. **Decision-ledger reconciliation** — plan-time conflict detection using keyword matching
   against `docs/decision-ledger.md` entries with `code-review-graph` impact radius.

4. **local-preview.sh** — isolated local instance with auto-port allocation, throwaway DB,
   and per-project env var overrides (`GO_CMD`, `DB_ENV_VAR`, `FE_DIR`).

5. **pretooluse-filesize.sh** — PreToolUse hook that computes the *resulting* file size for
   Edit operations (not just the fragment size) to enforce 300/500-line limits mechanically.
