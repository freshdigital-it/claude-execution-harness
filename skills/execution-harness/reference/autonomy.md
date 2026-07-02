# Autonomy guards (hands-off ≠ runaway)

## Budget ceiling

Set before run: `HARNESS_TOKEN_CEILING=200000` (tokens, env var for hook).
Master checks `/context-budget` at each phase gate. At ceiling → checkpoint + halt + run-report.

**HARD enforcement via PostToolUse hook** (`scripts/hooks/posttooluse-token-ceiling.sh`).
Wire in project `.claude/settings.json`:
```json
"PostToolUse": [{ "hooks": [{ "type": "command",
  "command": "HARNESS_TOKEN_CEILING=300000 ~/.claude/skills/execution-harness/scripts/hooks/posttooluse-token-ceiling.sh"
}] }]
```
Hook sums `tokens_est` from `trajectory.jsonl` for current `RUN_ID`. At ceiling: writes `.harness/ceiling-breached` flag, exits 2 → Claude Code surfaces and halts. Warns at 80%.
The failure-breaker (K=3) remains the real backstop for task-level runaway.

## Failure-breaker

K=3 consecutive gate failures on the same task:
1. `/harness-audit` (diagnose root cause)
2. halt + write run-report
3. Mark task BLOCKED with reason

Do NOT retry blind (Reflexion pattern: reflect → different strategy ≤ K, then BLOCKED).

## Reflexion on gate fail

Subagent writes ≤5-line root-cause reflection before retry:
- What failed and why
- What strategy changes in next attempt

Max K retries with different strategies. After K → BLOCKED.

## Model + effort routing

```
class             model    effort   notes
─────────────────────────────────────────────────────────────────────
security-core     Sonnet   high     Opus only on 2× gate fail (proven difficulty, not default)
business/bugfix   Sonnet   medium
mechanical-fan    Haiku    low      Sonnet if context >10 files or complex branching
refactor/FE-ops   Haiku    low      Sonnet if architectural judgment required
─────────────────────────────────────────────────────────────────────
Sonnet stuck (gate fail ×2)  → escalate to Opus, record reason in DAG note
rate-limit                   → checkpoint + backoff + resume  (NOT Opus — same quota, burns faster)
Opus stuck                   → BLOCKED (halt + report to human)
```

ALWAYS pass both `model:` and `effort:` when spawning Agent. Omitting either lets subagent inherit
parent session defaults — if master runs on Opus at default effort, all subagents inherit both.

## Verification model policy (QA is cheaper than implementation)

Verification/QA model is resolved RELATIVE to the implementation model, not hardcoded.
Master resolves it per verifier spawn:

```bash
V=$(scripts/verify-model.sh <impl_model> <task_class>)   # -> haiku | sonnet | opus
# then spawn verifier Agent with model: "$V"
```

Model ladder: `haiku(1) < sonnet(2) < opus(3)`.

`HARNESS_VERIFY_POLICY` env var controls the rule:

| Policy | Behavior | Opus impl -> verifier |
|---|---|---|
| `one-below` (default) | implementer - 1 tier, floored | **Sonnet** |
| `equal` | same tier as implementer | Opus |
| `fixed:<model>` | always this model | (whatever you set) |

**Per-class floor (one-below only):** everything that spawns an LLM verifier floors at
Sonnet — security adversarial verifier, fe-visual GAN evaluator, business/bugfix correctness.
Only `mechanical-fan`, `refactor`, `fe-mechanical` may drop to Haiku, and those use
deterministic gates (tsc/linter) so they rarely call the resolver at all. Net effect:
one-below only ever bites when the implementer was Opus → verifier becomes Sonnet.

This is the generator/verifier asymmetry: a strong implementer (Opus) is checked by a
capable-but-cheaper verifier (Sonnet 5). The default gives exactly "Opus builds, Sonnet verifies."

Applies to EVERY LLM verification spawn: the adversarial security verifier (Sub-step B below)
and the GAN evaluator for `fe-visual`. Deterministic gates (SAST/SCA, tsc, linter, qa-gate.sh
checks) are model-independent and unaffected.

## Deferred review — adversarial verifier contract

Security verifier is NOT a blessing pass. The verifier gate has two sub-steps:

### Sub-step A: SAST + SCA scan (zero LLM tokens)
Run `scripts/security-scan.sh <project_root> --changed-only` before spawning the LLM verifier.
- HIGH/CRITICAL findings → task does not proceed to LLM verifier → BLOCKED immediately.
- No tools available → WARN, log, proceed to LLM verifier (partial coverage disclosed).
- Tool: semgrep (SAST) + govulncheck / npm audit / pip-audit (SCA, by stack).
- Coverage: secrets, injection patterns, insecure deserialization, known CVEs in dependencies.
- This step costs ZERO LLM tokens — run it every security-core task without hesitation.

### Sub-step B: LLM adversarial verifier (~80k tokens, Sonnet)
Only runs after Sub-step A passes. Verifier prompt MUST:

1. **Adversarial framing**: *"Attempt to break this implementation. Try cross-tenant access, privilege escalation, injection, and boundary violations. Default to `REFUTED` unless you are certain the constraint holds under all inputs."*
2. **Different instance, model per verification policy** (a fresh instance prevents confirmation bias). Resolve with `scripts/verify-model.sh <impl_model> security-core` — under the default `one-below` policy: Opus impl → Sonnet verifier; Sonnet/Haiku impl → Sonnet verifier (security floor). Escalate verifier to Opus only if the gate already failed once at the resolved tier.
3. **Negative tests mandatory**: cross-tenant read, privilege escalation, invalid token/scope, injection attempt (SQL / path traversal), secrets-in-response check.
4. **Return contract**: `{verdict: APPROVED|NEEDS_REVIEW|BLOCKED, findings: [{issue, severity, proof}], confidence: high|medium|low}`.

Verdict meanings:
- `APPROVED` — adversarial attempts failed, confident safe to merge.
- `NEEDS_REVIEW` — verifier uncertain; human must inspect before merge.
- `BLOCKED` — found exploitable issue; implementer must fix, task does not commit.

## Stop-on-destructive / outward

Any action that is irreversible or outward-facing:
- `rm -rf`, force-push, drop table, `git reset --hard`
- Push to remote, send message, deploy, email

→ STOP immediately + run-report + wait for human.
Even if plan authorizes it. Authorization is per-action, not per-session.

## Strategic compaction

Run `/strategic-compact` at phase gates, not reactively mid-task.
Master holds pointer + slice, never raw corpus.

## Recovery sequence

```
loop churning
  → freeze current task
  → /harness-audit (scope=failing unit)
  → reduce scope or change strategy
  → replay with explicit acceptance criteria
```
