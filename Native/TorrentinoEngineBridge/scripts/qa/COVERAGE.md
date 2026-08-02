# Torrentino QA Coverage — WP-02 (SMAppService lifecycle spike)

Updated: 2026-08-02 (Test Engineer, WP-02 cycle)
Suite entry: `Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
**Last full suite:** 2026-08-02 — **24/24 PASS (GREEN)** — see `REPORT.md`

## Coverage policy

- Monotonic: old WP-01 scripts are never deleted; WP-02 adds `test_wp02_*.sh`.
- Full suite always runs WP-01 + WP-02.
- Exit 0 = pass; isolated cleanup on EXIT (no residual jobs/processes/temp data).
- Product Application Support path is hard-coded by the agent; WP-02 scripts wipe
  `~/Library/Application Support/com.torrentino.app/Engine` on EXIT.

---

## Stage A — New features this cycle (WP-02)

| # | Feature | Dedicated script | Happy | Error/invalid | Edge |
| --- | --- | --- | --- | --- | --- |
| 1 | SMAppService register/unregister | `test_wp02_smappservice_register.sh` | register→enabled+job | double-unregister | re-register restores |
| 2 | Mach XPC hello/health/counter (5 methods) | `test_wp02_xpc_roundtrip.sh` | 5 methods typed | no agent → exit 2; unknown cmd | on-demand relaunch |
| 3a | Durable counter (kill -9) | `test_wp02_counter_durability.sh` | counter survives SIGKILL | — | post-respawn continue |
| 3b | Counter corruption | `test_wp02_counter_corruption.sh` | checksum reject exit 1 | truncated / unknown magic | file not overwritten |
| 3c | Counter downgrade block | `test_wp02_counter_downgrade_block.sh` | v1 on v2 → exit 78 | — | v2 still loads value |
| 4 | Reconnect (EngineClient) | `test_wp02_reconnect_after_kill.sh` | reconnect after SIGKILL | permanent unavail exit 2 | new pid |
| 5 | Graceful shutdown | `test_wp02_graceful_shutdown.sh` | XPC ack exit 0; SIGTERM exit 0 | — | no auto-respawn |
| 6 | Launchd-only serving guard | `test_wp02_launchd_only_guard.sh` | SMAppService serves | direct launch exit 1 | empty XPC_SERVICE_NAME |
| 7 | lifecycle_test.sh (30 checks) | `test_wp02_lifecycle_script.sh` | exit 0 PASS=30 | — | residual cleanup |
| 8 | update_test.sh (26 checks) | `test_wp02_update_script.sh` | exit 0 PASS=26 | — | residual cleanup |
| 9 | LIFECYCLE_CONTRACT.md | `test_wp02_lifecycle_contract_complete.sh` | all sections + plist/XPC cross-check | — | plutil lint |
| 10 | No duplicate instance | `test_wp02_no_duplicate_instance.sh` | flock exit 0 | — | lock free after stop |
| 11 | Denial → degraded | `test_wp02_denial_degraded.sh` | status degraded exit 3 | XPC fails | static no in-process |

## Gate coverage (from plan)

| Gate | Test / evidence | Status |
| --- | --- | --- |
| UI/agent lifecycle on signed build | `test_wp02_lifecycle_script.sh` + preflight codesign | covered |
| Agent does not require root | all scripts run as user; contract | covered |
| No second instance | `test_wp02_no_duplicate_instance.sh` | covered |
| Reconnect returns authoritative state | `test_wp02_reconnect_after_kill.sh`, durability | covered |
| Helper correctly unregisters | `test_wp02_smappservice_register.sh` | covered |
| KeepAlive, exit codes, idle policy | graceful_shutdown + lifecycle_test + contract | covered |
| Denial no in-process fallback | `test_wp02_denial_degraded.sh` | covered |
| N-1/N/downgrade semantics | `test_wp02_update_script.sh`, downgrade_block, corruption | covered |

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

## Shared infrastructure

| File | Role |
| --- | --- |
| `qa_common.sh` | paths, mktemp, asserts (WP-01 + WP-02) |
| `qa_wp02_common.sh` | app resolve, launchd/cli helpers, cleanup |
| `run_qa_suite.sh` | runs `test_wp01_*.sh` + `test_wp02_*.sh` |

## Product evidence scripts (invoked by meta-gates)

| Script | Checks |
| --- | --- |
| `Native/Config/lifecycle_test.sh` | 30 |
| `Native/Config/update_test.sh` | 26 |
| `Native/Config/LIFECYCLE_CONTRACT.md` | frozen contract |
