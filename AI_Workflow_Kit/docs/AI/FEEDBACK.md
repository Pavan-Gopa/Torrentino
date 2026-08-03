# FEEDBACK - WP-08 Narrowed Bridge Completion Review

Date: 2026-08-03
WP: WP-08 - narrowed bridge completion round
Role: Implementation Engineer (Coder)
Scope: FEEDBACK §5 items 1-3 only

## 1. Build & tests

- `graphify query "TransferLimits normalized handleSetLimits InspectorView setLimits unsupportedOperation editTrackers EngineBridgeAdapter bridge_smoke bridge_swift_test TransferSmokeTests"`: PASS; requested graph context resolved.
- `graphify update .`: PASS; graph rebuilt with 3325 nodes, 7733 edges, 271 communities. Two existing JSON files produced zero AST nodes and were retried by graphify; no stale-graph blocker.
- `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: BUILD SUCCEEDED.
- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: TEST SUCCEEDED.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`: PASS; real Swift, agent, adapter, and C++ bridge path exercised.
- `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`: `97/97 PASS`, `SUITE RESULT: GREEN`.
- No git commit or push performed.

## 2. WP closure

| Item | Status | Closure evidence |
| --- | --- | --- |
| ITEM A - invalid limits | CLOSED | Removed `TransferLimits.normalized`. Shared validation rejects negative, non-finite, and out-of-native-range values with typed `invalidArgument`; validation runs before persistence, engine mutation, revision bump, or publication. Inspector parsing now treats only explicit empty/zero as unlimited and surfaces parse/overflow failures as typed errors. XCTest verifies the prior snapshot, engine-applied limits, and persisted limits remain unchanged after rejection. |
| ITEM B - real integration coverage | CLOSED | `bridge_swift_test.swift` covers real bandwidth success, ratio/seed-time `unsupportedOperation`, invalid native `invalidArgument`, tracker replacement and empty replacement, reannounce, malformed adapter payload, and IPC/agent-visible typed results through `TransferCoordinator -> BridgeTransferEngine -> EngineCoordinator -> adapter -> EngineBridge`. `bridge_smoke.cpp` independently covers the native success/error codes. `TransferSmokeTests` covers IPC rejection and no-mutation behavior. |
| ITEM C - tracker boundary validation | CLOSED | ObjC++ adapter rejects non-array and non-string tracker elements. C++ validates supported scheme, authority/host, ports, whitespace/control characters, and IPv6 literals. Empty tracker vectors remain valid. Swift bridge coverage verifies malformed payload rejection, invalid URL rejection, and empty-list success. |

## 3. Architecture

- Swift 6 Complete and warnings-as-errors build remains green.
- `TransferLimits` remains immutable/Codable/Sendable; validation is shared before the command reaches durable state or the engine.
- UI remains a projection and sends mutations through the IPC command lane; it does not become the source of truth.
- `TransferCoordinator` remains the sole record/revision publisher and preserves typed bridge faults instead of mapping them to `engineBusy`.
- `EngineCoordinator` remains the Swift actor owner of the ObjC++ adapter; C++ and libtorrent types remain behind the PIMPL facade.
- Native tracker and limit validation occurs before libtorrent mutation; explicit unsupported capabilities remain typed unsupported errors.
- No MainActor blocking I/O, Legacy/Tauri paths, WP-09+ work, session-settings work, or reconnect work was reopened.

## 4. Comments & readability

- Added concise English comments where the validation and real-path test ownership is non-obvious.
- Updated the WP-08 QA contract to require strict validation and the replacement invalid-input test rather than the removed normalization behavior.
- Removed the deprecated `httpShouldUsePipelining` assignment encountered while compiling the expanded strict Swift bridge harness.

--------------------------------------------------------------------------------

RESULT: waiting_review
