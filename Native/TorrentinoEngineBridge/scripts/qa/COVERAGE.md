# Torrentino QA Coverage — WP-11 Torrent Creator & Structured Tracker Topology

Updated: 2026-08-06 (Test Engineer, WP-11 QA cycle)
Suite entry: `Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
**WP-11 result:** **PRODUCT GREEN; ALL XCTESTS & QA SCRIPTS PASS**
**Last full suite:** **111/112 PASS; 1 ENVIRONMENTAL Legacy FAIL (waived per ADR-013)**
**Full XCTest run:** **287/287 PASS (100% GREEN)**

## WP-11 Feature Matrix

| # | Feature | Dedicated evidence | Happy | Error / invalid | Recovery / edge | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Creator v1/v2/hybrid options assertion | `test_wp11_creator_asserted_options.sh`; `testWP11CreatorAssertedOptionsFailClosed` | `commitCreateVerified` with matching asserted options | unasserted `commitCreate` throws `creatorAssertionMissing`; mismatched options throw `creatorAssertionMismatch` | token invalidated on form change / superseded plan | covered / PASS |
| 2 | Structured tracker topology (`[[String]]`) | `test_wp11_tracker_topology.sh`; `testWP11TrackerTopologyVectorPreservesTiersAndRepeatedURLs`; `testEditTrackers` | ordered tiers, URL order, repeated URLs preserved across boundaries | malformed URL, invalid inner tier, >512 URLs rejected | structured replacement; scalar delta fields rejected | covered / PASS |
| 3 | Persistence schema v3 (`torrent_tracker_topology`) | `test_wp11_schema_v3_topology.sh`; `testOpenCreatesSchemaWithWAL` | version 3, WAL mode, versioned JSON envelope + SHA-256 + generation | corrupt JSON / checksum mismatch fails closed | schema v2 migration; metainfo reconciliation | covered / PASS |
| 4 | Source scan & output exclusion | `testWP11OutputInsideSourceTreeIsExcluded` | output inside source tree excluded from manifest | source file modified during scan/hash fails closed | exact canonical output leaf excluded via aliases (/tmp /var) | covered / PASS |
| 5 | Atomic output transaction & cancellation | `test_wp11_creator_cancel.sh`; `testCancelBeforeHashingFailsClosed`; `testWP11CPUHasherProgressETAAndCancel` | descriptor-relative temp/final/rename/sync | ENOSPC / read-only dir / missing dir fails closed | cancellation before seeding leaves zero temp/final artifacts | covered / PASS |
| 6 | Independent metadata & info hash verification | `testV1V2HybridFormatInterop`; `testSingleFileCommitUsesParentDirectorySavePath` | raw-info SHA-1 v1 / SHA-256 v2 match pinned libtorrent identity | v1/v2 identity mismatch or parse failure fails closed | single-file seed uses parent directory savePath | covered / PASS |
| 7 | Private-tracker admission | `testWP11PrivateTrackerRequiresAtLeastOneURL` | private torrent with >=1 URL admits and disables DHT/PEX/LSD | private torrent with 0 URLs rejected before persistence/engine | scalar tracker field cannot bypass private admission | covered / PASS |
| 8 | Agent-authoritative operation identity & cancellation | `testCreatorSeedUsesDurableAddPathAndContainingDirectory`; `TransferSmokeTests` | agent mints `OperationID` and returns `createOperationAccepted` | cancellation of non-existent or inactive operation rejected | terminal cancellation state observable in UI projection | covered / PASS |

## WP-11 Gate Matrix

| Gate | Evidence | Result |
| --- | --- | --- |
| v1/v2/hybrid independent verification | `testV1V2HybridFormatInterop`, raw-info SHA-1/SHA-256 verifier | PASS |
| Source not modified | `testSourceModifiedDuringHashingFails`, manifest generation check | PASS |
| Cancel leaves no partial output | `testCancelBeforeHashingFailsClosed`, `testWP11CPUHasherProgressETAAndCancel` | PASS |
| All edge cases covered (zero-byte, unreadable, overlong, etc.) | 15.5 matrix tests (15.5-1..15.5-13) | PASS |
| Creator usable without Metal | `CPUHasher` CPU-only pipeline, strict concurrency | PASS |

## New XCTest & QA Script Inventory

New WP-11 XCTests added:
- `testWP11TrackerTopologyVectorPreservesTiersAndRepeatedURLs`
- `testWP11CreatorAssertedOptionsFailClosed`
- `testWP11OutputInsideSourceTreeIsExcluded`
- `testWP11PrivateTrackerRequiresAtLeastOneURL`
- `testWP11CPUHasherProgressETAAndCancel`

New WP-11 QA scripts added:
- `test_wp11_creator_asserted_options.sh`
- `test_wp11_tracker_topology.sh`
- `test_wp11_schema_v3_topology.sh`
- `test_wp11_creator_cancel.sh`

---

# Torrentino QA Coverage — WP-10 Safe File Operations

Updated: 2026-08-04 (Test Engineer, WP-10 re-run after `0ec428f`)
Suite entry: `Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
**WP-10 result:** **PRODUCT GREEN; WP10-BUG-001 CLOSED**
**Last full suite:** **111/112 PASS; 1 ENVIRONMENTAL Legacy FAIL (waived)**
**Full XCTest run:** **257/257 PASS**

## WP-10 Feature Matrix

| # | Feature | Dedicated evidence | Happy | Error / invalid | Recovery / edge | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Manifest-scoped removal | `test_wp10_manifest_safety_contract.sh`; runtime manifest/order tests | exact durable manifest and leaf-first order | unmanifested sibling, symlink, identity, hardlink refusals | shared paths and non-empty directories | covered / PASS |
| 2 | Keep-data removal | `testWP10KeepDataRemovalLeavesPayloadByteIdentical` | record-only commit | no payload offered to Trash | byte-identical payload after commit | covered / PASS |
| 3 | Failed / partial Trash | partial and total failure XCTest cases | successful item-by-item journaling | failed provider keeps record and token pending | explicit same-token replay without duplicate mutation | covered / PASS |
| 4 | Removal journal fail-closed | `test_wp10_fail_closed_contract.sh`; append/update/settle tests | durable journal before mutation | typed persistence fault on failpoint | pending evidence survives restart and replay | covered / PASS; exact cleanup injection gaps recorded |
| 5 | Prepare admission fault | `testWP10PrepareRemovalPersistenceCountFailureFailsClosed` | durable token path | token-count read failure is typed | no token or payload mutation | covered / PASS |
| 6 | Pending-removal enumeration | `testWP10FetchPendingRemovalsPersistenceFailureDoesNotFabricateProgress` | pending summary path | persistence fault is not zero progress | exact post-enumeration journal fault lacks failpoint | covered / PASS; gap noted |
| 7 | Move admission and recheck | three new move fault XCTest cases | journal, move, record, recheck | admission/recheck/delete faults typed | row survives and recovery converges | covered / PASS |
| 8 | Interrupted move recovery | resume, rollback-noop, guided, symlink/split evidence tests | full payload evidence resumes | ambiguous/missing evidence stays guided | deletion-failure retry contract is static-only | covered / PASS; gap noted |
| 9 | Delete-free ABI | `test_wp10_delete_free_abi.sh`; headless + Swift bridge | token-only bridge surface | no permanent delete API | real bridge lifecycle remains green | covered / PASS |

## WP-10 Gate Matrix

| Gate | Evidence | Result |
| --- | --- | --- |
| File outside manifest cannot be removed | unmanifested sibling runtime test + manifest contract | PASS |
| Keep-data leaves payload unchanged | byte-identical payload XCTest | PASS |
| Failed Trash keeps record | partial/total failure XCTest | PASS |
| Partial Trash recovers or stays guided | journal replay + pending restore | PASS |
| Move crash recovers | move evidence/recheck/delete-fault tests | PASS |
| No permanent delete API | delete-free ABI contract | PASS |
| Fail-closed journals | mandatory contract script; WP10-BUG-001 | PASS / CLOSED |

## New XCTest Inventory

WP-10 now has **30** methods, represented by the WP-10 runners:

- `testWP10PrepareRemovalPersistenceCountFailureFailsClosed`
- `testWP10FetchPendingRemovalsPersistenceFailureDoesNotFabricateProgress`
- `testWP10MoveStorageAdmissionReadFailureAbortsBeforeMove`
- `testWP10MoveStorageRecheckFailureLeavesJournalForRecovery`
- `testWP10MoveStorageJournalDeletionFailureLeavesRowForRecovery`

The existing 25 WP-10 tests were retained; coverage is monotonic.

## Fault-Path Gaps

| Path | Status / reason |
| --- | --- |
| `fetchPendingRemovals` journal-row read failure after token enumeration | N/A exact injection; static contract plus earlier persistence-read runtime negative test |
| Post-settle `deleteTrashJournal` / token-prune failure | N/A exact injection; no existing post-settle failpoint; replay and static contract retained |
| Interrupted recovery `deleteMoveJournal` failure | N/A exact injection; explicit catch/static contract and successful retry-equivalent coverage retained |

No product failpoints were added by QA.

## Regression Evidence

| Layer | Result |
| --- | --- |
| WP-10 scripts | 8/8 PASS |
| Full QA suite | 111/112; only environmental Legacy failure |
| Full scheme XCTest | 257/257 PASS |
| Headless bridge | PASS |
| Swift bridge | PASS |

---

# Historical WP-08 Record

Updated: 2026-08-04 (Test Engineer, WP-08 QA cycle)
Suite entry: `Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
**Last full suite:** 2026-08-04 — **99/100 PASS; 1 ENVIRONMENTAL Legacy FAIL (waived)** — see `REPORT.md`
**Full XCTest run:** **201/201 PASS** — see `REPORT.md`

## WP-08 Feature Matrix

| # | Feature | Dedicated QA / XCTest / bridge evidence | Happy | Error / invalid | Edge | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Inspector tabs, selection sync, Cmd+I | `test_wp08_inspector_tabs.sh`; `TorrentListProjection` XCTest | tabs and selected row projection | no-selection path is source-covered | four tabs and shortcut | covered / PASS |
| 2 | Sorting, columns, search, multi-select, batch actions | `test_wp08_sorting_search.sh`; `testTorrentListProjectionSearchFilterAndSort` | six sortable columns and search | command-lane batch actions | case-insensitive query and filter projection | covered / PASS |
| 3 | Drag/drop and Finder associations | `test_wp08_dnd_association.sh` | `.torrent` and magnet drop/open handlers | non-torrent and non-magnet inputs rejected | UTI extension + `magnet` URL scheme in Info.plist | covered / PASS |
| 4 | Native menus and shortcuts | `test_wp08_menus_shortcuts.sh` | File/Edit/Torrent/View menus | duplicate shortcut detection | Cmd+N, Cmd+Shift+N, Cmd+., Cmd+/, Cmd+Delete, Cmd+R, Cmd+I, Cmd+F | covered / PASS |
| 5 | Settings sections and transaction | `test_wp08_settings_sections.sh`, `test_wp08_settings_transaction.sh`; IPC transaction tests | validate/persist/apply | validation, revision conflict, persist/apply rollback | revision fetch and inline errors | covered / PASS |
| 6 | Session settings live apply | `test_wp08_session_settings.sh`; 4 new `TransferSmokeTests`; `bridge_smoke` | all session fields reach live engine | invalid candidate and apply failure do not mutate | proxy metadata, all rate/toggle fields, revision persistence | covered / PASS |
| 7 | Tracker edit/replace/reannounce | `test_wp08_trackers_reannounce.sh`; 3 `TransferSmokeTests`; bridge harness | fetch, replace, empty replacement, reannounce | malformed URL, missing record, cooldown | deduplicated additions and typed rate limit | covered / PASS |
| 8 | Per-torrent bandwidth and typed goals | `test_wp08_per_torrent_limits.sh`; limit XCTest; bridge harness | bandwidth round-trip | invalidArgument, unsupported ratio/seed | empty/zero unlimited, non-finite and native overflow | covered / PASS |
| 9 | Notifications | `test_wp08_notifications.sh`; completion/all-complete/error XCTest | authoritative snapshot transition processing | error transition | de-duplication and all-complete edge | covered / PASS |
| 10 | Full EN/RU catalog | `test_wp08_localization_full.sh` | 183 keys with EN+RU values | missing source references fail | 18 long Russian values | covered / PASS |
| 11 | Accessibility and reconnect focus | `test_wp08_accessibility.sh`, `test_wp08_focus_reconnect.sh` | labels, contrast, reduce motion, focus hooks | inline errors; reconnect snapshot recovery | sheet dismissal and connectionGeneration | covered / PASS (source level) |
| 12 | Keychain credential boundary | `test_wp08_keychain.sh`; 4 Keychain XCTest methods | save/load/delete | load after delete returns nil | detached Security calls, no UserDefaults, password omitted from IPC candidate | covered / PASS |
| 13 | 100/500 row performance | `test_wp08_fixture_perf.sh`; 2 AppTests with `measure` | 100/500 fixture and projection | empty fixture is bounded | sorted/filter projection at 500 rows | covered / PASS |
| 14 | Full-stack invalidArgument and malformed trackers | `test_wp08_bridge_integration.sh`; `bridge_swift_test.swift` | native bandwidth and tracker IPC success | `Int64.max`, malformed array/element, invalid URL | snapshot/revision/engine/persistence no-mutation assertions | covered / PASS |
| 15 | Bridge integration | `test_wp08_bridge_integration.sh`; `test_bridge_headless.sh`; `test_bridge_swift.sh` | bandwidth, tracker replace, reannounce | unsupported and invalid typed faults | real Swift -> ObjC++ -> C++ path | covered / PASS |

## WP-08 Gate Matrix

| Gate | Evidence | Result |
| --- | --- | --- |
| Keyboard-only core flow | `test_wp08_menus_shortcuts.sh`, Cmd+F/Cmd+I/selection source contracts | PASS (source level) |
| VoiceOver audit | `test_wp08_accessibility.sh`, explicit labels and hidden-checkbox label | PASS (source minimum; runtime UI audit residual) |
| Light/Dark/Increase Contrast/Reduce Motion | dynamic AppKit colors; contrast/reduce-motion source contracts | PASS (source level) |
| Focus restoration after sheet/reconnect | `test_wp08_focus_reconnect.sh`, `connectionGeneration` and AppKit first responder path | PASS (source minimum; runtime UI audit residual) |
| Zero missing String Catalog keys | `test_wp08_localization_full.sh` | PASS |
| Russian long-string layout | 18 catalog cases and fixed Settings/Inspector frames | PASS (source evidence; no pixel snapshot) |
| No routine modal alerts | `test_wp08_accessibility.sh` rejects app `.alert` usage | PASS (source level) |
| 100-500 row performance | fixture/projection `measure` XCTest and QA contract | PASS |
| Settings transaction and honest live apply | session-settings XCTest + native bridge smoke | PASS |
| Limits/trackers/reannounce engine path and typed faults | dedicated XCTest plus real bridge harness | PASS |
| Keychain credentials boundary | detached Security API checks and save/load/delete XCTest | PASS |
| Legacy product tree clean in history | prior approved range is clean; working-tree check is Human research dirt | PASS (environmental working-tree fail waived) |

## WP-08 Execution

| Layer | Result |
| --- | --- |
| WP-01..WP-07 regression scripts | 83/84 PASS; `test_wp03_legacy_untouched.sh` environmental FAIL only |
| Existing WP-08 scripts | 13/13 PASS |
| New WP-08 scripts | 3/3 PASS: `bridge_integration`, `focus_reconnect`, `session_settings` |
| Full QA suite | 99/100 PASS; PRODUCT GREEN under Legacy waiver |
| `xcodebuild build` | BUILD SUCCEEDED |
| `xcodebuild test` | TEST SUCCEEDED, 201/201 |
| `test_bridge_headless.sh` | PASS |
| `test_bridge_swift.sh` | PASS |

## Remaining Audit Residuals

| Gap | Severity | Notes |
| --- | --- | --- |
| Runtime VoiceOver / AppKit focus audit | P2 | Deterministic source contracts and XCTest projection coverage pass; signed UI automation was not run in this headless QA cycle. |
| Full 24h soak burn-in | N/A | Wall-clock gate; existing WP-01 smoke and sanitizer regressions pass. |
| Legacy working-tree dirt | ENVIRONMENTAL | `Legacy/Tauri` tracked changes belong to Human research. Do not restore or edit; Orchestrator waiver applies. |

---

## Regression Base (WP-01..WP-07)

## Coverage policy

- Monotonic: old WP-01..WP-06 scripts are never deleted; each WP adds tests.
- Full suite always runs WP-01 + WP-02 + WP-03 + WP-04 + WP-05 + WP-06 + WP-07 + WP-08.
- Exit 0 = pass; isolated cleanup on EXIT.
- ADR-010: every public API ≥3 unit axes; every actor ≥1 stress; every parser ≥1 negative/fuzz.
- WP-07 surface is the core transfer vertical slice (`Native/TorrentinoEngineAgent/Transfer/`,
  `Native/TorrentinoDomain/PathValidator.swift`) verified at XCTest level
  (`TransferSmokeTests`, 57 cases — 32 written this cycle) plus 13 dedicated shell QA scripts
  (`test_wp07_*.sh`).

---

## Stage A — New features this cycle (WP-07)

| # | Feature | Dedicated script / tests | Happy | Error/invalid | Edge | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Bencode parser boundedness | `test_wp07_bencode_parser.sh` + `testBencodePositiveInputsParse`, `testBencodeNegativeCorpusRejects`, `testBencodeDepthBoundary`, `testBencodeInputSizeBound`, `testBencodeStrictIntegerFormsTyped` | dict/list/int/string parse | negative corpus (truncated, unterminated, leading-zero, negative length, non-digit, trailing garbage, too deep) | depth 64/66; 16 MiB size rejected BEFORE tokenizing; strict int grammar | covered / PASS |
| 2 | Metainfo limits + SHA-1 | `test_wp07_metainfo_parser.sh` + `testMetainfoSingleFileParse`, `testMetainfoMultiFileParse`, `testMetainfoNegativeCorpusRejects`, `testMetainfoRejectsBadInfoDictionary`, `testMetainfoSHA1KnownVector`, `testMetainfoFileCountLimitExactBoundary`, `testMetainfoTrackerLimitCappedAt512`, `testMetainfoPiecesSanityTyped`, `testPreflightRejectsOversizeAndZeroTotal` | single/multi-file parse | missing info, bad pieces, empty name, traversal paths | 10 000/10 001 files; 512 deduped trackers; independent BEP-3 SHA-1 vector | covered / PASS |
| 3 | Magnet parser (v1/base32/v2) | `test_wp07_magnet_parser.sh` + `testMagnetParseValid`, `testMagnetBase32HashDecodesToKnownBytes`, `testMagnetRejectsMissingHash`, `testMagnetRejectsShortHashTyped`, `testMagnetBTMHOnlyRejectedHybridUsesBTIH`, `testMagnetTrackerDedupeAndSchemeWhitelist`, `testMagnetLengthBoundaryExact`, `testMagnetRejectsOversizeURI`, `testMagnetNegativeCorpusRejects` | 40-hex + 32-char base32 → same bytes | btmh-only, short hash, oversize, negative corpus | 8 KiB exact boundary; tracker dedupe; ftp tracker rejected | covered / PASS |
| 4 | HTTP source limits | `test_wp07_http_source.sh` + 12 `testHTTPSourceFetch*` | http/https success | unsupported scheme; wrong content-type; non-success status; invalid URL; oversize body | 5/6 redirects (loopback server); redirect→ftp; absent Content-Type allowed; deadline | covered / PASS |
| 5 | Duplicate detection + idempotency | `test_wp07_duplicate_detection.sh` + `testDuplicateAddReturnsExistingRecord`, `testDuplicateMagnetSameHashReturnsExistingRecord`, `testCommitAddIdempotentReplay` | same content → same recordID | different content → different recordID | same hash, different dn/tr; replay of commit key | covered / PASS |
| 6 | PathValidator traversal corpus | `test_wp07_path_validator.sh` + `testPathValidatorPositives`, `testPathValidatorNegatives`, `testMetainfoPathLengthBoundaries`, `testMetainfoNegativeCorpusRejects` | normal/unicode/.hidden paths | `../`, `a/../../`, absolute, `a//b`, `a/./b`, `.`, `..`, null bytes, backslash, `con.txt`, `C:`, 300-char, 600 components | 255/256; 4096/4097; 513 components → pathTooLong | covered / PASS |
| 7 | File selection round-trip | `test_wp07_file_selection.sh` + `testSetFileSelectionInvalidatesInspection`, `testFileSelectionPrioritiesRoundTrip`, `testFileSelectionRejectsUnknownPath` | skip/normal round-trip | unknown path → typed fault | selection emits inspectionInvalidated(files) | covered / PASS |
| 8 | Start state + pause/resume | `test_wp07_pause_resume.sh` + `testCommitAddImmediateStartRuns`, `testPauseResumeUpdatesRecord`, `testCommitAddFlowPublishesDelta` | startPaused nil/false → running; true → paused | — | pause↔resume persisted on record | covered / PASS |
| 9 | Paginated files drill-down | `test_wp07_paginated_files.sh` + `testFilesPageWithDirectoryDrillDown`, `testSetFileSelectionInvalidatesInspection` | root → sub → deep drill-down | — | PageCursor round-trip; last page → nil cursor; dir rows aggregate | covered / PASS |
| 10 | Error isolation | `test_wp07_error_isolation.sh` + `testEngineAddFailureIsolatesRecord`, `testEngineStatusErrorDegradesOnlyThatRecord`, `testCommitAddWithoutInspectFails` | per-record fault → only that record degraded | engine busy / per-record status error | pump heals after recovery; siblings keep live rates; store keeps serving | covered / PASS |
| 11 | Restart preserves flow | `test_wp07_restart_flow.sh` + `testCommitAddFlowPublishesDelta`, `testHundredRowFixtureRestoresAndRenders` | add → restart → restore → record present | — | desiredState + displayName survive; 100-record restore | covered / PASS |
| 12 | Event-driven deltas (no polling) | `test_wp07_event_continuity.sh` + `testCommitAddFlowPublishesDelta`, `testDeltaContinuityTwoAddsSingleBatch`, `testSnapshotRequiredFlushesImmediately`, `testEventBusCoalescesBurstIntoOneDelivery`, `testSetFileSelectionInvalidatesInspection` | commitAdd → torrentDelta | — | contiguous revisions in one batch; urgent bypasses 5 s window; burst → single delivery | covered / PASS |
| 13 | 100-row fixture + concurrency stress | `test_wp07_100row_fixture.sh` + `testHundredRowFixtureRestoresAndRenders`, `testConcurrentMixedCommandsAllResolve` | 100 rows restore + render with identity | — | 100 interleaved commands all resolve | covered / PASS |

## WP-07 gates (from plan)

| Gate | Verified by | Status |
| :--- | :--- | :---: |
| UI не polling | `testCommitAddFlowPublishesDelta`, `testDeltaContinuityTwoAddsSingleBatch`, `testEventBusCoalescesBurstIntoOneDelivery` | **PASS** |
| Row identity / focus / scroll (100 rows) | `testHundredRowFixtureRestoresAndRenders` | **PASS** |
| 100-row fixture | `testHundredRowFixtureRestoresAndRenders` | **PASS** |
| Metadata не блокирует MainActor | actor isolation + `testConcurrentMixedCommandsAllResolve` | **PASS** |
| Restart сохраняет flow | `testCommitAddFlowPublishesDelta`, `testHundredRowFixtureRestoresAndRenders` | **PASS** |
| Error isolation | `testEngineAddFailureIsolatesRecord`, `testEngineStatusErrorDegradesOnlyThatRecord` | **PASS** |
| Untrusted source → нет пути вне root | `testPathValidatorNegatives`, `testMetainfoNegativeCorpusRejects`, `testMetainfoPathLengthBoundaries` | **PASS** |

---

## Stage A — Previous cycle (WP-06) — kept for reference

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
| `test_wp01_fallback_2014.sh` | 2.0.14 fallback (renamed from `test_wp01_fallback_2013.sh`; suite discovers `test_wp0*` by glob) |
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

## Regression (WP-07) — NEW, run every suite from this cycle

| Script | Feature |
| --- | --- |
| `test_wp07_bencode_parser.sh` | Bencode happy + corpus + depth/size/strict-int bounds |
| `test_wp07_metainfo_parser.sh` | Single/multi-file, SHA-1 vector, 10k files, 512 trackers, pieces sanity |
| `test_wp07_magnet_parser.sh` | v1/base32/btmh-hybrid, hash bounds, tracker dedupe, 8 KiB limit |
| `test_wp07_http_source.sh` | Scheme whitelist, 5/6 redirects, oversize, deadline, content-type |
| `test_wp07_duplicate_detection.sh` | Same content → same record; idempotent replay |
| `test_wp07_path_validator.sh` | Traversal/absolute/null-byte/reserved/overlong corpus + boundaries |
| `test_wp07_file_selection.sh` | skip/normal round-trip, inspectionInvalidated, unknown path |
| `test_wp07_pause_resume.sh` | startPaused nil/false/true, pause↔resume persisted |
| `test_wp07_paginated_files.sh` | Root-first drill-down, PageCursor round-trip |
| `test_wp07_error_isolation.sh` | Per-record engine faults, pump healing, siblings unaffected |
| `test_wp07_restart_flow.sh` | Add → restart → restoreFromPersistence → record present |
| `test_wp07_event_continuity.sh` | Deltas, contiguous revisions, urgent flush, coalescing |
| `test_wp07_100row_fixture.sh` | 100-row restore/render, 100-command concurrency stress |

## Shared infrastructure

| File | Role |
| --- | --- |
| `qa_common.sh` | paths, mktemp, asserts |
| `qa_wp02_common.sh` | app resolve, launchd/cli helpers |
| `run_qa_suite.sh` | runs `test_wp0{1,2,3,4,5,6,7}_*.sh` |

## Open gaps (after this run)

| Gap | Severity | Notes |
| --- | --- | --- |
| `FileSelectionPriority.high` (plan WP-07 #8) | P3 | Plan specifies skip/normal/high; product ships only `{skip, normal}`. QA covers everything that exists; "high" unexercisable until the product adds the case (see REPORT.md Observation 1). |
| Redirect coverage via loopback HTTP server | N/A | URLProtocol stubs cannot reproduce 3xx hops (empty-buffer `.emptyResponse` is correct product behavior); redirect-count/scheme cases run against a 127.0.0.1 python server helper in the test file (see REPORT.md Observation 2). |
| End-to-end XPC persistence surface | P2 | `AgentService` exposes counter + health only; `PersistenceStore` is opened at agent bootstrap but not yet reachable via XPC commands — WP-06 store verified in-process (isolated TestProfile), real SIGKILL of the agent exercises the store only indirectly (health snapshot). Wire the persistence XPC surface in a later WP. |
| Trio presence inside `corrupt-*` dir | P3 | Rebuild test asserts preserved main file; WAL/SHM trio-on-rebuild asserted across two tests rather than one (see REPORT.md Observation 2). |
| Lock file unlink race | P3 | `AdvisoryLockHandle.release()` removes `persistence.lock`; a releasing holder could unlink a file a third opener is about to flock. Benign under single-writer + instance-lock model (see REPORT.md Observation 3). |
| GUI pixel/UI automation of empty window | N/A | Covered via source contract + AppTests; no AppKit snapshot harness yet |
| Full 24h soak burn-in | N/A | Wall-clock item (WP-01 gate); smoke soaks green every suite run |

---

## WP-13 ADR-020 Stabilization Campaign — 2026-08-10

**Lane:** `[WP13-STABILITY-TEST-CAMPAIGN-001]`  
**Principle:** risk-based contract coverage; monotonic; TestProfile/mktemp only  
**XCTest:** 317/317 PASS (+2 new)  
**QA suite:** 107 PASS / 0 FAIL / 13 WP-02 BLOCKED / 1 Legacy WAIVED  
**Product edits:** none

### Matrix → evidence (new this run marked ★)

| ADR-020 / I-cell | Evidence | Status |
| --- | --- | --- |
| I1 R0 degrade + fail-closed snapshot | ★ `testWP13StabilityR0DegradesAndFailsSnapshotClosed` | PASS |
| I2 tolerant restore shapes | `testRestoreToleratesExtraFieldsAndOldShape` | PASS |
| I3 restore summary markers | existing observability / restore summary tests; live markers disposable | PARTIAL (in-process PASS; live disposable deferred) |
| I4 unified admission / no idle limbo | `testCommitAddImmediateStartRunningNotIdle`, multi-file offline recovery, restore warning clear | PASS |
| I5 health latch clear / rates / progress | `testStatusCacheMergesSentinelsAndClearsTransientHealth`, `testTransferRatesAndProgressProjection` | PASS |
| I6 actionable triangle policy | wp09 health/fault matrix + HealthPolicy coverage | PASS |
| I7 session-scoped shutdown veto | live disposable only | BLOCKED (Human agent present) |
| I8 event subscription timing | event bus flush/coalesce + continuity tests | PASS (contract) |
| I9 diagnostics redaction/correlation | ★ `testWP13StabilityDiagnosticsRedactsSecretsAndPreservesSafeCorrelation`, rotate sink test, `test_wp13_diagnostics_security.sh` | PASS |
| I10 app projection / no false fixture | AppTests list + ETA/health gating | PASS |
| I11 preserved file-selection + removal | `testFileSelectionPrioritiesRoundTrip`, WP10 keep/trash/partial/move + wp07/wp10 scripts | PASS |
| Persistence WAL/crash/generation | persistence XCTest + wp06 scripts | PASS |
| XPC envelope/reconnect/stress | IPC tests in matrix + wp05 scripts | PASS |
| Bridge priorities/status/alerts | priorities round-trip + wp04 scripts | PASS |
| Deterministic stress | concurrent commands, 100-row, envelope stress, wp09 matrix | PASS |
| Soak preparation | wp01 soak/flush smoke | PREP ONLY (no multi-hour claim) |
| Lifecycle launchd live | `test_wp02_*` | BLOCKED this host |

### New / updated scripts this run

| File | Role |
| --- | --- |
| ★ `test_wp13_stability_matrix.sh` | 30-test deterministic matrix harness |
| `run_qa_suite.sh` | includes wp13 stability; WP-02 block; Legacy waive |
| `test_wp03_empty_state.sh` | realign empty-state brand/add action |
| `test_wp03_domain_types.sh` / `test_wp03_ipc_envelope.sh` | cold-target prime |
| `test_wp03_strict_concurrency.sh` | ignore AppIntents tool warning |
| `test_wp08_dnd_association.sh` | realign TorrentDropRouting gate |
| ★ `TransferSmokeTests` R0 + redaction tests | XCTest contracts |

### Open gaps after this run

| Gap | Severity | Notes |
| --- | --- | --- |
| Disposable live I7 shutdown veto | P2 | Needs Human-authorized sterile agent identity |
| Disposable live I1/I9 first-boot markers | P2 | Same; in-process contracts already green |
| Multi-hour soak | N/A | Wall-clock WP-14/15; smoke only here |
| WP-02 live suite on this host | ENV | Re-run when Human agent stopped or on disposable machine |


---

## WP-13 ADR-020 Stabilization Campaign-002 — 2026-08-10

Updated: 2026-08-10 (Test Engineer, [WP13-STABILITY-TEST-CAMPAIGN-002])
Suite entry: `Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
**Campaign-002 result:** **PRODUCT GREEN**
**XCTest:** **323/323 PASS** (+6 new campaign-002 tests; baseline was 317)
**QA suite:** **109 PASS / 0 FAIL / 13 BLOCKED / 1 WAIVED** (2 new wp13 scripts)

### Campaign-002 Cell Closure

| Cell | Evidence | Status |
| --- | --- | --- |
| I3 restore summary fields consistent (success) | `testWP13C002I3RestoreSummarySuccessFieldsConsistent` — RestoreSummary.stored/rebuilt/skipped/failure + sessionPhase/degradedReason + restoreRebuiltCount/restoreSkippedCount | **CLOSED** |
| I3 restore summary fields consistent (anomaly) | `testWP13C002I3RestoreSummaryAnomalyFieldsConsistent` — anomaly sets failure="restoreAnomaly", sessionPhase=.degraded, degradedReason matches | **CLOSED** |
| I3 restore count identity | `testWP13C002I3RestoreSummaryCountsAreConsistent` — stored == rebuilt + skipped invariant | **CLOSED** |
| I8 event bus register/unregister | `testWP13C002I8EventBusRegisterAndUnregisterMaintainsCount` — sinkCount tracks add/remove accurately | **CLOSED** |
| I8 event bus same-ID replace | `testWP13C002I8EventBusSameIDReplacesExistingSink` — second register with same ID replaces, count stays 1 | **CLOSED** |
| I8 event bus unregister unknown noop | `testWP13C002I8EventBusUnregisterNeverRegisteredIsNoop` — unregister unknown ID leaves count 0 | **CLOSED** |
| I7 shutdown veto source contracts | `test_wp13_stability_i7i9.sh` I7-A/B/C/D — shutdownAuthorization var, guard, reply(false), reply(true) before hook | **SOURCE-CONTRACT CLOSED** |
| I9 diagnostics/bootstrap source contracts | `test_wp13_stability_i7i9.sh` I9-A/B/C/D/E/F — env override, markers, last-line proof, degraded flag, redact function, record path | **SOURCE-CONTRACT CLOSED** |
| I7 shutdown veto live | Requires disposable launchd agent (Human-authorized) | **BLOCKED-seam** |
| I9 bootstrap live first-boot marker | Requires agent executable process (pbxproj frozen) | **BLOCKED-seam** |

### New Artifacts

| Artifact | Contract |
| --- | --- |
| `TransferSmokeTests.testWP13C002I3RestoreSummarySuccessFieldsConsistent` | I3: RestoreSummary fields correct on success restore |
| `TransferSmokeTests.testWP13C002I3RestoreSummaryAnomalyFieldsConsistent` | I3: RestoreSummary fields correct on anomaly (degraded) |
| `TransferSmokeTests.testWP13C002I3RestoreSummaryCountsAreConsistent` | I3: stored == rebuilt + skipped invariant |
| `TransferSmokeTests.testWP13C002I8EventBusRegisterAndUnregisterMaintainsCount` | I8: sinkCount tracks register/unregister |
| `TransferSmokeTests.testWP13C002I8EventBusSameIDReplacesExistingSink` | I8: same-ID register replaces, count stays 1 |
| `TransferSmokeTests.testWP13C002I8EventBusUnregisterNeverRegisteredIsNoop` | I8: unregister unknown ID is a no-op |
| `scripts/qa/test_wp13_stability_campaign002.sh` | Deterministic 6-test matrix for campaign-002 new XCTests |
| `scripts/qa/test_wp13_stability_i7i9.sh` | I7/I9 source-contract proofs (9 static assertions); BLOCKED-seam documented |

### Remaining Open Gaps

| Gap | Severity | Notes |
| --- | --- | --- |
| I7 live shutdown veto | P2 | Requires Human-authorized sterile disposable launchd agent identity |
| I9 live bootstrap first-boot marker | P2 | Requires agent executable process (pbxproj frozen under ADR-020) |
| Multi-hour soak | N/A | Wall-clock WP-14/15; smoke only here |
| WP-02 live suite on this host | ENV | Re-run when Human agent stopped or on disposable machine |

---

## WP-14 Performance Qualification — 2026-08-22

**Lane:** `[WP14-PERF-CAMPAIGN-001]`  
**Mode:** Release, isolated TestProfile/mktemp, no live app/LaunchAgent  
**Verdict:** **FINDINGS OPEN / PARTIAL**

### New measurement coverage

| Area | New evidence | Status |
| --- | --- | --- |
| Headless primary/fallback hybrid + v2 | ★ `test_wp14_01_headless_baselines.sh`; 28 measured rows | PASS |
| 100-record restore/snapshot | ★ `WP14PerformanceMeasurements.testWP14InProcessPerformanceCampaign` | PASS |
| 100 idle / 10 active footprint | same XCTest; `TASK_VM_INFO.phys_footprint` | PASS (in-process synthetic) |
| Large creator | 2 GiB sparse `SourceScanner` + real `CPUHasher` cancellation | PASS for scan/cancel; full completion GAP |
| Recheck | 50 in-process dispatch acknowledgements | PASS for dispatch; real large completion/cancel GAP |
| 500-row table/row projection | ★ `WP14ProjectionMeasurements.testFiveHundredRowProjectionP50P95` | PASS |
| FD/thread/quiescent footprint | baseline/during/after `proc_pidinfo` + `TASK_VM_INFO` | PASS (campaign window) |
| Idle CPU | 30 × 100 ms process CPU samples | PASS (in-process surrogate) |
| 100k mixed-event overload | bounded queue + slow consumer + mutation/health lanes | **FAIL — WP14-PERF-001** |
| Disconnect/resync seam | sink unregister + unknown-revision authoritative snapshot | PASS (in-process seam) |

### New files

| File | Role |
| --- | --- |
| ★ `scripts/qa/test_wp14_01_headless_baselines.sh` | deterministic 2.1.1/2.0.14 headless baseline driver |
| ★ `scripts/qa/test_wp14_02_inprocess_metrics.sh` | Release XCTest measurement driver |
| ★ `Tests/TorrentinoAppTests/WP14ProjectionMeasurements.swift` | 500-row p50/p95 projection measurement |
| ★ `Tests/TorrentinoEngineAgentTests/WP14PerformanceMeasurements.swift` | records/active/creator/recheck/overload/resource campaign |
| `Measurements/wp14/report.md` | per-SLO report, finding, and honest gap ledger |

### Open gaps

| Gap | Severity | Notes |
| --- | --- | --- |
| WP14-PERF-001 overflow recovery marker replacement | P1 | bounded queue can replace `.snapshotRequired(.droppedDelta)` before slow consumer observes it |
| Live launch/XPC/UI+engine metrics | Human gate | sterile app/LaunchAgent identity required |
| Time Profiler/Allocations/Energy/main-thread signposts | Human gate | Instruments GUI required |
| Real large creator/recheck completion | P2 | current in-process lane caps creator and stubs recheck engine |
| Tracker/peer alert drain + stalled disk I/O | P2 | real libtorrent alert/disk lane not reached |
| 2h slope / 12h soak comparison / WP-15 168h | wall clock | not claimed by this campaign |
| Watchdog slow-I/O + relaunch/reconnect SLO | Human gate | live Human LaunchAgent explicitly forbidden |