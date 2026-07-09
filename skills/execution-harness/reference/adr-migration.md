# ADRs & Migration Safety

Two disciplines the harness had informally (decision-ledger, "migration rollback"
field in Spec) now made first-class.

---

## Architecture Decision Records (ADR)

The decision-ledger records that a decision exists; an ADR records *why* — so future
work (and future subagents) don't relitigate or silently violate it.

**Write an ADR when a decision is:** hard to reverse, cross-cutting, or non-obvious
(picked A over a reasonable B). NOT for routine choices.

Format — `docs/adr/NNNN-title.md`:
```markdown
# ADR-0007: Use event-driven cross-domain communication
**Status:** accepted   (proposed | accepted | superseded by ADR-XXXX)
**Date:** YYYY-MM-DD

## Context
What forces are at play — constraints, requirements, the problem.

## Decision
What we chose, stated plainly.

## Consequences
What becomes easier, what becomes harder, what we're now committed to.

## Alternatives considered
B, and why we didn't pick it.
```

**Wiring:**
- Plan-time: decision-ledger reconciliation (lifecycle.md) checks ADRs for conflicts.
  A task that contradicts an `accepted` ADR → surface to user before running.
- Run-end: a new hard-to-reverse decision made during the run → write/append an ADR,
  don't just leave it in a commit message.
- Superseding: never delete an ADR. Set `Status: superseded by ADR-XXXX` and write the new one.

---

## Migration Safety

A schema/data migration is the highest-blast-radius change in the system. Rules:

**1. Forward + rollback are both required.** The Spec's Data Model section already asks
for a rollback path — it is mandatory when production data exists. A migration with no
tested `down` → gate FAIL.

**2. Expand-contract (never break in one step).** For a rename/type-change/removal on a
live column, do it in phases across deploys, not atomically:
```
Expand:   add the new column/table, write to BOTH old and new
Migrate:  backfill existing rows; app reads new, still writes both
Contract: stop writing old, drop it — in a LATER deploy, after verification
```
This keeps the old and new app versions both working during rollout (no downtime,
safe rollback at every step).

**3. Additive-first.** Prefer adding over altering. Adding a nullable column or a new
table is safe; changing a type or dropping a column is not.

**4. No destructive migration without a two-phase plan.** `DROP COLUMN` / `DROP TABLE` /
data-deleting UPDATEs are never in the same migration that introduces the replacement.
Ship the replacement, verify, then a later migration removes the old.

**5. Backfills are batched & resumable.** A backfill over a large table runs in batches
(not one giant UPDATE that locks the table) and can resume if interrupted.

**6. Test on a realistic copy.** Run the migration forward AND back on a seed/snapshot
that matches production shape (ties to lifecycle.md migration workaround), not an empty DB.

---

## Anti-patterns

- **Migration with no `down`** — you can't roll back a bad deploy. Always write + test the reverse.
- **Rename/drop in one atomic migration on a live column** — breaks the old app version mid-rollout. Expand-contract instead.
- **`DROP` in the same migration as the replacement** — leaves no verification window. Two phases, two deploys.
- **One giant `UPDATE` backfill** — locks the table, takes prod down. Batch it.
- **Deleting an ADR because it's "outdated"** — supersede, don't delete. The history is the point.
- **A cross-cutting decision that lives only in a commit message** — write the ADR; commit messages aren't discoverable at plan-time.
