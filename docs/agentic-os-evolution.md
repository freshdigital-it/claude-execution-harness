# Design & Roadmap: Evolve the Harness into an Agentic OS

**Status:** design (approved for planning, not yet in execution)
**Date:** 2026-07-10
**Decision:** Full metamorphosis (all three axes: scope, persistence, multi-user),
executed as a phased evolution that preserves the kernel's determinism.

---

## 1. The core insight — the harness is already a kernel

The harness *feels* functionally similar to an "Agentic OS" not by accident: its
reliability machinery **is** operating-system kernel machinery. It already implements
~8 classic kernel responsibilities.

| Harness component | Kernel primitive |
|---|---|
| `plan.dag.json` + scheduler loop | Process scheduler |
| Typed ephemeral subagents | Processes |
| Git worktree + `file-claims.json` | Memory protection / process isolation |
| Model/effort routing + token ceiling | Resource governor (quota/CPU) |
| Gates (fact-forcing, qa-gate, phase-integration) | Syscall permission / access control |
| trajectory + recall + frontier | Persistent storage + learning |
| Checkpoints + durable state | Journaling FS / crash recovery |
| `parallel-wait` + result files | IPC (notification-independent) |
| standing-constraints + rationalizations | libc — runtime linked into every process |

**Design principle (kernel/userland split):** a real OS keeps a small, boring,
deterministic **kernel** and lets flexible **userland** run on top. Determinism lives
in the kernel; flexibility lives in the workloads. The metamorphosis is NOT "harness
becomes a do-everything blob" — it is "make the existing kernel explicit and run
diverse workloads on it."

This resolves the central tension: the harness *constrains* agents (its value); an
Agentic OS *frees* them (its value). The kernel keeps the constraints; workloads get
the freedom.

---

## 2. Target architecture — kernel + three subsystems

### Kernel (formalize what mostly exists)
Scheduler · process model · isolation (generalize worktree/claims → "resource claims")
· resource governor · access control (gates as syscalls) · durable state + journaling
· IPC · learning · standard runtime (constraints + rationalizations). **Plus tenancy
as a first-class kernel primitive** (see §3, Phase 0).

### Subsystem 1 — Workloads (scope beyond coding)
A **workload** is a typed unit of work with its own classifier, task-classes, gates,
and definition of "done". Software-delivery is workload #0. New workloads: research
(the existing `deep-research` skill), ops/automation, content/marketing (the existing
marketing skill set), PM/Notion. The kernel schedules, isolates, governs, and gates
them identically — it does not care what a process does.

### Subsystem 2 — Persistence (always-on)
An init/daemon, cron-driven, wakes on schedule or event → picks a workload → runs it
through the kernel → sleeps. Event sources: cron (`scheduled-tasks` MCP / CronCreate),
inbox/webhook/file-watch, nudge timers. Cross-time memory = the trajectory/recall layer
upgraded with FTS5 indexing + **playbook authorship** (distill proven procedures into
reusable, injectable playbooks — borrowed from hermes-agent). **Achievable inside the
Claude Code ecosystem** (CronCreate, scheduled cloud agents, `/loop`) — no separate
daemon runtime required to start.

### Subsystem 3 — Multi-user platform
Split into two parts of different nature:
- **Tenancy** (state/memory/secret/claim namespacing per tenant) — a **kernel**
  concern, pulled forward to Phase 0. Cheap early, painful to retrofit.
- **Gateway + auth + hosting/ops** — the **product** part. A separate discipline
  (ops/security/SRE) with its own product decisions (hosting, billing, support).
  Runs as a parallel track once the kernel is tenant-aware.

---

## 3. Roadmap — shared foundation, then two parallel tracks

Multi-user is NOT deferred to the end. Its foundational half (tenancy) is in Phase 0;
its product half runs on a parallel track. This is safe because the kernel is
tenant-aware before either track builds on it.

### Phase 0 — Shared foundation (LOW risk: refactor + doc)
- Extract and document the kernel primitives from the existing harness.
- Define the `workload` interface (classifier, task-classes, gates, done-definition).
- **Bake tenancy into the state model**: every `.harness/` path, memory row, trajectory
  row, and resource claim is tenant-scoped from day one.
- Software-delivery becomes workload #0 (no behavior change, just re-homed on the API).
- **Deliverable:** kernel spec + workload API + tenant-scoped state model.

### Track A — Capability (runs after Phase 0)
- **A1 — Second workload:** run ONE non-coding workload (research is cleanest;
  `deep-research` exists) through the kernel. Proves the workload abstraction.
- **A2 — Persistence:** daemon/scheduler/event-loop + persistent memory (FTS5 +
  playbook authorship). Wakes workloads unattended.
- **Deliverable:** an always-on agent running diverse workloads.

### Track B — Platform (parallel to Track A, after Phase 0)
- **B1 — Gateway + auth:** interface layer (CLI first; then web / Telegram / Notion),
  per-tenant authentication.
- **B2 — Hosting/ops:** deployment, per-tenant secret management, resource limits,
  observability (reuse `reference/observability.md`).
- **Deliverable:** a hosted, multi-tenant surface.

### Convergence
Multi-user Agentic OS = Track A capabilities × Track B platform. The remaining
decision is a small ops go/no-go: **when to flip on the public/hosted gateway** —
the tenancy foundation already exists, so this is a switch, not a rebuild.

---

## 4. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Determinism dissolves as scope broadens | Kernel/userland split — constraints stay in the kernel; only workloads gain freedom. |
| Multi-user muddies the core | Tenancy is a deterministic kernel primitive (Phase 0); the messy ops part is isolated to Track B and never touches kernel decision logic. |
| Platform effort (~10x) starves capability work | Two independent tracks; Track A ships value even if Track B stalls. |
| Leaves the Claude Code skill model prematurely | Persistence (A2) starts inside the Claude ecosystem (CronCreate / scheduled agents / `/loop`); a standalone runtime is a later, optional Track-B decision. |
| Over-building before value is proven | Every phase is independently shippable; if Phases 0 + A1 + A2 suffice, Track B can pause with nothing wasted. |

---

## 5. What is NOT changing

The existing harness — Phase 0→3 delivery pipeline, gates, self-test suite, FE/backend
playbooks, learning loop — becomes **workload #0**, intact. Nothing about the
software-delivery path regresses; it gains a kernel underneath and siblings beside it.

---

## 6. Next step

This is a design + roadmap, not an implementation plan. The next action is to turn
**Phase 0** into a concrete implementation plan (writing-plans), since it is the shared
foundation both tracks depend on. Phases A/B get their own plans once Phase 0 lands.
