# WP-10 Verification Feedback

### 1. Build & tests

- Focus commits: review `fac8ac5` (changes_requested) → coder fix on top of baseline `0725b57`.
- `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: PASS.
- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: PASS (full suite green, including all WP-10 adversarial gates).
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp10_removal_durable.sh`: PASS (now runs 12 tests: durable token + exact manifest, keep-data, full commit, resumable partial, total failure, shared paths, safety validator, unmanifested sibling, ancestor symlink swap, same-size replacement, hardlink swap, journal append/update/settle failure gates).
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp10_move_recovery.sh`: PASS (now runs 7 tests, including the payload-evidence gates).
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp10_trash_only.sh`: PASS (now also asserts the unmanifested sibling survives a real Trash move).
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh`: PASS (smoke with the single-argument `prepareRemoval`, no `files_deleted`).
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/run_bridge_sanitizers.sh`: PASS (ASan/UBSan/TSan clean).
- `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`: 106 PASS, 1 FAIL. The only failure is `test_wp03_legacy_untouched.sh`; per ADR-013 instructions this is the known environmental exception (pre-existing dirty `Legacy/Tauri/**` at baseline), not product evidence. Legacy was not read or modified.
- Bridge API sweep: no `delete_files`/`files_deleted` remain in `EngineBridge.h/.cpp`, the ObjC adapter, or the Swift DTOs (only libtorrent-internal symbol names in build artifacts).

### 2. WP compliance

| # | Gate | Status | Evidence |
|---|---|---|---|
| 1 | File outside manifest cannot be deleted/trashed | **PASS** | `FileSafetyValidator.verifyDirectoryEmpty` (single `open(O_NOFOLLOW)`+`fdopendir`/`readdir` descriptor) gates every directory trash (`RemovalManifest.swift:326-349`); `TrashService.swift:87-89` refuses non-empty dirs with `not_empty`. Tests: `testWP10UnmanifestedSiblingSurvivesDirectoryTrash`, `testWP10CommitRemovalPartialFailureKeepsRecordAndJournalWithResumableReplay` (dirs fail `not_empty`), `testWP10SharedPathRemovalSkipsFilesSharedWithAnotherTorrent` (dirs holding shared data refuse). |
| 2 | Keep-data does not alter payload bytes | **PASS** | `BridgeTransferEngine.remove` never passes delete flags; keep-data/Trash smoke tests pass. |
| 3 | Failed Trash does not remove record | **PASS** | All journal append/update and token settlement paths are fail-closed with typed `EngineFault`s (`TransferCoordinator.swift` `handleCommitRemoval`); no `seq = -1` continue, no swallowed `try?` on settlement. Tests: `testWP10JournalAppendFailureAbortsBatchBeforeAnyMutation`, `testWP10JournalUpdateFailureAbortsFailClosedAndResumes`, `testWP10SettleFailureFailsClosedAndPendingTokenSurvivesRestart`. |
| 4 | Partial Trash has recovery/guided recovery and no silent auto-resume | **PASS** | `restorePendingRemovalTokens()` re-populates the in-memory map at startup (`TransferCoordinator.swift:229-247`); commit loads the durable per-item journal before mutating and resumes handled rows instead of re-trashing (`TransferCoordinator.swift` `handleCommitRemoval`); partial/failed batches stay `pending` with no outcome — explicit user re-commit only. Test: `testWP10SettleFailureFailsClosedAndPendingTokenSurvivesRestart` (restart → `fetchPendingRemovals` → explicit resume). |
| 5 | Crash during move recovers from journal plus evidence | **PASS** | `MoveStorageRecovery` decodes `fileListJSON` and requires every listed file to be a real regular file (lstat) on the destination for resume or origin for rollback; directory existence alone never counts (`MoveStorageRecovery.swift`). Tests: `testWP10MoveRecoveryDestinationWithoutPayloadIsNotResume`, `testWP10MoveRecoverySplitPayloadStaysGuided`; the original resume test now materializes the destination payload. |
| 6 | No permanent-delete API; Trash only | **PASS** | `prepareRemoval` is single-argument; `commitRemoval` uses empty `lt::remove_flags_t`; adapter JSON drops `delete-files`/`files-deleted`; `RemovalTokenDTO`/`RemovalResultDTO` dropped the fields. |
| 7 | Shared paths, symlink/hardlink/TOCTOU safety | **PASS** | `verifyChain` runs on the mutation path before every trash (`TrashService.swift:62-70`), including the root-leaf; `verifyFileIdentity` uses `open(O_RDONLY|O_NOFOLLOW)`+`fstat` with dev/inode/link-count identity captured at prepare. Tests: `testWP10AncestorSymlinkSwapRefusedBeforeAnyMutation`, `testWP10SameSizeReplacementRefusedByIdentity`, `testWP10HardlinkSwapRefusedByIdentity`, existing validator test. |
| 8 | Journal-before-mutation and idempotent commit replay | **PASS** | Append strictly precedes mutation; update failures abort; settlement is fail-closed; committed outcomes replay identically with a record-repair path for the settle→remove crash window. Tests: the three Gate 8 tests above plus `testWP10CommitRemovalPartialFailureKeepsRecordAndJournalWithResumableReplay` (replay returns identical result without re-trashing). |
| 9 | UI is not source of truth | **PASS** | New `fetchPendingRemovals` command + `PendingRemovalSummary`; startup + reconnect enumeration in `TorrentListViewModel`; `removeSelected`/`retryRemoval` surface `RemovalBatchResult` inline via `removalRecoveryBanner` (`TorrentListView.swift`) with localized strings; manifest page still served from the durable token row. |
| 10 | Swift 6, PIMPL, Sendable | **PASS** | Project build, strict-concurrency bridge script, and headless bridge script all pass. |

### 3. Architecture

1. **Manifest-scoped Trash.** Directories are trashed only when proven empty on a single O_NOFOLLOW descriptor after their manifest children were handled; unmanifested/shared siblings keep a directory untouchable (`not_empty`), which makes cross-torrent directory sharing resolve to a partial batch + pending token (guided recovery), never a recursive delete.
2. **TOCTOU defense on the mutation path.** Chain verification (root included) runs immediately before the provider call; leaf identity (dev/inode/nlink captured at prepare) is compared on the opened descriptor so same-size replacements, hardlink aliases, and ancestor/root symlink swaps are refused with typed codes (`unsafe_symlink`, `identity_changed`, `size_mismatch`, `not_empty`).
3. **Evidence-based move recovery.** `fileListJSON` is decoded and every listed path must exist at the destination (resume) or origin (rollbackNoop); split/missing payload stays guided with the journal row kept.
4. **Fail-closed durable state.** Append-before-mutation, fail-closed updates and settlement; partial/failed batches remain pending (no outcome, no cancellation) so an explicit re-commit resumes from the journal; startup restores pending tokens and a settled-committed replay repairs a record left behind by the settle→remove window.
5. **Bridge is Trash-only.** The native ABI no longer accepts delete flags at all; agent-level `deleteFiles` on `PrepareRemovalRequest`/`RemovalTokenRecord` remains only as the manifest-vs-empty (keep-data) distinction.
6. **Positive:** existing green paths (keep-data, ordinary injected failure, shared lexical paths, move happy path, guided test, Swift 6 checks, PIMPL, sanitizers, bridge smoke) all remain green alongside the new adversarial gates.

### 4. Comments

- All eight required adversarial scenarios are now covered by XCTest gates: unmanifested sibling in a manifest dir, ancestor/root symlink swap, hardlink alias, same-size replacement, failed journal append, failed journal update, crash between engine move and stage update (payload-evidence resume), and restart with a pending removal token (enumerable + resumable).
- `test_wp03_legacy_untouched.sh` failure is recorded only as the instructed environmental exception; it is not a product finding.
- The `fileListJSON` evidence rule changes one old recovery test's setup: the resume test now materializes the destination payload (the old setup — empty destination — now correctly resolves to rollback-noop/guided).
- No Legacy code was read or modified; no commit/push was made.

### 5. Files changed by the coder

- `Native/TorrentinoEngineAgent/Transfer/RemovalManifest.swift` (FileIdentity, captureIdentity, verifyChain root check, verifyFileIdentity O_NOFOLLOW, verifyDirectoryEmpty)
- `Native/TorrentinoEngineAgent/Transfer/TrashService.swift` (chain-first, identity + emptiness gates, new failure codes)
- `Native/TorrentinoEngineAgent/Transfer/MoveStorageRecovery.swift` (fileListJSON evidence)
- `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift` (fail-closed commit, journal-aware resume, pending restore, fetchPendingRemovals, move journal fail-closed)
- `Native/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift` (single-arg prepareRemoval)
- `Native/TorrentinoEngineAgent/Persistence/RemovalJournal.swift` + `FailpointInjector.swift` (failpoints 9-11)
- `Native/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift`, `EngineBridgeDTOs.swift`
- `Native/TorrentinoEngineBridge/bridge/EngineBridge.h`, `EngineBridge.cpp`, `adapter/EngineBridgeAdapter.h`, `adapter/EngineBridgeAdapter.mm`, `bridge/bridge_smoke.cpp`
- `Native/TorrentinoIPC/Commands.swift`, `IPCEnvelope.swift`
- `Native/TorrentinoApp/Features/TorrentListViewModel.swift`, `TorrentListView.swift`, `Resources/Localizable.xcstrings`
- `Native/Tests/TorrentinoEngineAgentTests/WPSafeFileOperationsTests.swift`, `Native/Tests/TorrentinoIPCTests/TorrentinoIPCTests.swift`
- QA scripts: `test_wp10_removal_durable.sh`, `test_wp10_move_recovery.sh`, `test_wp10_trash_only.sh`
- `graphify-out/` (graph update after the code changes)

------------------------------------------------------------------------

RESULT: waiting_review
