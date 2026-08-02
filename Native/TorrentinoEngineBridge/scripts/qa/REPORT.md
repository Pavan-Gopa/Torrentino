# Torrentino QA REPORT — WP-03 (Native project skeleton + strict concurrency)

**Date:** 2026-08-02  
**Role:** Test Engineer  
**Verdict:** **FAIL** (see `BUG_REPORT.md`)  
**Entry point:** `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`  
**Suite log:** `/tmp/torrentino_qa_suite_wp03.log`

## Summary

| Metric | Value |
| --- | --- |
| Total scripts | 32 |
| Pass | 30 |
| Fail | 2 |
| WP-01 (regression) | 11 / 11 PASS |
| WP-02 (regression) | 13 / 13 PASS |
| WP-03 (new) | 6 / 8 PASS |
| Suite result | **FAIL** |
| Wall time (suite) | ~246 s |

**Blocking product bug:** `EngineError` does not conform to `LocalizedError`  
→ `test_wp03_domain_types.sh` + `test_wp03_xctest_pass.sh` FAIL.  
Details: `BUG_REPORT.md` (WP03-BUG-001).

---

## Results table

### Regression (WP-01) — existing scripts

| Script | Kind | Result | Duration |
| --- | --- | --- | --- |
| `test_wp01_build_idempotent.sh` | old | PASS | 2s |
| `test_wp01_crash_restore.sh` | old | PASS | 0s |
| `test_wp01_exception_firewall.sh` | old | PASS | 0s |
| `test_wp01_fallback_2013.sh` | old | PASS | 3s |
| `test_wp01_flush_barrier_smoke.sh` | old | PASS | 26s |
| `test_wp01_harness_all_scenarios.sh` | old | PASS | 3s |
| `test_wp01_no_homebrew_negative.sh` | old | PASS | 0s |
| `test_wp01_no_homebrew_positive.sh` | old | PASS | 0s |
| `test_wp01_sanitizers_clean.sh` | old | PASS | 3s |
| `test_wp01_soak_smoke.sh` | old | PASS | 26s |
| `test_wp01_versions_lock_valid.sh` | old | PASS | 0s |

### Regression (WP-02) — existing scripts

| Script | Kind | Result | Duration |
| --- | --- | --- | --- |
| `test_wp02_counter_corruption.sh` | old | PASS | 4s |
| `test_wp02_counter_downgrade_block.sh` | old | PASS | 9s |
| `test_wp02_counter_durability.sh` | old | PASS | 13s |
| `test_wp02_denial_degraded.sh` | old | PASS | 10s |
| `test_wp02_graceful_shutdown.sh` | old | PASS | 23s |
| `test_wp02_launchd_only_guard.sh` | old | PASS | 2s |
| `test_wp02_lifecycle_contract_complete.sh` | old | PASS | 0s |
| `test_wp02_lifecycle_script.sh` | old | PASS | 25s |
| `test_wp02_no_duplicate_instance.sh` | old | PASS | 12s |
| `test_wp02_reconnect_after_kill.sh` | old | PASS | 17s |
| `test_wp02_smappservice_register.sh` | old | PASS | 2s |
| `test_wp02_update_script.sh` | old | PASS | 7s |
| `test_wp02_xpc_roundtrip.sh` | old | PASS | 21s |

### New (WP-03) — this cycle

| Script | Feature | Result | Duration |
| --- | --- | --- | --- |
| `test_wp03_domain_types.sh` | TorrentState / TorrentInfo / EngineError unit | **FAIL** | 17s |
| `test_wp03_empty_state.sh` | Native empty state + AppTests | PASS | 3s |
| `test_wp03_ipc_envelope.sh` | IPCEnvelope / IPCVersion / Command / Event | PASS | 2s |
| `test_wp03_legacy_untouched.sh` | Legacy/ git clean | PASS | 0s |
| `test_wp03_strict_concurrency.sh` | SWIFT_STRICT_CONCURRENCY=complete, 0 warnings | PASS | 1s |
| `test_wp03_string_catalog.sh` | xcstrings EN+RU complete | PASS | 0s |
| `test_wp03_testprofile_isolation.sh` | TestProfile isolation + cleanup | PASS | 3s |
| `test_wp03_xctest_pass.sh` | All XCTest targets green | **FAIL** | 12s |

---

## Gate evidence (from plan)

| Gate | Evidence | Status |
| --- | --- | --- |
| Clean build without warnings | `test_wp03_strict_concurrency.sh` | PASS |
| Unit test targets green | Domain fails on LocalizedError | **FAIL** |
| App shows native empty state | ContentView + catalog + AppTests | PASS |
| Legacy/ untouched | `test_wp03_legacy_untouched.sh` | PASS |

---

## XCTest coverage (ADR-010)

| Target | Cases (approx) | Notes |
| --- | --- | --- |
| TorrentinoDomainTests | 18 | 1 FAIL: LocalizedError |
| TorrentinoIPCTests | 18 | all PASS |
| TorrentinoAppTests | 3 | all PASS |

Product code was **not** modified. No git commit / push.
