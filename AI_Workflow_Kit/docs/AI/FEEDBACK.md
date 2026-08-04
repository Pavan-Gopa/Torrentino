# WP-10 Verification Feedback

**VERDICT: WAITING_REVIEW**

### 1. Commands & results

- `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: **BUILD SUCCEEDED** (Swift 6 Complete, warnings as errors, C++17 `-Werror` behind PIMPL).
- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: **TEST SUCCEEDED** (full suite incl. 12 new WP-10 gates in `WPSafeFileOperationsTests`; schema test updated to expect v2).
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh`: **PASS**.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`: **PASS** (source list extended with the 4 new WP-10 agent files).
- `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`: **106/107 PASS**; the only failure is `test_wp03_legacy_untouched.sh` due to pre-existing untracked Human research files in `Legacy/` (ADR-013 — environmental, not fixed). New `test_wp10_removal_durable.sh`, `test_wp10_move_recovery.sh`, `test_wp10_trash_only.sh` all **PASS**.

### 2. WP-10 gate table

| # | WP-10 Gate | Status | Evidence |
|---|---|---|---|
| 1 | File outside manifest undeletable | **PASS** | Only manifest-validated relative paths (strict join of persisted saveLocation) are ever touched; `FileSafetyValidator.verifyChain` refuses any path escaping the root; `testWP10SafetyValidatorRefusesSymlinksMissingItemsAndSizeChanges`. |
| 2 | Keep-data unchanged payload | **PASS** | Shared-path protection marks every path covered by another torrent (same save location or nested root) and skips it (`testWP10SharedPathRemovalSkipsFilesSharedWithAnotherTorrent`); `test_wp10_trash_only.sh` proves the untouched control payload stays byte-identical through a real platform Trash move. |
| 3 | Failed Trash keeps record | **PASS** | `.partial`/`.failed` outcomes settle the token cancelled, keep the record, and keep the per-item journal rows as evidence (`testWP10CommitRemovalPartialFailure…`, `testWP10CommitRemovalTotalFailure…`). |
| 4 | Partial Trash → recovery or guided recovery, no silent auto-resume | **PASS** | Partial batches never auto-resume: the token is settled with the exact outcome JSON, replay returns the IDENTICAL result, and recovery is user-guided (`testWP10MoveRecoveryGuidedKeepsJournalWhenEvidenceAmbiguous`, idempotent-replay assertions). |
| 5 | Crash-during-move recovers | **PASS** | Move journal written BEFORE destination creation/engine move; stage advances only on durable evidence; restore derives resume / rollback-noop / guided from journal stage + lstat evidence (`testWP10MoveRecoveryResumesInterruptedMove`, `testWP10MoveRecoveryRollsBackNeverStartedMove`). |

### 3. Invariants

- **Trash-only, no permanent delete**: commit uses the injected `TrashProviding` (`FileManager.trashItem`) per manifest item; no delete API exists on the agent surface; engine is told to remove WITHOUT file deletion.
- **Journal-before-mutation**: a removal token row exists before any trash row; a trash row exists before its item moves; a move journal row exists before the engine move; rows of completed operations are deleted only after the record is gone or the move is durably committed.
- **Durability + idempotency**: `outcome_json` is written in the SAME update that settles the token, so a replayed commit returns the identical `RemovalBatchResult`; bounded pruning keeps 128 settled tokens.
- **TOCTOU**: every payload mutation is preceded by an lstat-based chain verification (no symlink traversal, size/kind identity checks).
- **ADR-013**: `Legacy/` untouched — not read, edited, staged, or committed.

### 4. Comments

- Fixed this session: move-journal stage updates previously targeted `seq 0` while rows auto-increment (updates silently missed the row) — `moveJournalCreate` now returns the seq; payload root corrected to the save location itself (this app's metainfo paths are relative to save path, no torrent-name prefix); duplicate pbxproj build-file IDs (`05F1`–`05F4`) colliding with app UI files resolved by renumbering the test-phase entries; `test_wp03_legacy_untouched.sh` environmental failure documented, not fixed.
- One production-facing note for the UI: guided move recovery and cancelled removal tokens surface via the next manifest/move attempt (no silent resolution) — coordinator keeps the journal row until the user resolves.
- `graphify update .` re-ran after code changes (3789 nodes).

### 5. If changes_requested — concrete file list only

N/A (awaiting review)
