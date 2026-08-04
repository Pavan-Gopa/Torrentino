# WP-10 Verification Feedback

### 1. Build & tests

- Review range: `torrentino/pre-WP-10..HEAD`; focus commit `0725b57`.
- `git diff --stat torrentino/pre-WP-10..HEAD -- Legacy/`: empty. Legacy was not read or modified.
- `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: PASS.
- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp10_removal_durable.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp10_move_recovery.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp10_trash_only.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`: 106 PASS, 1 FAIL. The only failure is `test_wp03_legacy_untouched.sh`; per ADR-013 instructions this is environmental and is not product CHANGES_REQUESTED evidence.
- `git diff --check` for the review scope: PASS.

### 2. WP compliance

| # | Gate | Status | Evidence |
|---|---|---|---|
| 1 | File outside manifest cannot be deleted/trashed | **FAIL** | The manifest synthesizes parent directory entries (`RemovalManifest.swift:132-145`), then `TrashService` offers each directory to `FileManager.trashItem` after checking only that the directory exists (`TrashService.swift:65-72`). An unrelated file inside that directory is therefore moved with the directory although it is not a manifest entry. |
| 2 | Keep-data does not alter payload bytes | **PASS** | The agent production path uses `BridgeTransferEngine.remove` with `deleteFiles: false` (`BridgeTransferEngine.swift:104-106`), and the keep-data/Trash smoke tests pass. This does not offset the permanent-delete API finding in gate 6. |
| 3 | Failed Trash does not remove record | **PARTIAL** | Injected provider failures keep the record and pass the XCTest gate. However, journal append/update, token settlement, and journal cleanup are all best-effort (`TransferCoordinator.swift:1899-1915`, `1926-1943`, `1968-1973`, `2007-2014`), so a persistence failure after a payload mutation is not represented reliably. |
| 4 | Partial Trash has recovery/guided recovery and no silent auto-resume | **FAIL** | Startup recovery only calls `pendingMoveJournals()` (`TransferCoordinator.swift:223-274`); the available `pendingRemovalTokens()` reader is never used. A replay loops over every manifest item without consulting existing trash-journal status (`TransferCoordinator.swift:1880-1945`), so already trashed items are retried as missing instead of being resumed or surfaced through a guided recovery flow. |
| 5 | Crash during move recovers from journal plus evidence | **FAIL** | `MoveStorageRecovery.recommendation` treats destination-directory existence as sufficient evidence for resume and origin-directory existence as sufficient evidence for rollback (`MoveStorageRecovery.swift:26-56`). It never decodes or verifies `fileListJSON`; the recovery test creates the destination directory but does not materialize the destination payload (`WPSafeFileOperationsTests.swift:525-570`, `TestProfile.swift:45-49`). A crash after partial/complete engine mutation but before the stage update can therefore drop the journal or adopt an empty destination. |
| 6 | No permanent-delete API; Trash only | **FAIL** | The public native bridge still accepts `delete_files`, maps it to `lt::session_handle::delete_files`, and exposes it through the ObjC adapter (`EngineBridge.h:276-277`, `EngineBridge.cpp:1167-1175`, `EngineBridgeAdapter.mm:575-600`). The Swift agent route currently passes false, but the requested API-level prohibition is not met. |
| 7 | Shared paths, symlink/hardlink/TOCTOU safety | **FAIL** | `TrashService` does not call the existing `verifyChain`; file validation checks only leaf type and size (`RemovalManifest.swift:201-246`). The root/ancestor symlink case is therefore not protected, hardlink identity is never inspected (`LStatResult` has no inode/link-count fields, `RemovalManifest.swift:252-267`), and a same-size replacement passes the identity check. The path check is also non-atomic relative to the subsequent path-based Trash call. |
| 8 | Journal-before-mutation and idempotent commit replay | **PARTIAL** | Normal success/partial tests pass, and settled `outcome_json` can replay identically. But a failed `trashJournalAppend` becomes `seq = -1` and mutation still proceeds (`TransferCoordinator.swift:1899-1918`); ignored persistence errors and restart handling leave crash windows that are not idempotent. |
| 9 | UI is not source of truth | **PARTIAL** | Normal commit uses the durable token manifest, not UI paths. There is no startup enumeration or UI command for pending removal recovery, while `TorrentListViewModel.removeSelected` discards the batch result (`TorrentListViewModel.swift:331-355`), so durable partial-removal evidence is not surfaced to the user. |
| 10 | Swift 6, PIMPL, Sendable | **PASS** | Project build, strict-concurrency bridge script, and headless bridge script all pass. |

### 3. Architecture

1. **Blocker: directory trash is not manifest-scoped.** A parent directory is a legal manifest item, but the implementation never proves it is empty after manifest children are handled. `trashItem` on that directory can move unlisted payload/user files as a recursive unit.
2. **Blocker: the advertised TOCTOU defense is not on the mutation path.** `verifyChain` is tested but unused by `TrashService`; leaf `lstat` does not protect an ancestor swap, hardlink alias, root symlink, or same-size replacement before the path-based provider call.
3. **Blocker: move recovery is based on directory presence, not payload evidence.** The journal stores `fileListJSON`, but recovery ignores it. The prepared-stage fallback can delete a journal after a crash window in which the engine has already moved files while the origin directory still exists.
4. **High: durable failure handling is swallowed.** `try?` around journal state transitions and token settlement permits payload mutation or record removal without durable evidence. There is no startup recovery path for pending removal tokens, and the in-memory `pendingRemovalTokens` map is not restored.
5. **High: the native bridge retains a permanent deletion capability.** A safe Swift caller does not make an API safe when the adapter exposes a boolean that reaches libtorrent's permanent `delete_files` flag.
6. **Positive:** the ordinary injected-failure path, shared lexical-path case, move happy path, guided-path test, Swift 6 checks, PIMPL boundary, and bridge smoke tests are green. The missing adversarial cases are exactly the cases that determine the requested gates.

### 4. Comments

- The WP-10 XCTest/QA coverage is insufficient for an approval verdict: no extra unmanifested file inside a manifest directory, ancestor/root symlink, hardlink, same-size replacement, failed journal append/update, crash between engine mutation and stage update, or restart with a pending removal token is tested.
- The `test_wp03_legacy_untouched.sh` failure is recorded only as the instructed environmental exception; it is not used as a product finding.
- No product code was changed by this review. Only this feedback document is being overwritten.

### 5. If changes_requested — concrete file list only

- `Native/TorrentinoEngineAgent/Transfer/RemovalManifest.swift`
- `Native/TorrentinoEngineAgent/Transfer/TrashService.swift`
- `Native/TorrentinoEngineAgent/Transfer/MoveStorageRecovery.swift`
- `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift`
- `Native/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift`
- `Native/TorrentinoEngineAgent/Persistence/RemovalJournal.swift`
- `Native/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift`
- `Native/TorrentinoEngineAgent/EngineCoordinator/EngineBridgeDTOs.swift`
- `Native/TorrentinoEngineBridge/bridge/EngineBridge.h`
- `Native/TorrentinoEngineBridge/bridge/EngineBridge.cpp`
- `Native/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.h`
- `Native/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.mm`
- `Native/TorrentinoApp/Features/TorrentListViewModel.swift`
- `Native/Tests/TorrentinoEngineAgentTests/WPSafeFileOperationsTests.swift`

------------------------------------------------------------------------

RESULT: CHANGES_REQUESTED
