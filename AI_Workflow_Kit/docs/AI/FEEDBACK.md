# FEEDBACK - WP-08 Native UX Re-review

Date: 2026-08-03
WP: WP-08 - Native UX completeness
Role: Verification Engineer (Code Reviewer)
Target range: torrentino/pre-WP-08..HEAD

### 1. Build & tests

- Builds/tests after changes? Yes
- Commands run:
  - `graphify query "WP-08 Native UX settings engine limits trackers notifications accessibility localization DnD Keychain performance"`
  - `xcodebuild -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64' build`
  - `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`
  - `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`
  - `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
  - `graphify update .`
- Results: Xcode build succeeded, XCTest succeeded, Swift bridge smoke succeeded, and the full QA suite is green: `97/97` scripts, including `13/13` WP-08 scripts. Swift 6 strict concurrency remains enabled with warnings as errors. The known XCTest deployment-target and AppIntents metadata warnings are non-fatal and unrelated to the changed behavior.
- Comment: The QA scripts are source-contract checks. They verify the Swift coordinator and transfer lanes, but they cannot prove operations that are absent from the linked C++ bridge binary.

### 2. WP compliance

- All requirements of current WP met? Partial; source/UI/persistence paths are implemented and verified, but the linked bridge still lacks the mandatory production methods for per-torrent limits, tracker editing, and reannounce.
- No work from future WPs? Yes; no WP-09+ product surface was added.
- target_files only? Yes for product changes. The required `FEEDBACK.md` handoff, generated Graphify output, and QA runner update are process artifacts.
- Each WP08-BUG-001..011 addressed? Partial:
  - BUG-001: URL/document open declarations, URL open handling, file URL representations, plain-text magnet trimming, and torrent-path handoff are present. Runtime drag/drop UI coverage remains source-only.
  - BUG-002: Settings now fetch the agent snapshot/revision, validate before side effects, submit `expectedRevision`, persist transactionally, apply through `EngineCoordinator`, restore persisted settings on startup, and roll back on apply failure. The older linked bridge ignores the new settings metadata fields, so full proxy/rate application is not yet effective.
  - BUG-003: Per-torrent limits are normalized, persisted, restored, sent through `TransferEngine`, and rolled back if the engine rejects them. The production `EngineCoordinator` endpoint currently reports unsupported because the linked C++ bridge has no corresponding API.
  - BUG-004: Tracker validation, persistence, cooldown, and engine routing are present with inline command errors. The linked C++ bridge still has no tracker/reannounce API, so production execution is blocked at that boundary.
  - BUG-005: Snapshot fetches and authoritative deltas now call `NotificationManager.processSnapshots`; completion, all-complete, and error transition tests pass.
  - BUG-006: Sorting, projection-based filtering, batch commands, Cmd+F first-responder focus, reconnect/sheet focus restoration, file checkbox labels, and reduce-motion handling are present.
  - BUG-007: File/Edit/Torrent/View menus and required shortcuts are present and covered by the WP-08 source contract.
  - BUG-008: Changed user-visible paths use String Catalog keys, including settings validation and command errors. Full EN/RU catalog validation passes.
  - BUG-009: Accessibility labels, increased-contrast table styling, reduce-motion transaction handling, and file/path labels are present. Runtime VoiceOver and visual gates remain outside XCTest coverage.
  - BUG-010: The app now projects/filter/sorts the same 100/500-row fixture path used by the table, with performance assertions for both sizes.
  - BUG-011: One detached async `KeychainStore` owns save/load/delete; Security attributes and negative deletion coverage pass, and no app `UserDefaults` password path exists.

### 3. Architecture invariants

- Swift 6 strict concurrency complete? Yes; build and tests pass with warnings as errors.
- No MainActor blocking ops? Yes for the changed settings path. Keychain Security I/O and torrent file reads run off the main actor; UI updates remain MainActor-isolated.
- C++ hidden behind PIMPL? Yes. Swift sees only the ObjC adapter and immutable JSON DTOs.
- DTO immutable/Sendable? Yes. `SessionProxyDTO` and `SessionConfigurationDTO` are immutable `Codable`/`Sendable` value types; proxy passwords are not included in the session DTO.
- UI not source of truth? Yes for settings and transfers. Settings are fetched from the agent revision; transfer rows are projected from authoritative snapshots/deltas.
- Legacy untouched? Yes; no Legacy/Tauri paths were changed.
- No Homebrew runtime links? Yes; full existing QA suite remains green.
- Comment: The remaining architecture gap is the linked bridge API surface, not Swift actor isolation, persistence ordering, DTO ownership, or UI state ownership.

### 4. Comments & readability

- New/modified modules retain role headers and explain the non-obvious actor, persistence, Keychain, focus, and notification boundaries.
- The standalone WP-04 Swift harness remains compatible through an immutable local wire DTO rather than importing the IPC module into the harness-only compile path.
- Comments explicitly distinguish authoritative persistence/engine paths from UI projection and fixture fallback.
- Comment: Readability is acceptable. The unsupported bridge operations are intentionally surfaced as typed errors rather than hidden behind fake success or DTO-only state.

### 5. If changes_requested - concrete list

1. [P1] `Native/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift:64-81` and `Native/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift:72-82` - extend the linked C++ `EngineBridge` and ObjC adapter with real session settings, per-torrent limits/seed goals, tracker edit, and reannounce operations. The current target-file restriction excludes `Native/TorrentinoEngineBridge/bridge/*` and `adapter/*`; without resolving that scope conflict, those commands correctly return typed unsupported errors instead of pretending to have reached libtorrent.
2. [P2] Run a macOS UI audit against the built app for drag/drop representations, VoiceOver, increased contrast, reduced motion, long Russian strings, and focus restoration. Source tests and XCTest cover the logic but not these AppKit runtime gates.

RESULT: waiting_review
