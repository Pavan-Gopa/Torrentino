# FEEDBACK - WP-08 Narrowed Bridge Completion Coder Handoff

Date: 2026-08-03
WP: WP-08 - narrowed bridge completion round
Role: Implementation Engineer (coder handoff)
Scope: FEEDBACK attempt 3 items 1-3 only

## 1. Build & tests

- Commands run:
  - `graphify query "WP-08 attempt3: SettingsView SettingsTransaction TransferCoordinator BridgeTransferEngine EngineCoordinator NotificationManager processSnapshots setLimits editTrackers reannounce KeychainStore TorrentListView focus localization"`
  - `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`
  - `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`
  - `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh`
  - `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`
  - `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
  - `graphify update .`
- Results:
  - Xcode build: `BUILD SUCCEEDED`.
  - XCTest: `TEST SUCCEEDED`, including `testUnsupportedEngineOperationRemainsTypedOnWire`.
  - Headless bridge smoke: `PASS`.
  - Swift ObjC++/C++ bridge harness: `PASS`.
  - QA: `97/97 PASS`, `SUITE RESULT: GREEN`, including `13/13` WP-08 scripts.
  - Graphify: updated successfully to `3301 nodes`, `7644 edges`, `277 communities`.
- Graphify emitted a non-blocking warning that `acl-manifests.json` and `capabilities.json` produced zero AST nodes; they remain absent from the graph.

## 2. WP compliance

| Scope item | Status | Implementation evidence |
| --- | --- | --- |
| Session settings wire path | REAL | `EngineBridgeAdapter.mm` decodes all new configuration keys. `EngineBridge.cpp:make_settings` applies listen port, peer prefix, DHT/LSD/UPnP/NAT-PMP, encryption policy, connection/rate limits, proxy kind/host/port/username, and clears the unavailable password slot. |
| Live settings apply | REAL | `EngineBridge::apply` calls `session.apply_settings` without dropping torrent handles, updates operation timeout and the default add directory. |
| Download directory for new torrents | REAL | Empty add paths use the bridge default; `TransferCoordinator.configuredSaveLocation()` reads persisted `activeSettings.downloadDirectory` instead of only `defaultSaveLocation`. |
| Per-torrent bandwidth limits | REAL | `EngineBridge::setLimits` validates bounds and calls `torrent_handle.set_download_limit` / `set_upload_limit`; nil or non-positive values map to unlimited. |
| Per-torrent ratio and seed-time goals | TYPED UNSUPPORTED | Positive goals return `BridgeError::unsupported_operation` because libtorrent ABI 2 exposes no matching handle setters. Invalid negative/non-finite values return `invalid_argument`; zero goals can clear the value. |
| Tracker replacement | REAL | `EngineBridge::editTrackers` validates URLs and calls `torrent_handle.replace_trackers`, including an empty list. |
| Reannounce | REAL | `EngineBridge::reannounce` calls `force_reannounce(0, high_priority)`. |
| Unsupported error honesty | REAL | Bridge code 10 maps to `EngineCoordinatorError.unsupportedOperation`, then `BridgeTransferEngine` creates `EngineFault.unsupportedOperation`; `TransferCoordinator` preserves that fault instead of collapsing it to `engineBusy`. |
| Tracker UI command path | REAL | `InspectorView` provides tracker URL add/remove controls through `TorrentListViewModel.editTrackers`, with localized labels and error handling. |
| Reconnect recovery | REAL | `EngineClient` reconnects with bounded retry, restores the event subscription before the request, then invokes the reconnect handler. `TorrentListViewModel` fetches an authoritative full snapshot and increments `connectionGeneration`, which drives focus restoration. |

- No WP-09+ product surface was added.
- Product edits stayed within the target file list; this handoff is the required process artifact.
- No commit or push was performed.

## 3. Architecture invariants

- Swift 6 strict concurrency remains enabled with warnings as errors; build and test pass.
- C++ remains behind the ObjC++ adapter and PIMPL; no libtorrent, Boost, OpenSSL, or C++ types cross into Swift.
- Bridge DTOs are immutable `Codable`/`Sendable` values; the standalone Swift harness remains compilable without `TorrentinoIPC` through conditional compilation of the IPC-only payload.
- Settings apply is live and does not restart or drop torrent handles.
- Proxy passwords never cross the Swift/XPC boundary; the bridge explicitly clears the unavailable password field.
- Torrent file reads and Keychain I/O remain off the MainActor; persistence stays actor-isolated.
- UI state remains a projection of authoritative agent snapshots.
- Legacy/Tauri paths are untouched; no Homebrew/runtime gate regressions were reported by QA.

## 4. Comments & readability

- Added role/invariant comments at the bridge, adapter, coordinator, reconnect, tracker, and error-contract boundaries.
- Comments document why proxy passwords are not forwarded, why ratio/seed goals are typed unsupported, why live apply preserves handles, and why reconnect requires a full snapshot.
- The only notable graphify follow-up is the existing zero-node warning for two JSON manifests; it does not affect source build or runtime verification.

RESULT: waiting_review
