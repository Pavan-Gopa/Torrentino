# QA Verification Report — WP-06 Durable Persistence/Recovery (final run)

**Date:** 2026-08-03
**Role:** Test Engineer (QA)
**Status:** **GREEN (ALL 71 QA SCRIPTS PASS + 118/118 TESTS PASS)**

---

## Executive Summary

WP-06 (durable persistence/recovery — SQLite WAL, atomic generations, checksums,
operation journal, quarantine, controlled rebuild, failpoints, advisory lock) is
verified green on two levels:

1. **Regression suite:** all **71 QA scripts** across WP-01..WP-06 pass
   (`SUITE RESULT: GREEN`) — 57 previous scripts untouched (monotonic coverage)
   plus **14 NEW `test_wp06_*.sh` scripts**, one per WP-06 feature area.
2. **XCTest:** full scheme run — **118/118 PASS, 0 FAIL** across 4 bundles:
   `TorrentinoIPCTests` (74) + `TorrentinoAppTests` (9) + `TorrentinoDomainTests` (19)
   + `TorrentinoEngineAgentPersistenceTests` (**16 NEW** WP-06 cases).

Every gate item from the WP-06 plan is covered (see Gate table below). No product
bugs found this cycle; one coverage nuance noted (Observation 2).

---

## QA Suite Execution Results (final full-suite run, 2026-08-03)

### WP-01 (Engine Headless Harness) — Regression
| Script | Status | Duration |
| :--- | :---: | :---: |
| `test_wp01_build_idempotent.sh` | PASS | 1s |
| `test_wp01_crash_restore.sh` | PASS | 1s |
| `test_wp01_exception_firewall.sh` | PASS | 0s |
| `test_wp01_fallback_2013.sh` | PASS | 2s |
| `test_wp01_flush_barrier_smoke.sh` | PASS | 27s |
| `test_wp01_harness_all_scenarios.sh` | PASS | 2s |
| `test_wp01_no_homebrew_negative.sh` | PASS | 0s |
| `test_wp01_no_homebrew_positive.sh` | PASS | 0s |
| `test_wp01_sanitizers_clean.sh` | PASS | 3s |
| `test_wp01_soak_smoke.sh` | PASS | 26s |
| `test_wp01_versions_lock_valid.sh` | PASS | 0s |

### WP-02 (Launchd Agent & Lifecycle) — Regression
| Script | Status | Duration |
| :--- | :---: | :---: |
| `test_wp02_counter_corruption.sh` | PASS | 4s |
| `test_wp02_counter_downgrade_block.sh` | PASS | 13s |
| `test_wp02_counter_durability.sh` | PASS | 13s |
| `test_wp02_denial_degraded.sh` | PASS | 10s |
| `test_wp02_graceful_shutdown.sh` | PASS | 22s |
| `test_wp02_launchd_only_guard.sh` | PASS | 2s |
| `test_wp02_lifecycle_contract_complete.sh` | PASS | 0s |
| `test_wp02_lifecycle_script.sh` | PASS | 25s |
| `test_wp02_no_duplicate_instance.sh` | PASS | 12s |
| `test_wp02_reconnect_after_kill.sh` | PASS | 17s |
| `test_wp02_smappservice_register.sh` | PASS | 2s |
| `test_wp02_update_script.sh` | PASS | 8s |
| `test_wp02_xpc_roundtrip.sh` | PASS | 20s |

### WP-03 (Native Skeleton & Strict Concurrency) — Regression
| Script | Status | Duration |
| :--- | :---: | :---: |
| `test_wp03_domain_types.sh` | PASS | 2s |
| `test_wp03_empty_state.sh` | PASS | 3s |
| `test_wp03_ipc_envelope.sh` | PASS | 2s |
| `test_wp03_legacy_untouched.sh` | PASS | 0s |
| `test_wp03_strict_concurrency.sh` | PASS | 1s |
| `test_wp03_string_catalog.sh` | PASS | 0s |
| `test_wp03_testprofile_isolation.sh` | PASS | 2s |
| `test_wp03_xctest_pass.sh` | PASS | 3s |

### WP-04 (Bridge & Engine Kernel) — Regression
| Script | Status | Duration |
| :--- | :---: | :---: |
| `test_wp04_adapter_compile.sh` | PASS | 3s |
| `test_wp04_alert_batching.sh` | PASS | 3s |
| `test_wp04_bridge_headless.sh` | PASS | 3s |
| `test_wp04_bridge_sanitizers.sh` | PASS | 13s |
| `test_wp04_bridge_swift.sh` | PASS | 3s |
| `test_wp04_deadline_cancellation.sh` | PASS | 3s |
| `test_wp04_dto_codable.sh` | PASS | 2s |
| `test_wp04_exception_firewall.sh` | PASS | 3s |
| `test_wp04_peer_id_config.sh` | PASS | 3s |
| `test_wp04_pimpl_isolation.sh` | PASS | 0s |
| `test_wp04_shutdown_idempotent.sh` | PASS | 3s |
| `test_wp04_torrent_id_payload.sh` | PASS | 3s |
| `test_wp04_xcode_integration.sh` | PASS | 0s |

### WP-05 (XPC Protocol v1) — Regression
| Script | Status | Duration |
| :--- | :---: | :---: |
| `test_wp05_identity_types.sh` | PASS | 1s |
| `test_wp05_commands_roundtrip.sh` | PASS | 2s |
| `test_wp05_events_roundtrip.sh` | PASS | 2s |
| `test_wp05_error_contract.sh` | PASS | 2s |
| `test_wp05_envelope_limits.sh` | PASS | 2s |
| `test_wp05_pagination.sh` | PASS | 2s |
| `test_wp05_settings_transaction.sh` | PASS | 2s |
| `test_wp05_handshake.sh` | PASS | 2s |
| `test_wp05_idempotency.sh` | PASS | 2s |
| `test_wp05_reconciliation.sh` | PASS | 2s |
| `test_wp05_peer_validation.sh` | PASS | 2s |
| `test_wp05_contract_tests.sh` | PASS | 8s |

### WP-06 (Durable Persistence/Recovery) — NEW this cycle
| Script | Status | Duration | Verifies |
| :--- | :---: | :---: | :--- |
| `test_wp06_sqlite_wal.sh` | PASS | 2s | WAL mode, synchronous=NORMAL, foreign_keys=ON, WAL file with un-checkpointed frames after writes, TRUNCATE checkpoint collapses WAL to 0 |
| `test_wp06_schema_migration.sh` | PASS | 2s | Fresh DB → v1 schema (schema_version table), 6 tables usable (75-record fixture), reopen idempotent (migrations never re-run) |
| `test_wp06_atomic_generation.sh` | PASS | 2s | Generations strictly monotonic, read returns latest, superseded deleted, clock never reused after crash |
| `test_wp06_checksum_integrity.sh` | PASS | 1s | Corrupt byte → checksum mismatch detected + quarantined; legit 8 KiB payload byte-identical |
| `test_wp06_operation_journal.sh` | PASS | 2s | 1100 appends → capped at 1000; clean shutdown → 0 entries; pending → replay → never replayed twice |
| `test_wp06_clean_shutdown.sh` | PASS | 3s | clean_shutdown=true after clean close; false after kill -9; desired states persisted |
| `test_wp06_startup_reconciliation.sh` | PASS | 2s | Unclean boot triggers reconciliation; 80/80 records survive; WAL-only record restored; replay single-shot |
| `test_wp06_quarantine.sh` | PASS | 1s | Corrupt resume → quarantine table (payload preserved), torrent needs-recheck, store keeps serving |
| `test_wp06_rebuild.sh` | PASS | 2s | Garbage main DB → rebuilt=true + degraded=true, forensic trio moved aside, store usable post-rebuild |
| `test_wp06_wal_only_recovery.sh` | PASS | 2s | WAL-only record (proven absent from main via copy) restored byte-exact after crash |
| `test_wp06_forensic_group.sh` | PASS | 2s | Unclean → main+WAL(+SHM) preserved with frames; clean → WAL collapsed; rebuild moves trio together |
| `test_wp06_failpoints.sh` | PASS | 2s | All 8 failpoints: write-path (1-6) + shutdown-path (7-8) → clean_shutdown=false, records intact, store serves |
| `test_wp06_advisory_lock.sh` | PASS | 2s | flock single writer: 2nd open → alreadyLocked; release → reacquire |
| `test_wp06_crash_cycles.sh` | PASS | 2s | 3 clean cycles × 30 → 90/90; 4 kill -9 × 20 → 80/80 no dupes; 8 KiB payload unchanged |

```
total: 71  pass: 71  fail: 0  (wp01: 11  wp02: 13  wp03: 8  wp04: 13  wp05: 12  wp06: 14)
SUITE RESULT: GREEN
```

---

## WP-06 Unit Tests (TorrentinoEngineAgentPersistenceTests — 16 NEW)

All run inside the full scheme test; each also mapped 1:1 into the 14 QA scripts.

| Area | Test | Coverage |
| :--- | :--- | :--- |
| WAL / schema | `testOpenCreatesSchemaWithWAL` | journal_mode=wal, synchronous=1, schema_version=1, foreign_keys=ON, reopen idempotent |
| Clean cycles | `testThreeCleanRestoreCycles` | 3 × 30 records → 90/90, resume+metainfo present, last flag clean |
| Kill -9 cycles | `testRepeatedKillNineRestore` | 4 × 20 → 80/80, no dupes (resume 80, metainfo 80), flag false |
| Generations | `testNoDuplicateOrLostRecordsWithGenerations` | monotonic g2>g1, latest served, superseded deleted, g3>g2 across crash |
| Desired states | `testDesiredStatesPersisted` | state/infoHash/name/addedAt survive clean round-trip |
| Quarantine | `testCorruptResumeQuarantinedAndTorrentRechecked` | checksum corrupt → quarantined + needs-recheck + others unaffected |
| Rebuild | `testCorruptDatabaseControlledRecovery` | garbage main → rebuilt+degraded, corrupt-* dir preserved, store usable |
| WAL-only | `testRecordOnlyInWALRestoredAfterCrash` | main copy has no schema ⇒ record only in WAL ⇒ restored byte-exact |
| Forensic group | `testForensicGroupPreserved` | unclean: main+WAL preserved, WAL>0; clean: WAL→0 |
| Failpoints | `testCleanShutdownFlagStaysFalseAtEveryInterruptedPhase` | failpoints 1-6 (write) + 7-8 (shutdown) → flag false, records intact |
| Failpoint lifecycle | `testFailpointLifecycle` | unarmed no-op / armed throws / disarm restores (all 8 IDs) |
| Payload integrity | `testPayloadUnchangedAcrossCycles` | 8 KiB payload × 20 writes + crash → byte-identical |
| Journal | `testJournalCapAndCleanTruncation` | 1100 → 1000 cap; clean → 0 |
| Journal replay | `testJournalReplayMarksTorrentsForRecheck` | pending → replay ≥1, needs-recheck, never replayed twice |
| Advisory lock | `testAdvisoryLockSingleWriter` | 2nd acquire → `.alreadyLocked`, release → reacquire |
| Fixture | `testFixtureSeventyFiveRecords` | 75 torrents / 75 resume / 75 metainfo / 0 quarantine |

---

## WP-06 Gate Coverage (from plan)

| Gate (from plan) | Test(s) | Status |
| :--- | :--- | :---: |
| Три clean restore cycles | `testThreeCleanRestoreCycles` (3 × 30 → 90/90) | **PASS** |
| Repeated kill -9 restore | `testRepeatedKillNineRestore` (4 × 20 → 80/80) | **PASS** |
| No duplicate/lost records | `testRepeatedKillNineRestore` (counts 80/80), `testNoDuplicateOrLostRecordsWithGenerations` | **PASS** |
| Desired states сохранены | `testDesiredStatesPersisted` | **PASS** |
| Corrupt resume → quarantine/recheck, не crash | `testCorruptResumeQuarantinedAndTorrentRechecked` (quarantine + needs-recheck + store serving 5/5) | **PASS** |
| Corrupt DB copy → controlled recovery/degraded | `testCorruptDatabaseControlledRecovery` (rebuilt=true, degraded=true, usable) | **PASS** |
| Запись только в WAL восстанавливается | `testRecordOnlyInWALRestoredAfterCrash` (proven via main-file copy, byte-exact) | **PASS** |
| SQLite main/WAL/SHM — единая forensic group | `testForensicGroupPreserved` (unclean trio + WAL>0), `testCorruptDatabaseControlledRecovery` (moved aside together) | **PASS** |
| clean_shutdown=false при любой незавершённой фазе | `testCleanShutdownFlagStaysFalseAtEveryInterruptedPhase` (all 8 failpoints) | **PASS** |
| Payload не изменён | `testPayloadUnchangedAcrossCycles` (8 KiB byte-identical) | **PASS** |

---

## QA Tooling Changes This Cycle

| File | Change |
| :--- | :--- |
| `run_qa_suite.sh` | Runner now also collects `test_wp06_*.sh` and reports a wp06 bucket in the summary (was wp01..wp05 only). Without this the 14 new scripts would NOT be part of the monotonic regression. |
| `scripts/qa/test_wp06_*.sh` (14 files) | New per-feature scripts: `sqlite_wal`, `schema_migration`, `atomic_generation`, `checksum_integrity`, `operation_journal`, `clean_shutdown`, `startup_reconciliation`, `quarantine`, `rebuild`, `wal_only_recovery`, `forensic_group`, `failpoints`, `advisory_lock`, `crash_cycles` — each runs its targeted `TorrentinoEngineAgentPersistenceTests` selection, all GREEN. |
| `scripts/qa/COVERAGE.md` | WP-06 feature/gate matrix added; regression tables extended with WP-06. |

No product code was modified this cycle (test-only QA deliverables).

---

## Build / Configuration Evidence

| Check | Command | Result |
| :--- | :--- | :---: |
| Full scheme tests (4 bundles) | `xcodebuild test -scheme Torrentino ...` | **118/118 PASS, 0 FAIL** (IPC 74, App 9, Domain 19, EngineAgentPersistence 16) |
| QA regression | `bash scripts/qa/run_qa_suite.sh` | **71/71 PASS — SUITE RESULT: GREEN** |

---

## Observations (non-blocking)

1. **kill -9 at process level:** the WP-06 store is exercised with in-process
   kill -9 semantics (`close(clean:false)` leaves the WAL untouched, exactly what
   SIGKILL leaves behind; the connection is closed only by the kernel in a real
   crash, which `rawClose()` models). A real OS-level SIGKILL of the Swift agent
   against the WP-06 store is not yet possible end-to-end: `AgentService` exposes
   only counter + health via XPC — `PersistenceStore` is opened at `AgentRuntime`
   bootstrap but has no XPC persistence surface yet (health snapshot only). The
   C++ harness `crash_restore` scenario (WP-01) remains the process-level kill -9
   proof. LOW — wire the persistence XPC surface in a later WP.
2. **Forensic trio inside `corrupt-*` dir:** `testCorruptDatabaseControlledRecovery`
   asserts the preserved main file; `moveForensicGroupAside` moves all three names
   (main/WAL/SHM) and `testForensicGroupPreserved` asserts the WAL lifecycle — the
   trio-together-on-rebuild assertion is split across two tests rather than one.
   LOW — could be tightened by asserting WAL+SHM presence inside the corrupt dir.
3. **Lock file cleanup:** `AdvisoryLockHandle.release()` removes `persistence.lock`
   after unlocking; the lock file is created by `acquire()` when absent. Two racing
   acquirers where one releases could unlink a file a third opener is about to
   flock — benign today (single-writer process model + instance lock), noted as LOW.

---

## Overall Summary

- **Total QA scripts:** 71 (57 regression + **14 new**) — **Passed: 71 — Failed: 0 — SUITE RESULT: GREEN**
- **XCTest:** 118/118 PASS (IPC 74, App 9, Domain 19, EngineAgentPersistence 16)
- **New unit tests this cycle:** 0 added by QA (16 WP-06 tests existed in the commit; QA mapped them 1:1)
- **Bugs found this cycle:** 0 product bugs. 3 LOW observations (see above).
- **Coverage matrix:** `Native/TorrentinoEngineBridge/scripts/qa/COVERAGE.md`
