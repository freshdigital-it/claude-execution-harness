# Autonomy guards (hands-off ≠ runaway)

## Budget ceiling

Set before run: `HARNESS_TOKEN_BUDGET=200000` (tokens).
Master checks `/context-budget` at each phase gate. At ceiling → checkpoint + halt + run-report.

**Current status: SOFT enforcement** — instructed stop, no hard kill mechanism. There is no automatic process termination today. A PostToolUse hook checking token counters would make this hard; not yet built. Treat as disciplined self-monitoring, not a circuit breaker. The failure-breaker (K=3) is the real backstop.

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

## Deferred review — adversarial verifier contract

Security verifier is NOT a blessing pass. The verifier prompt MUST:

1. **Adversarial framing**: *"Attempt to break this implementation. Try cross-tenant access, privilege escalation, and boundary violations. Default to `REFUTED` unless you are certain the constraint holds under all inputs."*
2. **Different model** from the implementer — prevents confirmation bias. Use the next tier up from
   the implementer: Sonnet implementer → Sonnet verifier (different instance); Haiku implementer
   → Sonnet verifier. Opus is only needed if the implementer already used Opus and gate failed once.
3. **Negative tests mandatory**: at minimum — cross-tenant read, escalation attempt, invalid token/scope.
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
