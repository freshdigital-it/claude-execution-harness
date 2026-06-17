---
alwaysApply: true
---

# Behavioral Rules — How to Work, Not What to Build
# Adapted from Karpathy's CLAUDE.md. Applies ALL projects, ALL languages.

## CRITICAL: Complements clean-architecture.md (structural). These govern PROCESS.

---

## 1. Think Before Coding **[HARD]**

- State assumptions explicitly before implementing.
- If multiple valid interpretations exist, name them — don't silently pick one.
- If simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- **Never hide confusion behind plausible-looking code.**

## 2. Simplicity First **[HARD]**

- Minimum code that solves what was asked. Nothing speculative.
- No features beyond the request.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for scenarios that cannot happen.
- Test: if you wrote 200 lines and it could be 50, rewrite it.

## 3. Surgical Changes **[HARD]**

When editing existing code:
- Touch only what the task requires.
- Do NOT "improve" adjacent code, comments, or formatting.
- Do NOT refactor things that aren't broken.
- Match existing style even if you'd do it differently.
- If you notice unrelated dead code — mention it, don't delete it.

When your changes create orphans:
- Remove imports/vars/functions that YOUR changes made unused.
- Do NOT remove pre-existing dead code unless asked.

**Test: every changed line must trace directly to the user's request.**

## 4. Goal-Driven Execution **[SOFT]**

Transform tasks into verifiable goals before starting:
- "Fix bug" → "Write test that reproduces it, then make it pass"
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state brief plan:
```
1. [step] → verify: [check]
2. [step] → verify: [check]
```

Weak criteria ("make it work") require constant clarification — avoid.
