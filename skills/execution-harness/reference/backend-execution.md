# Backend / API Execution Playbook

Parallel to `fe-execution.md`, for backend & API tasks (`business`, `security-core`,
and API-wiring work). The harness was FE-heavy; this restores backend rigor.
Framework/language-agnostic (Go, Node, Python, PHP, …).

Applies to task classes: `business`, `bugfix`, `security-core` when they touch
endpoints, services, or data.

---

## API Contract Discipline (gate criterion)

**Contract-first.** The API contract (request/response shape, status codes, auth,
errors) is defined in the Spec BEFORE implementation — same SSOT idea as UX contracts.
Implementation makes the contract real; it does not invent it.

- **Explicit error semantics.** Every endpoint documents its failure modes with the
  right status: `400` validation, `401` unauth, `403` forbidden, `404` absent,
  `409` conflict, `422` business-rule violation, `429` rate-limit, `5xx` server.
  A handler that returns `500` for a validation error → gate FAIL.
- **Errors are structured & stable.** `{code, message, details}` — `code` is a stable
  machine string (`INSUFFICIENT_CREDIT`), `message` is human, never a raw stack trace.
- **Validation at the boundary.** Validate/parse input at the HTTP edge, not deep in
  business logic. Reject malformed early with `400`/`422`.
- **Idempotency.** Any create/mutation that a client may retry (payments, orders)
  accepts an idempotency key or is naturally idempotent. Double-POST must not double-charge.
- **Versioning & Hyrum's Law.** Assume every observable behavior becomes a dependency.
  Additive changes only within a version; breaking changes → new version. Don't quietly
  change a response shape.
- **Pagination & limits.** List endpoints paginate and cap page size — no unbounded queries.

Example error contract (synthetic):
```json
{ "code": "SESSION_PACKAGE_EXPIRED", "message": "Paket sesi sudah habis masa berlaku", "details": {"expired_at": "..."} }
```

## Auth & tenancy (security-core)

- Authorization in middleware/policy, never inline `if user.role == ...` in business logic.
- Multi-tenant: every query is tenant-scoped. The adversarial verifier's cross-tenant
  read test (autonomy.md Sub-step B) is mandatory for any data endpoint.
- Never trust client-supplied `tenant_id`/`user_id` — derive from the authenticated context.

## Testing layers (backend)

| Layer | What | When |
|---|---|---|
| Unit | Pure domain logic (calculations, state machines, validators) — no I/O | test-first for `business`/`security-core` |
| Integration | Real DB / real dependencies — repository, migration, transaction behavior | DB-backed tests (not mocked away) |
| Contract | Response shape + status codes match the Spec contract | per endpoint |
| Negative (security-core) | cross-tenant, injection, authz bypass, invalid token | mandatory, adversarial verifier |

**Beware the CI-skips-DB trap:** if CI runs `go test` / `pytest` without a database,
DB-backed tests silently SKIP and regressions ship. Integration tests must run against
a real DB in CI (service container), and the suite must FAIL (not skip) when the DB is absent
for a test that needs it.

## Transactions & consistency

- Multi-write operations run in a transaction; partial failure must not leave half-state.
- Cross-service writes: no distributed transaction — use events + idempotent consumers,
  and make the operation retry-safe.

---

## Anti-patterns

- **`500` for a validation error** — use `400`/`422`. `5xx` means *we* broke, not the client.
- **Raw error / stack trace in the response body** — leaks internals; return a stable `code`.
- **Auth check inside business logic** — belongs in middleware/policy. Business logic assumes authorized.
- **Trusting client `tenant_id`** — cross-tenant data leak waiting to happen. Derive from auth context.
- **Non-idempotent money mutation** — a retried POST double-charges. Idempotency key or natural idempotency.
- **Unbounded list query** — no pagination = the query that takes down prod at scale.
- **Mocking the DB in the only test that exercises it** — you tested the mock, not the repository.
