# QA Verification Report — WP-11 Creator & Structured Tracker Topology

**Date:** 2026-08-06
**Role:** Test Engineer (functional QA; test code and defect detection only)
**Scope:** WP-11 Torrent Creator CPU Reference & Structured Tracker Topology (ADR-016 / ADR-017)
**Verdict:** **PRODUCT GREEN (tests green) / ENVIRONMENTAL LEGACY FAIL WAIVED**

---

## Executive Summary

All 9 previously red/stale XCTest expectations and 5 stale QA script checks have been reworked and aligned with current ADR-016 / ADR-017 contracts. Dedicated unit and integration tests were added covering all WP-11 feature axes (asserted CreateOptions, structured [[String]] tracker topology, persistence schema v3, atomic output transaction, independent verifier, private tracker admission, and CPUHasher progress/cancel).

The full XCTest scheme passes **287/287 GREEN** (100%).
The full QA suite passes **111/112 PASS**: the only failure is the pre-existing environmental `test_wp03_legacy_untouched.sh` check caused by Human research dirt under `Legacy/Tauri` (waived per ADR-013).

No product code was touched by QA.

---

## Result Matrix

| Layer | Result |
| --- | --- |
| WP-11 XCTest | **13/13 PASS** (5 new dedicated + 8 updated) |
| Full scheme XCTest | **287/287 PASS, 0 FAIL** |
| WP-11 QA scripts | **4/4 PASS** (`creator_asserted_options`, `tracker_topology`, `schema_v3_topology`, `creator_cancel`) |
| Reworked QA scripts | **4/4 PASS** (`test_wp06_schema_migration.sh`, `test_wp06_sqlite_wal.sh`, `test_wp07_metainfo_parser.sh`, `test_wp08_trackers_reannounce.sh`) |
| Full QA suite | **111/112 PASS; 1 environmental Legacy FAIL** |
| Headless bridge | **PASS** |
| Swift bridge | **PASS** |
| Product changes by QA | **none** |

---

## Reworked Tests (Stale Expectation Fixes)

| # | Test / Script | Rework rationale | Result |
| --- | --- | --- | --- |
| 1 | `TorrentCreatorAgentTests.testCreatorPlanStoreTwoPhaseFlowAndAtomicWrite` | Switched from unasserted `commitCreate` to `commitCreateVerified` with `assertedOptions`. | PASS |
| 2 | `TorrentCreatorAgentTests.testCancelBeforeHashingFailsClosed` | Switched to `commitCreateVerified` with `assertedOptions` and cancel closure. | PASS |
| 3 | `TorrentCreatorAgentTests.testMissingOutputDirectoryFailsClosed` | Switched to `commitCreateVerified` with `assertedOptions` expecting `volumeUnavailable`. | PASS |
| 4 | `TorrentCreatorAgentTests.testReadOnlyOutputDirectoryFailsClosed` | Switched to `commitCreateVerified` with `assertedOptions` expecting `permissionDenied`. | PASS |
| 5 | `TorrentCreatorAgentTests.testSingleFileCommitUsesParentDirectorySavePath` | Switched to `commitCreateVerified` with `assertedOptions` and canonical path assertion. | PASS |
| 6 | `TransferSmokeTests.testCreatorSeedUsesDurableAddPathAndContainingDirectory` | Updated `CommitCreateRequest` to pass asserted `options` (`optionsWereAsserted = true`). | PASS |
| 7 | `TransferSmokeTests.testEditTrackers` | Added metainfo data to record; used structured `trackerTiers` replacement payload. | PASS |
| 8 | `TransferSmokeTests.testMetainfoTrackerLimitCappedAt512` | Updated assertion to expect fail-closed rejection (`invalidTrackerURL`) for >512 trackers. | PASS |
| 9 | `TorrentinoEngineAgentTests.testOpenCreatesSchemaWithWAL` | Updated expected schema version assertion to `3` (schema v3 migration). | PASS |
| 10 | `test_wp06_schema_migration.sh` & `test_wp06_sqlite_wal.sh` | Evaluated against updated `testOpenCreatesSchemaWithWAL`. | PASS |
| 11 | `test_wp07_metainfo_parser.sh` | Evaluated against updated `testMetainfoTrackerLimitCappedAt512`. | PASS |
| 12 | `test_wp08_trackers_reannounce.sh` | Updated static python check to accept `record.trackerTiers` / `rows.count`. | PASS |

---

## Dedicated WP-11 New Tests

| # | Test Method / Script | Axis Covered | Result |
| --- | --- | --- | --- |
| 1 | `testWP11TrackerTopologyVectorPreservesTiersAndRepeatedURLs` | Ordered `[[String]]` tiers, tier order, URL order, and repeated URLs preserved end-to-end. | PASS |
| 2 | `testWP11CreatorAssertedOptionsFailClosed` | Fail-closed rejection for unasserted commit (`creatorAssertionMissing`) and mismatched options (`creatorAssertionMismatch`). | PASS |
| 3 | `testWP11OutputInsideSourceTreeIsExcluded` | Exact output leaf excluded from inspection manifest and final torrent file tree. | PASS |
| 4 | `testWP11PrivateTrackerRequiresAtLeastOneURL` | Private torrent without trackers rejected before scan/hash (`creatorPrivateTrackerMissing`). | PASS |
| 5 | `testWP11CPUHasherProgressETAAndCancel` | CPUHasher byte progress, ETA reporting, and cancellation handling. | PASS |
| 6 | `test_wp11_creator_asserted_options.sh` | QA runner for asserted CreateOptions contract. | PASS |
| 7 | `test_wp11_tracker_topology.sh` | QA runner for structured tracker topology vector and edit. | PASS |
| 8 | `test_wp11_schema_v3_topology.sh` | QA runner for persistence schema v3 `torrent_tracker_topology` table. | PASS |
| 9 | `test_wp11_creator_cancel.sh` | QA runner for creator cancellation and atomic output transaction. | PASS |

---

## WP-11 Gate Matrix

| Gate | Evidence | Result |
| --- | --- | --- |
| v1/v2/hybrid independent verification | `testV1V2HybridFormatInterop`, raw-info SHA-1/SHA-256 verifier | PASS |
| Source not modified | `testSourceModifiedDuringHashingFails`, manifest generation check | PASS |
| Cancel leaves no partial output | `testCancelBeforeHashingFailsClosed`, `test_wp11_creator_cancel.sh` | PASS |
| All edge cases covered | 15.5 matrix tests (15.5-1..15.5-13) | PASS |
| Creator usable without Metal | `CPUHasher` CPU-only pipeline, strict concurrency | PASS |

---

## Environmental Waiver

`test_wp03_legacy_untouched.sh` failed due to pre-existing Human research changes under `Legacy/Tauri`. Per ADR-013 (HARD BAN `Legacy/Tauri/`), QA did not touch, edit, or commit any file in `Legacy/`. The failure is environmental and waived.

---

## Verification Commands

- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'` -> **287/287 PASS**
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp11_creator_asserted_options.sh` -> **PASS**
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp11_tracker_topology.sh` -> **PASS**
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp11_schema_v3_topology.sh` -> **PASS**
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp11_creator_cancel.sh` -> **PASS**
- `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh` -> **111/112 PASS (1 environmental Legacy FAIL waived)**
