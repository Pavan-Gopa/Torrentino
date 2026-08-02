# WP-01 Coverage Matrix — Test Engineer

**WP:** WP-01 — libtorrent arm64 bakeoff
**Updated:** 2026-08-02 (this run)
**Principle:** monotonic coverage — scripts are never deleted; WP-02+ adds to this base.
**Location of scripts:** `Native/TorrentinoEngineBridge/scripts/qa/`
**Suite runner:** `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`

This is the FIRST WP with a QA suite, so there is no prior regression base. Every
script below is **new this run** and becomes the regression base for WP-02+.

## Feature → test coverage (all "new this run")

| Area | Feature (from kick) | Test script | Scenarios covered | Status |
|------|---------------------|-------------|-------------------|--------|
| Build | build.sh static arm64 build; rebuild idempotent; artifact arm64; SHA-256 == lock | `test_wp01_build_idempotent.sh` | repeat build exits 0; object-content hash stable across rebuilds; arm64; cached-archive SHA-256 == lock; manifest valid JSON | new this run |
| Deps | versions.lock pin file validity | `test_wp01_versions_lock_valid.sh` | valid shell fragment; all pins present; SHA-256=64hex, commit=40hex; default∈supported; arm64/13.0 contract; cached archives match pins; prefixes exist | new this run |
| Harness | run_tests.sh — 11 scenarios | `test_wp01_harness_all_scenarios.sh` | all 11 PASS, 0 FAIL, "11 passed, 0 failed", each named scenario PASS | new this run |
| Harness | fallback libtorrent 2.0.13 | `test_wp01_fallback_2013.sh` | binary reports 2.0.13; 11/11 PASS on 2.0.13 | new this run |
| Sanitizers | run_sanitizers.sh ASan+UBSan | `test_wp01_sanitizers_clean.sh` | exit 0; "sanitizer reports: 0"; clean banner; no ASan/UBSan diagnostics in log | new this run |
| Soak | run_soak.sh status/start/stop + 30s smoke | `test_wp01_soak_smoke.sh` | `status` parses (RUNNING/NOT running); isolated 25s soak exits 0; report JSON valid; status=ok; iterations>0; error_alerts=0; no ERROR/FATAL | new this run |
| Deps/Gate | verify_no_homebrew.sh positive | `test_wp01_no_homebrew_positive.sh` | default + fallback binaries CLEAN (arm64, 13.0, no Homebrew//usr/local links or rpaths) | new this run |
| Deps/Gate | verify_no_homebrew.sh negative | `test_wp01_no_homebrew_negative.sh` | poisoned binary (Homebrew dylib + rpath) rejected; missing file rejected; correct diagnostics fire | new this run |
| Firewall | C-ABI exception containment | `test_wp01_exception_firewall.sh` | exception_containment PASS; set_terminate + catch(...) + run_guarded present; misuse (unknown scenario / missing arg / unknown flag) → exit 6, no terminate | new this run |
| Persistence/Gate | crash_restore (SIGKILL + restore) | `test_wp01_crash_restore.sh` | scenario PASS; child spawned + SIGKILLed; partial data restored; restore genuinely partial (0<restored<total); registry survival enforced by in-scenario TH_REQUIRE | new this run |
| Soak/Gate | flush_cache barrier / digest verification | `test_wp01_flush_barrier_smoke.sh` | flush_cache()+cache_flushed_alert+sha256_file_hex present; isolated 25s soak: 0 "payload digest mismatch", status=ok, error_alerts=0, N digests verified | new this run |

## Gate → test mapping (WP-01 gate bullets)

| Gate | Covered by | N/A? |
|------|------------|------|
| Restore без потери registry/partial data | `test_wp01_crash_restore.sh` (+ `crash_restore` scenario TH_REQUIRE) | — |
| Нет Homebrew runtime links | `test_wp01_no_homebrew_positive.sh` + `test_wp01_no_homebrew_negative.sh` | — |
| Точный dependency lock (versions.lock) | `test_wp01_versions_lock_valid.sh` + `test_wp01_build_idempotent.sh` | — |
| Все C++ exceptions остаются внутри harness | `test_wp01_exception_firewall.sh` | — |
| ASan/UBSan clean | `test_wp01_sanitizers_clean.sh` | — |
| 24h soak без crash/hang (smoke 30s, errors=0) | `test_wp01_soak_smoke.sh` + `test_wp01_flush_barrier_smoke.sh` (smoke); full 24h is wall-clock, observed via `run_soak.sh status` | full 24h not assertable in CI time — smoke covers correctness; live burn-in observed separately |

## Regression base for WP-02+

All 11 scripts + `run_qa_suite.sh` + `qa_common.sh`. The runner auto-discovers
`test_wp01_*.sh` (and future `test_wpNN_*.sh` can be added alongside).
