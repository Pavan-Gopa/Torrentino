# Torrentino QA REPORT — WP-02 (SMAppService lifecycle spike)

**Date:** 2026-08-02  
**Role:** Test Engineer  
**Verdict:** **GREEN** — full suite pass  
**Entry point:** `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`  
**Suite log:** `/tmp/torrentino_qa_suite_wp02.log`

## Summary

| Metric | Value |
| --- | --- |
| Total scripts | 24 |
| Pass | 24 |
| Fail | 0 |
| WP-01 (regression) | 11 / 11 PASS |
| WP-02 (new) | 13 / 13 PASS |
| Suite result | GREEN |
| Wall time (suite) | ~204 s |

No product bugs detected in this cycle. Residual check after suite: no
`TorrentinoEngineAgent` processes, no launchd job
`com.torrentino.app.engine-agent`, Engine Application Support dir wiped by
per-script EXIT traps.

---

## Results table

### Regression (WP-01) — existing scripts

| Script | Kind | Result | Duration |
| --- | --- | --- | --- |
| `test_wp01_build_idempotent.sh` | old | PASS | 1s |
| `test_wp01_crash_restore.sh` | old | PASS | 0s |
| `test_wp01_exception_firewall.sh` | old | PASS | 1s |
| `test_wp01_fallback_2013.sh` | old | PASS | 2s |
| `test_wp01_flush_barrier_smoke.sh` | old | PASS | 27s |
| `test_wp01_harness_all_scenarios.sh` | old | PASS | 2s |
| `test_wp01_no_homebrew_negative.sh` | old | PASS | 0s |
| `test_wp01_no_homebrew_positive.sh` | old | PASS | 0s |
| `test_wp01_sanitizers_clean.sh` | old | PASS | 3s |
| `test_wp01_soak_smoke.sh` | old | PASS | 27s |
| `test_wp01_versions_lock_valid.sh` | old | PASS | 0s |

### New (WP-02) — this cycle

| Script | Feature | Result | Duration |
| --- | --- | --- | --- |
| `test_wp02_smappservice_register.sh` | SMAppService register/unregister | PASS | 1s |
| `test_wp02_xpc_roundtrip.sh` | Mach XPC 5 methods | PASS | 20s |
| `test_wp02_counter_durability.sh` | Durable counter vs SIGKILL | PASS | 13s |
| `test_wp02_counter_corruption.sh` | Checksum / truncation reject | PASS | 2s |
| `test_wp02_counter_downgrade_block.sh` | v1 on v2 → exit 78 | PASS | 9s |
| `test_wp02_reconnect_after_kill.sh` | EngineClient bounded reconnect | PASS | 18s |
| `test_wp02_graceful_shutdown.sh` | XPC + SIGTERM exit 0 + flush | PASS | 22s |
| `test_wp02_launchd_only_guard.sh` | Direct launch → exit 1 | PASS | 1s |
| `test_wp02_lifecycle_script.sh` | lifecycle_test.sh 30 checks | PASS | 25s |
| `test_wp02_update_script.sh` | update_test.sh 26 checks | PASS | 7s |
| `test_wp02_lifecycle_contract_complete.sh` | LIFECYCLE_CONTRACT.md sections | PASS | 0s |
| `test_wp02_no_duplicate_instance.sh` | flock bail-out | PASS | 12s |
| `test_wp02_denial_degraded.sh` | Denial → DEGRADED, no in-process | PASS | 10s |

---

## Gate evidence (from plan)

| Gate | Evidence | Status |
| --- | --- | --- |
| UI/agent lifecycle on signed build | lifecycle_test PASS=30 (codesign preflight + register→XPC→crash→shutdown→unregister) | PASS |
| Agent does not require root | all scripts as user; no sudo | PASS |
| No second instance | `test_wp02_no_duplicate_instance.sh` + lifecycle lock checks | PASS |
| Reconnect returns authoritative state | counter=N after SIGKILL + EngineClient retries | PASS |
| Helper correctly unregisters | SMAppService status=notRegistered; launchctl print fails | PASS |
| KeepAlive, exit codes, idle policy | exit 0 on clean stop; no auto-respawn; ThrottleInterval respawn after crash | PASS |
| Denial no in-process fallback | status exit 3 degraded; no agent process; XPC fails | PASS |
| N-1/N/downgrade semantics | update_test PASS=26; dedicated downgrade/corruption scripts | PASS |

---

## Artifacts added this cycle (test-only)

| Path | Role |
| --- | --- |
| `scripts/qa/qa_wp02_common.sh` | Shared WP-02 helpers (app resolve, CLI, cleanup) |
| `scripts/qa/test_wp02_*.sh` (13) | Dedicated feature scripts |
| `scripts/qa/run_qa_suite.sh` | Updated to pick `test_wp01_*.sh` + `test_wp02_*.sh` |
| `scripts/qa/qa_common.sh` | Header note for WP-02 Engine dir cleanup contract |
| `scripts/qa/COVERAGE.md` | Inventory + gate gap hunt |
| `scripts/qa/REPORT.md` | This report |

Product code was **not** modified. No git commit / push.

---

## Notes for orchestrator

1. Suite requires a signed Debug `Torrentino.app` in DerivedData (`Developer ID Application`, team `438UQRF7JV`) for WP-02 dynamic scripts.
2. Agent hard-codes Application Support; WP-02 scripts wipe `…/com.torrentino.app/Engine` on EXIT (product constraint, not a test leak).
3. Coverage is monotonic: 11 WP-01 + 13 WP-02 = 24 scripts, all green.
