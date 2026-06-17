# File schemas: plan.dag.json + review-ledger.md

## plan.dag.json

Tulis di plan-time, update per-task, jadi sumber resume deterministik.

```json
{
  "plan": "docs/plans/sprint-42.md",
  "created": "2026-06-17T10:00:00Z",
  "tasks": [
    {
      "id": "task-001",
      "title": "Add tenant binding to /api/invoices",
      "class": "security-core",
      "deps": [],
      "model": "Opus",
      "tdd": true,
      "gate": "deferred-verify",
      "split": false,
      "status": "pending"
    },
    {
      "id": "task-002",
      "title": "Sweep 40 handlers: attach tenant scope",
      "class": "mechanical-fan",
      "deps": ["task-001"],
      "model": "Sonnet",
      "tdd": false,
      "gate": "pipeline",
      "split": false,
      "status": "pending"
    }
  ]
}
```

### Field reference

| Field | Values | Set by |
|---|---|---|
| `class` | `security-core` / `business` / `bugfix` / `mechanical-fan` / `refactor` / `FE-ops` | master at plan-time |
| `model` | `Opus` / `Sonnet` / `Haiku` | derived from class |
| `tdd` | `true` / `false` | derived from class (see standing-constraints.md) |
| `gate` | `serial-human`(old) / `deferred-verify` / `pipeline` / `supervised` / `auto` | derived from class |
| `split` | `true` if file >500 lines and must be split first | master at plan-time |
| `status` | `pending` / `in-progress` / `done` / `blocked` / `failed` | master updates per-task |

---

## review-ledger.md

Append-only. Security verifier writes during run. Human reads ONCE at end.

```markdown
# Review Ledger

## 2026-06-17T10:45:00Z — task-001

**Decision:** ADD tenant binding to /api/invoices  
**Verifier:** independent (Opus, not the implementer)  
**Tests:** negative tests pass (cross-tenant access rejected)  
**Security scan:** no findings  
**Status:** APPROVED — safe to merge  

---

## 2026-06-17T11:02:00Z — task-005

**Decision:** MODIFY RBAC catalogue — add hr:self permission  
**Verifier:** independent (Opus)  
**Tests:** 3 negative tests (privilege escalation attempts) — all rejected  
**Security scan:** 1 finding (INFO) — unused import, not security-relevant  
**Status:** NEEDS REVIEW — verifier flagged: scope of hr:self vs hr:read overlap unclear  
**Action required:** human confirm hr:self cannot read other users' data  

---
```

### Status values

| Status | Meaning |
|---|---|
| `APPROVED` | Verifier confident, safe to merge |
| `NEEDS REVIEW` | Verifier unsure, human must read before merge |
| `BLOCKED` | Verifier found issue, task not committed — fix before proceed |

---

## decision-ledger.md (Perubahan 9)

Codebase-level decisions. Lives in project `docs/decision-ledger.md`.

```markdown
| Date | Decision | Reason | Module | Supersedes | Status |
|---|---|---|---|---|---|
| 2026-06-10 | supply migrations use explicit schema order | 2 conflicting migrations can't apply on fresh DB | supply | — | open |
| 2026-06-16 | Q2C portal uses staged payment schedule | finance team requirement for installment support | finance | old lump-sum approach | closed |
```
