# Torrentino QA Coverage — WP-03 (Native skeleton + strict concurrency)

Updated: 2026-08-02 (Test Engineer, WP-03 cycle)  
Suite entry: `Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`  
**Last full suite:** 2026-08-02 — **30/32 PASS (FAIL)** — see `REPORT.md` + `BUG_REPORT.md`

## Coverage policy

- Monotonic: old WP-01 / WP-02 scripts are never deleted; WP-03 adds `test_wp03_*.sh`.
- Full suite always runs WP-01 + WP-02 + WP-03.
- Exit 0 = pass; isolated cleanup on EXIT.
- ADR-010: every public API ≥3 unit axes; every actor ≥1 stress; every parser ≥1 negative/fuzz.

---

## Stage A — New features this cycle (WP-03)

| # | Feature | Dedicated script / tests | Happy | Error/invalid | Edge | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `TorrentState` enum | Domain XCTest + `test_wp03_domain_types.sh` | allCases + Codable | unknown raw/JSON fail | concurrent reads | covered |
| 2 | `TorrentInfo` struct | Domain XCTest + domain script | fields + Codable | tampered JSON | empty name, size=0, progress 0/1, OOR fuzz | covered |
| 3 | `EngineError` enum | Domain XCTest + domain script | all cases, Error, descriptions | — | equality | **LocalizedError FAIL (BUG-001)** |
| 4 | `IPCEnvelope` | IPC XCTest + `test_wp03_ipc_envelope.sh` | round-trip | tampered/missing/garbage | truncated fuzz, stress | covered |
| 5 | `IPCVersion` | IPC XCTest + ipc script | current=1.0, order | major mismatch | same-major minor OK | covered |
| 6 | `EngineCommand` | IPC XCTest + ipc script | all Codable | unknown decode fail | raw values | covered |
| 7 | `EngineEvent` | IPC XCTest + ipc script | all Codable | unknown decode fail | placeholders | covered |
| 8 | `TestProfile` | Domain XCTest + `test_wp03_testprofile_isolation.sh` | creates temp dir | — | not production path, tearDown | covered |
| 9 | Strict concurrency complete | `test_wp03_strict_concurrency.sh` | build 0 warnings | — | xcconfig complete + Werror | covered |
| 10 | String Catalog EN/RU | `test_wp03_string_catalog.sh` | valid JSON | missing lang fail | required keys present | covered |
| 11 | Empty state | `test_wp03_empty_state.sh` + AppTests | ContentView keys | no fabricated TorrentInfo | catalog EN+RU | covered |
| — | Legacy untouched | `test_wp03_legacy_untouched.sh` | git clean | any Legacy change fails | — | covered |
| — | Full XCTest green | `test_wp03_xctest_pass.sh` | Domain+IPC+App | fails if any case red | — | **FAIL (BUG-001)** |

## Gate coverage (from plan)

| Gate | Test / evidence | Status |
| --- | --- | --- |
| Clean build without warnings | `test_wp03_strict_concurrency.sh` | covered / PASS |
| Unit test target runs | `test_wp03_xctest_pass.sh` + Domain/IPC/App | covered / **FAIL** |
| App shows native empty state | `test_wp03_empty_state.sh` | covered / PASS |
| Legacy/ untouched | `test_wp03_legacy_untouched.sh` | covered / PASS |

## Regression (WP-01) — still run every suite

| Script | Feature |
| --- | --- |
| `test_wp01_build_idempotent.sh` | build.sh idempotency |
| `test_wp01_crash_restore.sh` | crash restore |
| `test_wp01_exception_firewall.sh` | C-ABI exception firewall |
| `test_wp01_fallback_2013.sh` | 2.0.11 fallback |
| `test_wp01_flush_barrier_smoke.sh` | flush barrier |
| `test_wp01_harness_all_scenarios.sh` | harness all scenarios |
| `test_wp01_no_homebrew_negative.sh` | no Homebrew negative |
| `test_wp01_no_homebrew_positive.sh` | no Homebrew positive |
| `test_wp01_sanitizers_clean.sh` | ASan/UBSan clean |
| `test_wp01_soak_smoke.sh` | soak smoke |
| `test_wp01_versions_lock_valid.sh` | versions.lock |

## Regression (WP-02) — still run every suite

| Script | Feature |
| --- | --- |
| `test_wp02_smappservice_register.sh` | SMAppService register/unregister |
| `test_wp02_xpc_roundtrip.sh` | Mach XPC 5 methods |
| `test_wp02_counter_durability.sh` | Durable counter vs SIGKILL |
| `test_wp02_counter_corruption.sh` | Checksum / truncation reject |
| `test_wp02_counter_downgrade_block.sh` | v1 on v2 → exit 78 |
| `test_wp02_reconnect_after_kill.sh` | EngineClient bounded reconnect |
| `test_wp02_graceful_shutdown.sh` | XPC + SIGTERM exit 0 |
| `test_wp02_launchd_only_guard.sh` | Direct launch → exit 1 |
| `test_wp02_lifecycle_script.sh` | lifecycle_test.sh |
| `test_wp02_update_script.sh` | update_test.sh |
| `test_wp02_lifecycle_contract_complete.sh` | LIFECYCLE_CONTRACT.md |
| `test_wp02_no_duplicate_instance.sh` | flock bail-out |
| `test_wp02_denial_degraded.sh` | Denial → DEGRADED |

## Shared infrastructure

| File | Role |
| --- | --- |
| `qa_common.sh` | paths, mktemp, asserts |
| `qa_wp02_common.sh` | app resolve, launchd/cli helpers |
| `run_qa_suite.sh` | runs `test_wp01_*.sh` + `test_wp02_*.sh` + `test_wp03_*.sh` |

## Open gaps (after this run)

| Gap | Severity | Notes |
| --- | --- | --- |
| `EngineError: LocalizedError` | P1 | WP03-BUG-001 — product fix required |
| GUI pixel/UI automation of empty window | N/A | Covered via source contract + AppTests; no AppKit snapshot harness yet |
