# Observability — close the loop after ship

The harness ships code but was blind afterward (one `curl /health`). This closes
the gap: shipped code must be *observable* and *verified healthy in production*,
not just deployed. Framework/stack-agnostic.

Applies at two points:
- **Build-time gate** (`business` / `fe-api-wiring` / backend tasks): new code paths
  must emit the right signals.
- **Phase 3 post-deploy**: verify golden signals, not just a 200 on `/health`.

---

## 1. Structured logging (gate criterion)

- Logs are **JSON**, one event per line — never `printf`/`console.log` prose in prod paths.
- Every log line carries correlation context: `request_id` / `trace_id`, `tenant_id`
  (multi-tenant), `route`, `status`, `latency_ms`.
- **Levels mean something**: `error` = needs human/alert; `warn` = degraded but handled;
  `info` = business event; `debug` = off in prod.
- **Never log secrets or PII** (tokens, passwords, full card/NIK). Redact at the boundary.
- A new endpoint/handler without a structured log on error path → gate FAIL.

Example event (synthetic):
```json
{"ts":"...","level":"error","trace_id":"abc","tenant_id":"t1","route":"POST /invoices","status":500,"latency_ms":812,"err":"gl_post_failed"}
```

## 2. RED metrics (the three that matter for request-driven services)

Every service endpoint should expose:
- **R**ate — requests/sec
- **E**rrors — failed requests/sec (and error ratio)
- **D**uration — latency distribution (p50/p95/p99), not just average

For async/queue work use **USE** (Utilization, Saturation, Errors) instead.
A new endpoint with no metric on error/duration → flag in review-ledger.

## 3. Tracing (for anything crossing a boundary)

- Propagate a trace context across service / queue / external-API hops (OpenTelemetry
  or the stack's equivalent). One `trace_id` should stitch a request end-to-end.
- Span the expensive/risky spots: DB calls, external gateways (payment, WA), GL posting.
- Don't trace everything — trace boundaries and known-slow paths.

## 4. Post-deploy verification (Phase 3 — replaces the single curl)

After staging deploy, before declaring success, verify **golden signals**, not just liveness:
```
1. Health endpoint 200 (liveness)          — necessary, not sufficient
2. Readiness: dependencies reachable (DB, cache, gateway) via /ready or a probe
3. Smoke the critical journey(s) end-to-end (the ATDD Playwright critical-path subset)
4. Error rate over the first N minutes stays under threshold (watch the RED error signal)
5. p95 latency within budget (ties to performance-budget.json)
```
Any of 2-5 failing → treat as a failed deploy → trigger rollback (deploy.sh already
calls rollback.sh; extend its health check to these signals, not just HTTP 200).

## 5. Error tracking (runtime, not build)

- Wire an error tracker (Sentry-style) for unhandled exceptions + frontend error boundaries.
- The FE production-grade rubric already scores "error boundary" — this makes those
  boundaries *report*, not just render a fallback.

---

## Anti-patterns

- **`/health` returns 200 while dependencies are down** — health must reflect readiness, not just "process alive."
- **Average latency as the SLO** — averages hide the p99 tail where users actually hurt. Track percentiles.
- **Logging the happy path only** — the error path is the one you'll read at 2am. Log it structured.
- **Deploy = success** — deploy is not verified until golden signals are green. Green build ≠ green prod.
- **Secrets/PII in logs** — a logging statement is an exfiltration path. Redact at the boundary.
