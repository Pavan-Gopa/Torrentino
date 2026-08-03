# FEEDBACK - WP-08 Validation Polish Review

Date: 2026-08-03
WP: WP-08 - validation polish, prior §5 items 1-3
Focus commit: 8db5aca
Reviewed range: 70fd9b5..HEAD
Role: Verification Engineer (Code Reviewer)
Scope: Invalid limits, real bridge integration coverage, native tracker validation

### 1. Build & tests

- `graphify query "TransferLimits validate handleSetLimits InspectorView setLimits editTrackers EngineBridgeAdapter bridge_swift_test bridge_smoke unsupportedOperation invalidArgument"`: PASS; 372 relevant nodes resolved and no missing/stale-graph blocker was observed.
- `git log --oneline 70fd9b5..HEAD`: `8db5aca`, `6a74179`.
- `git diff --stat 70fd9b5..HEAD`: 16 files, 662 insertions, 135 deletions.
- `git diff --check 70fd9b5..HEAD`: PASS.
- `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: BUILD SUCCEEDED.
- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: TEST SUCCEEDED.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp08_per_torrent_limits.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp08_trackers_reannounce.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp04_bridge_swift.sh`: PASS.
- Optional `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`: not completed; the 300-second run timed out during a repeated WP-04 Swift harness invocation. No full-suite result is claimed.
- No git commit or push performed by the reviewer.

### 2. WP compliance (A/B/C table)

| Item | Status | Evidence and residual risk |
| --- | --- | --- |
| A - invalid limits | PARTIAL | `TransferLimits.normalized` is removed and no longer used. `TransferCoordinator.handleSetLimits` validates before persistence, native mutation, revision bump, and publication (`TransferCoordinator.swift:997-1040`). Native checks signed-int range and finite/non-negative goals (`EngineBridge.cpp:807-835`), and Inspector parse failures surface an `invalidArgument` command error (`InspectorView.swift:262-350`). The rejection test uses one composite value whose first failure is negative, so overflow/non-finite/parse-fail and explicit zero semantics are not independently proven with prior-state assertions. |
| B - real integration coverage | PARTIAL | The Swift harness proves real bandwidth success, positive ratio/seed `unsupportedOperation`, native direct `invalidArgument`, tracker replacement, empty replacement, reannounce, and a malformed non-string adapter payload. The agent IPC invalid case (`bridge_swift_test.swift:169-177`) is rejected by `TransferCoordinator` validation before `BridgeTransferEngine -> EngineCoordinator -> adapter -> EngineBridge`; the direct native invalid case (`bridge_swift_test.swift:78-86`) does not produce an IPC result. Non-array payload rejection is implemented but not exercised. Thus the required native invalid-to-IPC typed path is not fully proven. |
| C - native tracker validation | PARTIAL | The adapter rejects non-array and non-string elements (`EngineBridgeAdapter.mm:135-155`), C++ checks scheme, authority, port, whitespace, and controls (`EngineBridge.cpp:95-159`), and empty replacement is tested. The host check accepts any non-empty string made of a small character set, while the IPv6 check only checks characters and the presence of a colon; malformed percent escapes, invalid IPv6 group counts, and malformed host forms can pass. There are no native tests for non-array payloads or these host/IPv6 edge cases. |

### 3. Architecture

- Swift 6 Complete and warnings-as-errors build successfully.
- `TransferLimits` and bridge DTOs remain immutable, `Codable`, and `Sendable`; validation is before durable state and engine mutation on the IPC command path.
- UI remains a projection and sends mutations through the IPC command lane.
- `TransferCoordinator` remains the record/revision publisher and preserves typed `unsupportedOperation` and `invalidArgument` faults instead of mapping them to `engineBusy`.
- `EngineCoordinator` remains the Swift actor owner of the ObjC++ adapter; C++ and libtorrent types remain behind the PIMPL facade.
- No WP-09+ or Legacy/Tauri product path was reopened. Previously passing session settings and reconnect items were not re-reviewed.

### 4. Comments

- The implementation removes the prior limit laundering and the source-level WP-08 QA checks pass.
- The relevant QA checks are mostly source-contract checks; they do not establish the missing native invalid-to-IPC path or the untested native tracker edge cases.
- `TransferCoordinator.engineFault` still accepts `operation` and `recordID` without using them (`TransferCoordinator.swift:874-887`); minor readability issue, not the verdict driver.

### 5. If changes_requested - concrete list only

1. [P1] Extend `bridge_swift_test.swift` with one request that traverses `TransferCoordinator -> BridgeTransferEngine -> EngineCoordinator -> adapter -> EngineBridge` and receives a native `invalidArgument` in the IPC result. The current agent invalid-limit case exits at `TransferCoordinator.swift:997-1004`; use a native-rejected value that passes the Swift coordinator boundary, assert the typed IPC fault, and assert snapshot, revision, engine, and persistence remain unchanged. Add direct adapter assertions for both a non-array `trackers` value and a non-string element.
2. [P1] Strengthen `EngineBridge.cpp:66-92,95-159` tracker URL validation at the native boundary. Validate host syntax/IPv4 and IPv6 structure and percent escapes, not only non-empty allowed characters; add native tests for malformed hosts, invalid IPv6, invalid ports, controls, unsupported schemes, and preserve the valid empty-list case.
3. [P2] Split `TransferSmokeTests.swift:820-862` into independent negative, overflow, non-finite, and parse-failure/Inspector cases. Assert for every rejected input that the prior snapshot, record revision, engine-applied limits, and persisted limits remain unchanged; add explicit empty/zero unlimited coverage.

--------------------------------------------------------------------------------

RESULT: CHANGES_REQUESTED
