# WP-12 Research Report — Metal hashing experiment (ADOPT_METAL / REJECT_METAL)

**Date:** 2026-08-06
**Status:** Completed — **REJECT_METAL** (a normal, successful research outcome per
`TORRENTINO_NATIVE_MACOS_IMPLEMENTATION_PLAN.md` §12.7)
**Decision reference:** ADR-018 (AI_Workflow_Kit/docs/DECISIONS.md)

---

## 1. Machine and environment

- Apple M4 (4P+6E), 32 GiB RAM, macOS 26.5.2 (25F84), arm64, 10 CPUs.
- `lowpowermode: 0`; no `sudo` available (energy proxy = `getrusage` CPU-seconds
  + `ProcessInfo.thermalState` + `pmset -g therm`).
- APFS Data volume ~6 GiB free during the run: the plan's 10 GiB, 10 GiB/10k-file
  and 50–100 GiB corpora are **N/A (storage)**; the 4 GiB single-file corpus fit
  and was measured, so the §12.7 eligibility line (>= 4 GiB) **was** exercised.
- External SSD, M1 and Low Power Mode rows: N/A (hardware/admin unavailable).
- Full environment snapshot: `Measurements/wp12/env-20260806-*.txt`.

## 2. Method (per §12.4/§12.7)

- Backends: Swift CPU reference (`ResearchHashingBackend`, cpu), experimental
  Metal (metal, under `TORRENTINO_METAL_EXPERIMENTAL=1`), and the production
  baseline libtorrent 2.0.13 (`torrentino-harness bench-hash`).
- Corpus: deterministic splitmix64 payloads (seed 7), 64 MiB / 1 GiB / 4 GiB,
  piece sizes 256K / 1M / 4M / 16M, hybrid format.
- 10 timed reps per cell per backend; backend order randomized per rep (Swift)
  and rotated across cells (libtorrent block); 1 warm-up rep per cell per backend
  before the timed reps; **no system purge** (page cache left between runs);
  cells executed in random order.
- Shared CSV schema: `run,cell,backend,wall_s,cpu_s,peak_rss_mb,thermal_before,
  thermal_after,cpu_speed_limit,gpu_wall_s,fallbacks,staged_bytes,
  throughput_mib_s`. Raw data: `Measurements/wp12/bench-20260806-112438.csv`.
  Analysis (medians, 95% CI via t9, p95, gate verdicts):
  `Measurements/wp12/gate-verdict-20260806.md`.

## 3. Results

| cell | CPU median | Metal median | libtorrent median | Metal/CPU |
|---|---|---|---|---|
| 64m/256KiB | 0.141s | 0.314s | 0.057s | 0.45x |
| 64m/1024KiB | 0.129s | 0.356s | 0.056s | 0.36x |
| 64m/4096KiB | 0.140s | 0.539s | 0.057s | 0.26x |
| 64m/16384KiB | 0.142s | 1.289s | 0.056s | 0.11x |
| 1g/1024KiB | 2.246s | 4.658s | 0.889s | 0.48x |
| 1g/4096KiB | 2.222s | 5.201s | 0.810s | 0.43x |
| 1g/16384KiB | 2.263s | 8.652s | 0.894s | 0.26x |
| **4g/1024KiB** | **9.013s** | **18.601s** | **3.675s** | **0.48x** |
| **4g/4096KiB** | **8.969s** | **21.681s** | **3.260s** | **0.41x** |
| **4g/16384KiB** | **8.907s** | **34.358s** | **3.646s** | **0.26x** |

95% CIs are tight (<= ±2% of the median in every cell). Peak RSS: CPU 10–73 MB,
Metal 344 MB–2.35 GB (scales with corpus + staging), libtorrent 73 MB–4.1 GB.
Fallbacks: 0 on every row (healthy hardware). Thermal evidence: no throttling
recorded on any run (`thermal_before/after` = 100/nominal in all 300 rows).

## 4. Gate verdicts (§12.7)

| gate | verdict | evidence |
|---|---|---|
| G1 bit-for-bit known vectors | PASS | KnownAnswerTests 5/5 (test_wp12_01) |
| G2 v1/v2/hybrid vs CPU reference 100% | PASS | CorrectnessTests 4/4 incl. 100 + 100 randomized cases (test_wp12_01) |
| G3 >= 100 randomized cases | PASS | CorrectnessTests (test_wp12_01) |
| G4 >= 1000 stress iterations | PASS | StressTests: 1000 iterations, 0 mismatches (test_wp12_01) |
| G5 independent BEP validator | PASS | libtorrent 2.0.13: 18/18 cells, v1 pieces + v2 roots + layer content byte-equal (test_wp12_04) |
| **G6 >= 20% median wall-clock on >= 4 GiB** | **FAIL** | 4 GiB cells: Metal is **0.26x–0.48x** of CPU speed (2–4x slower) |
| **G7 p95 regression <= 5%** | **FAIL** | p95 ratio CPU/Metal = 0.26–0.49 everywhere |
| **G8 memory budget** | **FAIL** | Metal/CPU peak RSS ratio 22–38x (>= 10x is over budget) |
| **G9 throughput-per-joule (cpu-s proxy)** | **FAIL** | Metal burns ~2x the CPU-seconds per MiB of CPU hashing |
| G10 no new thermal events | PASS | none observed on either backend |
| G11 fallbacks == 0 on healthy hardware | PASS | all 300 rows fallbacks=0 (test_wp12_03) |

## 5. Root-cause findings (report material)

1. **M4 GPU is bandwidth-bound for SHA-1 piece hashing.** Metal throughput
   ~180 MiB/s vs CPU ~470 MiB/s (1 GiB cells). The M4's small GPU does not win
   for whole-corpus hashing; staging 1:1 into MTLBuffers (`staged_bytes` =
   corpus size) dominates both time and memory.
2. **Hybrid Metal pays twice.** In hybrid format the v1 SHA-1 path uses the GPU
   while the v2 SHA-256 block tree is still hashed on CPU; the metal rows show
   `cpu_s` ~= wall − gpu_wall (4.2s CPU-seconds on the 1 GiB cell). There is no
   GPU SHA-256 v2 path, so hybrid Metal = GPU + CPU = worst of both.
3. **Metal wall grows superlinearly with piece size** (64m: 0.31s@256K → 1.29s@16M;
   4g: 18.6s@1M → 34.4s@16M) — per-piece orchestration cost, while CPU is flat
   (~0.14s on 64m at any piece size).
4. **libtorrent 2.0.13 CPU baseline is ~2.5x faster than the Swift CPU
   reference** (4 GiB: 3.3–3.7s vs 8.9–9.0s) — multi-threaded hashing
   (`hashing_threads`) plus optimized SHA-1. Production already uses libtorrent
   (WP-04), so the CPU baseline Torrentino would ship with is the fast one.
5. **libtorrent v2 merkle semantics** (documented in the verifier work):
   - `torrent_info::info_hashes().v2` is the info-dict hash, **not** the merkle root.
   - `create_torrent` computes the file root as `merkle_root(piece_roots, pad_hash)`
     with `pad_hash = merkle_pad(piece_length/16384, 1)` (two-level tree), which
     for piece-aligned and sub-piece single files coincides with the strict
     BEP-52 whole-file tree our Swift writer produces (verified byte-equal).
   - libtorrent's own `torrent_info` parse re-derives a different root value on
     load (e.g. tiny: stored `0db73843…`, parse-derived `dc0131fc…`); the stored
     root matches `generate_buf()`, which is what peers validate against.
   - `lt::create_torrent` must not be returned/moved by value in 2.0.13
     (`file_storage` self-offsets → EXC_BAD_ACCESS); construct in place.
6. **Deliverable evidence for §12.4 in-feasible rows:** 10 GiB, 10 GiB/10k files,
   50–100 GiB, external SSD, M1, LPM rows are documented N/A with reasons in the
   QA scripts and this report; the 4 GiB row (the eligibility line) is measured.

## 6. Decision

**REJECT_METAL.** The experimental Metal backend is correct (bit-for-bit,
independent-verified) but slower than CPU on every measured workload, uses
22–38x the memory of CPU hashing, and violates every performance gate at the
eligible >= 4 GiB line. Per §12.7, `REJECT_METAL` is a normal successful
research outcome: the experiment is complete, evidence is archived, and no
production path is affected (Creator remains CPU-only via libtorrent, WP-11
unchanged). The Metal code stays behind `TORRENTINO_METAL_EXPERIMENTAL=1` and
is never selected automatically.
