# QA Verification Report — WP-08 Native UX Completeness (final run)

**Date:** 2026-08-04
**Role:** Test Engineer (test code and defect detection only)
**Verdict:** **PRODUCT GREEN / ENVIRONMENTAL LEGACY FAIL WAIVED**

---

## Executive Summary

WP-08 is product-green. All product checks pass; the only non-zero result is the
pre-existing tracked working-tree dirt reported by
`test_wp03_legacy_untouched.sh` under `Legacy/Tauri`. It is Human research and
was not read, edited, restored, staged, or committed by QA.

| Layer | Previous baseline | This run | Result |
| --- | --- | --- | --- |
| WP-01..WP-07 regression | 84 scripts | 83/84 PASS; 1 environmental Legacy FAIL | PRODUCT PASS / waiver |
| Existing WP-08 QA scripts | 13 scripts | 13/13 PASS | PASS |
| New WP-08 QA scripts | 0 | 3/3 PASS | PASS |
| Full QA suite | 84/84 in prior report | 99/100; one environmental failure | PRODUCT GREEN |
| Full scheme XCTest | 175/175 in prior report | 201/201 PASS | PASS |
| Headless bridge | prior PASS | PASS | PASS |
| Swift bridge | prior PASS | PASS | PASS |
| Product changes by QA | none | none | scope PASS |

## New Coverage

| Deliverable | What it detects | Result |
| --- | --- | --- |
| `TransferSmokeTests` session settings axes | fetch revision, live apply of all fields, persistence, invalid/revision no-mutation, engine rollback | PASS |
| `TorrentinoAppTests.testTorrentListProjectionSearchFilterAndSort` | case-insensitive search, filter projections, stable sort ordering | PASS |
| `test_wp08_session_settings.sh` | UI -> IPC -> agent -> EngineCoordinator -> native session field mapping | PASS |
| `test_wp08_focus_reconnect.sh` | sheet/reconnect generation and AppKit first-responder restoration contract | PASS |
| `test_wp08_bridge_integration.sh` | retention of real Swift/ObjC++/C++ limit, tracker, reannounce, settings and typed-fault scenarios | PASS |
| strengthened DND/Keychain scripts | actual UTI/scheme association and detached credential boundary | PASS |

## WP-08 Feature Results

| Feature | Evidence | Result |
| --- | --- | --- |
| Inspector tabs, selection sync, Cmd+I | `test_wp08_inspector_tabs.sh` | PASS |
| Sorting, columns, search, multi-selection, batch actions | `test_wp08_sorting_search.sh` plus projection XCTest | PASS |
| Drag/drop and Finder association | `test_wp08_dnd_association.sh` and source Info.plist | PASS |
| File/Edit/Torrent/View menus and shortcuts | `test_wp08_menus_shortcuts.sh` | PASS |
| Settings sections and transaction | `test_wp08_settings_sections.sh`, `test_wp08_settings_transaction.sh` | PASS |
| Session settings live apply | `test_wp08_session_settings.sh`, XCTest, native bridge | PASS |
| Tracker edit/replace/reannounce | `test_wp08_trackers_reannounce.sh`, XCTest, bridge | PASS |
| Per-torrent bandwidth and typed unsupported goals | `test_wp08_per_torrent_limits.sh`, XCTest, bridge | PASS |
| Completion/all-complete/error notifications | `test_wp08_notifications.sh` and AppTests | PASS |
| Full EN/RU catalog | `test_wp08_localization_full.sh` | PASS; 183 keys, 18 long RU cases |
| Accessibility, contrast, reduce motion | `test_wp08_accessibility.sh` | PASS at source level |
| Focus restore and reconnect generation | `test_wp08_focus_reconnect.sh` | PASS at source level |
| Keychain boundary | `test_wp08_keychain.sh` and AppTests | PASS |
| 100/500 row projection performance | `test_wp08_fixture_perf.sh` and measured AppTests | PASS |
| Full-stack invalidArgument and malformed trackers | `test_wp08_bridge_integration.sh`, `bridge_swift_test.swift` | PASS |

## Gate Matrix

| Gate | Evidence | Status |
| --- | --- | --- |
| Keyboard-only core flow | menus, Cmd+F, Cmd+I, table selection source contracts | PASS (source minimum) |
| VoiceOver audit | explicit labels and labeled file checkbox | PASS (source minimum; runtime audit residual) |
| Light/Dark/Increase Contrast/Reduce Motion | dynamic colors and behavior source contracts | PASS (source minimum) |
| Focus restoration after sheet/reconnect | connectionGeneration and first-responder path | PASS (source minimum; runtime audit residual) |
| Zero missing String Catalog keys | full source-reference scan | PASS |
| Russian long-string layout | catalog and fixed window sizing evidence | PASS (source evidence; no pixel snapshot) |
| No routine modal alerts | app source scan | PASS |
| 100-500 row performance | fixture/projection `measure` tests | PASS |
| Settings transaction and live engine honesty | transaction + live engine XCTest and bridge | PASS |
| Limits/trackers/reannounce typed engine path | XCTest and bridge harness | PASS |
| Keychain credentials boundary | detached Security calls, no UserDefaults, negative load | PASS |
| Legacy product tree clean in history | approved product range remains clean | PASS; working-tree environmental fail waived |

## Environmental Waiver

`test_wp03_legacy_untouched.sh` reports tracked changes in:

- `Legacy/Tauri/src-tauri/src/gui.rs`
- `Legacy/Tauri/ui/app.js`
- `Legacy/Tauri/ui/styles.css`

These are pre-existing Human research changes. They are not product-range
commits and are not a product defect. The Orchestrator waiver applies: this
failure alone does not make WP-08 product red.

## Residual Audit Items

- Runtime VoiceOver/AppKit focus automation was not run in this headless QA cycle; source-level minimums pass.
- Full 24-hour soak is a wall-clock qualification and remains outside this run.

---

## Historical WP-07 Core Transfer Vertical Slice Report

**Date:** 2026-08-03
**Role:** Test Engineer (QA)
**Status:** **GREEN (ALL 84 QA SCRIPTS PASS + 175/175 TESTS PASS)**

---

## Executive Summary

WP-07 (core transfer vertical slice — bencode/metainfo/magnet parsers, HTTP source
fetching, duplicate detection, path validation, file selection, start/pause/resume,
paginated files, error isolation, restart flow, event-driven deltas, 100-row fixture)
is verified green on two levels:

1. **Regression suite:** all **84 QA scripts** across WP-01..WP-07 pass
   (`SUITE RESULT: GREEN`) — 71 previous scripts untouched (monotonic coverage)
   plus **13 NEW `test_wp07_*.sh` scripts**, one per WP-07 feature area.
2. **XCTest:** full scheme run — **175/175 PASS, 0 FAIL** across 5 bundles:
   `TorrentinoIPCTests` (74) + `TorrentinoAppTests` (9) + `TorrentinoDomainTests` (19)
   + `TorrentinoEngineAgentPersistenceTests` (16) + `TransferSmokeTests` (**57** =
   25 existing + **32 NEW** WP-07 cases written by QA).

Every gate item from the WP-07 plan is covered (see Gate table below). No product
bugs found this cycle; two plan-vs-product coverage nuances noted (Observations 1-2).

---

## QA Suite Execution Results (final full-suite run, 2026-08-03)

### WP-07 (Core Transfer Vertical Slice) — NEW this cycle
| Script | Status | Duration | Verifies |
| :--- | :---: | :---: | :--- |
| `test_wp07_bencode_parser.sh` | PASS | 2s | Bencode happy + negative corpus; depth 64/66 boundary; 16 MiB size bound rejected BEFORE tokenizing; strict integers (leading-zero, -0, empty, non-digit, overflow) |
| `test_wp07_metainfo_parser.sh` | PASS | 2s | Single/multi-file; negative corpus; bad info dict; SHA-1 known vector; 10 000/10 001 file boundary; announce-list capped at 512 deduplicated; pieces sanity; preflight >10 MiB / zero total |
| `test_wp07_magnet_parser.sh` | PASS | 2s | v1 40-hex + base32 decode-to-known-bytes; short hash reject; btmh-only → missingHash, hybrid → btih; tracker dedupe + scheme whitelist; 8 KiB length boundary exact; negative corpus |
| `test_wp07_http_source.sh` | PASS | 3s | http/https allowed; ftp/file/gopher reject; exactly 5 redirects OK / 6 → tooManyRedirects (loopback python server, no external network); redirect→ftp rejected; >10 MiB body; 30 s deadline via never-responding source; content-type allowlist incl. absent header; 404; invalid URL |
| `test_wp07_duplicate_detection.sh` | PASS | 1s | Same .torrent → same recordID; same magnet hash (different dn/tr) → same recordID; different content → different recordID; idempotent replay of commitAdd key |
| `test_wp07_path_validator.sh` | PASS | 3s | Traversal (`../`, `a/../../`, absolute, `a//b`, `a/./b`, `.`, `..`), null bytes, backslash escapes, reserved device names (con.txt, `C:`), overlong (300 chars / 600 components); positives not rejected; 255/256, 4096/4097, 513-component boundaries |
| `test_wp07_file_selection.sh` | PASS | 2s | skip/normal priorities round-trip via fetchFiles; selection emits inspectionInvalidated(files) with recordID; unknown path → typed fault, no crash |
| `test_wp07_pause_resume.sh` | PASS | 2s | startPaused true/false/nil → desiredState paused/running/running; pause↔resume transitions persisted; full add flow publishes delta |
| `test_wp07_paginated_files.sh` | PASS | 2s | Multi-file root page → shared directory first; FileCursor drill-down root → sub → deep; PageCursor round-trip (2 then 1, last → nil cursor); directory rows aggregate children |
| `test_wp07_error_isolation.sh` | PASS | 2s | Engine add failure degrades ONLY that record (recoverableError(.engineBusy)), siblings healthy + live rates; pump heals after recovery; commitAdd without inspect → typed operationNotFound, store keeps serving |
| `test_wp07_restart_flow.sh` | PASS | 2s | Add → in-process restart (fresh coordinator, same TestProfile store) → restoreFromPersistence → record present with displayName + desiredState; 100-record store restores to exactly 100 rows |
| `test_wp07_event_continuity.sh` | PASS | 2s | commitAdd → .torrentDelta (no full-list polling); two rapid adds coalesce into one batch with CONTIGUOUS revisions; .snapshotRequired urgent — bypasses 5 s coalescing window; burst coalesces into single delivery; selection → inspectionInvalidated(files) |
| `test_wp07_100row_fixture.sh` | PASS | 2s | 100 seeded records restore → snapshot of exactly 100 rows with per-row recordID identity + aggregate totals; 100 interleaved mixed commands on one coordinator all resolve (no deadlock / dropped replies) |

### WP-01..WP-06 — Regression (all 71 previous scripts, unchanged)
| Bucket | Scripts | Result |
| :--- | :---: | :---: |
| WP-01 (Headless Harness) | 11 scripts (build_idempotent … versions_lock_valid) | 11/11 PASS |
| WP-02 (Launchd Agent & Lifecycle) | 13 scripts (counter_* … xpc_roundtrip) | 13/13 PASS |
| WP-03 (Native Skeleton & Strict Concurrency) | 8 scripts (domain_types … xctest_pass) | 8/8 PASS |
| WP-04 (Bridge & Engine Kernel) | 13 scripts (adapter_compile … xcode_integration) | 13/13 PASS |
| WP-05 (XPC Protocol v1) | 12 scripts (identity_types … contract_tests) | 12/12 PASS |
| WP-06 (Durable Persistence/Recovery) | 14 scripts (sqlite_wal … crash_cycles) | 14/14 PASS |

```
total: 84  pass: 84  fail: 0  (wp01: 11  wp02: 13  wp03: 8  wp04: 13  wp05: 12  wp06: 14  wp07: 13)
SUITE RESULT: GREEN
```

---

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

### WP-06 (Durable Persistence/Recovery) — Regression detail (previous cycle)
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

## WP-07 Unit Tests (TransferSmokeTests — 32 NEW by QA, 57 total in class)

All run inside the full scheme test; each also mapped 1:1 into the 13 QA scripts.

| Area | Test | Coverage |
| :--- | :--- | :--- |
| Bencode bounds | `testBencodeDepthBoundary` | 64 nested OK / 66 → `.depthExceeded` |
| Bencode bounds | `testBencodeInputSizeBound` | >16 MiB → `.sizeExceeded` before tokenizing (fail-fast) |
| Bencode strict int | `testBencodeStrictIntegerFormsTyped` | `<leading-zero>`, `-0`, `""`, `<non-digit>`, `<overflow>` all reject; canonical forms pass |
| Metainfo limits | `testMetainfoFileCountLimitExactBoundary` | exactly 10 000 files accepted, 10 001 → `.tooManyFiles` |
| Metainfo limits | `testMetainfoTrackerLimitCappedAt512` | announce-list >512 → exactly 512 deduplicated trackers |
| Metainfo limits | `testMetainfoPathLengthBoundaries` | 255-char component OK/256 reject; 4096 total OK/4097 reject; 513 components → `.pathTooLong` |
| Metainfo limits | `testMetainfoPiecesSanityTyped` | 0 pieces / non-multiple-of-20 → `.invalidPieces` |
| Metainfo limits | `testMetainfoSHA1KnownVector` | info hash `dcc9ecbd…dbae0c` vs independently-computed BEP-3 vector (not mirroring product code) |
| Magnet | `testMagnetBase32HashDecodesToKnownBytes` | 32-char base32 → byte-identical to 40-hex form |
| Magnet | `testMagnetRejectsShortHashTyped` | 39-hex → `.invalidHash` |
| Magnet | `testMagnetBTMHOnlyRejectedHybridUsesBTIH` | urn:btmh-only → `.missingHash`; btih+btmh → btih identity |
| Magnet | `testMagnetTrackerDedupeAndSchemeWhitelist` | duplicate `tr` collapses; ftp:// tracker rejected |
| Magnet | `testMagnetLengthBoundaryExact` | exactly 8 KiB accepted, 8 KiB+1 → `.tooLong` |
| HTTP | `testHTTPSourceFetchHTTPSchemeAllowed` / `testHTTPSourceFetchRejectsUnsupportedScheme` | https ok; ftp/file/gopher → `.unsupportedScheme` |
| HTTP | `testHTTPSourceFetchAllowsExactlyFiveRedirects` / `testHTTPSourceFetchRejectsMoreThanFiveRedirects` | loopback python HTTP server (URLProtocol stubs cannot reproduce 3xx hops): 5 → success, 6 → `.tooManyRedirects` |
| HTTP | `testHTTPSourceFetchRejectsRedirectToUnsupportedScheme` | 302 → ftp → `.redirectToUnsupportedScheme` |
| HTTP | `testHTTPSourceFetchDeadlineEnforced` | never-responding source + short deadline → `.deadlineExceeded` |
| HTTP | `testHTTPSourceFetchMissingContentTypeAllowed` | absent Content-Type allowed (stub install with `contentType: nil`) |
| Duplicate | `testDuplicateMagnetSameHashReturnsExistingRecord` | same hash, different dn/tr → same recordID |
| Start state | `testCommitAddImmediateStartRuns` | startPaused nil → `.running` immediately (no user action needed) |
| Selection | `testFileSelectionPrioritiesRoundTrip` / `testFileSelectionRejectsUnknownPath` | skip/normal round-trip via fetchFiles; unknown path → typed fault |
| Isolation | `testEngineAddFailureIsolatesRecord` | per-record `failAdds(containing:)` fault injection → only that record degraded; pause/resume on siblings works; pump heals |
| Isolation | `testEngineStatusErrorDegradesOnlyThatRecord` | per-record status error → only that record degraded, healthy keep live rates |
| Events | `testDeltaContinuityTwoAddsSingleBatch` | two rapid adds → ONE batch, contiguous revisions (no gap for UI) |
| Events | `testSnapshotRequiredFlushesImmediately` | urgent event bypasses 5 s coalescing window |
| Events | `testEventBusCoalescesBurstIntoOneDelivery` | burst of publishes → single delivery |
| Concurrency | `testConcurrentMixedCommandsAllResolve` | 100 interleaved add/pause/resume/fetch/status on one coordinator → all resolve |
| Fixture | `testHundredRowFixtureRestoresAndRenders` | 100 seeded records → exactly 100 rows, per-row recordID identity, aggregate totals |

---

## WP-07 Gate Coverage (from plan)

| Gate (from plan) | Test(s) | Status |
| :--- | :--- | :---: |
| UI не polling (event-driven deltas) | `testCommitAddFlowPublishesDelta`, `testDeltaContinuityTwoAddsSingleBatch`, `testEventBusCoalescesBurstIntoOneDelivery` | **PASS** |
| Row identity, focus, scroll под 100 rows | `testHundredRowFixtureRestoresAndRenders` (100 rows, per-row recordID) | **PASS** |
| 100-row fixture на старте | `testHundredRowFixtureRestoresAndRenders` (seed 100 → restore → snapshot = 100) | **PASS** |
| Metadata не блокирует MainActor | parsers + coordinator are actor-isolated; concurrency stress `testConcurrentMixedCommandsAllResolve` (100 commands, no deadlock) | **PASS** |
| Restart сохраняет flow | `testCommitAddFlowPublishesDelta` (in-process restart + restoreFromPersistence), `testHundredRowFixtureRestoresAndRenders` | **PASS** |
| Error isolation (одна ошибка не блокирует остальных) | `testEngineAddFailureIsolatesRecord`, `testEngineStatusErrorDegradesOnlyThatRecord` | **PASS** |
| Untrusted source не создаёт путь вне torrent root | `testPathValidatorNegatives` (traversal/absolute/null-byte/reserved/overlong corpus), `testMetainfoNegativeCorpusRejects`, `testMetainfoPathLengthBoundaries` | **PASS** |
| Parser = happy + negative/fuzz (ADR-010) | bencode/metainfo/magnet negative corpora + boundary tests, all rejecting before payload write | **PASS** |
| Security bypass attempts | `testMagnetBTMHOnlyRejectedHybridUsesBTIH`, `testHTTPSourceFetchRejectsRedirectToUnsupportedScheme`, `testMagnetTrackerDedupeAndSchemeWhitelist` (ftp in tracker), `testPathValidatorNegatives` (`.`, `..`, `C:`, backslash) | **PASS** |
| Concurrency stress | `testConcurrentMixedCommandsAllResolve` (100 interleaved commands, single actor, no dropped replies) | **PASS** |

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
| `run_qa_suite.sh` | Runner now also collects `test_wp07_*.sh` and reports a wp07 bucket in the summary (was wp01..wp06 only). Without this the 13 new scripts would NOT be part of the monotonic regression. |
| `scripts/qa/test_wp07_*.sh` (13 files) | New per-feature scripts: `bencode_parser`, `metainfo_parser`, `magnet_parser`, `http_source`, `duplicate_detection`, `path_validator`, `file_selection`, `pause_resume`, `paginated_files`, `error_isolation`, `restart_flow`, `event_continuity`, `100row_fixture` — each runs its targeted `TransferSmokeTests` selection, all GREEN. |
| `Tests/TorrentinoEngineAgentTests/TransferSmokeTests.swift` | **+32 new test methods** (25 → 57): parser bounds/typed errors, SHA-1 known vector, magnet base32/v2/hybrid, HTTP redirect limit via loopback python server, deadline via HangURLProtocol, per-record engine fault injection (`failAdds(containing:)`), event continuity/urgent flush, 100-command concurrency stress, 100-row restore fixture. |
| `scripts/qa/COVERAGE.md` | WP-07 feature/gate matrix added; regression tables extended with WP-07. |

No product code was modified this cycle (test-only QA deliverables).

---

## Build / Configuration Evidence

| Check | Command | Result |
| :--- | :--- | :---: |
| Full scheme tests (5 bundles) | `xcodebuild test -scheme Torrentino ...` | **175/175 PASS, 0 FAIL** (IPC 74, App 9, Domain 19, EngineAgentPersistence 16, TransferSmokeTests 57) |
| QA regression | `bash scripts/qa/run_qa_suite.sh` | **84/84 PASS — SUITE RESULT: GREEN** |

---

## Observations (non-blocking)

1. **`FileSelectionPriority` lacks `.high`:** the WP-07 plan specifies skip/normal/high
   priorities, but the IPC enum ships only `{skip, normal}`. QA covered everything
   that exists (skip/normal round-trip + unknown-path reject); "high" cannot be
   exercised until the product adds the case. LOW — plan-vs-product gap, not a
   defect in what ships.
2. **URLProtocol stubs cannot reproduce redirect hops:** `URLSession` completes a
   3xx hop with an empty buffer, so `URLProtocol`-based tests surface
   `.emptyResponse` (correct product behavior) before redirect machinery runs.
   Redirect-count and redirect-scheme cases are therefore exercised against a
   loopback python HTTP server (`startRedirectServer()` helper, 127.0.0.1, no
   external network). Test-infra note, not a product issue.
3. **Deadline test timing:** `testHTTPSourceFetchDeadlineEnforced` uses a short
   deadline + never-responding stub; verified stable across repeated full-suite
   runs (0 flaky occurrences).


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

- **Total QA scripts:** 84 (71 regression + **13 new**) — **Passed: 84 — Failed: 0 — SUITE RESULT: GREEN**
- **XCTest:** 175/175 PASS (IPC 74, App 9, Domain 19, EngineAgentPersistence 16, TransferSmokeTests 57)
- **New unit tests this cycle:** **+32** by QA in `TransferSmokeTests` (25 → 57), all mapped into the 13 WP-07 scripts
- **Bugs found this cycle:** 0 product bugs. 3 observations (1 plan-vs-product gap in `FileSelectionPriority`, 2 test-infra notes).
- **Coverage matrix:** `Native/TorrentinoEngineBridge/scripts/qa/COVERAGE.md`
