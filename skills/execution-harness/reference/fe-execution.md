# FE Execution Playbook

Panduan eksekusi task Frontend di harness. Dibaca oleh master dan diinjeksikan ke subagent FE.

## Testing Model: ATDD + CDD + Testing Trophy

TDD klasik (unit-test-first) tidak cocok untuk FE. Model yang dipakai:

> **Framework-neutral.** Prinsip di bawah berlaku lintas framework. Tool di kolom "Tool"
> adalah default (Vue) — padanannya 1:1: composable↔hook, Vue Test Utils↔React Testing Library,
> Pinia↔Zustand/Redux, Vue Query↔TanStack Query. Pilih tool mengikuti codebase, jangan lock.

| Layer | Pendekatan | Tool (per stack) | Kapan |
|---|---|---|---|
| Static | TS strict + ESLint + **a11y lint** | tsc, eslint (+ `jsx-a11y` / `vuejs-accessibility`) | Setiap commit |
| Unit/Logic | Hook/composable + util sebagai logika murni, tanpa render | Vitest/Jest | logika diekstrak dari komponen (§ Logic/Presentation) |
| Integration/Behavior | Testing Trophy — find by role | Vue Test Utils / RTL | `fe-component` gate |
| Acceptance | ATDD — test ditulis DULU (failing) | Playwright | `fe-page`, `fe-api-wiring` |
| Visual Regression | VRT baseline + diff | Playwright screenshot | `fe-visual` (escalation only) |
| Component spec | CDD — states per screen = contract | UX contract YAML | Plan-time |

**Urutan eksekusi (bukan implement-dulu-test-kemudian):**
```
Plan-time: approved contract → fe-atdd-generate.py → Playwright tests FAIL
                             → fe-behavior-test-generate.py → Vue Tests FAIL
Loop:      subagent menerima failing tests → tugasnya: make them green
           gate: run tests → PASS atau localized delta FAIL
```

---

---

## FE Sub-classes

Ganti satu kelas `FE-ops` dengan 4 sub-class berdasarkan failure-attribution complexity:

| Sub-class | Kapan | Model | Effort | Gate |
|---|---|---|---|---|
| `fe-mechanical` | Rename prop, bump import, text swap, trivial token swap | Haiku | low | `pipeline` |
| `fe-component` | Build/modify 1 komponen isolated vs prototype fragment | Sonnet | medium | `conformance` |
| `fe-page` | Compose page: layout, multi-komponen, routing, states | Sonnet | medium | `conformance + fe-journey` |
| `fe-api-wiring` | Bind store/composable ke API, loading/error/empty states | Sonnet | medium | `auto + fixtures` |
| `fe-visual` | Escalation saja — pixel fidelity gagal 1x | Sonnet GAN | high | `GAN K≤3` |

**Aturan penting:**
- `fe-mechanical` (~40% FE tasks): kompiler adalah oracle. Tidak perlu browser.
- Semua sub-class lain: Sonnet karena butuh failure-attribution lintas CSS/component/state/API.
- Screenshot **hanya** di `fe-visual`. Semua lain: DOM + CSS text assertions.
- `fe-visual` adalah recovery path, bukan default. Hanya diaktifkan setelah `fe-component`/`fe-page` gagal conformance 1x pada pixel fidelity.
- **Model GAN evaluator** diresolusi via `scripts/verify-model.sh <generator_model> fe-visual`, bukan hardcode. Default `one-below` + floor Sonnet: generator Sonnet → evaluator Sonnet; generator Opus → evaluator Sonnet. Lihat `reference/autonomy.md` § Verification model policy.

---

## State Architecture (server-state vs UI-state) — framework-agnostic

Bug arsitektur FE terbesar: mencampur **server state** dan **UI state**. Harness memisahkan tegas.

| Jenis | Definisi | Mekanisme | Contoh |
|---|---|---|---|
| **Server state** | Data yang dimiliki backend, cuma di-cache di client | Server-state library (TanStack/Vue Query, RTK Query) | daftar invoice, profil user, hasil search |
| **UI state** | State asli client, tidak ada di server | `useState`/`ref`/signal, atau store ringan (Zustand/Pinia/Context) | modal open, tab aktif, filter draft, wizard step |

**Gate criterion (`fe-api-wiring`, dan `fe-page` yang fetch data):**
- Server data WAJIB lewat server-state library (fetch + cache + invalidation). **DILARANG** disimpan di `useState`/`ref` manual atau disalin ke store global sebagai sumber kebenaran.
- Store global (Pinia/Zustand/Redux) hanya untuk UI state asli. Response API yang disalin ke store manual → gate FAIL.
- Loading/error/empty diturunkan dari status server-state library (`isLoading`/`isError`), bukan boolean manual yang gampang de-sync.
- **Jika codebase belum punya server-state library:** jangan diam-diam menaruh server data di Pinia manual. Surface sebagai design decision (`status: blocked` + `assumption_if_unblocked`) — introduksi library adalah keputusan lintas-cutting, bukan asumsi subagent.

**Kenapa:** server data di state manual → stale cache, de-sync antar komponen, refetch manual, race condition. Kelas bug "halu arsitektur" yang paling sering.

---

## Logic/Presentation Separation — framework-agnostic

Prinsip: komponen = **presentasi tipis**. Logic (derivasi data, side-effect, orkestrasi) ditarik ke **hook (React) / composable (Vue)** yang bisa dites tanpa render. Ini melengkapi global clean-architecture rule ("No business logic in components") dengan verifikasi di gate — bukan cuma aturan tertulis.

**Gate criterion (`fe-component`, `fe-api-wiring`):**
- Komponen tidak boleh berisi: API call langsung, business logic non-trivial, transformasi data kompleks → ekstrak ke hook/composable.
- Logic yang diekstrak WAJIB punya **unit test terpisah** (deterministik, tanpa render UI) — inilah layer "Unit/Logic" di Testing Model. Ini juga titik di mana TDD selektif masuk akal.
- Pembagian test: behavior test (VTU/RTL) menguji komponen dari sudut user; unit test menguji hook/composable sebagai logika murni. Jangan tumpang tindih.

**Heuristik "komponen terlalu tebal":** kalau sebuah komponen butuh >1 `useEffect`/watcher untuk data, atau punya fungsi transformasi >10 baris di dalam body-nya → ekstrak.

---

## Accessibility (a11y) — framework-agnostic

A11y bukan skor Lighthouse sekali di release. Tiga lapis, termurah dulu:

1. **Lint (per-commit)** — `eslint-plugin-jsx-a11y` (React) / `eslint-plugin-vuejs-accessibility` (Vue) di static layer. Tangkap: missing alt, label tanpa control, role invalid, positive tabindex. Zero-cost.
2. **axe-core (conformance gate)** — `scripts/fe-a11y-check.sh <url> <route>` per screen. WCAG 2.1 AA per-node. Gate FAIL pada impact serious/critical. Jauh lebih dalam dari skor Lighthouse (~35% coverage) → axe ~57% + spesifik per elemen.
3. **Lighthouse a11y (release)** — skor agregat di `qa-gate.sh` tetap jalan sebagai coarse net.

**Yang wajib di setiap interactive component (masuk rubric + behavior test):**
- Semua control punya accessible name (label/aria-label). Behavior test find-by-role sudah menegakkan ini sebagian.
- Focus visible + focus trap benar di modal/dialog. Focus kembali ke trigger saat close.
- Error pakai `role="alert"` / `aria-live`. State (loading/disabled) diekspos via `aria-*`, bukan cuma visual.
- Kontras warna dari design tokens memenuhi 4.5:1 (teks) — cek di axe.

---

## Forms & Mutations — framework-agnostic

### Validation (gate: form journeys, `fe-page`/`fe-api-wiring`)
- **Schema-driven**, bukan if-else manual: zod/yup/valibot + adapter (vee-validate / react-hook-form). Satu sumber kebenaran validasi.
- Field-level error muncul **on blur / on submit**, bukan on every keystroke (kecuali async uniqueness check dengan debounce).
- Submit **disabled sampai valid**, atau enabled + tampilkan error saat submit. Konsisten per app, catat di contract.
- Error message spesifik & actionable ("Email harus mengandung @"), bukan "Invalid".
- Server-side validation error (422) dipetakan kembali ke field yang tepat, bukan toast generik.

### Mutations (gate: `fe-api-wiring`)
- Mutation lewat server-state library (`useMutation`), bukan fetch manual + refetch manual.
- **Optimistic update + rollback**: update UI segera, snapshot state lama, rollback on error, invalidate query on settle. Untuk operasi yang sering & low-risk (toggle, reorder, quick edit).
- **Double-submit dilarang**: tombol disabled selama pending (`isPending`).
- Setiap mutation punya 3 UI-state: pending (feedback), success (invalidate + toast/inline), error (rollback + pesan + retentif input user).

**Anti-pattern:** optimistic update tanpa rollback (UI bohong saat server tolak), atau mutation yang menyalin response ke store manual alih-alih invalidate query (§ State Architecture).

---

## UX Contract

Machine-readable spec per screen yang menjadi SSOT untuk implementasi dan verifikasi.

### Generate dari prototype

```bash
scripts/ux-contract-generate.py design/PrototypeName.html --output ux-contracts/
```

Script parse `design/*.html` → extract struktur per screen → generate YAML draft → human review + approve sebelum dipakai di loop.

### Schema YAML

```yaml
# ux-contracts/invoice-list.yaml
screen: invoice-list
prototype_source: design/Reksa ERP.html
prototype_section: "#invoice-list"   # section id atau line range

breakpoints:                          # multi-viewport verification (min mobile + desktop)
  mobile:  375                        # table → cards/stacked, no horizontal scroll
  desktop: 1280                       # full table layout

states:
  loading:
    - skeleton rows visible (N rows)
    - action buttons disabled
    - header tetap visible
  empty:
    - illustration atau icon
    - text deskriptif (bukan "No data")
    - CTA button yang actionable
  error:
    - inline error banner (bukan full page takeover)
    - retry button
    - tidak pernah tampil "undefined" atau stack trace
  data:
    - tabel dengan kolom: [col1, col2, ...]
    - row hover state visible
    - bulk action bar muncul saat row diselect
    - pagination atau infinite scroll

journeys:
  - id: create_flow
    steps:
      - trigger: click CTA "Buat Invoice"
      - expect: modal opens dengan form kosong
      - action: isi form (required fields)
      - expect: submit button enabled
      - action: submit
      - expect: modal close + row baru muncul di tabel + toast success
  - id: filter_flow
    steps:
      - trigger: buka filter dropdown
      - action: pilih filter value
      - expect: tabel re-fetch + URL update dengan query param

production_grade_rubric:
  loading_state: true        # ada skeleton/spinner, bukan blank
  empty_state_cta: true      # empty state punya CTA actionable
  error_never_raw: true      # tidak pernah tampil raw error/undefined
  hover_focus_states: true   # semua interactive element ada hover+focus
  keyboard_navigable: true   # bisa tab through semua primary actions
  error_inline: true         # error muncul inline, bukan redirect
  transitions_smooth: true   # ada loading feedback pada setiap async op

playwright_assertions:
  # Dibuat otomatis dari states + journeys di atas saat fe-conformance.sh dijalankan
  # Format: { test_id, selector, assertion_type, expected_value }
```

### Contract approval workflow

1. Generate draft: `scripts/ux-contract-generate.py`
2. Human review file di `ux-contracts/<screen>.yaml`
3. Set `status: approved` di YAML header
4. Master baca hanya contract dengan `status: approved`
5. Unapproved contracts → `status: draft` → skip di loop, surfaced ke human di run-report

---

## Closed-Loop FE Execution

Ganti: `analyze → report → (command terpisah) → implement → manual QA → ulang`

Dengan: `contract → implement → evaluator verify → delta → fix → verify → DONE`

```
Plan-time:
  1. prototype → ux-contract-generate.py → draft contracts
  2. human approve contracts (set status: approved)
  3. master baca approved contracts, inject ke DAG task
  4. fe-server-check.sh (prerequisite sebelum semua verifikasi FE)

Loop per task:
  5. spawn implementor (Sonnet) dengan FE context bundle
  6. implementor mengimplementasi berdasarkan UX contract
  7. fe-server-check.sh → konfirmasi latest build serving
  8. conformance evaluator jalankan Playwright terhadap contract
  9. jika PASS → done
  10. jika FAIL → return localized delta → implementor fix → kembali ke 7
  11. setelah K=3 gagal → BLOCKED + report ke human
```

---

## FE Server Health Check (Prerequisite Wajib)

**Jalankan sebelum semua verifikasi FE. Jangan skip.**

```bash
scripts/fe-server-check.sh <url> <build_dir>
```

Check sequence:
1. Apakah dev server running di URL yang dimaksud?
2. Apakah build artifacts lebih baru dari source files? (Vite hot reload check)
3. Apakah response bukan cached build lama?

Jika gagal:
- Trigger rebuild: `vite build` atau `vite dev --force`
- Tunggu server ready (max 30s)
- Retry check 1x
- Jika masih gagal → BLOCKED dengan reason "FE server tidak serving latest build"

Ini fix untuk false positive di mana agent claim "done" tapi perubahan tidak terlihat karena Vite issue.

---

## Conformance Gate

Gate khusus FE yang test terhadap UX contract, bukan hanya build green.

### Tier verifikasi (cheapest first)

1. **tsc + linter + build** — `fe-mechanical` oracle. Text, deterministic, no browser.
2. **CSS token checklist** — `toHaveCSS` untuk properties dari design tokens (bg, color, padding, gap, font-size, radius). Cheapest browser check. Pakai untuk bottleneck A (visual).
3. **DOM structure diff** — normalize outerHTML skeleton → compare ke prototype section skeleton. Catches missing component, wrong nesting, missing empty-state.
4. **axe-core a11y** — `fe-a11y-check.sh <url> <route>` → WCAG 2.1 AA per-node violations. Gate FAIL pada serious/critical. Lebih dalam dari skor Lighthouse. Zero image tokens.
5. **Multi-viewport** — jalankan tier 2-4 minimal di 2 viewport: mobile (375px) + desktop (1280px). Breakpoint dari `breakpoints` di UX contract. Layout tidak boleh overflow/overlap di salah satu.
6. **Playwright journey** — drive interaction → assert DOM state transitions. Untuk bottleneck B dan C. No screenshot.
7. **Screenshot diff** — image tokens, paling mahal. **Hanya di `fe-visual`/GAN.** Never first.

### Localized delta format (mandatory evaluator return)

Ganti feedback generik dengan format ini:

```json
{
  "verdict": "FAIL",
  "contract_ref": "ux-contracts/invoice-list.yaml",
  "deltas": [
    {
      "state": "empty",
      "selector": ".empty-state .cta",
      "issue": "MISSING",
      "expected": "Button 'Buat Invoice' dari contract empty.cta",
      "got": "tidak ada elemen",
      "fix_hint": "tambah <button class='btn-primary'>Buat Invoice</button> di .empty-state"
    },
    {
      "state": "data",
      "selector": ".table-row",
      "prop": "background-color",
      "issue": "WRONG_VALUE",
      "expected": "var(--surface-hover) = #F5F7FA",
      "got": "transparent",
      "fix_hint": "tambah hover:bg-surface-hover atau CSS var(--surface-hover)"
    }
  ],
  "rubric_score": {
    "loading_state": 2,
    "empty_state_cta": 0,
    "error_never_raw": 2,
    "hover_focus_states": 1,
    "keyboard_navigable": 2
  },
  "rubric_total": "7/10",
  "screenshot_attached": false
}
```

Subagent yang terima `selector + issue + expected + got + fix_hint` konvergen dalam 1–2 iterasi.

---

## Visual Regression Testing (VRT) — Gap 2 Fix

VRT mencegah pixel drift di antara run. Baseline disimpan setelah `fe-visual` PASS pertama kali.

### Capture baseline (pertama kali)
```bash
scripts/fe-vrt-baseline.sh capture http://localhost:5173 /invoice-list invoice-list \
  --harness-dir $PROJECT_ROOT/.harness
```
Menyimpan screenshot ke `.harness/vrt-baselines/invoice-list.png`.

### Diff pada run berikutnya
```bash
scripts/fe-vrt-baseline.sh diff http://localhost:5173 /invoice-list invoice-list \
  --threshold 5 --harness-dir $PROJECT_ROOT/.harness
# Exit 0 = PASS (diff ≤ 5%)
# Exit 1 = FAIL (regression detected, diff image saved to .harness/vrt-diffs/)
# Exit 2 = no baseline yet (run capture first)
```

### Kapan VRT jalan
- `fe-visual` PASS pertama → otomatis capture baseline
- `fe-visual` run berikutnya → diff dulu sebelum GAN evaluator (lebih murah)
- Jika diff PASS → skip GAN evaluator, langsung done
- Jika diff FAIL → jalankan GAN evaluator untuk localized delta

### Baseline regeneration
Jika prototype berubah (UX contract di-update): delete baseline lama dan capture ulang.
```bash
rm .harness/vrt-baselines/<screen_id>.png
scripts/fe-vrt-baseline.sh capture ...
```
Baseline bukan permanen — ia adalah frozen visual contract untuk versi prototype tertentu.

---

## Testing Trophy: Behavior Tests (Gap 3 Fix)

Untuk `fe-component`: gate tidak hanya CSS conformance, tapi juga behavior test.

### Generated behavior tests (Vue Test Utils)
```bash
# Plan-time: generate behavior test stubs dari approved contract
python3 scripts/fe-behavior-test-generate.py ux-contracts/ --output tests/unit/ux-contracts/
```

### Prinsip Testing Trophy yang diterapkan
- **Find by role/label** — bukan CSS class atau component internals
  ```typescript
  // WRONG (Testing Trophy violation)
  wrapper.find('.btn-create-invoice')
  // CORRECT
  wrapper.find('[role="button"]').filter(b => /buat invoice/i.test(b.text()))
  ```
- **Test behavior**, bukan implementation — apakah CTA muncul saat empty, apakah error ada role=alert
- **Test states** (loading/empty/error/data) sebagai props/mocks, bukan DOM inspection
- **No snapshot testing** — snapshots test implementation, bukan behavior

### Integrasi ke conformance gate
`fe-component` gate sekarang = CSS token check + DOM diff + behavior tests (Vitest):
```bash
vitest run tests/unit/ux-contracts/<screen>.test.ts
```
Harus PASS sebelum task dianggap done.

---

## GAN Loop untuk FE (Recovery Path)

Aktifkan **hanya** ketika conformance gate gagal 1x pada pixel fidelity. Bukan default.

### Evaluator prompt — visual

```
Adversarial visual evaluator. App running at {URL}, route {ROUTE}.
Ground truth: ux-contracts/{SCREEN}.yaml + design-tokens.json
Prototype reference: {PROTOTYPE_FILE} section {SECTION}.

Render app. Score rubric items 0-2 (0=absent, 1=partial, 2=match):
  - layout_structure, spacing_scale, color_tokens, typography
  - component_completeness (semua states: loading/empty/error/data ada?)
  - interactive_states (hover/focus/disabled visible?)

Default FAIL jika total < 10/14.

Return JSON: { verdict, rubric_scores, deltas: [{state, selector, prop, expected, got, fix_hint}] }
Attach screenshot HANYA jika delta tidak bisa diekspresikan sebagai CSS/DOM assertion.
```

### Evaluator prompt — behavior/API

```
Adversarial behavior evaluator. Drive app at {URL}{ROUTE}.
UX contract: ux-contracts/{SCREEN}.yaml — section journeys.

Jalankan setiap journey dengan Playwright. Test semua state transitions:
  initial → loading → success (data shape match) → error (500) → empty (0 rows)
Test edge cases: double-submit, back-nav mid-load, expired token, empty required field.

Default REFUTED kecuali semua branch render state DOM yang benar.

Return JSON: { verdict, failing_transitions: [{journey_id, from, to, expected_dom, got_dom}], confidence }
No screenshot.
```

### K threshold: 3 (align dengan failure-breaker)

Setelah K=3 dengan strategy berbeda → BLOCKED + reason ke human.
K=3 GAN failure hampir selalu berarti ada design decision yang belum ada di contract → surface ke human, jangan grind terus.

---

## Independent Conformance Verifier (dual-diff)

Untuk `fe-page`/`fe-visual` yang shipping UI: setelah gate build/test lolos, spawn
verifier **terpisah dari implementer** (mencegah bias "kelihatan selesai"). Prompt
adversarial: "cari mismatch; anggap NOT-conformant sampai terbukti." Ia menjalankan app
live dan menghasilkan dua diff:

1. **UI ↔ prototype** — screenshot layar yang dibangun di viewport sama dengan baseline,
   diff vs baseline PNG. Delta konkret: spacing, warna, komponen hilang/lebih, copy salah.
2. **UX journey** — jalankan click-path contract; assert tiap checkpoint, **0 console error**,
   **0 network 4xx/5xx**, + persistence (reload → data tetap benar).

Output ACI (bounded, bukan raw) → `review-ledger.md` sebagai `CONFORMANT`/`DELTAS`/`BLOCKED`:
```json
{ "screen": "invoices-list", "conformant": false,
  "ui_deltas": [{"area":"header CTA","expected":"primary blue","actual":"gray ghost"}],
  "journey": [{"step":3,"expected":"tax 110000","actual":"tax 0","pass":false}],
  "console_errors": 0, "network_failures": 1 }
```
Prinsip anti-rework: gate di batas TASK (bukan akhir sprint) → miss muncul saat konteks
masih panas; referensi frozen & shared → redo menyasar delta spesifik, bukan seluruh layar.

## reksa-erp actualization

Operasional spesifik proyek reksa-erp (jangan reinvent):
- **Prototype binding:** `design/*.html` di worktree reksa-erp adalah kebenaran — match
  visual DAN behavioral ("cara kerja").
- **Port pinned per vertical (`scripts/dev-up.sh <vertical>`):** clinic 5173/:8080,
  b2b 5273/:8180, superadmin 5373/:8280. Verifikasi selalu di port vertical sendiri
  (separuh "tidak match" = salah server). Lihat user-memory `reksa-erp-dev-port-convention`.
- **Pakai Playwright infra EXISTING** — jangan bikin baru: `frontend/apps/web/e2e/`
  sudah punya `clinic-booking.spec.ts`, `console-provision.spec.ts`, `axe-smoke.spec.ts`
  + config. Tulis journey spec di situ; GAN evaluator pakai runner yang sama.
- **DB caveat:** fresh-DB migrate diblokir di reksa-erp (lihat `lifecycle.md`). Preview
  isolated pakai seed snapshot, bukan fresh migrate.
- **Critical journeys (tier fe-visual/GAN, K=3):** Clinic booking + receipt-first POS;
  B2B lead→quotation→invoice (Q2C) + portal link; Superadmin tenant onboarding + role gate.

---

## FE Context Bundle

Diinjeksikan ke setiap FE subagent saat spawn. Hard budget: ≤1,500 tokens.

### Required (~1,800 tok)

| Konten | Token est. | Cara dapat |
|---|---|---|
| `design-tokens.json` (extracted plan-time) | ~400 | `scripts/ux-contract-generate.py --tokens-only` |
| UX contract section yang relevan | ~300 | `ux-contracts/<screen>.yaml` (hanya states + journeys task ini) |
| **Failing Playwright test file** (ATDD) | ~400 | `tests/e2e/ux-contracts/<screen>.spec.ts` (generated plan-time) |
| **Failing Vue behavior test file** (Trophy) | ~300 | `tests/unit/ux-contracts/<screen>.test.ts` (generated plan-time) |
| Component inventory manifest | ~200 | Generated plan-time dari `src/components/` |
| Verify recipe untuk sub-class ini | ~50 | Dari table sub-classes di atas |

**Instruksi ke subagent yang wajib disertakan:**
> "Tests di `tests/e2e/ux-contracts/<screen>.spec.ts` dan `tests/unit/ux-contracts/<screen>.test.ts`
> saat ini FAILING. Tugasmu: implementasi komponen sehingga semua test PASS.
> Jangan modifikasi test files — modifikasi source code saja.
>
> ARSITEKTUR (gate criteria, lihat § State Architecture + § Logic/Presentation):
> - Server data lewat server-state library, JANGAN di useState/ref manual atau store global.
> - Komponen tetap tipis: ekstrak business logic/API call ke hook/composable + unit-test terpisah.
> - Loading/error/empty diturunkan dari status server-state library, bukan boolean manual.
>
> KUALITAS (gate criteria, lihat § Accessibility + § Forms & Mutations):
> - a11y: control punya accessible name, focus visible, error role=alert. Lolos axe serious/critical.
> - Layout benar di mobile (375) + desktop (1280) — no horizontal scroll.
> - Form: validasi schema-driven, submit anti double-click. Mutation optimistic wajib rollback."

### Optional (pull on demand, jangan push)

- Full prototype section HTML (subagent Read via pointer)
- Related component source (Read by path)
- API contract / OpenAPI fragment (hanya `fe-api-wiring`)

### Never inject

- Whole `design/*.html` (thrash, violates thin-master invariant)
- Full Pinia store tree
- Screenshot atau Playwright trace dari task lain
- BE implementation detail yang tidak relate ke response shape

---

## Design Decision Hierarchy

Ketika FE task ambiguitas, pakai hierarki ini sebelum tanya human:

1. **Prototype autoritatif** — jika `design/*.html` menjawab (di mana empty state, apa error state-nya) → ikuti, tidak perlu tanya.
2. **Design tokens autoritatif untuk values** — warna/spacing/type → resolve dari `design-tokens.json`, never invent hex atau px.
3. **Existing component precedent** — jika screen lain sudah solve pattern ini → match, bukan reinvent.
4. **Reversible + tiny + unanswered** → ambil keputusan + catat di trajectory `assumptions` field + lanjut. Jangan block loop untuk 4px decision.
5. **Irreversible / cross-cutting / unanswered di prototype** → `status: blocked` + `blocked_reason` + `assumption_if_unblocked`.

---

## Production-Grade Rubric (Scoring)

Dipakai oleh evaluator untuk score setiap screen. Target: ≥12/14 sebelum task dianggap `done`.

| Kriteria | Score 0 | Score 1 | Score 2 |
|---|---|---|---|
| Loading state | Tidak ada (blank/frozen) | Spinner saja | Skeleton yang sesuai konten |
| Empty state | Tidak ada / "No data" | Ada text, no CTA | Illustration + descriptive text + actionable CTA |
| Error state | Raw error / undefined / redirect | Generic "Error" message | Inline banner + specific message + retry action |
| Hover/focus states | Tidak ada | Sebagian interactive element | Semua interactive element punya hover+focus |
| Keyboard navigation | Tidak bisa tab | Bisa tab, tapi skip beberapa | Full tab order, semua primary actions reachable |
| Transition/feedback | Tidak ada (snap/jump) | Ada loading pada beberapa op | Semua async operations punya loading feedback |
| Error boundary | Crash tanpa recovery | Catch error, blank screen | Catch + informative message + recovery option |

**Total: 14 poin. Pass threshold: ≥12/14**
