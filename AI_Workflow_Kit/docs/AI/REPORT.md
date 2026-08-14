# WP-01 QA Report — Test Engineer

**Date:** 2026-08-02
**WP:** WP-01 — libtorrent arm64 bakeoff
**Role:** Test Engineer (test code & QA scripts only; **no product code modified**)
**Graphify:** `graphify query "WP-01 test scenarios, harness architecture, soak test, sanitizer suite, build scripts"` — OK (graph fresh, 2026-08-02 08:02)
**Suite:** `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`

---

## Verdict: **GREEN (tests green)**

All 11 dedicated QA scripts pass; full regression suite is green. No blocking bugs
found. Two non-blocking observations recorded (§4). The 24h soak burn-in is healthy
mid-run and already far past the 2h / >6000-iteration gate.

---

## 1. Suite results — old scripts vs new scripts

This is the **first WP with a QA suite**, so there were **no pre-existing test
scripts**. All scripts below are **new this run** and become the regression base
for WP-02+ (coverage grows monotonically; nothing is deleted).

| Category | Count | Result |
|----------|-------|--------|
| Old (regression) scripts | **0** | n/a — first WP with tests |
| New scripts this run | **11** (+ `run_qa_suite.sh` runner + `qa_common.sh`) | **11/11 PASS** |
| **Full suite** | **11** | **GREEN, exit 0** |

### 1.1 Per-script results (final full-suite run)

| # | Script (new this run) | Feature / gate covered | Result |
|---|-----------------------|------------------------|--------|
| 1 | `test_wp01_build_idempotent.sh` | build.sh rebuild idempotent; arm64 artifact; SHA-256 == lock | **PASS** |
| 2 | `test_wp01_versions_lock_valid.sh` | versions.lock format, pins, SHA-256/commit formats, reality match | **PASS** |
| 3 | `test_wp01_harness_all_scenarios.sh` | run_tests.sh — all 11 scenarios PASS | **PASS** |
| 4 | `test_wp01_fallback_2013.sh` | run_tests.sh --lt-version 2.0.13 — 11/11 PASS | **PASS** |
| 5 | `test_wp01_sanitizers_clean.sh` | run_sanitizers.sh — 0 ASan/UBSan reports | **PASS** |
| 6 | `test_wp01_soak_smoke.sh` | run_soak.sh status parses; 25s smoke errors=0; report JSON valid | **PASS** |
| 7 | `test_wp01_no_homebrew_positive.sh` | verify_no_homebrew CLEAN on default + fallback binaries | **PASS** |
| 8 | `test_wp01_no_homebrew_negative.sh` | poisoned binary (Homebrew dylib + rpath) rejected — negative test | **PASS** |
| 9 | `test_wp01_exception_firewall.sh` | C-ABI containment; set_terminate; misuse → exit 6, no terminate | **PASS** |
| 10 | `test_wp01_crash_restore.sh` | SIGKILL child + partial-data restore; registry survival | **PASS** |
| 11 | `test_wp01_flush_barrier_smoke.sh` | flush_cache barrier; 25s soak, 0 payload digest mismatch | **PASS** |

```
total: 11  pass: 11  fail: 0
SUITE RESULT: GREEN   (exit 0)
```

### 1.2 Underlying production-script evidence

| Check | Command | Result |
|-------|---------|--------|
| Scenarios 2.1.0 | `run_tests.sh` | 11 passed, 0 failed |
| Scenarios 2.0.13 | `run_tests.sh --lt-version 2.0.13` | 11 passed, 0 failed |
| Sanitizers | `run_sanitizers.sh` | `sanitizer reports: 0`, ASan/UBSan clean |
| No Homebrew | `verify_no_homebrew.sh …/harness-2.1.0-release/torrentino-harness` | OK: arm64, macOS 13.0+, system libs only |

---

## 2. Gate coverage (WP-01 gate bullets)

| Gate | Test(s) | Status | Evidence |
|------|---------|--------|----------|
| Restore без потери registry/partial data | `test_wp01_crash_restore.sh` | **PASS** | child SIGKILLed; `restored 2097152/4194304 bytes after kill -9` (genuinely partial); registry/session/resume/torrent survival enforced by in-scenario `TH_REQUIRE(fs::exists(...))` before PASS |
| Нет Homebrew runtime links | `test_wp01_no_homebrew_positive.sh` + `_negative.sh` | **PASS** | positive CLEAN; negative proves the gate actually fails a poisoned binary (dylib-link + rpath diagnostics both fire) |
| Точный dependency lock (versions.lock) | `test_wp01_versions_lock_valid.sh` + `test_wp01_build_idempotent.sh` | **PASS** | all pins present; SHA-256=64hex / commit=40hex; cached archives == pins; arm64/13.0 contract |
| Все C++ exceptions остаются внутри harness | `test_wp01_exception_firewall.sh` | **PASS** | `exception_containment` PASS; `std::set_terminate` + `catch(...)` + `run_guarded` present; misuse → exit 6, never a terminate |
| ASan/UBSan clean | `test_wp01_sanitizers_clean.sh` | **PASS** | 11/11, 0 reports |
| 24h soak без crash/hang (smoke 30s, errors=0) | `test_wp01_soak_smoke.sh` + `test_wp01_flush_barrier_smoke.sh` | **PASS (smoke) / ON TRACK (full 24h)** | two isolated 25s soaks: exit 0, errors=0, 0 digest mismatch, valid JSON; live burn-in §3 |

---

## 3. Live 24h soak burn-in (observed, not blocking)

At verification time (the long burn-in runs concurrently; my smoke soaks used
isolated disposable workspaces and never touched it):

| Metric | Value |
|--------|-------|
| Status | **RUNNING** (pid 34809) |
| Elapsed | **~8h10m** |
| Iterations | **27816** (≫ 6000 gate) |
| Bytes transferred | **~109.4 GB** |
| Errors | **0** |
| RSS | **27–29 MiB** (stable, non-monotonic) |
| Slowest iteration | 5.006s |

The 2h / >6000-iteration gate is **already satisfied** (8h+, 27816 iters, 0 errors).
Full 24h completion remains a wall-clock item for the orchestrator to re-confirm at
T+24h; no failures so far.

---

## 4. Observations (non-blocking)

1. **Build idempotency nuance (not a bug):** a repeat `build.sh` run is
   functionally idempotent — the **object content** of `libtorrent-rasterbar.a`
   is byte-identical across rebuilds (verified by hashing every `.o` member).
   The *raw* `.a` hash differs only because BSD `ar` re-stamps the `__.SYMDEF`
   symbol-table member with the current time on re-archive. Bit-for-bit
   reproducible archives are **not** a WP-01 requirement; the test therefore
   asserts object-content stability, not raw-archive hash.
2. **Silent-on-success digest/registry checks:** `soak.cpp` logs only on
   `payload digest mismatch`; `crash_restore` proves registry survival via
   silent `TH_REQUIRE`. Tests assert on the real signals (iterations + zero
   mismatches; PASS implies the existence checks passed), not on log lines that
   do not exist.
3. **Two QA fixes this run (uncommitted; orchestrator to commit per rule 7):**
   - `qa_common.sh`: temp-dir cleanup now uses a per-PID list **file** — the
     original in-memory array was lost because `qa_mktemp` runs inside `$(...)`
     subshells, which leaked ~46 scratch dirs. Now verified **0 leaked dirs**.
   - `test_wp01_flush_barrier_smoke.sh`: removed an assertion on a non-existent
     "digest ok" log line; replaced with iterations + zero-mismatch proof.
4. **Full 24h not elapsed:** gate stays open until the process completes 86400s;
   trajectory is healthy.

---

## 5. Hygiene verification

| Rule | Check | Result |
|------|-------|--------|
| No production Application Support | harness uses only `--workspace`/`$TMPDIR` | OK |
| Download paths only mktemp/disposable | all smoke soaks use `mktemp -d` | OK |
| No leftover helper processes | only the intended 24h soak (pid 34809) remains | OK |
| No leftover temp data | `qa_wp01.*` dirs: **0**, list files: **0** after full suite | OK |
| No product code modified | `harness/src/*` mtimes predate this session; only `scripts/qa/*` + docs changed | OK |

---

## 6. Artifacts

| Artifact | Path |
|----------|------|
| QA suite (new) | `Native/TorrentinoEngineBridge/scripts/qa/` (11 tests + runner + common) |
| Coverage matrix | `AI_Workflow_Kit/docs/AI/COVERAGE.md` |
| Final suite run | `/tmp/qa_suite.out` (11/11 GREEN) |
| versions.lock | `Native/ThirdParty/versions.lock` |
| Static lib | `Native/ThirdParty/.build/prefix/libtorrent-2.1.0-release/lib/libtorrent-rasterbar.a` |
| Soak log | `Native/TorrentinoEngineBridge/runs/soak/soak.log` |

---

## 7. Итог

| | |
|--|--|
| **Overall** | **GREEN (tests green)** |
| New scripts | 11 (+ runner + common), all PASS |
| Regression base | established for WP-02+ |
| Bugs found | **0 blocking** (2 non-blocking observations, §4) |
| Soak | healthy RUNNING, 8h+, 27816 iters, 0 errors (2h/6000 gate met) |
| Action for Human | Return to orchestrator with GREEN; orchestrator to commit the 2 QA fixes + COVERAGE.md and re-confirm soak at T+24h |

No BUG_REPORT.md written (no FAIL).

| Dependency lock | `versions.lock` | valid; SHA-256 pins match cached archives |

---

## WP-13 bounded lane QA — TRACKER-SHARING-IMPL-001

**Date:** 2026-08-11  
**Verdict:** **GREEN**

- Reviewer: `approved`, all six ADR-021 Judgment Gates, no findings.
- Focused XCTest: 12 executions, 0 failures; exact catalog, composition matrix,
  capacity, private fail-closed, EN/RU keys and generated-artifact round trip.
- Existing Creator QA: `test_wp11_tracker_topology.sh`,
  `test_wp11_schema_v3_topology.sh`, and
  `test_wp11_creator_asserted_options.sh` — 3/3 PASS.
- Final full XCTest: 332/332 passed, 0 failed, 0 skipped.
- Final result bundle: `build/TrackerSharingFinal2.xcresult`.
- Tester strengthened the exact three-tier catalog contract and repaired one
  pre-existing baseline-count race in an unrelated pump test; Main verified
  both test diffs and the final full suite.
- Human screenshot failure was correlated to the existing no-overwrite safety
  contract: the selected `.torrent` output already existed. It was not a
  tracker or inspection-topology failure.
- Bugs open: 0. No `BUG_REPORT.md` update required.
