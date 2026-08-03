# FEEDBACK - WP-08 Validation Polish Implementation Handoff

Date: 2026-08-04
WP: WP-08 - FEEDBACK section 5 items 1-3
Role: Implementation Engineer (Coder)
Scope: native invalidArgument IPC path, native tracker URL validation, split invalid-limit tests

## 1. Build and tests

- `graphify query "TransferLimits validate handleSetLimits bridge_swift_test editTrackers EngineBridge tracker URL validation invalidArgument TransferSmokeTests"`: PASS; scoped graph query completed before source inspection.
- `graphify update .`: PASS; graph rebuilt after code changes. Graphify reported two existing zero-node JSON files (`acl-manifests.json`, `capabilities.json`) and continued successfully.
- `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: PASS.
- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: PASS; all XCTest targets passed, including the new TransferSmokeTests.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp08_per_torrent_limits.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp08_trackers_reannounce.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`: 96/97 PASS. The only failure is `test_wp03_legacy_untouched.sh`, which detects pre-existing tracked changes under `Legacy/Tauri/`; Legacy/Tauri was not modified or reverted by this implementation.
- `git diff --check`: PASS.
- No git commit or push performed.

## 2. WP-08 items closed

### Item 1 - native invalidArgument through full IPC

- `bridge_swift_test.swift` now sends `seedTimeSeconds: Int64.max` through `TransferCoordinator -> BridgeTransferEngine -> EngineCoordinator -> EngineBridgeAdapter -> EngineBridge`.
- Swift coordinator validation accepts the non-negative seed value; native `EngineBridge` rejects it as outside the native signed range and the result remains typed IPC `invalidArgument`.
- The harness asserts unchanged snapshot, per-record revision, native handle-applied limits through the read-only `currentLimits` bridge DTO, and persisted limits.
- The same harness directly asserts adapter `invalidArgument` for a non-array `trackers` value and a non-string tracker element.
- Evidence: Swift bridge harness in `Native/TorrentinoEngineBridge/harness/bridge_swift_test.swift`; `test_bridge_swift.sh` PASS.

### Item 2 - native tracker URL validation

- `EngineBridge.cpp` now validates percent escapes, controls/whitespace, scheme syntax and whitelist, DNS labels, IPv4 octets, bracketed IPv6 group/compression structure, and ports from 1 through 65535.
- Empty tracker replacement remains valid.
- `bridge_smoke.cpp` covers malformed IPv4/DNS hosts, malformed and overlong IPv6, invalid ports, unsupported schemes, controls, bad percent escapes, valid IPv6, and empty-list success.
- Evidence: native `bridge_smoke` tracker assertions; `test_bridge_headless.sh` PASS.

### Item 3 - split invalid-limit XCTests

- Independent tests now cover `testTransferLimitsRejectsNegativeWithoutMutation`, `testTransferLimitsRejectsOverflowWithoutMutation`, `testTransferLimitsRejectsNonFiniteAtJSONBoundaryWithoutMutation`, and `testTransferLimitsRejectsInspectorParseFailureWithoutMutation`.
- Each rejection checks the prior snapshot, record revision, Stub engine-applied limits, and persistence.
- `testTransferLimitsEmptyAndZeroMeanUnlimited` explicitly covers empty and zero unlimited values.
- Evidence: `TransferSmokeTests` in `Native/Tests/TorrentinoEngineAgentTests/TransferSmokeTests.swift`; full `xcodebuild test` PASS.

## 3. Architecture

- `EngineBridge` remains the only libtorrent-facing PIMPL translation unit. The new applied-limit read is a read-only native-handle query used to verify mutation invariants.
- `EngineBridgeAdapter` continues to expose only Foundation JSON/NSError surfaces; `EngineCoordinator` owns the adapter inside its actor and decodes immutable Sendable DTOs.
- `BridgeTransferEngine` remains the production `TransferEngine` implementation. `TransferCoordinator` remains the record/revision/persistence authority and rolls persistence back when native mutation rejects a candidate.
- Tracker validation is enforced at the native boundary in addition to existing Swift URL normalization and adapter JSON shape checks.
- No session settings or reconnect work was reopened. No WP-09+ or Legacy/Tauri product path was changed.

## 4. Comments

- Comments added for the native-only signed-range validation, raw native limit semantics, URL parser edge cases, and JSON non-finite rejection are in English and explain non-obvious validation behavior.
- The full QA suite's single WP-03 failure is unrelated pre-existing `Legacy/Tauri` working-tree drift; it was intentionally left untouched per scope.
- Required WP-08 verification is green. Waiting for review.

RESULT: waiting_review
