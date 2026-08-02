# Torrentino QA Coverage — WP-06 (Durable persistence/recovery)

Updated: 2026-08-03 (Test Engineer, WP-06 QA cycle)
Suite entry: `Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
**Last full suite:** 2026-08-03 — **71/71 PASS (GREEN)** — see `REPORT.md`
**Full XCTest run:** `TorrentinoIPCTests` (74) + `TorrentinoAppTests` (9) + `TorrentinoDomainTests` (19) + `TorrentinoEngineAgentPersistenceTests` (16) — **118/118 PASS**

## Coverage policy

- Monotonic: old WP-01..WP-05 scripts are never deleted; each WP adds tests.
- Full suite always runs WP-01 + WP-02 + WP-03 + WP-04 + WP-05 + WP-06.
- Exit 0 = pass; isolated cleanup on EXIT.
- ADR-010: every public API ≥3 unit axes; every actor ≥1 stress; every parser ≥1 negative/fuzz.
- WP-06 surface is the SQLite persistence layer (`Native/TorrentinoEngineAgent/Persistence/`)
  verified at XCTest level (`TorrentinoEngineAgentPersistenceTests`, 16 cases) plus 14 dedicated
  shell QA scripts (`test_wp06_*.sh`).

---

## Stage A — New features this cycle (WP-06)

| # | Feature | Dedicated script / tests | Happy | Error/invalid | Edge | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | SQLite WAL mode (`journal_mode=WAL`, `synchronous=NORMAL`, `foreign_keys=ON`) | `test_wp06_sqlite_wal.sh` + `testOpenCreatesSchemaWithWAL`, `testForensicGroupPreserved` | mode=wal, sync=1, FK=ON, WAL frames on disk after writes | — | clean TRUNCATE checkpoint collapses WAL to 0; reopen idempotent | covered / PASS |
| 2 | Schema migration v1 (schema_version table, 6 tables) | `test_wp06_schema_migration.sh` + `testOpenCreatesSchemaWithWAL`, `testFixtureSeventyFiveRecords` | fresh DB → version=1, 75-record round-trip | — | reopen does not re-run migrations | covered / PASS |
| 3 | Atomic generations (temp→fsync→rename→dir fsync) | `test_wp06_atomic_generation.sh` + `testNoDuplicateOrLostRecordsWithGenerations` | generations strictly monotonic | — | superseded deleted; clock never reused across crash | covered / PASS |
| 4 | SHA-256 checksums on payloads | `test_wp06_checksum_integrity.sh` + `testCorruptResumeQuarantinedAndTorrentRechecked`, `testPayloadUnchangedAcrossCycles` | verified on every read | corrupt byte → mismatch detected + quarantined | 8 KiB payload byte-identical after 20 writes + crash | covered / PASS |
| 5 | Operation journal (cap 1000, truncate on clean) | `test_wp06_operation_journal.sh` + `testJournalCapAndCleanTruncation`, `testJournalReplayMarksTorrentsForRecheck` | 1100 → trimmed to 1000 | — | clean shutdown → 0 entries; replay never twice | covered / PASS |
| 6 | Clean/unclean shutdown (`clean_shutdown` flag) | `test_wp06_clean_shutdown.sh` + `testThreeCleanRestoreCycles`, `testRepeatedKillNineRestore`, `testDesiredStatesPersisted` | clean close → flag true | kill -9 → flag false | desired states survive | covered / PASS |
| 7 | Startup reconciliation (verify→orphan sweep→journal replay) | `test_wp06_startup_reconciliation.sh` + `testRepeatedKillNineRestore`, `testRecordOnlyInWALRestoredAfterCrash`, `testJournalReplayMarksTorrentsForRecheck` | unclean boot → reconcile, all records survive | — | replay single-shot; orphan sidecars swept | covered / PASS |
| 8 | Quarantine (corrupt resume → quarantine, needs-recheck) | `test_wp06_quarantine.sh` + `testCorruptResumeQuarantinedAndTorrentRechecked` | corrupt payload quarantined with payload preserved | corrupt record never served | store keeps serving 5/5, others unaffected | covered / PASS |
| 9 | Rebuild (corrupt DB → salvage + rebuild, degraded) | `test_wp06_rebuild.sh` + `testCorruptDatabaseControlledRecovery` | garbage main → rebuilt=true, degraded=true | — | store usable post-rebuild; clean_shutdown=false | covered / PASS |
| 10 | WAL-only record recovery | `test_wp06_wal_only_recovery.sh` + `testRecordOnlyInWALRestoredAfterCrash` | record only in WAL restored byte-exact | — | proven absent from main via copy | covered / PASS |
| 11 | Forensic group (main+WAL+SHM together) | `test_wp06_forensic_group.sh` + `testForensicGroupPreserved`, `testCorruptDatabaseControlledRecovery` | unclean → trio preserved, WAL>0 | — | clean → WAL collapsed; rebuild moves trio aside together | covered / PASS |
| 12 | Failpoints (8 injection points) | `test_wp06_failpoints.sh` + `testCleanShutdownFlagStaysFalseAtEveryInterruptedPhase`, `testFailpointLifecycle` | unarmed no-op / armed throws | all 8 phases → clean_shutdown=false | records intact + store serving after each phase | covered / PASS |
| 13 | Advisory lock (flock single writer) | `test_wp06_advisory_lock.sh` + `testAdvisoryLockSingleWriter` | first writer acquires | second open → `.alreadyLocked` | release → reacquire (idempotent) | covered / PASS |
| 14 | 3 clean restore cycles | `test_wp06_crash_cycles.sh` + `testThreeCleanRestoreCycles` | 3 × 30 → 90/90 with resume+metainfo | — | last shutdown flagged clean | covered / PASS |
| 15 | Repeated kill -9 (4 cycles × 20) | `test_wp06_crash_cycles.sh` + `testRepeatedKillNineRestore` | 80/80 survive | — | no duplicates (resume 80, metainfo 80) | covered / PASS |
| 16 | Payload unchanged (8 KiB) | `test_wp06_crash_cycles.sh` + `testPayloadUnchangedAcrossCycles` | byte-identical after crash-restart | — | 20 rewrites before crash | covered / PASS |
| — | Full XCTest green | `test_wp06_*.sh` (14) + full scheme `xcodebuild test` | 118/118 | fails if any case red | — | covered / PASS |

## Gate coverage (from plan — WP-06)

| Gate | Test / evidence | Status |
| --- | --- | --- |
| три clean restore cycles | `testThreeCleanRestoreCycles` (90/90) | covered / PASS |
| repeated kill -9 restore | `testRepeatedKillNineRestore` (80/80) | covered / PASS |
| no duplicate/lost records | `testRepeatedKillNineRestore` + `testNoDuplicateOrLostRecordsWithGenerations` | covered / PASS |
| desired states сохранены | `testDesiredStatesPersisted` | covered / PASS |
| corrupt resume → quarantine/recheck, не crash | `testCorruptResumeQuarantinedAndTorrentRechecked` | covered / PASS |
| corrupt DB copy → controlled recovery/degraded mode | `testCorruptDatabaseControlledRecovery` (rebuilt + degraded + usable) | covered / PASS |
| запись, существующая только в WAL, восстанавливается | `testRecordOnlyInWALRestoredAfterCrash` | covered / PASS |
| SQLite main/WAL/SHM — единая forensic group | `testForensicGroupPreserved` + `testCorruptDatabaseControlledRecovery` | covered / PASS |
| clean_shutdown остаётся false при любой незавершённой фазе | `testCleanShutdownFlagStaysFalseAtEveryInterruptedPhase` (failpoints 1-8) | covered / PASS |
| payload не изменён | `testPayloadUnchangedAcrossCycles` (8 KiB byte-identical) | covered / PASS |

## Previous cycle (WP-05) — kept for reference

| # | Feature | Dedicated script / tests | Happy | Error/invalid | Edge | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `IPCVersion` (wire 1.0) | IPC XCTest | current=1.0, ordering, parsing | major mismatch fault | same-major minor OK | covered |
| 2 | `IPCEnvelope` v1 discriminated union (request/event/result) | IPC XCTest | round-trip all kinds | tampered/garbage/unknown-kind fail | truncated fuzz, concurrent stress, >4 MiB rejected | covered |
| 3 | `EngineCommandV1` (32 commands + payloads) | IPC XCTest | allCases round-trip | unknown decode fail | every payload has requestID; mutating ⇒ idempotency key | covered |
| 4 | `EngineEventV1` (11 events + payloads) | IPC XCTest | allCases round-trip | unknown decode fail | revision/instance gating | covered |
| 5 | Identity model (RecordID/OperationID/RequestID/IdempotencyKey) | IPC XCTest | round-trip + description | — | ContentIdentity v1/v2/hybrid, unknown both nil | covered |
| 6 | State model (DesiredTorrentState/Activity/Health/Rates/PeerSummary) | IPC XCTest | all cases round-trip | — | frozen case sets | covered |
| 7 | Snapshots + revisions (full/incremental) | IPC XCTest | Torrent/Engine snapshot round-trip | dropped delta → full snapshot | first snapshot full; instance change → full; revision monotonic | covered |
| 8 | Handshake (hello/version range/negotiation) | IPC XCTest | negotiate same/overlap | mismatch across majors | validateResponse lie → fault | covered |
| 9 | Idempotency tracker (duplicate replay) | IPC XCTest | duplicate replays same result | different keys no replay | canonical key deterministic | covered |
| 10 | `ClientReconnectPolicy` (bounded backoff) | IPC XCTest | first attempt immediate | budget exhausted | backoff monotonic | covered |
| 11 | Error contract (24 codes, fault, localization keys) | IPC XCTest | fault round-trip + factories | — | localizationKey stable `fault.<rawValue>` | covered |
| 12 | Pagination (PageCursor/FileCursor/Page/entries) | IPC XCTest | cursor + page round-trip | — | page size bounded (max 200); 4 entry types | covered |
| 13 | Transactional Settings (validate→persist→apply→rollback) | IPC XCTest | applied | revision conflict, validation failed | apply-failure rollback; persist failure no rollback | covered |
| 14 | Peer code-signing policy (`PeerValidation`) | `test_wp05_peer_validation.sh` + AppTests | requirement expression compiles; identities frozen | unsigned/wrong-team/nonexistent rejected (`testPeerValidationWrongTeamIdentifierRejected` — ad-hoc signed Mach-O) | Debug skips (no embedded agent); Release enforces (`isEnforcementActive`) | covered |
| 15 | Agent advertises ipcVersion/protocolRange | integration (hello via CLI) | health advertises 1.0 | — | handshake negotiates against advertised | covered |
| — | Full XCTest green | `test_wp05_contract_tests.sh` (3 targets, standalone + combined) | 102/102 | fails if any case red | — | covered / PASS |

## Gate coverage (from plan — WP-05)

| Gate | Test / evidence | Status |
| --- | --- | --- |
| Version mismatch | `testVersionMismatchProducesFault`, `testHandshakeMismatchAcrossMajors`, `testVersionBackwardCompatLogicViaEnvelope` | covered / PASS |
| Duplicate command idempotent | `testIdempotencyDuplicateReplaysSameResult`, `testIdempotencyDifferentKeysDoNotReplay` | covered / PASS |
| Dropped delta | `testDroppedDeltaRequiresFullSnapshot`, `testContiguousDeltaApplicable` | covered / PASS |
| Reconnect | `testReconnectPolicy*` (3) + WP-02 `test_wp02_reconnect_after_kill.sh` | covered / PASS |
| Instance change → full snapshot | `testInstanceChangeRequiresFullSnapshot`, `testFirstSnapshotAlwaysFull` | covered / PASS |
| Oversized/invalid payload rejected | `testEnvelopeOversizedPayloadRejected`, `testEnvelopeGarbageJSONDecodeFails`, `testEnvelopeTamperedPayloadDecodeFails`, `testEnvelopeFuzzTruncatedJSON`, `testEnvelopeUnknownKindDecodeFails`, `testEnvelopeRequestIDMismatch` | covered / PASS |
| Stale event | `testSnapshotRevisionMonotonic`, `testEnvelopeEventKindValidation` | covered / PASS |
| Unsigned peer rejected | `testPeerValidationUnsignedDummyFileRejected`, `testPeerValidationNonexistentPathRejected` | covered / PASS |
| Wrong team rejected | `testPeerValidationWrongTeamIdentifierRejected` (ad-hoc signed Mach-O → `.wrongTeamIdentifier`) | covered / PASS |
| Settings rollback / version conflict | `testSettingsTransactionRollbackOnApplyFailure`, `testSettingsTransactionRevisionConflict`, `testSettingsTransactionPersistFailureNoRollback`, `testSettingsRevisionConflictFault` | covered / PASS |
| Hierarchical file paging | `testFileCursorHierarchyRoundTrip`, `testPaginatedItemsRoundTrip`, `testPageSizeBounded`, `testPageCursorRoundTrip` | covered / PASS |
| All contract tests green | 74/74 `TorrentinoIPCTests` + 9/9 `TorrentinoAppTests` + 19/19 `TorrentinoDomainTests` | covered / PASS |

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

## Regression (WP-03) — still run every suite

| Script | Feature |
| --- | --- |
| `test_wp03_domain_types.sh` | Domain types + BUG-001 resolved (LocalizedError now conforms) |
| `test_wp03_empty_state.sh` | Empty state + catalog |
| `test_wp03_ipc_envelope.sh` | Legacy IPCEnvelope surface (kept untouched) |
| `test_wp03_legacy_untouched.sh` | Legacy/ git clean |
| `test_wp03_strict_concurrency.sh` | Swift 6 Complete + Werror, 0 warnings |
| `test_wp03_string_catalog.sh` | String Catalog EN/RU |
| `test_wp03_testprofile_isolation.sh` | TestProfile isolation |
| `test_wp03_xctest_pass.sh` | Full XCTest green (incl. TorrentinoIPCTests) |

## Regression (WP-04) — still run every suite

| Script | Feature |
| --- | --- |
| `test_wp04_adapter_compile.sh` | ObjC++ adapter + JSON envelope |
| `test_wp04_alert_batching.sh` | Alert batching bounds |
| `test_wp04_bridge_headless.sh` | Headless lifecycle |
| `test_wp04_bridge_sanitizers.sh` | ASan/UBSan + TSan clean |
| `test_wp04_bridge_swift.sh` | EngineCoordinator actor integration |
| `test_wp04_deadline_cancellation.sh` | Deadline + cancellation |
| `test_wp04_dto_codable.sh` | Swift DTO round-trip |
| `test_wp04_exception_firewall.sh` | C++ exception firewall |
| `test_wp04_peer_id_config.sh` | peer-id prefix |
| `test_wp04_pimpl_isolation.sh` | PIMPL boundary |
| `test_wp04_shutdown_idempotent.sh` | Deterministic shutdown |
| `test_wp04_torrent_id_payload.sh` | TorrentIDPayload |
| `test_wp04_xcode_integration.sh` | pbxproj refs |

## Regression (WP-05) — NEW, run every suite from this cycle

| Script | Feature |
| --- | --- |
| `test_wp05_identity_types.sh` | Identity model round-trips |
| `test_wp05_commands_roundtrip.sh` | 32 EngineCommandV1 Codable + requestID/idempotencyKey invariants |
| `test_wp05_events_roundtrip.sh` | 11 EngineEventV1 Codable |
| `test_wp05_error_contract.sh` | EngineFault structure / localization keys |
| `test_wp05_envelope_limits.sh` | 4 MiB bound, garbage/tampered/unknown-kind, fuzz, version mismatch |
| `test_wp05_pagination.sh` | Cursor round-trips, page size ≤ 200 |
| `test_wp05_settings_transaction.sh` | Transaction / rollback / revision conflict |
| `test_wp05_handshake.sh` | Version negotiation / floor / mismatch |
| `test_wp05_idempotency.sh` | Duplicate replay same result |
| `test_wp05_reconciliation.sh` | Dropped delta / instance change → full snapshot |
| `test_wp05_peer_validation.sh` | Unsigned/wrong-team/nonexistent rejected, enforcement gate |
| `test_wp05_contract_tests.sh` | All 3 test targets standalone + combined |

## Regression (WP-06) — NEW, run every suite from this cycle

| Script | Feature |
| --- | --- |
| `test_wp06_sqlite_wal.sh` | WAL mode, synchronous=NORMAL, foreign_keys=ON, checkpoint collapse |
| `test_wp06_schema_migration.sh` | Fresh DB v1 schema, reopen idempotent |
| `test_wp06_atomic_generation.sh` | Monotonic generations, superseded deleted, byte-identical |
| `test_wp06_checksum_integrity.sh` | Corrupt byte → mismatch detected, payload unchanged |
| `test_wp06_operation_journal.sh` | Cap 1000, clean truncation, single replay |
| `test_wp06_clean_shutdown.sh` | clean_shutdown flag true/false, desired states |
| `test_wp06_startup_reconciliation.sh` | Unclean boot reconcile, WAL-only restore |
| `test_wp06_quarantine.sh` | Corrupt → quarantine + needs-recheck, store serving |
| `test_wp06_rebuild.sh` | Garbage DB → rebuilt + degraded, usable |
| `test_wp06_wal_only_recovery.sh` | WAL-only record survives crash |
| `test_wp06_forensic_group.sh` | Main+WAL+SHM preserved, moved together |
| `test_wp06_failpoints.sh` | 8 phases → flag false, records intact |
| `test_wp06_advisory_lock.sh` | Second writer rejected (alreadyLocked) |
| `test_wp06_crash_cycles.sh` | 3 clean + 4 kill -9 cycles, no loss, payload intact |

## Shared infrastructure

| File | Role |
| --- | --- |
| `qa_common.sh` | paths, mktemp, asserts |
| `qa_wp02_common.sh` | app resolve, launchd/cli helpers |
| `run_qa_suite.sh` | runs `test_wp0{1,2,3,4,5,6}_*.sh` |

## Open gaps (after this run)

| Gap | Severity | Notes |
| --- | --- | --- |
| End-to-end XPC persistence surface | P2 | `AgentService` exposes counter + health only; `PersistenceStore` is opened at agent bootstrap but not yet reachable via XPC commands — WP-06 store verified in-process (isolated TestProfile), real SIGKILL of the agent exercises the store only indirectly (health snapshot). Wire the persistence XPC surface in a later WP. |
| Trio presence inside `corrupt-*` dir | P3 | Rebuild test asserts preserved main file; WAL/SHM trio-on-rebuild asserted across two tests rather than one (see REPORT.md Observation 2). |
| Lock file unlink race | P3 | `AdvisoryLockHandle.release()` removes `persistence.lock`; a releasing holder could unlink a file a third opener is about to flock. Benign under single-writer + instance-lock model (see REPORT.md Observation 3). |
| GUI pixel/UI automation of empty window | N/A | Covered via source contract + AppTests; no AppKit snapshot harness yet |
| Full 24h soak burn-in | N/A | Wall-clock item (WP-01 gate); smoke soaks green every suite run |
