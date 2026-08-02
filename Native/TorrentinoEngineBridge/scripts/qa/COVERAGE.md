# Torrentino QA Coverage — WP-05 (XPC protocol v1)

Updated: 2026-08-03 (Test Engineer, WP-05 QA cycle)
Suite entry: `Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
**Last full suite:** 2026-08-03 — **57/57 PASS (GREEN)** — see `REPORT.md`
**Contract tests:** `TorrentinoIPCTests` (74) + `TorrentinoAppTests` (9) + `TorrentinoDomainTests` (19) — **102/102 PASS**

## Coverage policy

- Monotonic: old WP-01..WP-04 scripts are never deleted; each WP adds tests.
- Full suite always runs WP-01 + WP-02 + WP-03 + WP-04 + WP-05.
- Exit 0 = pass; isolated cleanup on EXIT.
- ADR-010: every public API ≥3 unit axes; every actor ≥1 stress; every parser ≥1 negative/fuzz.
- WP-05 surface is a Swift contract framework (`Native/TorrentinoIPC/`) verified at XCTest level
  (`TorrentinoIPCTests`, 74 cases) plus 12 dedicated shell QA scripts (`test_wp05_*.sh`).

---

## Stage A — New features this cycle (WP-05)

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

## Shared infrastructure

| File | Role |
| --- | --- |
| `qa_common.sh` | paths, mktemp, asserts |
| `qa_wp02_common.sh` | app resolve, launchd/cli helpers |
| `run_qa_suite.sh` | runs `test_wp0{1,2,3,4,5}_*.sh` |

## Open gaps (after this run)

| Gap | Severity | Notes |
| --- | --- | --- |
| End-to-end transport peer rejection (Release artifact) | P2 | Executable wrong-team/unsigned rejection proven at unit level; `setCodeSigningRequirement` on the live XPC connection still needs the Developer-ID Release artifact (WP-16 signing chain) |
| GUI pixel/UI automation of empty window | N/A | Covered via source contract + AppTests; no AppKit snapshot harness yet |
| Full 24h soak burn-in | N/A | Wall-clock item (WP-01 gate); smoke soaks green every suite run |
