# QA Verification Report — WP-05 XPC Protocol v1 (final run)

**Date:** 2026-08-03
**Role:** Test Engineer (QA)
**Status:** **GREEN (ALL 57 QA SCRIPTS PASS + 102/102 CONTRACT TESTS PASS)**

---

## Executive Summary

WP-05 (XPC protocol v1) is verified green on two levels:

1. **Regression suite:** all **57 QA scripts** across WP-01..WP-05 pass (`SUITE RESULT: GREEN`).
2. **Contract tests:** `TorrentinoIPCTests` (74) + `TorrentinoAppTests` (9) + `TorrentinoDomainTests` (19)
   — **102/102 PASS** across the three targets (versioned envelopes, all 32 `EngineCommandV1` +
   11 `EngineEventV1` round-trips, handshake, idempotency, reconciliation, reconnect policy,
   settings transaction, pagination, envelope validation/fuzz/stress, PeerValidation).

This cycle (vs the previous WP-05 report):

- **12 NEW shell QA scripts** were added under `scripts/qa/test_wp05_*.sh` (one per feature area),
  and `run_qa_suite.sh` was updated to pick up `test_wp05_*.sh` — the runner previously only
  collected `test_wp0{1,2,3,4}_*.sh`, so the 12 new scripts are now part of the monotonic regression.
- **1 NEW unit test** `testPeerValidationWrongTeamIdentifierRejected` was added to
  `TorrentinoAppTests` (ad-hoc signed Mach-O → `.wrongTeamIdentifier`), closing the executable
  wrong-team-rejection gap (previously design/build-level evidence only).
- 1 defect found in QA tooling this cycle (missing test reference in
  `test_wp05_peer_validation.sh`), fixed in-cycle — see Observations §4.

---

## QA Suite Execution Results (final full-suite run, 2026-08-03)

### WP-01 (Engine Headless Harness) — Regression
| Script | Status | Duration |
| :--- | :---: | :---: |
| `test_wp01_build_idempotent.sh` | PASS | 2s |
| `test_wp01_crash_restore.sh` | PASS | 0s |
| `test_wp01_exception_firewall.sh` | PASS | 0s |
| `test_wp01_fallback_2013.sh` | PASS | 3s |
| `test_wp01_flush_barrier_smoke.sh` | PASS | 26s |
| `test_wp01_harness_all_scenarios.sh` | PASS | 3s |
| `test_wp01_no_homebrew_negative.sh` | PASS | 0s |
| `test_wp01_no_homebrew_positive.sh` | PASS | 0s |
| `test_wp01_sanitizers_clean.sh` | PASS | 3s |
| `test_wp01_soak_smoke.sh` | PASS | 26s |
| `test_wp01_versions_lock_valid.sh` | PASS | 0s |

### WP-02 (Launchd Agent & Lifecycle) — Regression
| Script | Status | Duration |
| :--- | :---: | :---: |
| `test_wp02_counter_corruption.sh` | PASS | 4s |
| `test_wp02_counter_downgrade_block.sh` | PASS | 14s |
| `test_wp02_counter_durability.sh` | PASS | 13s |
| `test_wp02_denial_degraded.sh` | PASS | 10s |
| `test_wp02_graceful_shutdown.sh` | PASS | 23s |
| `test_wp02_launchd_only_guard.sh` | PASS | 1s |
| `test_wp02_lifecycle_contract_complete.sh` | PASS | 0s |
| `test_wp02_lifecycle_script.sh` | PASS | 26s |
| `test_wp02_no_duplicate_instance.sh` | PASS | 11s |
| `test_wp02_reconnect_after_kill.sh` | PASS | 18s |
| `test_wp02_smappservice_register.sh` | PASS | 2s |
| `test_wp02_update_script.sh` | PASS | 9s |
| `test_wp02_xpc_roundtrip.sh` | PASS | 20s |

### WP-03 (Native Skeleton & Strict Concurrency) — Regression
| Script | Status | Duration |
| :--- | :---: | :---: |
| `test_wp03_domain_types.sh` | PASS | 3s |
| `test_wp03_empty_state.sh` | PASS | 2s |
| `test_wp03_ipc_envelope.sh` | PASS | 3s |
| `test_wp03_legacy_untouched.sh` | PASS | 0s |
| `test_wp03_strict_concurrency.sh` | PASS | 1s |
| `test_wp03_string_catalog.sh` | PASS | 0s |
| `test_wp03_testprofile_isolation.sh` | PASS | 3s |
| `test_wp03_xctest_pass.sh` | PASS | 2s |

### WP-04 (Bridge & Engine Kernel) — Regression
| Script | Status | Duration |
| :--- | :---: | :---: |
| `test_wp04_adapter_compile.sh` | PASS | 4s |
| `test_wp04_alert_batching.sh` | PASS | 3s |
| `test_wp04_bridge_headless.sh` | PASS | 3s |
| `test_wp04_bridge_sanitizers.sh` | PASS | 13s |
| `test_wp04_bridge_swift.sh` | PASS | 3s |
| `test_wp04_deadline_cancellation.sh` | PASS | 3s |
| `test_wp04_dto_codable.sh` | PASS | 3s |
| `test_wp04_exception_firewall.sh` | PASS | 3s |
| `test_wp04_peer_id_config.sh` | PASS | 3s |
| `test_wp04_pimpl_isolation.sh` | PASS | 0s |
| `test_wp04_shutdown_idempotent.sh` | PASS | 3s |
| `test_wp04_torrent_id_payload.sh` | PASS | 3s |
| `test_wp04_xcode_integration.sh` | PASS | 0s |

### WP-05 (XPC Protocol v1) — NEW this cycle
| Script | Status | Duration | Verifies |
| :--- | :---: | :---: | :--- |
| `test_wp05_identity_types.sh` | PASS | 1s | TorrentRecordID/ContentIdentity/AddOperationID/RequestID/IdempotencyKey round-trip |
| `test_wp05_commands_roundtrip.sh` | PASS | 2s | All 32 EngineCommandV1 Codable, requestID on every payload, idempotencyKey on mutating |
| `test_wp05_events_roundtrip.sh` | PASS | 2s | All 11 EngineEventV1 Codable round-trip |
| `test_wp05_error_contract.sh` | PASS | 2s | EngineFault structure, localizationKey `fault.<code>` (no raw text), factories |
| `test_wp05_envelope_limits.sh` | PASS | 2s | 4 MiB bound, garbage/tampered/unknown-kind decode fail, fuzz, requestID mismatch, version mismatch |
| `test_wp05_pagination.sh` | PASS | 2s | PageCursor/FileCursor round-trip, PageSize bounded ≤ 200, 4 entry types |
| `test_wp05_settings_transaction.sh` | PASS | 2s | validate→persist→apply→rollback, revision conflict, persist failure |
| `test_wp05_handshake.sh` | PASS | 2s | version negotiation, most-conservative floor, mismatch → fault |
| `test_wp05_idempotency.sh` | PASS | 2s | duplicate requestID+key → same result, no replay on different keys |
| `test_wp05_reconciliation.sh` | PASS | 2s | dropped delta → full snapshot, instance change → full snapshot, revision monotonic |
| `test_wp05_peer_validation.sh` | PASS | 2s | unsigned/wrong-team/nonexistent rejected, frozen requirement, enforcement gate |
| `test_wp05_contract_tests.sh` | PASS | 9s | TorrentinoIPCTests + TorrentinoAppTests + TorrentinoDomainTests + combined run all GREEN |

```
total: 57  pass: 57  fail: 0  (wp01: 11  wp02: 13  wp03: 8  wp04: 13  wp05: 12)
SUITE RESULT: GREEN
```

---

## WP-05 Contract Tests (new this cycle)

`TorrentinoIPCTests` — `xcodebuild test ... -only-testing:TorrentinoIPCTests` → **TEST SUCCEEDED, 74/74**.
`TorrentinoAppTests` — **9/9** (includes new `testPeerValidationWrongTeamIdentifierRejected`).
`TorrentinoDomainTests` — **19/19**.

| Area | Test count | Coverage |
| :--- | :---: | :--- |
| IPCVersion | 6 | current=1.0, ordering, parsing, backward-compat via envelope, mismatch |
| Identity model | 4 | RecordID, OperationID, RequestID, ContentIdentity (v1/v2/hybrid) |
| State model | 4 | DesiredTorrentState/TorrentActivity frozen, TorrentHealth, TransferProgress/Rates, PeerSummary |
| Snapshots | 7 | TorrentSnapshot, EngineSnapshot, revision monotonic, first-snapshot-full, dropped-delta → full, contiguous delta, instance-change → full |
| Commands (EngineCommandV1) | 5 | 32-case surface + round-trip, unknown decode fail, requestID on every payload, mutating ⇒ idempotency key |
| Events (EngineEventV1) | 2 | 11-case surface + round-trip |
| Error contract | 3 | fault round-trip, stable localization keys, factories |
| Envelope | 15 | happy round-trip (request/event/result), kind validation, tampered/garbage/truncated fuzz, requestID mismatch, unknown kind, oversized (>4 MiB) rejected, concurrent stress |
| Pagination | 5 | PageCursor, FileCursor hierarchy, Page<T>, page-size bounds, 4 entry types |
| Settings | 8 | round-trip, validation rules, transaction applied/validationFailed/revisionConflict/rollback/persist-failure, conflict fault |
| Handshake | 6 | request/response round-trip, negotiation same/overlap/mismatch, validateResponse happy/fault |
| Idempotency | 4 | canonical key deterministic, duplicate replay, different keys no replay, key round-trip |
| ReconnectPolicy | 3 | immediate first attempt, monotonic backoff, budget exhausted |
| PeerValidation (AppTests) | 6 | nonexistent path, unsigned dummy, **ad-hoc signed → wrongTeamIdentifier (NEW)**, frozen requirement, invalid expression, enforcement gate |
| TestProfile | 1 | isolation (no production Application Support) |

---

## WP-05 Gate Coverage

| Gate (from plan) | Test(s) | Status |
| :--- | :--- | :---: |
| Version mismatch handled | `testVersionMismatchProducesFault`, `testHandshakeMismatchAcrossMajors`, `testVersionBackwardCompatLogicViaEnvelope` | **PASS** |
| Duplicate command idempotent | `testIdempotencyDuplicateReplaysSameResult`, `testIdempotencyDifferentKeysDoNotReplay` | **PASS** |
| Dropped delta → reconciliation | `testDroppedDeltaRequiresFullSnapshot`, `testContiguousDeltaApplicable`, `testSnapshotRevisionMonotonic` | **PASS** |
| Reconnect works | `testReconnectPolicyFirstAttemptImmediate`, `testReconnectPolicyBackoffMonotonic`, `testReconnectPolicyBudgetExhausted` + WP-02 `test_wp02_reconnect_after_kill.sh` | **PASS** |
| Instance change → full snapshot | `testInstanceChangeRequiresFullSnapshot`, `testFirstSnapshotAlwaysFull` | **PASS** |
| Oversized/invalid payload rejected | `testEnvelopeOversizedPayloadRejected`, `testEnvelopeGarbageJSONDecodeFails`, `testEnvelopeTamperedPayloadDecodeFails`, `testEnvelopeFuzzTruncatedJSON`, `testEnvelopeRequestIDMismatch`, `testEnvelopeUnknownKindDecodeFails` | **PASS** |
| Stale event / revision ordering | `testSnapshotRevisionMonotonic`, `testEnvelopeEventKindValidation` (revision-gated deltas) | **PASS** |
| Unsigned peer rejected | `testPeerValidationUnsignedDummyFileRejected`, `testPeerValidationNonexistentPathRejected` | **PASS** |
| Wrong team rejected | **`testPeerValidationWrongTeamIdentifierRejected` (NEW)** — ad-hoc signed Mach-O fails the frozen requirement → `.wrongTeamIdentifier` | **PASS** |
| Enforcement active in Release | `testPeerValidationEnforcementGate` (Debug=false / Release=true) + `testPeerValidationRequirementExpressionFrozen` | **PASS** |
| Settings rollback / version conflict | `testSettingsTransactionRollbackOnApplyFailure`, `testSettingsTransactionRevisionConflict`, `testSettingsTransactionPersistFailureNoRollback`, `testSettingsRevisionConflictFault` | **PASS** |
| Hierarchical file paging | `testFileCursorHierarchyRoundTrip`, `testPaginatedItemsRoundTrip`, `testPageSizeBounded`, `testPageCursorRoundTrip` | **PASS** |
| All contract tests green | 74/74 IPC + 9/9 App + 19/19 Domain | **PASS** |
| 32-command / 11-event surface complete | `testEngineCommandV1SurfaceComplete`, `testEngineEventV1SurfaceComplete` | **PASS** |

---

## QA Tooling Changes This Cycle

| File | Change |
| :--- | :--- |
| `run_qa_suite.sh` | **Fixed:** runner now collects `test_wp05_*.sh` (was `test_wp0{1,2,3,4}_*.sh` only); summary now reports a wp05 bucket. Without this the 12 new scripts were NOT part of the monotonic regression. |
| `scripts/qa/test_wp05_*.sh` (12 files) | New per-feature scripts (identity, commands, events, error contract, envelope limits, pagination, settings transaction, handshake, idempotency, reconciliation, peer validation, contract tests) — all run targeted XCTest selections, all GREEN. |
| `Native/Tests/TorrentinoAppTests/TorrentinoAppTests.swift` | **New test:** `testPeerValidationWrongTeamIdentifierRejected` (copies `/usr/bin/true`, ad-hoc re-signs, expects `.wrongTeamIdentifier`). |

---

## Build / Configuration Evidence

| Check | Command | Result |
| :--- | :--- | :---: |
| Full scheme, Developer ID signed | `xcodebuild build -scheme Torrentino -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=438UQRF7JV` | **BUILD SUCCEEDED** |
| Swift 6 strict concurrency | `test_wp03_strict_concurrency.sh` (xcconfig Complete + Werror) | PASS |
| Contract tests | `test_wp05_contract_tests.sh` (3 targets, standalone + combined) | 102/102 PASS |

---

## Observations (non-blocking)

1. **Enforcement gate (Debug vs Release):** `PeerValidation.isEnforcementActive` skips the
   SecStaticCode + `setCodeSigningRequirement` checks in Debug (no embedded agent / unsigned dev
   builds). The executable wrong-team rejection path is now proven by the new unit test; the
   end-to-end transport enforcement still needs the Developer-ID Release artifact (WP-16 signing chain).
2. **SDK API note:** `SecStaticCodeCopyDesignatedRequirement` is absent from the current SDK's
   public headers; validation compiles the frozen requirement expression and passes it to
   `SecStaticCodeCheckValidity` instead — equivalent team/identifier rejection semantics.
3. **Ad-hoc signing test source:** `/bin/true` does not exist on this macOS (coreutils moved to
   `/usr/bin`); the test copies `/usr/bin/true` and re-signs it ad-hoc.
4. **QA defect found & fixed in-cycle:** `test_wp05_peer_validation.sh` referenced
   `testPeerValidationWrongTeamIdentifierRejected` before it existed — the script would have
   failed with "no such test". Fixed by adding the missing unit test (test code only; no product
   code touched). No product defects found this cycle.
5. **ReconnectPolicy** has no dedicated shell script (not in the 12-script plan); its 3 unit tests
   run inside `test_wp05_contract_tests.sh` + WP-02 `test_wp02_reconnect_after_kill.sh`.

---

## Overall Summary

- **Total QA scripts:** 57 (45 regression + **12 new**) — **Passed: 57 — Failed: 0 — SUITE RESULT: GREEN**
- **Contract tests:** 102/102 PASS (IPC 74, App 9, Domain 19)
- **New unit test added:** 1 (`testPeerValidationWrongTeamIdentifierRejected`)
- **Bugs found this cycle:** 1 in QA tooling (missing test reference), fixed in-cycle. Product bugs: 0.
- **Coverage matrix:** `Native/TorrentinoEngineBridge/scripts/qa/COVERAGE.md`
