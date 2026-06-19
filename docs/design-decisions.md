# Plan Optimasi `/execution-harness`

- **Status:** Draft untuk review (belum dieksekusi)
- **Tanggal:** 2026-06-17
- **Sasaran:** skill global `~/.claude/skills/execution-harness/`

## Tujuan akhir
Mengubah harness dari *"94 baris dokumen self-contained yang berhenti di tiap
security-core, berakhir di commit, amnesia antar-run, tanpa governance"* menjadi
*"policy-delta ramping yang menjalankan plan → build → evaluate → buka localhost
secara hands-off, menegakkan aturan secara mekanis, dan belajar antar-run"* —
sehingga **satu command, kamu lihat hasil di akhir**.

## Prinsip pemersatu
**Klasifikasi di plan-time · Otomasi yang mekanis · Suntik yang judgment · Tunda manusia ke akhir.**

## Disiplin token (mengatur SEMUA memory/context)
Korpus (code-graph, transkrip, ledger, repo-map) hidup **eksternal** (MCP/file) —
tak pernah masuk context. Yang masuk hanya **hasil query** yang
**budget-bounded + relevance-ranked + context-aware** (pola repo-map Aider:
default ~1k token, ranking dependency-graph, mengecil bila file relevan sudah ada
di context). Master pegang **pointer + slice ber-budget**, bukan korpus. Ini =
invariant thin-master diperluas ke memori. Jika dibatasi, pola-pola pinjaman ini
**net hemat token** (cegah baca-banyak-file, retry-buta, eksekusi-task-konflik);
boros hanya bila "load everything".

## Snapshot Sekarang → Sesudah

| Dimensi | Sekarang | Sesudah |
|---|---|---|
| Interupsi manusia | Berhenti di tiap security-core | Nol di tengah; review sekali di akhir |
| Scope | Berakhir di `commit` | Sampai localhost siap-verifikasi |
| Multi-sesi paralel | Auto-staging bentrok (clobber/migrasi) | Isolasi lokal per-worktree, nol bentrok |
| 300-LOC & clean-arch | Tidak ke-enforce | Hook blok di write-time |
| Memori antar-run | Amnesia | Belajar (agentdb + user-memory) |
| Resume pasca-compaction | Menebak ulang dari checkbox (lossy) | Deterministik dari `plan.dag.json` |
| Governance | Tak ada rem | Budget + failure-breaker + terminal |
| Bentuk file | 94 baris, drift (hardcode "Sonnet 4.6") | Core <500 kata + `reference/` + `scripts/` |

## 9 Perubahan (Apa · Tujuan · Impact)

### 1 — Jadikan SATU loop-owner + delegasi (de-redundancy)
- **Apa:** Hapus duplikasi ECC; delegasi by-name (classifier→konsep `orch-pipeline`,
  shared-file→`team-agent-orchestration`, recovery→`continuous-agent-loop`,
  model→`/model-route`). Koreksi "SDD stacks" → "pinjam two-stage review sebagai
  teknik, jangan invoke loop kedua".
- **Tujuan:** Harness = policy murni, bukan re-implementasi muscle. Hindari dua-orchestrator.
- **Impact:** ~70% isi yang menduplikasi ECC + hardcode versi model basi hilang;
  drift lenyap, risiko nested-orchestrator hilang, maintenance turun.

### 2 — Klasifikasi & state di plan-time (`plan.dag.json`)
- **Apa:** Saat memuat plan tulis `plan.dag.json` per-task `{id, class, deps, model,
  tdd, gate, split?, status}`. Kelas = satu sumbu (model + TDD + gate + paralelisme).
  Pre-decide TDD, split file >500 baris, model tier — semua di sini, sekali.
- **Tujuan:** Loop tak berhenti bertanya di tengah; resume deterministik.
- **Impact:** DAG/klasifikasi tak lagi cuma di context master → resume pasca-compaction akurat.

### 3 — Deferred review (hapus gate sinkron)
- **Apa:** Tak ada gate manusia di tengah loop. security-core → verifier independen
  (≠ pelaku, Opus, negative test, `security-scan`) → commit → catat ke
  `review-ledger.md`. Verifier gagal → BLOCKED + revert idempoten + lanjut.
- **Tujuan:** Hands-off tanpa mengorbankan rel keamanan.
- **Impact:** Dari N interupsi (sekali per security-core) → 0; keamanan lebih ketat & terdokumentasi.

### 4 — Lifecycle: build → evaluate → local preview
- **Apa:** EVALUATE di instance lokal terisolasi (port sendiri + DB sekali-pakai
  migrated fresh) + e2e/smoke + bukti. PREVIEW: biarkan lokal jalan, buka, kasih URL +
  checklist, STOP. Deploy keluar jalur autonomous → `--deploy=staging` opt-in
  (deploy-lock); prod selalu gate.
- **Tujuan:** Goal "verifikasi" + membunuh hazard concurrency.
- **Impact:** Berakhir di localhost siap-klik; dua worktree tak berbagi instance → nol clobber/migrasi-paralel.

### 5 — Enforcement mekanis (hook/gate) + standing-constraints
- **Apa:** `check_file_sizes.sh` + PreToolUse hook blok Write/Edit >300/500
  (whitelist generated/migration); method≤30/CC≤10 via linter di gate set; SOFT
  clean-arch (SRP/deps/public) disuntik ke tiap prompt subagent; gate verifikasi always-on.
- **Tujuan:** Mekanis ditegakkan mesin; judgment tetap sampai ke subagent.
- **Impact:** 300-LOC yang sekarang mustahil ke-enforce (subagent tak warisi CLAUDE.md,
  GateGuard off, skrip tak ada) jadi ditolak di write-time.
- **Kontrak return subagent (ACI / SWE-agent):** subagent balikkan **ringkasan
  ber-batas + terfilter**, bukan dump mentah — nama test gagal + 1-baris sebab, bukan
  output penuh; sinyal eksplisit ("gate lulus, nol temuan" — jangan diam ambigu);
  **validasi sintaksis (lint/build) WAJIB lulus sebelum lapor "done"** (cegah error
  beruntun). Token-positif: feedback ringkas-terstruktur = hasil lebih baik + token lebih hemat.

### 6 — Autonomy guards (hands-off ≠ runaway)
- **Apa:** Plafon budget token + tracking + stop-on-ceiling; failure-breaker (3 gagal
  beruntun → `/harness-audit` → halt+report); eskalasi berujung (Sonnet→Opus→BLOCKED);
  destruktif/outward → stop-and-report; escalate by difficulty bukan rate-limit.
- **Tujuan:** Run fire-and-forget yang aman.
- **Impact:** Run buntu berhenti rapi + laporan, bukan membakar budget diam-diam.

### 7 — Context & token governance
- **Apa:** Strategic compaction di phase-gate (`/strategic-compact`); ledger/dag
  pointer-only di master; `/context-budget` audit lantai sebelum run panjang; batch
  unit mekanis remeh ke satu subagent.
- **Tujuan:** Master tetap tipis sepanjang run panjang; token tak terbuang.
- **Impact:** Compaction tak lagi memutus acak; 50 type-fix tak jadi 50 cold-spawn.

### 8 — Memory / learning (titik terlemah sekarang)
- **Apa:** Plan-time `agentdb_pattern_search` + baca user-memory → lipat gotcha ke
  DAG/standing-constraints. Run-end `pattern_store` + tulis project-memory bila ada
  fakta durable. Disiplin: state→file, pelajaran→semantic memory.
- **Tujuan:** Harness makin pintar tiap run.
- **Impact:** Dari amnesia (rediscover `supply-migration-blocker` via gagal migrasi) →
  blocker diketahui di plan-time, task ditandai pre-BLOCKED.

### 9 — Codebase decision memory + plan-time reconciliation
- **Apa:** Decision ledger terkurasi di `docs/decision-ledger.md` — schema per-entri:
  `{date, decision, reason, module, supersedes?, status: open|closed}`.
  Di **plan-time**: (a) query `code-review-graph` `get_impact_radius` scoped ke file
  yang plan sentuh → ambil entri ledger yang modulnya overlap; (b) keyword match
  (modul + 3 kata-kunci task vs `decision` field) → flag `DECISION-CONFLICT`
  bila ≥2/3 kata-kunci cocok; (c) putuskan awal: rekam supersession atau surfacing ke user.
  Verifikasi entri vs kode kini sebelum act (jangan percaya memori basi). Run-end: append.
  **Heuristik awal (best-effort, bukan jaminan):** false negative lebih aman daripada
  false positive — lebih baik miss konflik halus daripada flood noise. Iterasi ke
  semantic matching bila false negative terlalu sering.
- **Tujuan:** Plan tak terpaut dari eksekusi; "pick up where left off"; konflik diputus dini.
- **Impact:** Cegah eksekusi task konflik lalu unwind (hemat token bersih). Korpus
  (graph + ledger) eksternal; hanya slice ber-budget (~1k token) yang masuk context.

## Prasyarat (harus selesai sebelum P0)

| Prasyarat | Status | Catatan |
|---|---|---|
| `supply-migration-blocker` | **OPEN** | `local-preview.sh` gagal bila `make migrate` tidak ada atau migration path conflict. Workaround: seed-DB snapshot (`PREVIEW_SEED_DB`) atau `PREVIEW_SKIP_MIGRATE=1`. |
| `code-review-graph` MCP aktif | **DONE** (re-enabled) | Butuh **restart sesi Claude** agar perubahan `settings.local.json` efektif. |
| One-command local bring-up | **UNKNOWN** | `local-preview.sh` butuh: Go build (`GO_CMD`), port allocation, DB bring-up. Jalankan prerequisite verification (`reference/verification.md §2`) sebelum pertama kali pakai. |

## Urutan rollout

| Fase | Perubahan | Kenapa dulu | Batas |
|---|---|---|---|
| **P0 — hands-off jalan** | 3, 4, 2 | Tanpa ini "satu command lihat di akhir" tak tercapai | ← **MVP wajib** |
| **P1 — keselamatan & kualitas** | 5, 6 | Hands-off butuh rel pengaman | ← **MVP wajib** |
| **VALIDASI** | — | Acceptance test lulus sebelum lanjut P2 | ← **gerbang** |
| P2 — kecerdasan & efisiensi | 8, 9, 7 | Run makin murah & pintar | opsional |
| P3 — kepatuhan bentuk | 1 + restruktur artefak | Rapikan + hapus drift setelah perilaku benar | opsional |

### Acceptance test (gerbang P1 → P2)

Skenario: beri plan 5-task (2 security-core, 2 feature, 1 mechanical), jalankan `/execution-harness` sekali. Assert:
1. **Nol prompt manusia** di tengah run.
2. **Localhost terbuka** dan bisa diklik di akhir.
3. `run-report` + `review-ledger` terbit.
4. Token total < budget ceiling yang ditentukan.
5. Tidak ada file baru > 300 baris (hook enforcement terbukti).

Bila gagal → perbaiki P0/P1, jangan maju ke P2.

## Bentuk artefak akhir
```
execution-harness/
  SKILL.md                  # <500 kata: description trigger-focused, one-loop-owner,
                            # 3 invariant, task-class table, lifecycle 3-baris,
                            # deferred-review, anti-patterns
  reference/
    lifecycle.md            # eval→local-preview, isolasi, --deploy, deploy-lock
    autonomy.md             # guards, recovery, run-report template
    standing-constraints.md # SOFT clean-arch + hook memory plan-time/run-end
  scripts/
    check_file_sizes.sh · hooks/pretooluse-filesize.sh · local-preview.sh · deploy-lock.sh
```

## Yang TIDAK dirubah (dipertahankan)
Thin master (invariant 1-3), model routing by-stakes, freeze-the-root,
serialize-shared-file, recovery `freeze→/harness-audit→replay`, lazy-skill.

## Risiko & mitigasi
- Hook file-size false-positive pada generated/migration → whitelist eksplisit.
- Memory recall tercemar bila state transien masuk semantic store → disiplin pemisahan.
- Aturan disiplin dirasionalisasi agent → ditangkap oleh acceptance test gerbang P1→P2 (lihat atas).

## Referensi & pola yang dipinjam (token-disciplined)
| Referensi | Pola | Bentuk hemat | Perub. |
|---|---|---|---|
| Aider | repo-map ber-budget (~1k, ranked, context-aware) | pakai `code-review-graph` MCP, query scoped | 2, 8b |
| hermes-agent | FTS5 episodic recall + trajectory capture | index di disk; recall top-3 ringkasan; trajectory ke file | 8, 8b |
| SWE-agent | ACI / observation design | kontrak return `{status,summary,next_actions,artifacts}` | 5 |
| OpenHands | event-stream loop + sandboxed runtime | local-isolation per-worktree | 4, 6 |
| Voyager | skill library tumbuh + self-verify | `pattern_store` (bukan auto-create skill) | 8 |
| Reflexion | reflect-on-failure | refleksi capped → retry ≤K, lalu halt | 6 |

Aturan: **pinjam pola, jangan adopsi framework** (adopsi platform = melanggar one-loop-owner).
