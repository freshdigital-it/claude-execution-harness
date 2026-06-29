# FE Execution Playbook

Panduan eksekusi task Frontend di harness. Dibaca oleh master dan diinjeksikan ke subagent FE.

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
4. **Playwright journey** — drive interaction → assert DOM state transitions. Untuk bottleneck B dan C. No screenshot.
5. **Screenshot diff** — image tokens, paling mahal. **Hanya di `fe-visual`/GAN.** Never first.

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

## FE Context Bundle

Diinjeksikan ke setiap FE subagent saat spawn. Hard budget: ≤1,500 tokens.

### Required (~1,350 tok)

| Konten | Token est. | Cara dapat |
|---|---|---|
| `design-tokens.json` (extracted plan-time) | ~400 | `scripts/ux-contract-generate.py --tokens-only` |
| UX contract section yang relevan | ~300 | `ux-contracts/<screen>.yaml` (hanya states + journeys task ini) |
| Component inventory manifest | ~400 | Generated plan-time dari `src/components/` |
| Store conventions (1 skeleton pattern) | ~200 | Extract dari standing-constraints atau template |
| Verify recipe untuk sub-class ini | ~50 | Dari table sub-classes di atas |

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
