# FEEDBACK — WP-10 FIX round 2: WP10-BUG-001 fail-closed journal contract

Date: 2026-08-04
Role: Implementation Engineer (coder; fix of QA finding WP10-BUG-001)
Scope: TransferCoordinator.swift mutation/recovery paths only. All other WP-10
surface was already APPROVED and is untouched.

### 1. Build & commands

| Check | Result |
|---|---|
| `xcodebuild build` (Torrentino, macOS arm64) | ✅ BUILD SUCCEEDED |
| `xcodebuild test` full suite | ✅ TEST SUCCEEDED |
| `qa/test_wp10_fail_closed_contract.sh` | ✅ PASS — all 7 fail-closed checks |
| `qa/run_qa_suite.sh` | 111/112 — sole FAIL is `test_wp03_legacy_untouched.sh`: pre-existing Human research dirt in `Legacy/Tauri` (ADR-013 environmental waiver; per HARD BAN not read, not staged, not touched). All 8 WP-10 gates PASS. |

### 2. WP compliance (7 points from BUG_REPORT.md WP10-BUG-001)

| # | Finding | Fix | Evidence |
|---|---|---|---|
| 1 | `removalTokenCount()` failure defaulted to 0 → capacity check failed open | throwing `do/catch` in `handlePrepareRemoval`; error returns typed `persistenceFault` | `try? await persistence.removalTokenCount()` gone |
| 2 | `trashJournalEntries()` failure fabricated empty journal → zero progress | throwing `do/catch` in `handleFetchPendingRemovals`; error aborts with typed `persistenceFault` (no fabricated summary) | `try? await persistence.trashJournalEntries` gone |
| 3 | `deleteTrashJournal` / `pruneSettledRemovalTokens` used `try?` after settle → cleanup loss silently discarded | both moved into `settleRemovalEvidenceCleanup(token:)` (throwing); failure surfaces as typed fault, evidence rows kept | no `try?` left in `handleCommitRemoval` |
| 4 | `moveJournal` lookup failure treated as "no journal" → new move after failed admission | throwing `do/catch` in `handleMoveStorage`; lookup error aborts fail-closed before any mutation | `(try? await persistence.moveJournal` gone |
| 5 | move-journal deletion + force recheck used `try?` → success with stale journal / no recheck | recheck moved BEFORE the journal drop (both throwing); failures return typed `engineFault`/`persistenceFault`, row survives for convergent recovery | `try? await persistence.deleteMoveJournal` / `(try? await engine.recheck` gone |
| 6 | interrupted-move recovery ignored journal deletion failures (L284/L289) | `do/catch` in `.resume`/`.rollbackNoop`; failed drop keeps the row for the next recovery pass (convergent, idempotent) | `try? await persistence.deleteMoveJournal` gone from `recoverInterruptedMoves()` |

Convergence: a commit whose settle succeeded but cleanup failed returns a fault;
re-committing the SAME token replays the identical durable outcome and retries
the cleanup (`settleRemovalEvidenceCleanup` added to the settled-outcome replay
branch) — cleanup converges without duplicating any mutation.

### 3. Invariants

- No `try?` / fail-open default remains on the WP-10 mutation/recovery paths
  (strict static detector PASS: pending-token admission, pending-progress fetch,
  removal cleanup, move admission, move cleanup/recheck, move recovery).
- Durable token/move-journal evidence lives until cleanup/recheck is confirmed:
  failed drops keep the row; recovery or replay retries until confirmed.
- Recovery stays convergent: resumed/rolled-back/cleaned operations are
  idempotent; re-running never duplicates payload or record mutations.
- Existing failpoint machinery (`beforeTrashJournalAppend` / `beforeTrashJournalUpdate`
  / `beforeRemovalTokenSettle`) and `finishCommittedRemoval` repair untouched.
- Scope discipline: no edits outside `TransferCoordinator.swift`; no test
  expectations needed changing (all existing WP-10 XCTest behavior preserved).

### 4. Comments

- Reorder recheck-before-journal-drop in `handleMoveStorage`: the journal row is
  dropped only after durable record update AND confirmed recheck; a failed
  recheck leaves the row so recovery resumes the same move instead of
  interleaving a fresh one over the moved payload.
- Cleanup failure returns a fault even though the payload/record mutation
  already completed: the durable committed outcome makes the retry converge
  via the replay path (same pattern as the pre-existing engine-remove
  failure-after-settle handling).
- QA suite: the `test_wp03_legacy_untouched.sh` failure is environmental
  (Legacy/Tauri human research dirt, ADR-013 waiver) — no product change;
  `git` history untouched, no commits made.

──────────────────────────────────────────────────────────────────────

## RESULT: waiting_review

──────────────────────────────────────────────────────────────────────

# FEEDBACK — WP-10 FIX Review (Native macOS) — HISTORICAL (prior round, APPROVED)

Reviewer: Verification Engineer (independent review of 7758e4b, prior
CHANGES_REQUESTED baseline fac8ac5; coder self-PASS disregarded).

### 1. Build & tests

| Check | Result |
|---|---|
| `xcodebuild build` (Torrentino, macOS arm64) | ✅ BUILD SUCCEEDED (only unrelated AppIntents metadata warning) |
| `xcodebuild test` full suite | ✅ TEST SUCCEEDED — 248 tests passed, 0 failed (21 WP-10 tests green) |
| `qa/test_wp10_removal_durable.sh` | ✅ PASS (13 tests incl. all new adversarial gates) |
| `qa/test_wp10_move_recovery.sh` | ✅ PASS (5 tests incl. payload-evidence gates) |
| `qa/test_wp10_trash_only.sh` | ✅ PASS (sibling-survival assertion added) |
| `test_bridge_headless.sh` / `test_bridge_swift.sh` | ✅ PASS / PASS |
| `qa/run_qa_suite.sh` | 106/107 — sole FAIL is `test_wp03_legacy_untouched.sh`, caused by **human research dirt in the Legacy/ working tree** (uncommitted `gui.rs`, `gui.rs.fixed`, untracked `Torrentino.command`). `git diff --stat fac8ac5..HEAD -- Legacy/` is **empty** — no in-scope commit touches Legacy. Per ADR-013 review charter: ignored, not a product failure. |

### 2. WP compliance (gate table vs prior FAILs)

| # | Prior FAIL gate | Status | Evidence |
|---|---|---|---|
| 1 | No recursive trash of unlisted files; empty-dir only after children | ✅ FIXED | `TrashService.trash` runs `verifyDirectoryEmpty` (single O_NOFOLLOW descriptor: open+fstat+fdopendir/readdir) before any directory trash; leaf-first `orderedEntries()` ordering. Adversarial test `testWP10UnmanifestedSiblingSurvivesDirectoryTrash`: unmanifested sibling survives, dir refused `not_empty`, outcome `.partial`. |
| 2 | verifyChain + identity on mutation path before trash | ✅ FIXED | `verifyChain` re-checks root leaf + every component (lstat, no symlinks) immediately before the provider call; `verifyFileIdentity` opens O_NOFOLLOW and fstat-checks size + dev/ino/nlink against prepare-time `FileIdentity`. Tests: ancestor symlink swap (0 provider mutations, `unsafe_symlink`), same-size replacement (`identity_changed`), hardlink swap (`identity_changed`) — all refuse before any mutation. |
| 3 | Move recovery from fileListJSON evidence, not empty dest dir | ✅ FIXED | `MoveStorageRecovery` decodes `fileListJSON`; resume requires **every** listed file present (lstat regular file, no symlink) at destination; empty dest + intact origin → rollback-noop; split payload → guided. Tests `…DestinationWithoutPayloadIsNotResume` and `…SplitPayloadStaysGuided` prove both. |
| 4 | No `delete_files`/`files_deleted` in bridge/adapter ABI | ✅ FIXED | `delete_files` field removed from C++ `RemovalToken`/`RemovalResult`, param removed from `prepareRemoval`, `commitRemoval` passes empty `lt::remove_flags_t`; ObjC adapter drops `delete-files`/`files-deleted` JSON keys; Swift DTOs updated. `rg` confirms only comments + the **internal** agent journal column remain — never exposed through bridge/adapter public ABI. |
| 5 | Startup restore of pendingRemovalTokens; journal-aware resume; no silent half-trash auto-complete | ✅ FIXED | `restorePendingRemovalTokens()` at restore; new `fetchPendingRemovals` command (IPC #33) enumerates unsettled batches with per-batch journal progress; replayed commit loads the durable per-item journal first — `trashed`/`skippedShared` rows are never touched again; partial/failed batches keep the token **pending** (no cancellation, no outcomeJSON) for explicit user re-commit. Nothing auto-resumes. Test proves pending token survives a coordinator restart, is enumerable, and resumes to `.completed` with 0 re-trashes. |
| 6 | Fail-closed journal append/update/settle | ✅ FIXED | Every `try?` in the mutation path replaced with throwing `try` + typed persistence fault abort; new failpoints `beforeTrashJournalAppend`/`beforeTrashJournalUpdate`/`beforeRemovalTokenSettle`; settle moved **before** engine remove + record deletion (crash-safe ordering, with convergent `finishCommittedRemoval` repair). Tests: append-fail aborts with zero mutations; update-fail aborts then resumes correctly (5 journal rows); settle-fail keeps record + pending token. |
| 7 | UI surfaces RemovalBatchResult / pending removals / retry | ✅ FIXED | `TorrentListViewModel`: `lastRemovalResult`, `pendingRemovals`, `refreshPendingRemovals()` on connect/reconnect, `retryRemoval()`; `TorrentListView`: recovery banner (pending batches with Resume button + non-completed outcome text); 7 new localized strings present in `Localizable.xcstrings`. |
| 8 | Adversarial tests actually prove the above (not greps only) | ✅ PROVEN | Real filesystem adversarial setups: symlink swaps of the payload root, same-size inode replacements, hardlink swaps, unmanifested siblings, failpoint-injected journal crashes, full coordinator restart cycles — behavioral assertions on filesystem state, journal rows, token status, and provider call counts (`RecordingTrashProvider`). QA scripts run the exact tests via `-only-testing`. |

### 3. Architecture

- Layering intact: manifest/verification/trash/journal logic stays in
  EngineAgent/Transfer + Persistence; IPC gains one read-only command and one
  payload type; the bridge only **loses** surface (delete-free by construction).
- Crash-window analysis is complete and ordered: journal append → mutation →
  row update → … → settle committed → engine remove → record delete; every
  crash point is either resumable from durable evidence or convergently
  repaired (`finishCommittedRemoval`, pending-record-gone settle).
- TOCTOU residual is correctly documented: verification and the path-based
  `FileManager.trashItem` cannot be made fully atomic on macOS; the code
  closes the window as far as the platform allows (single-descriptor checks,
  O_NOFOLLOW, identity re-verification) and the manifest scope bounds worst
  case to manifest entries only.
- No dead code, no `try?` left in the removal mutation path; comments are
  precise and gate-referenced.

### 4. Comments

- `RemovalBatchResult` fabricated for the record-gone crash repair reports
  `trashedItems: 0` — acceptable as durable repair evidence (nothing left to
  remove), noted only for completeness.
- `delete_files INTEGER NOT NULL DEFAULT 0` remains in the agent-internal
  `removal_tokens` schema; it never crosses the bridge ABI and always reflects
  the IPC keep/trash semantics. No action required.
- Legacy env-suite FAIL is human research dirt (ADR-013): not a product issue.

### 5. If changes_requested — concrete file list only

N/A — no changes requested.

──────────────────────────────────────────────────────────────────────

## RESULT: APPROVED (historical — superseded by FIX round 2 above)
