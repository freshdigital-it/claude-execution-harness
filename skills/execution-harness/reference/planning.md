# Planning Protocol (Phase 0)

Interactive PRD → Spec → Plan generation. No assumptions. Everything cleared upfront.
Master runs this before Phase 1. Human approves each stage before the next begins.

---

## Entry logic

When `/execution-harness` is invoked, master FIRST runs:

```bash
find docs/prds/ docs/specs/ docs/plans/ -name "*.md" 2>/dev/null | sort -r | head -10
```

### If artifacts found — ask before doing anything:

```
Saya menemukan dokumen yang sudah ada:

  📋 Plan:  docs/plans/2026-06-30-invoice-payment.md  (12 tasks, 3 done)
  📄 Spec:  docs/specs/2026-06-30-invoice-payment.md
  📑 PRD:   docs/prds/2026-06-30-invoice-payment.md

Pilihan:
  A. Lanjutkan — resume dari task yang belum selesai
  B. Eksekusi ulang — jalankan ulang semua task dari plan yang sama (reset pending)
  C. Buat baru — abaikan dokumen lama, mulai dari PRD baru

Pilihan Anda?
```

- A → skip Phase 0, go to Phase 1 (load DAG, resume)
- B → skip Phase 0, reset all task status → pending, go to Phase 1
- C → proceed to PRD generation

### If no artifacts — proceed to idea-refine check, then PRD generation.

---

## Idea-Refine (P0-pre) — only when the idea is still vague

The PRD questions *clarify* a known feature. They do NOT help when you don't yet know
*what* to build. Detect that first.

**Trigger (idea is vague/exploratory) if the request is:**
- a one-liner with no clear direction ("bikin fitur loyalty", "improve onboarding"),
- an outcome without a mechanism ("kurangi churn"), or
- explicitly asking to explore ("gimana sebaiknya…", "opsi apa saja…").

**If NOT vague** (feature is concrete, e.g. "add subtract() to math.js") → skip this,
go straight to PRD.

**If vague → run one divergent→convergent round BEFORE the PRD:**
```
1. DIVERGE: propose 2-3 distinct directions, each with a one-line mechanism +
   its main trade-off. Not variations of one idea — genuinely different approaches.
2. CONVERGE: ask the user to pick a direction (or combine), or offer /decide
   for a weighted comparison if they're torn.
3. Only after a direction is chosen → proceed to PRD questions for THAT direction.
```
This is the `idea-refine` step (borrowed from agent-skills). It is the ONE place the
harness does divergent ideation; everything after assumes the *what* is settled.

Do NOT invent the direction yourself and proceed — offer options, let the user choose.
If the user's one-liner is already concrete, do not manufacture ambiguity.

---

## PRD Generation — Batch Questions

Ask ALL questions in ONE message. Never one-by-one (avoids 10-round ping-pong).
Do NOT generate PRD until ALL questions are answered.
Do NOT assume any answer, even if it seems obvious from context.

### Batch 1: Problem & Users

```
Sebelum saya mulai, saya perlu memahami feature ini dengan jelas.
Jawab semua pertanyaan berikut — tidak ada yang bisa dilewati:

1. MASALAH APA yang diselesaikan? Siapa yang merasakan pain-nya sekarang?
   (konkret: "X tidak bisa melakukan Y karena Z" — bukan "sistem kurang lengkap")

2. SIAPA penggunanya? Role/persona apa? Dalam konteks apa mereka pakai feature ini?

3. KRITERIA SUKSES yang terukur — bukan "berhasil" tapi behavior atau angka konkret.
   Contoh: "User selesaikan flow dalam < 3 langkah" atau "Error rate < 1%"

4. APA YANG TIDAK TERMASUK scope ini? Batas eksplisit mencegah scope creep.

5. CONSTRAINT teknis: stack, existing API, schema DB, library, atau pattern yang harus diikuti?

6. Ada DEADLINE atau dependency ke feature/tim/modul lain?
```

### Batch 2: Edge Cases (setelah Batch 1 dijawab)

```
Beberapa hal lagi sebelum saya tulis PRD:

7. Apa yang terjadi jika [operasi utama] GAGAL? User perlu tahu? Bisa retry?

8. Ada perbedaan PERMISSION antar role? Siapa bisa lihat, siapa bisa edit, siapa tidak boleh akses?

9. Ada DATA LAMA yang perlu dimigrasikan atau dipertimbangkan?

10. Harus BACKWARD COMPATIBLE dengan sesuatu yang sudah ada di production?
```

Generate PRD hanya setelah semua 10 pertanyaan dijawab.

---

## PRD Schema

File: `docs/prds/YYYY-MM-DD-<kebab-case-feature>.md`

```markdown
# PRD: [Feature Name]
**Status:** draft
**Date:** YYYY-MM-DD

## Problem Statement
[1-2 paragraf. Pain konkret, user konkret.]

## Users & Context
[Siapa, kapan, seberapa sering.]

## Success Criteria
- [ ] [Kriteria terukur 1]
- [ ] [Kriteria terukur 2]

## Out of Scope
- [Eksklusi eksplisit 1]

## Constraints
- Tech: [stack, API, schema, pattern]
- Business: [deadline, dependency, compliance]

## Edge Cases & Permissions
- [Failure scenario + expected behavior]
- [Permission matrix jika multi-role]
```

After generating PRD, show to user:

```
PRD draft siap. Review:
  - Problem statement akurat?
  - Success criteria bisa diverifikasi?
  - Ada yang perlu diubah?

Ketik 'approved' untuk lanjut ke Spec, atau berikan feedback untuk revisi.
```

**HARD GATE: Do NOT generate Spec until user sets PRD status = approved.**
Update file: change `Status: draft` → `Status: approved`.

---

## Spec Generation — Questions

After PRD approved, ask before generating Spec:

```
Sebelum Spec teknis, saya perlu klarifikasi:

1. ENDPOINT baru yang dibutuhkan? Method + path + siapa yang memanggil?
   Atau hanya modifikasi endpoint yang sudah ada?

2. PERUBAHAN DATA MODEL? Tabel baru, kolom baru, relasi, enum?
   Atau hanya baca data yang sudah ada?

3. KOMPONEN FE yang dibangun? Baru atau modifikasi?
   Sebutkan nama/lokasi jika sudah tahu.

4. INTEGRASI EKSTERNAL? Payment gateway, notif, third-party API?

5. Ada BACKGROUND JOB / QUEUE / SCHEDULER yang terlibat?
```

---

## Spec Schema

File: `docs/specs/YYYY-MM-DD-<kebab-case-feature>.md`

```markdown
# Spec: [Feature Name]
**Status:** draft
**PRD:** docs/prds/YYYY-MM-DD-<feature>.md
**Date:** YYYY-MM-DD

## API Contracts
### POST /api/v1/[resource]
Request:  `{ field: type }`
Response: `{ field: type }`
Auth: [role required]
Errors: 400 (validation) | 401 (unauth) | 403 (forbidden) | 422 (business rule)

## Data Model
### New/Modified: [table name]
| column | type | nullable | notes |
|--------|------|----------|-------|

Migration forward:  [what changes]
Migration rollback: [how to reverse — required if production data exists]

## Components
| Name | New/Modify | Responsibility | UX contract |
|------|-----------|----------------|-------------|

## External Integrations
[Service, trigger, data flow, failure behavior]

## Background Jobs
[Job name, trigger, what it does, retry strategy]
```

Same approval gate as PRD. **Do NOT generate Plan until Spec is approved.**

---

## Plan Generation

After Spec approved, generate plan following writing-plans protocol:
- Bite-sized tasks (2-5 minutes implementation each)
- TDD: failing test first → implement → pass → commit
- Exact file paths — never "somewhere in src/"
- Each task has: class / model / effort / gate / deps
- Tasks with mutual dependency must be ordered explicitly

File: `docs/plans/YYYY-MM-DD-<kebab-case-feature>.md`

Show classification preview before starting:

```
Plan selesai: N tasks.

Klasifikasi:
  security-core: X  (Sonnet/high/deferred-verify)
  business:      Y  (Sonnet/medium/auto)
  fe-page:       Z  (Sonnet/medium/conformance)
  mechanical:    W  (Haiku/low/pipeline)

Estimasi token: ~[X × class-constant]

Ketik 'mulai' untuk eksekusi, atau minta perubahan pada plan.
```

**HARD GATE: Phase 1 tidak dimulai sampai user confirm.**

---

## Phase 0 Anti-patterns

- **Generate PRD sebelum semua pertanyaan dijawab** — assumptions masuk, quality turun.
- **Tanya satu pertanyaan sekaligus** — 10 questions = 10 round trips. Batch selalu.
- **Skip Spec karena "PRD sudah jelas"** — Spec wajib jika ada perubahan API atau data model.
- **Mulai Phase 1 dari plan berstatus draft** — hanya approved plan yang masuk Phase 1.
- **Asumsikan scope** — "build invoice flow" bisa berarti: create? approve? pay? all? Tanya.
- **Re-tanya yang sudah dijawab** — baca semua jawaban sebelumnya sebelum tanya lagi.
- **Generate ulang PRD jika user hanya minta revisi kecil** — edit inline, jangan dari nol.
