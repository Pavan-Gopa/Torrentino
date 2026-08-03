# FEEDBACK - WP-08 Native UX Re-review (attempt 3)

Date: 2026-08-03
WP: WP-08 - Native UX completeness
Role: Verification Engineer (Code Reviewer)
Focus commit: bde5bb2
Target range: torrentino/pre-WP-08..HEAD

### 1. Build & tests

- Builds/tests after changes? Yes.
- Commands run:
  - `graphify query "WP-08 attempt3: SettingsView SettingsTransaction TransferCoordinator BridgeTransferEngine EngineCoordinator NotificationManager processSnapshots setLimits editTrackers reannounce KeychainStore TorrentListView focus localization"`
  - `git log --oneline torrentino/pre-WP-08..HEAD`
  - `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`
  - `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`
  - `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
- Comment: Xcode build and XCTest passed. The full QA suite passed `97/97`, including `13/13` WP-08 scripts. The first QA invocation exceeded the 120-second tool timeout; the same command was rerun with a 600-second timeout and completed green. QA and XCTest are primarily source/unit contracts and do not prove that ignored JSON settings reach libtorrent or that unsupported bridge operations are available at runtime.

### 2. WP compliance

- All WP-08 requirements met? No. Swift/UI/agent wiring is substantially improved, but Settings reports success for configuration fields that the linked bridge ignores, and the production bridge has no per-torrent limits/tracker/reannounce implementation.
- Prior P1/P2 items status:

| Item | Status | Evidence |
| --- | --- | --- |
| P1-1 Settings transaction and engine path | PARTIAL | `SettingsView` fetches settings/revision and submits `expectedRevision`; persistence, startup restore, apply, and rollback are wired. `EngineBridgeAdapter` only parses the old session fields, while `EngineBridge.cpp:56-84` ignores rates, proxy, download directory, and several toggles. `TransferCoordinator.swift:333` still uses its startup `defaultSaveLocation`. |
| P1-2 Per-torrent limits and seed goals | PARTIAL | Normalization, persistence, restore, rollback, and the `TransferEngine` call exist. `EngineCoordinator.swift:71-74` still throws unsupported because the production bridge has no method; `TransferCoordinator.swift:979-986` converts that failure to `engineBusy`. No fake snapshot success is produced, but the unsupported capability is not preserved on the wire. |
| P1-3 Tracker edit and reannounce | PARTIAL | Validation, persistence, restore, cooldown, and command routing exist. The C++ adapter/facade has no edit/reannounce API, and the Inspector has a reannounce button but no UI caller for `EditTrackersRequest`. Production execution therefore cannot complete. |
| P1-4 Notifications | PASS (source-level) | `fetchFullSnapshot` and authoritative delta application call `NotificationManager.processSnapshots`; completion, all-complete, and error transition tests pass. Runtime authorization/notification delivery still needs a macOS UI audit. |
| P1-5 Keyboard, accessibility, and focus | PARTIAL | Cmd+F, sheet focus restoration, file/path labels, contrast, and reduce-motion paths are present. `connectionGeneration` increments only in the initial `start()` path; `EngineClient` reconnects do not emit a generation change, so reconnect focus restoration is not demonstrated. |
| P1-6 Localization | PASS (source-level) | Changed UI strings use catalog lookup and validation messages are catalog keys. The full EN/RU catalog/source check passed. |
| P2-7 Drag and drop | PASS (source-level) | File URL, NSURL/Data/String representations and NSString/Data magnet text are handled; magnet text is trimmed and unsupported provider types return `false`. Runtime drag/drop behavior remains unaudited. |
| P2-8 100/500 row performance | PASS (source-level) | The table uses the pure projection/filter/sort path and XCTest measures 100 and 500 rows. Runtime Instruments/UI profiling is not included. |
| P2-9 Keychain | PASS | One `KeychainStore` owns save/load/delete and every Security call runs in a detached task; tests cover round-trip, deletion, secure attributes, and no password `UserDefaults` path. |

- Future WP creep? No product surface from WP-09+ was added.
- target_files only? Yes for product changes. The range also contains the required review artifact and `AI_Workflow_Kit/docs/AI/STATE.yaml` process synchronization; no product file outside the expanded target list was found.
- Comment: Source gates are green, but the bridge boundary prevents full WP-08 completion. A runtime VoiceOver, light/dark, increased-contrast, reduce-motion, Russian long-string, focus, and drag/drop audit is still needed even after the code changes.

### 3. Architecture invariants

Swift 6 strict concurrency builds successfully with warnings as errors. Keychain Security I/O and torrent file reads are off the MainActor; persistence is actor-isolated. C++ remains hidden behind the ObjC++ PIMPL facade, and the reviewed DTOs are immutable `Codable`/`Sendable` values. UI rows use agent snapshots rather than becoming the source of truth. Legacy paths remain untouched and the QA suite still passes the no-Homebrew/runtime checks.

The remaining invariant violation is effective engine ownership: `SessionConfigurationDTO` carries new metadata, but `EngineBridgeAdapter.mm:147-157` and `EngineBridge.cpp:56-84` do not apply it. Consequently Settings can acknowledge a persisted candidate without configuring the live session. Per-torrent rejection is not fake success at the record layer, but `unsupportedOperation` is collapsed to `engineBusy` before the IPC/UI boundary.

### 4. Comments & readability

Role headers and comments clearly describe the actor, persistence, Keychain, notification, focus, and projection boundaries. The transactional flow is readable and the source-contract tests are well named. The main readability risk is semantic overstatement: comments describe the complete settings candidate as an engine configuration while the bridge intentionally ignores several of its keys, and the UI success status does not distinguish persisted-only values from live engine values.

### 5. If changes_requested - concrete list

1. [P1] `Native/TorrentinoEngineBridge/bridge/EngineBridge.h:49-63,223-239`, `Native/TorrentinoEngineBridge/bridge/EngineBridge.cpp:56-84`, `Native/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.mm:147-157` - implement the full session-settings wire path used by `EngineCoordinator.apply`: bandwidth limits, proxy kind/host/port/username and the documented credential boundary, download directory behavior, and lsd/UPnP/NAT-PMP/encryption flags. Either verify each field reaches libtorrent with bridge tests or return an explicit typed unsupported result; do not let `SettingsView` show a successful apply for ignored fields. Also make `TransferCoordinator` use the persisted `downloadDirectory` rather than the immutable startup `defaultSaveLocation` for new torrents.
2. [P1] `Native/TorrentinoEngineBridge/bridge/EngineBridge.h/.cpp`, `Native/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.h/.mm`, `Native/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift:71-83` - add real PIMPL/ObjC++ operations for per-torrent bandwidth/ratio/seed goals, tracker replacement/edit, and reannounce, with success/error integration tests. If WP-08 intentionally closes with unsupported operations, preserve `unsupportedOperation` as an `EngineFault` through `TransferCoordinator.swift:979-986,1062-1066,1100-1107` and the UI instead of mapping it to generic `engineBusy`; the Inspector must either expose a tracker-edit command path or clearly disable that unavailable action.
3. [P2] `Native/TorrentinoApp/Features/TorrentListViewModel.swift:88-103,186-195`, `Native/TorrentinoApp/EngineClient/EngineClient.swift:275-300`, `Native/TorrentinoApp/Features/TorrentListView.swift:69-72` - emit a real connection-generation change (and re-establish the event subscription after an agent restart) on bounded reconnect/full-snapshot recovery so the existing first-responder restoration path is actually reached after reconnect.

RESULT: CHANGES_REQUESTED
