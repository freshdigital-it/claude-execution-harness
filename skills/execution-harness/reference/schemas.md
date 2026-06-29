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
      "model": "Sonnet",
      "effort": "high",
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
      "model": "Haiku",
      "effort": "low",
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
| `model` | `Sonnet` / `Haiku` / `Opus` | derived from class (see autonomy.md routing table) |
| `effort` | `high` / `medium` / `low` | derived from class (security-core=high, business=medium, mechanical-fan/FE-ops=low) |
| `tdd` | `true` / `false` | derived from class (see standing-constraints.md) |
| `gate` | `deferred-verify` / `pipeline` / `auto` | derived from class |
| `split` | `true` if file >500 lines and must be split first | master at plan-time |
| `status` | `pending` / `in-progress` / `done` / `blocked` / `failed` | master updates per-task |
| `blocked_reason` | string — mengapa subagent tidak bisa lanjut tanpa klarifikasi | subagent returns, master copies |
| `assumption_if_unblocked` | string — apa yang akan diasumsikan jika user minta lanjut tanpa jawaban | subagent returns |
| `note` | string — frontier decision reason, user clarification answer, atau catatan lain | master |

---

## review-ledger.md

Append-only. Security verifier writes during run. Human reads ONCE at end.

```markdown
# Review Ledger

## 2026-06-17T10:45:00Z — task-001

**Decision:** ADD tenant binding to /api/invoices  
**Verifier:** independent (Sonnet, not the implementer instance)  
**Tests:** negative tests pass (cross-tenant access rejected)  
**Security scan:** no findings  
**Status:** APPROVED — safe to merge  

---

## 2026-06-17T11:02:00Z — task-005

**Decision:** MODIFY RBAC catalogue — add hr:self permission  
**Verifier:** independent (Sonnet)  
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

## decision-ledger.md

Codebase-level decisions. Lives in project `docs/decision-ledger.md`.

```markdown
| Date | Decision | Reason | Module | Supersedes | Status |
|---|---|---|---|---|---|
| 2026-06-10 | supply migrations use explicit schema order | 2 conflicting migrations can't apply on fresh DB | supply | — | open |
| 2026-06-16 | Q2C portal uses staged payment schedule | finance team requirement for installment support | finance | old lump-sum approach | closed |
```

---

## trajectory.jsonl

Append-only per-task trace. One compact JSON object per line. Location: `<project>/.harness/trajectory.jsonl`.

| Field | Type | Required | Notes |
|---|---|---|---|
| `ts` | ISO-8601 string | no | Timestamp task closed |
| `run_id` | string | no | From Step-0 `RUN_ID` |
| `task_id` | string | **yes** | Matches `plan.dag.json` task id |
| `class` | string | **yes** | Task class (business, security-core, etc.) |
| `model` | string | no | Model used |
| `approach` | string | no | Strategy chosen (e.g. "middleware scope not inline") |
| `files` | array | no | Files touched |
| `gate_result` | string | **yes** | "pass" or "fail" |
| `gate_findings` | int | no | Count of findings |
| `reflection` | string | no | Root-cause or lesson from this task |
| `tokens_est` | int | no | Estimated tokens. **Source:** try `subagent_tokens` from Agent result metadata first; if absent (unverified field — may not exist), use class constant: mechanical-fan=50000, business=60000, security-core=80000, refactor=40000. Label as "estimated" in that case. |
| `status` | string | **yes** | "done", "failed", "reverted", "blocked" |
| `assumptions` | array of string | no | Asumsi yang dibuat subagent. `[]` jika tidak ada. Jangan omit jika ada asumsi — diaudit di review. |

**Required fields (validated by `trajectory-append.sh`):** `task_id`, `class`, `status`, `gate_result`.

**Discipline:** jejak eksekusi → file JSONL, bukan agentdb. Melayani dua loop: recall plan-time + fitness offline (C4).

## frontier.json

Learned per-class routing stats. Location: `<project>/.harness/frontier.json`. Updated by `frontier-update.sh` at run-end (idempotent — recomputed from full corpus, never incremental).

```json
{
  "updated": "2026-06-19T11:00:00Z",
  "classes": {
    "business": {
      "model": "Sonnet",
      "samples": 30,
      "pass_rate": 0.93,
      "revert_rate": 0.0,
      "avg_tokens": 14000
    }
  }
}
```

| Field | Type | Notes |
|---|---|---|
| `updated` | ISO-8601 UTC | Last recompute timestamp |
| `classes.<name>.model` | string | Most recent model used for this class |
| `classes.<name>.samples` | int | Total tasks in corpus for this class |
| `classes.<name>.pass_rate` | float (0–1) | Fraction with `gate_result == "pass"` |
| `classes.<name>.revert_rate` | float (0–1) | Fraction with `status in (reverted, blocked)` |
| `classes.<name>.avg_tokens` | int | Average `tokens_est` across corpus. Note: if `subagent_tokens` was unavailable and class constants were used, this value is a floor estimate, not a measurement. |

**`safe_to_downgrade` guard:** `samples ≥ 10 AND revert_rate == 0.0 AND pass_rate ≥ 0.9`. Evaluated by `frontier-route.sh`. Advisory only — master always decides.

**Haiku downgrade note:** when `safe_to_downgrade=true` for `mechanical-fan`, the corpus evidence is for the *current* model (usually Sonnet). Downgrading to Haiku is always a cold start — no Haiku samples exist. `frontier-route.sh` flags this explicitly via `downgrade_note`. Master must record the deliberate cold-start reason in the DAG `note` field.
