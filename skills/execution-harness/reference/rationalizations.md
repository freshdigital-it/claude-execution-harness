# Anti-Rationalization Tables

Agents (and humans) cut corners by telling themselves a plausible story. This file
lists the stories and their rebuttals. When you catch yourself reaching for a
left-column excuse, the right column is the standing answer — do the work.

Injected into every subagent alongside standing-constraints. If a subagent's
reasoning matches a left-column phrase, it must follow the rebuttal, not the excuse.

## Verification & testing

| Rationalization | Rebuttal |
|---|---|
| "The change is trivial, no test needed." | Trivial changes ship trivial bugs. If it's truly trivial the test is one line — write it. |
| "Tests are slow, I'll run them at the end." | The gate is per-task for a reason: a green task you can't reproduce isn't done. Run them now. |
| "It builds, so it works." | Build ≠ behavior. A green `tsc` says nothing about whether the empty state renders. Verify behavior. |
| "I verified it manually, that's enough." | Manual verification isn't reproducible and doesn't guard regressions. Encode it as a test. |
| "Deploy succeeded, so we're good." | Deploy ≠ healthy. Check golden signals (observability §4), not just HTTP 200. |
| "I'll add the negative test later." | Later never comes and the exploit ships. Security-core commits require the negative test now. |

## Scope & simplicity

| Rationalization | Rebuttal |
|---|---|
| "While I'm here, I'll also refactor X." | Every changed line must trace to the task. Note the refactor, don't do it (behavioral.md surgical-changes). |
| "I'll make it configurable for the future." | YAGNI. Build what's asked. Speculative flexibility is dead weight you'll debug later. |
| "This abstraction will be reused eventually." | One caller = no abstraction. Extract on the second use, not the first. |
| "The task is vague but I think they mean X." | Ambiguity surfaced late is a harness bug. Ask at Step-0, don't assume (never-assume [HARD]). |
| "I'll just make the file a bit longer." | 300-LOC is a hard limit. Split by responsibility instead of growing a god-file. |

## Architecture (FE/state)

| Rationalization | Rebuttal |
|---|---|
| "I'll cache the API response in a ref for now." | Server data belongs in the server-state library, not manual state. "For now" becomes the stale-cache bug (fe-execution §State Architecture). |
| "The component's small, logic inline is fine." | Inline logic isn't unit-testable. Extract to hook/composable — thin components are the testability contract. |
| "Optimistic update without rollback is simpler." | Simpler until the server rejects and the UI lies. Rollback is not optional. |
| "One viewport is enough to check." | Mobile is where layouts break. Verify 375 + 1280 (multi-viewport gate). |

## Security & data

| Rationalization | Rebuttal |
|---|---|
| "Auth is checked upstream, skip it here." | Defense in depth. Check at the boundary that owns the resource, not by assumption. |
| "I'll parametrize the query later." | String-concatenated SQL is an injection now. Parameterize before the commit, always. |
| "It's just a log line." | A log line with a token is an exfiltration path. Redact PII/secrets at the boundary. |
| "`--no-verify` just this once, the hook is annoying." | The hook is the control. Fix the underlying error; `--no-verify` is never acceptable in the harness. |

## Process

| Rationalization | Rebuttal |
|---|---|
| "I'll skip Phase 0, the plan's in my head." | No approved PRD/Spec/Plan = no SSOT = subagents diverge. Run Phase 0. |
| "Notifications will tell me when the agent's done." | Notifications can be lost. Poll the durable result file (parallel-wait.sh). |
| "I'll commit all files with `git add -A`." | Commit only the task's `files_touched`. `-A` hides what changed and pollutes the diff. |
| "The gate failed but it's a flake, I'll commit anyway." | A failing or blocked gate never earns a commit. Diagnose the flake or fix the code. |
