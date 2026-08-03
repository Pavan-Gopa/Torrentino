# FEEDBACK - WP-08 Native UX Re-review

Date: 2026-08-03
WP: WP-08 - Native UX completeness
Role: Verification Engineer (Code Reviewer)
Target range: torrentino/pre-WP-08..HEAD

### 1. Build & tests

- Builds/tests after changes? Yes
- Commands run:
  - `git log --oneline torrentino/pre-WP-08..HEAD`
  - `git diff --stat torrentino/pre-WP-08..HEAD`
  - `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`
  - `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`
  - All 13 `Native/TorrentinoEngineBridge/scripts/qa/test_wp08_*.sh` scripts, individually
- Comment: Build and XCTest succeeded. Swift 6 strict concurrency is `complete` in `Native/Config/Shared.xcconfig:17-18`. The WP-08 scripts are source-contract checks and all pass, but they do not exercise the runtime paths below. Xcode also emits the generic AppIntents metadata warning because no AppIntents framework is linked; no changed Swift compile error was observed.

### 2. WP compliance

- All requirements of current WP met? No
- No work from future WPs? Yes; no new WP-09+ product surface was found in the target code.
- target_files only? No. The range also changes root `FEEDBACK.md` and `AI_Workflow_Kit/docs/AI/STATE.yaml`; `AI_Workflow_Kit/docs/AI/FEEDBACK.md` is the explicitly required review artifact.
- Each WP08-BUG-001..011 addressed? Partial:
  - BUG-001: Finder document/URL declarations and `onOpenURL` are present and build into the app plist. The DnD handler is not robustly verified and only accepts one concrete provider representation.
  - BUG-002: Not end-to-end. The UI does not fetch agent settings/revision, sends `expectedRevision: nil`, and the agent apply closure only updates `activeSettings`; it never applies the candidate to the engine or exercises rollback.
  - BUG-003: Not end-to-end. Limits are persisted and echoed in snapshots, but never reach the engine bridge/libtorrent.
  - BUG-004: Not fixed end-to-end. Cooldown exists, but reannounce only returns an agent-local ack; edited trackers are memory-only and are not applied to or persisted for the engine.
  - BUG-005: Not reachable. `NotificationManager.processSnapshots` has no production caller, so no completion/all-complete/error notification is queued.
  - BUG-006: Sorting, command-based batch removal, and a Cmd+F menu item exist; explicit first-responder focus and focus restoration are missing.
  - BUG-007: Edit/View menus and required shortcuts are present.
  - BUG-008: Catalog entries are complete according to the script, but several user-visible strings are raw catalog keys or hardcoded English text.
  - BUG-009: Some labels, contrast styling, and reduce-motion handling exist, but the generic file-toggle label and focus/VoiceOver runtime gates remain incomplete.
  - BUG-010: The test measures fixture generation only, not 100-500-row table/view-model rendering, filtering, and sorting.
  - BUG-011: One `Features/Settings/KeychainStore.swift` exists; SecItem save/load/delete, secure attributes, and no password `UserDefaults` path are present.
- Comment: Static checks and pure/unit tests pass, but multiple required behaviors stop at the UI or agent model boundary and are not production-effective.

### 3. Architecture invariants

- Swift 6 strict concurrency Complete? Yes for the build configuration and current build.
- No MainActor blocking ops? No. `SettingsView.loadCurrentSettings()` synchronously calls Keychain on the main actor (`Native/TorrentinoApp/Features/Settings/SettingsView.swift:263-266`), and the save/delete calls in the inherited `Task` are also on the UI actor (`:310-324`).
- C++ hidden behind PIMPL? Yes. Public Swift engine APIs expose DTOs; the adapter is private to `EngineCoordinator`.
- DTO immutable/Sendable? Yes for the reviewed IPC/transfer DTOs.
- UI not source of truth? No for settings. `SettingsView` starts with hardcoded values, never fetches the agent snapshot/revision, and can overwrite persisted settings with those values. Transfer rows otherwise render agent snapshots.
- Legacy untouched? Yes; no Legacy/Tauri paths are in the target diff.
- No Homebrew runtime links? Yes; built binary dependencies are system/static project dependencies, with no Homebrew path.
- Comment: The main architecture breach is not C++ or DTO isolation; it is that settings, limits, trackers, and notifications are not carried through their authoritative runtime lanes.

### 4. Comments & readability

- New modules/types have role header? Yes for the reviewed Swift modules.
- Non-obvious logic explained with why? Mostly yes. The comments are clear, but some now describe behavior that is not implemented: the settings transaction claims engine apply, and the limits comment claims an engine boundary while no engine API exists.
- Comment: Readability is acceptable; the missing behavior is architectural, not a naming/comment problem.

### 5. If changes_requested - concrete list

1. [P1] `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:969-1010`, `Native/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift:28-33`, `Native/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift:30-48` - make `applySettings` actually configure the engine, restore the persisted configuration on startup, and make apply failure observable so rollback is real. `SettingsView.swift:263-325` must fetch current settings/revision and submit that revision instead of assembling hardcoded defaults with `expectedRevision: nil`. Proxy kind/host/port/user fields (`SettingsView.swift:178-192`) are also never sent to the agent.
2. [P1] `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:949-967`, `Native/TorrentinoEngineAgent/Transfer/TransferRecord.swift:190-204`, `Native/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift:35-79` - add the engine/bridge path that applies bandwidth limits, `ratioLimit`, and `seedTimeSeconds`. The current handler only persists and echoes them in a DTO; the passing tests assert the same coordinator snapshot and do not prove engine application or restart round-trip.
3. [P1] `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:1013-1041` and `Native/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift:35-55` - route reannounce to the engine after cooldown, validate/edit trackers through the engine, and persist edits. Current `editTrackers` mutates only the in-memory record, so edits disappear after restart; `reannounce` acknowledges without sending a tracker command. `TorrentListViewModel.swift:323-326` also swallows rate-limit/engine errors instead of exposing inline feedback.
4. [P1] `Native/TorrentinoApp/App/NotificationManager.swift:81-124` and `Native/TorrentinoApp/Features/TorrentListViewModel.swift:125-184` - connect authoritative snapshots/deltas to `NotificationManager.processSnapshots`. At present the only calls to the transition tracker are tests; authorization is requested, but no production path can enqueue completion, all-complete, or error notifications.
5. [P1] `Native/TorrentinoApp/Features/TorrentListView.swift:62-64,456-462` and `Native/TorrentinoApp/Features/InspectorView.swift:165-172` - complete the keyboard/VoiceOver contract: Cmd+F must make the search field first responder, restore focus after sheet/reconnect, and give each file checkbox a label containing its file/path. The reannounce hint is currently used as the accessibility label. These gates are not covered by a UI audit.
6. [P1] `Native/TorrentinoApp/Features/TorrentListViewModel.swift:95,114,191,204,213,242,303,370` and `Native/TorrentinoApp/Features/TorrentListView.swift:278-283` - localize connection/error notes with `String(localized:)` instead of rendering catalog keys such as `fixture.note` and `add.failed`. `Settings.swift:81-91` returns English validation messages that `SettingsView.swift:161-162,237-239` displays verbatim in Russian. The catalog file can be complete while the UI still shows keys/English text.
7. [P2] `Native/TorrentinoApp/Features/TorrentListView.swift:320-340` - handle all valid `NSItemProvider` URL/text representations, trim dropped magnet text, and return `false` when no accepted item was actually handled. The current handler returns `true` for every drop but only decodes `Data` for file URLs and `String` for plain text.
8. [P2] `Native/Tests/TorrentinoAppTests/TorrentinoAppTests.swift:277-283` and `Native/TorrentinoApp/Features/TorrentListViewModel.swift:94-98` - add a performance/UI-path test for 100 and 500 rows through the list projection/filter/sort path, and add evidence for Russian long-string layout, light/dark/increased-contrast/reduce-motion, VoiceOver, and focus restoration. The current performance test only constructs arrays; the degraded production path always constructs 100 rows.
9. [P2] `Native/TorrentinoApp/Features/Settings/SettingsView.swift:263-266,310-324` - move synchronous Keychain load/save/delete off the MainActor while preserving the single `KeychainStore` path. The current implementation is functionally secure but violates the no-I/O-on-main-actor invariant.

RESULT: CHANGES_REQUESTED
