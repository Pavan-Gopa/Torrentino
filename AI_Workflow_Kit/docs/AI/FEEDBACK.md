# FEEDBACK - WP-08 Narrowed Bridge Completion Review

Date: 2026-08-03
WP: WP-08 - narrowed bridge completion round
Focus commit: 88c33e5
Reviewed range: 4320482..HEAD
Role: Verification Engineer (Code Reviewer)
Scope: Items 1-3 only

## 1. Build & tests

- Graphify query completed successfully for the requested bridge/coordinator/reconnect symbols. No missing or stale-graph condition was reported.
- `git log --oneline 4320482..HEAD`: `7bf677c`, `88c33e5`.
- `git diff --stat 4320482..HEAD`: 19 files, 921 insertions, 146 deletions.
- `git diff --check 4320482..HEAD`: PASS.
- `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: `BUILD SUCCEEDED`.
- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: `TEST SUCCEEDED`.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`: `97/97 PASS`, `SUITE RESULT: GREEN`.

The green gates do not close the limits validation gap below: the relevant XCTest cases use the stub engine, and the Swift bridge harness does not exercise the new limits/tracker/reannounce calls.

## 2. WP compliance

| Item | Status | Evidence and residual risk |
| --- | --- | --- |
| ITEM 1 - session settings | PASS | `SessionConfigurationDTO` carries the complete wire key set (`EngineBridgeDTOs.swift:44-130`); `EngineBridgeAdapter.mm:176-199` decodes it; `make_settings` applies listen settings, rates, proxy metadata, DHT/LSD/UPnP/NAT-PMP, encryption, connection limits, and alert settings (`EngineBridge.cpp:59-120`). `EngineBridge::apply` uses live `apply_settings` without clearing handles (`EngineBridge.cpp:304-324`). The bridge stores the configured download directory for later adds, and `TransferCoordinator` uses persisted settings through `configuredSaveLocation()` (`TransferCoordinator.swift:156,349,869-872`). Proxy password is absent from the bridge DTO and the native password slot is cleared (`EngineBridge.cpp:86-101`). Settings UI reports success only after the agent result and Keychain operation. Residual: bridge smoke proves handle survival by using the same torrent after apply, but does not assert every native settings value through readback. |
| ITEM 2 - limits, trackers, reannounce, error honesty | PARTIAL | Real bridge calls are present: bandwidth reaches `set_download_limit`/`set_upload_limit`, positive ratio/seed goals return `unsupported_operation`, trackers call `replace_trackers`, and reannounce calls `force_reannounce` (`EngineBridge.cpp:688-786`). Adapter and coordinator wiring is real, and code 10 is preserved through `EngineCoordinatorError`, `BridgeTransferEngine`, and `EngineFault` rather than mapped to `engineBusy`. However, `TransferLimits.normalized` converts negative/non-finite values to zero and `handleSetLimits` sends the normalized value (`State.swift:133-141`, `TransferCoordinator.swift:998-1012`); Inspector parse failures also become zero/nil (`InspectorView.swift:262-275`). Therefore invalid user/IPC values can be persisted and acknowledged as unlimited instead of reaching the required `invalid_argument` path. The positive-goal and unsupported tests use `StubTransferEngine` (`TransferSmokeTests.swift:782-863`), while the real bridge smoke covers only direct C++ ratio rejection (`bridge_smoke.cpp:249-268`), so bridge-to-coordinator-to-IPC/UI proof is incomplete. Tracker add/remove UI and error surfacing are present. |
| ITEM 3 - reconnect recovery | PASS | `EngineClient.call` has bounded attempts, restores the event subscription before the recovered request, and invokes the recovery handler afterward (`EngineClient.swift:195-227,309-323`). `TorrentListViewModel` fetches a full snapshot and increments `connectionGeneration` on recovery (`TorrentListViewModel.swift:197-214`), and the existing view change handler requests focus restoration (`TorrentListView.swift:69-73`). Residual: no XCTest exercises a real NSXPC interruption, resubscription, generation increment, and first-responder callback as one path; this remains source-level verification. |

Residual risk is limited to the narrowed bridge boundary and its invalid-input/integration coverage. Previously passing notification, Keychain, DnD, catalog, and projection areas were not re-opened.

## 3. Architecture invariants

- Swift 6 Complete and warnings-as-errors build successfully.
- C++ remains behind the ObjC++ adapter and PIMPL; no C++ or libtorrent types appear in Swift-facing APIs.
- Bridge DTOs are immutable `Codable`/`Sendable` values.
- Live settings apply does not restart the session or clear torrent handles.
- Proxy passwords do not cross the bridge boundary.
- UI state remains a projection of agent snapshots and mutations use the IPC command lane.
- Legacy paths are untouched in the reviewed product diff.
- The unsupported bridge capability is not reported as success. The invalid-value normalization described in ITEM 2 is the remaining honesty issue.

## 4. Comments & readability

- Bridge, adapter, coordinator, error-contract, and reconnect comments clearly document ownership and recovery boundaries.
- The `TransferLimits.normalized` comment explicitly describes converting invalid values to unlimited (`State.swift:133-135`), which conflicts with this WP acceptance rule requiring invalid values to remain invalid and surface `invalid_argument`.
- `TransferCoordinator.engineFault` accepts `operation` and `recordID` but does not use them (`TransferCoordinator.swift:874-884`); this is minor readability noise and not the blocking issue.

## 5. If changes_requested - concrete list only

1. [P1] `Native/TorrentinoIPC/State.swift:133-141`, `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:998-1029`, and `Native/TorrentinoApp/Features/InspectorView.swift:262-277` - stop coercing invalid negative, non-finite, overflow, and parse-failed limit values to unlimited/omitted values. Preserve validation failure through the command path, return the required typed invalid error, and do not persist or publish a successful snapshot for rejected input. Replace the current negative-value success tests with invalid-value rejection coverage.
2. [P1] `Native/Tests/TorrentinoEngineAgentTests/TransferSmokeTests.swift:782-863`, `Native/TorrentinoEngineBridge/bridge/bridge_smoke.cpp:249-268`, and `Native/TorrentinoEngineBridge/harness/bridge_swift_test.swift:23-66` - add a real adapter/coordinator/IPC integration test covering bandwidth success, positive ratio and seed-time `unsupported_operation`, invalid-value rejection, tracker replacement including an empty list, reannounce, and UI-visible typed errors. The current unsupported wire test injects an `EngineFault` from a stub and does not prove the actual bridge error mapping.
3. [P2] `Native/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.mm:126-139` and `Native/TorrentinoEngineBridge/bridge/EngineBridge.cpp:747-770` - reject malformed tracker payload elements and validate tracker URLs at the native boundary instead of silently dropping non-string array elements or accepting any non-empty string. Keep an explicitly empty tracker list valid and covered by a bridge-level negative/empty-list test.

--------------------------------------------------------------------------------

RESULT: CHANGES_REQUESTED
