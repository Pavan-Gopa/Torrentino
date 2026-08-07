# BUG REPORT — WP13-BUG-010 log quality: idle DEBUG spam + empty libtorrent alert fields

Date: 2026-08-07
Role: Orchestrator record (live log forensics)
Scope: Native/TorrentinoEngineAgent (bridge alert drain loop, alert mapping)
Verdict: **OPEN — assigned to Coder**

## Evidence (engine_log_current.log, live session pid 74364)

- `bridge alerts drained count=0` at ~2 Hz while idle (208 lines in a short
  session) — floods the redacted log and buries command/state signal.
- `[ERROR] libtorrent alert kind=session/unknown torrent= error=` — alert
  kind and message not captured (empty fields), so real libtorrent errors
  are unreadable; defeats BUG-007 observability purpose.

## Required product-side follow-up

- Log drain only when count > 0 (or rate-limit/trace-level); idle ticks must
  be silent.
- Map libtorrent alert type name + message + severity into the redacted
  record (redact paths/tokens inside messages); ERROR-level alerts must
  carry actionable text.
- QA: observability matrix asserts absence of count=0 spam and presence of
  non-empty alert kind/message for a forced libtorrent alert.

---

# BUG REPORT — WP13-BUG-009 app-side add flow never reaches XPC after round-3 refactor

Date: 2026-08-07
Role: Orchestrator record (live log forensics + Human report)
Scope: Native/TorrentinoApp (AddTorrentSheet picker-mode refactor, commit path)
Verdict: **OPEN — assigned to Coder**

## Evidence

- Human: local .torrent files still "just don't get added" on the fresh
  round-3 build.
- Agent log, live session (bootstrap 05:28:25Z pid 74364): fetchSnapshot /
  fetchPendingRemovals / health present, but ZERO inspectAddSource or
  commitAdd entries after bootstrap. Last add commands in the log (04:52Z)
  are QA fixtures. => the add flow dies inside the app before XPC.
- Round 3 replaced two .fileImporter modifiers with one mode-driven
  importer (AddTorrentPickerMode); suspicion: picker result -> fileURL /
  scheduleInspection / commit wiring broken, canCommit never true, or
  security-scoped read fails silently so inspection never schedules.

## Required product-side follow-up

- Trace and fix the app-side chain: picker result => fileURL set =>
  security-scoped read of .torrent bytes => inspectAddSource => preflight
  render => Add enabled => commitAdd. Every failure branch must surface a
  localized error (no silent death).
- Add app-side logging (redacted client facade) for picker result,
  inspection schedule/finish, commit attempt/fault so the next failure is
  visible in ~/Library/Logs.
- Acceptance: real GUI run — Choose File... -> select local .torrent ->
  preflight visible -> Add -> record appears and transitions per desired
  state (or actionable localized fault, e.g. insufficientSpace with
  destination change). Magnet path regression green.

---

# BUG REPORT — WP13-BUG-008 Add sheet: "Choose File..." never opens a picker

Date: 2026-08-07
Role: Orchestrator record (Human manual verification run, annotated screenshot)
Scope: Native/TorrentinoApp/Features/AddTorrentSheet.swift
Verdict: **OPEN — assigned to Coder**

## Reproduction

1. Cmd+N (Add Torrent sheet).
2. Click "Choose File..." — nothing opens; a local .torrent cannot be added
   through the UI. (Magnet/URL text path and Destination button exist; the
   file path of the add flow is unusable.)

## Suspected root cause (verify)

- `AddTorrentSheet.swift` attaches TWO `.fileImporter` modifiers to the same
  view node (L116 for the .torrent file, L130 for the destination folder).
  Stacked `fileImporter` modifiers conflict in SwiftUI — one (or neither)
  presents; `pickingFile = true` produces no panel.

## Required product-side follow-up

- Rework to a single presentation source (e.g. one `.fileImporter` driven by
  a picker-mode enum, or attach importers on disjoint subviews) so BOTH
  pickers reliably present in the real GUI.
- On .torrent pick: set fileURL, clear URL text, run inspectAddSource
  preflight (required/available bytes render), commit path unchanged.
- On folder pick: destination updates and re-preflights (existing behavior
  preserved).
- Localized failure strings retained (pick_failed / destination_failed).
- Acceptance: real-GUI run — "Choose File..." opens the panel, selecting a
  local .torrent populates the sheet and shows preflight; "Destination..."
  opens the folder panel; scripted UI-level or integration test where
  feasible; add-flow regressions (preflight insufficientSpace, duplicateAdd)
  stay green.

---

# BUG REPORT — WP13-BUG-007 observability blind: command/transfer paths never logged

Date: 2026-08-06
Role: Orchestrator record (Human manual verification run + log forensics)
Scope: Native/TorrentinoEngineAgent (DiagnosticsLogging wiring),
Native/TorrentinoApp (EngineClient logging)
Verdict: **OPEN — assigned to Coder**

## Evidence

- `~/Library/Logs/com.torrentino.app.engine-agent/engine_log_current.log`
  contains ONLY `[xpc] Exported diagnostic bundle` entries (all from QA test
  runs); zero entries for add/remove/fetchFiles/setFileSelection/transfer/
  lifecycle during real Human sessions.
- `log show --last 2h --predicate 'process == "TorrentinoEngineAgent" OR
  process == "Torrentino"'` => empty.
- Human explicitly requested a logging system to trace "where the connection
  is missing and who is at fault"; current logs cannot answer that.

## Required product-side follow-up

Wire TorrentinoLog (redacted) into every XPC command handler (add/commit,
remove/prepareRemoval, fetchFiles, setFileSelection, pause/resume, reannounce),
transfer state transitions (desired vs activity vs health changes, libtorrent
error alerts with redacted paths), persistence checkpoints, and XPC
connect/peer-verification events on both sides. Levels: lifecycle/state
transitions and faults at notice/error; per-command at info. Keep redaction
(home paths, tokens, passkeys). Add a QA script asserting the log file gains
entries for each command class during a scripted session (redaction checked).

---

# BUG REPORT — WP13-BUG-006 phantom duplicate row: UI not engine-authoritative on add

Date: 2026-08-06
Role: Orchestrator record (Human manual verification run + persistence read)
Scope: Native/TorrentinoApp (TorrentListViewModel add/snapshot merge),
Native/TorrentinoEngineAgent (commitAdd duplicate info_hash handling)
Verdict: **OPEN — assigned to Coder**

## Evidence

- UI shows TWO rows "Шугар (Sugar) Сезон 2"; engine DB (`torrents` table)
  contains ONE record (id FB74E629-9721-4F73-A394-992F61DC9DE1).
- Second add of the same info_hash produced an in-memory UI row although the
  engine did not admit a second record (duplicate rejection or persistence
  collision), i.e. UI projected a non-authoritative row.

## Required product-side follow-up

- Engine: duplicate info_hash add must return a typed, localized fault
  (e.g. torrentAlreadyExists) or explicit idempotent attach semantics — one
  documented behavior.
- UI: never insert rows optimistically; the list is rebuilt from engine
  snapshot/events only; on duplicate fault show a localized banner, no
  phantom row. Regression test: add same torrent twice => one row + message.

---

# BUG REPORT — WP13-BUG-005 Remove failed for faulted record; user cannot delete

Date: 2026-08-06
Role: Orchestrator record (Human manual verification run)
Scope: Native/TorrentinoEngineAgent (prepareRemoval/removal manifest path),
Native/TorrentinoApp (remove flow projection)
Verdict: **OPEN — assigned to Coder**

## Evidence

- Human: status bar shows "Remove failed" when removing the stuck
  "Insufficient disk space" record; the row remains.
- Record state in DB: desired `running`, libtorrent storage-faulted; removal
  of a never-started/faulted record must still work (WP-10 contract: removal
  is a first-class, recoverable flow for ANY record state).

## Required product-side follow-up

- Diagnose via new logs (BUG-007) + journal tables (operation_journal,
  removal_tokens, trash_journal) why prepareRemoval/confirm fails for
  faulted/never-admitted records; fix so removal succeeds from every state
  (no files on disk => manifest trivially empty, keep-data and delete-data
  both work). Localized actionable error only for genuine persistence faults.
- Acceptance: remove the Human's stuck record successfully (keep-data), and
  scripted removal of faulted/paused/downloading records in tests.

---

# BUG REPORT — WP13-BUG-004 no add-time preflight: 25.38 GB admitted onto 15 GB volume

Date: 2026-08-06
Role: Orchestrator record (Human manual verification run + df forensics)
Scope: Native/TorrentinoEngineAgent (inspectAddSource/commitAdd preflight),
Native/TorrentinoApp (add sheet UX)
Verdict: **OPEN — assigned to Coder**

## Evidence

- `df -h /`: 15 Gi available on the destination volume; torrent size
  25.38 GB; save_path `/Users/pavan/Downloads` (same volume).
- Record admitted with desired=running, then latched into
  "Insufficient disk space" fault; download can never start. Plan acceptance:
  "Add magnet/file/URL + preflight ... работают".

## Required product-side follow-up

- inspectAddSource/commitAdd preflight: compute required size (total or
  selected files) vs available space on the resolved destination volume;
  fail closed BEFORE record admission with a localized, actionable fault
  (needed vs free, suggestion to pick another destination).
- Add sheet: show destination volume free space + required size live; allow
  choosing another destination before commit; after a storage fault, offer
  "change destination & retry" recovery in the Inspector banner.
- Acceptance: adding an oversized torrent is refused at add time with the
  actionable message; after freeing space or changing destination, retry
  succeeds; existing faulted record recovery path works.

---

# BUG REPORT — WP13-BUG-003 (REOPENED) Inspector still shows "No files" in real run

Date: 2026-08-06 (reopen addendum; original block below)
Role: Orchestrator record (Human manual verification run)
Verdict: **REOPENED — assigned to Coder (fix round 2)**

## Reopen evidence

- Human's record has metainfo persisted on disk
  (`.../Engine/generations/metainfo-FB74E629-...-2.bin`), yet the Inspector
  Files area shows "No files" for the selected/only record in a real GUI
  session on the fresh build that contained the round-1 fix.
- Round-1 fix verified by Reviewer via code paths and scripted tests, but the
  real-GUI scenario (faulted record, selected row) was not proven.

## Required product-side follow-up

- Trace fetchFiles for a faulted, metainfo-present record end-to-end (agent
  handler source = metainfo regardless of activity/health; UI must request on
  selection change and render; empty state only for genuinely no-metainfo
  magnets pre-metadata, with a localized "metadata not fetched yet" hint).
- Distinguish "no selection" hint from "no files" empty state.
- Acceptance: real run — select the Human-like faulted record => file tree
  with checkboxes appears; unchecking a file persists and is honored.

---

# BUG REPORT — WP13-BUG-003 Inspector "No files"; per-file selection missing end-to-end

Date: 2026-08-06
Role: Orchestrator record (Human manual verification run)
Scope: Native/TorrentinoApp (Inspector Files tab), Native/TorrentinoEngineAgent
(fetchFiles/setFileSelection chain), Native/TorrentinoIPC
Verdict: **OPEN — assigned to Coder**

## Reproduction

1. Add a multi-file torrent (Human added "Шугар (Sugar) Сезон 2", 25.38 GB).
2. Select the row, open Inspector (Cmd+I), Files tab.
3. Observed: "No files" empty state; no outline tree, no checkboxes.

## Contract (plan, authoritative)

- §7.4 XPC v1: `fetchFiles(recordID:cursor:pageSize:expectedRevision:)`;
  `setFileSelection` — only `skip | normal` in 1.0.
- Inspector UI: "Files: outline tree, tri-state selection, progress, Reveal".
- Acceptance: "Add magnet/file/URL + preflight/file selection работают".
- Persistence: selected/skipped file selection is durable; checkpoint after
  file selection change (§9.4).

## Observed vs expected

- IPC types exist (`FetchFilesRequest`, `SetFileSelectionRequest`, command
  cases in Commands.swift); engine/agent chain and UI wiring are incomplete
  or broken — Coder must trace end-to-end (agent file source from metainfo,
  paging, revision checks, UI outline tree with tri-state checkboxes for
  folder aggregation mapped to skip|normal on leaves, progress per file,
  Reveal, localization EN/RU) and complete it.
- Expected: files listed from metainfo regardless of download state; user can
  uncheck individual episodes; selection persists and is honored by the
  engine (skip|normal); Reveal works.

---

# BUG REPORT — WP13-BUG-002 added torrent stays Idle with fault warning; never starts

Date: 2026-08-06
Role: Orchestrator record (Human manual verification run)
Scope: Native/TorrentinoEngineAgent (desired-state enforcement, add flow),
Native/TorrentinoApp (state/fault projection)
Verdict: **OPEN — assigned to Coder**

## Reproduction

1. With engine operational, add a torrent (Human: magnet/file add of a
   25.38 GB multi-file torrent).
2. Row shows State "Idle", warning icon, Down/Up Zero KB/s indefinitely;
   download never starts.

## Observed vs expected

- Observed: record admitted but desired_state=running not enforced, or a
  fault latched without user-visible localized reason (warning icon with no
  actionable message).
- Expected: added torrent with start intent transitions to Downloading (or
  shows a localized, actionable fault with recovery per ErrorContract;
  offline/partial states preserve desired state per plan §fault recovery).
- Coder must diagnose with real evidence: agent OSLog
  (subsystem com.torrentino.app.engine-agent), persisted `last error code`,
  libtorrent alert path for the Human's stuck record; then fix root cause.
  Do not corrupt or delete the Human's existing record/data.

---

# BUG REPORT — WP13-BUG-001 stale engine-service status; no live re-poll/reconnect

Date: 2026-08-06
Role: Orchestrator record (Human manual verification run)
Scope: Native/TorrentinoApp lifecycle/status projection (EngineViewModel,
ContentView, TorrentListViewModel start, EngineClient reconnect)
Verdict: **OPEN — assigned to Coder**

## Reproduction

1. `Torrentino --cli unregister` (agent not registered).
2. `open Torrentino.app` → banner "Engine service is unavailable ·
   notRegistered", empty transfer list.
3. Externally: `Torrentino --cli register` → launchd spawns the agent;
   `Torrentino --cli status` => `STATE operational`.
4. The already-running app keeps the `notRegistered` banner and the empty
   list indefinitely; only a full app restart recovers it.

## Observed vs expected

- Observed root cause (verify): SMAppService status is sampled once via
  `ContentView.swift` `.task { viewModel.refreshServiceStatus() }`; there is
  no re-poll on app activation and no bounded periodic refresh while
  degraded; `transfers.start()` failure at launch is not retried once the
  engine becomes reachable, so the event subscription/list never recovers
  without restart.
- Expected: a running app detects engine availability without restart —
  refresh on `NSApplication.didBecomeActiveNotification` + bounded polling
  while degraded (a few seconds) + retry of `start()`/event subscription when
  the engine becomes reachable; the degraded banner clears and the list
  populates. Degraded state must never be silent (existing contract).

## Required product-side follow-up

Implement live status recovery in the UI layer without auto-registering the
agent (ServiceRegistration must-not stands: no registration without explicit
user intent). No launchd/XPC IO on the main actor. Add regression coverage
(XCTest via an injectable status/connection seam and/or QA script). QA does
not apply the fix; Tester will verify closure after Coder + Reviewer.

---

## WP-13 QA Closure Attempt — 2026-08-06

Command: `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp13_bug_closure.sh`

Result: **FAIL — no Human bug closed**.

- Disposable regression evidence passed: `7/7` targeted tests, including
  `testCommitAddImmediateStartRunningNotIdle`,
  `testMultiFileRunningDesiredStateAndOfflineRecovery`, file paging, selection
  round-trip, restart durability, and EN/RU health messages.
- WP13-BUG-001 remains open. The conditional seam
  `testEngineViewModelStatusRefreshAndReconnect` exists, but live launchd
  lifecycle was not run. Enabling the seam in the current target graph produced
  `warning: TorrentinoAppTests is missing a dependency on Torrentino` and
  `Linker command failed with exit code 1`.
- WP13-BUG-002 remains open. Stub-engine desired-state/offline tests pass, but
  they do not prove the Human record against live libtorrent.
- WP13-BUG-003 remains open. Persistence and paging tests pass, but
  `TransferEngine` has no live file-selection/priority method in
  `Native/TorrentinoEngineAgent/Transfer/TransferRecord.swift:194-228`, and
  `FileEntry` has no per-file progress field in
  `Native/TorrentinoIPC/Pagination.swift:65-80`. The current agent handler at
  `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:897-925`
  persists selection and publishes invalidation only.

No `--cli register` or `--cli unregister` command was executed. The Human's
`"Шугар (Sugar) Сезон 2"` record, production Application Support, and download
payload were not modified.

---

# BUG REPORT — WP-11 Torrent Creator CPU Reference & Structured Tracker Topology

Date: 2026-08-06
Role: Test Engineer (functional QA; test code and defect detection only)
Scope: WP-11 Torrent Creator CPU Reference & Structured Tracker Topology (ADR-016 / ADR-017)
Verdict: **NO PRODUCT BUGS DETECTED**

## Summary

The WP-11 product implementation is fully compliant with ADR-016 and ADR-017. All 287 XCTest cases and 111 out of 112 QA scripts pass (the only non-passing script is the pre-existing environmental `test_wp03_legacy_untouched.sh` waived per ADR-013).

No product bugs were found this cycle.

# BUG REPORT - WP-10 Safe File Operations (WP10-BUG-001 closed)

Date: 2026-08-04
Role: Test Engineer (functional QA; test code and defect detection only)
Scope: fix 0ec428f / safe file operations and recovery
Verdict: CLOSED - WP10-BUG-001 not reproduced after fix

## Closure Addendum

The mandatory `test_wp10_fail_closed_contract.sh` now passes. Full scheme
XCTest is **257/257 PASS**, all **8/8** WP-10 QA scripts pass, and the new
runtime tests confirm fail-closed admission, move recheck, and move-journal
cleanup behavior. No current product bug was found in this re-run.

The original FAIL record below is retained as historical evidence from before
commit `0ec428f`; its seven ignored-error findings are superseded by the fix.

## Historical FAIL Record

## Executive Summary

The WP-10 runtime behavior is green across 25 XCTest cases and the full
scheme is green at 252/252. The delete-free native bridge, manifest-scoped
Trash, TOCTOU refusals, move evidence recovery, pending-removal IPC/UI
contracts, and all WP-10 gates except fail-closed journal handling pass.

The new `test_wp10_fail_closed_contract.sh` detects seven ignored errors on
mutation/recovery paths. This is a product finding, not a Legacy waiver. QA
did not modify product code.

| Layer | Result |
| --- | --- |
| WP-10 XCTest | 25/25 PASS |
| WP-10 QA scripts | 7/8 PASS; fail-closed contract FAIL |
| Full QA suite | 110/112 PASS; fail-closed FAIL + Legacy environmental FAIL |
| Full `xcodebuild test` | 252/252 PASS |
| Direct headless bridge | PASS |
| Direct Swift bridge | PASS |
| Product changes by QA | none |

## Findings

### WP10-BUG-001 - Mutation/recovery paths ignore throwing failures (P1)

Detected by: `test_wp10_fail_closed_contract.sh`.

Evidence in `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift`:

- Line 1776: `removalTokenCount()` failure defaults to `0`, so the pending
  token capacity check can fail open.
- Line 1888: `trashJournalEntries()` failure defaults to an empty journal, so
  `fetchPendingRemovals` can report fabricated zero progress instead of a
  typed persistence fault.
- Lines 2181-2182: `deleteTrashJournal` and
  `pruneSettledRemovalTokens` use `try?` after record removal. Cleanup failure
  is silently discarded, losing durable recovery evidence while the command
  can still report success.
- Line 2251: `moveJournal` lookup failure is treated as if no journal exists,
  allowing a new move to proceed after a failed durable admission check.
- Lines 2358 and 2361: move-journal deletion and the force recheck use `try?`,
  so a successful-looking move can return with stale journal state or without
  the required recheck.
- Lines 284 and 289: interrupted-move recovery also ignores journal deletion
  failures.

Impact: a persistence or engine failure can leave the durable journal,
in-memory record, and reported command outcome inconsistent. This contradicts
the WP-10 fail-closed requirement that mutation-path persistence calls use
throwing handling and that recovery remain convergent.

Reproduction:

```text
bash Native/TorrentinoEngineBridge/scripts/qa/test_wp10_fail_closed_contract.sh
```

Observed failures:

- pending token limit defaults open on persistence failure
- pending progress defaults to fabricated zero evidence
- removal journal cleanup failure is ignored
- settled token prune failure is ignored
- move admission journal lookup failure is ignored
- successful move journal deletion failure is ignored
- move recheck failure is ignored

Required product-side follow-up: replace these `try?` mutation/recovery paths
with explicit throwing/error-return handling, preserving the durable token or
move journal until cleanup/recheck is known to have completed. QA does not
apply that fix.

## WP-10 Gate Matrix

| Gate | Evidence | Result |
| --- | --- | --- |
| File outside manifest cannot be removed | `testWP10UnmanifestedSiblingSurvivesDirectoryTrash`; manifest safety contract | PASS |
| Keep-data leaves payload unchanged | `testWP10KeepDataRemovalLeavesPayloadByteIdentical` | PASS |
| Failed Trash keeps the record | partial/total failure XCTest cases | PASS |
| Partial Trash remains recoverable/guided | journal replay + pending restore XCTest cases | PASS |
| Move crash recovery | resume, rollback-noop, empty destination, split payload, symlink evidence cases | PASS |
| No permanent delete API | `test_wp10_delete_free_abi.sh`; bridge runners | PASS |
| Fail-closed journals | `test_wp10_fail_closed_contract.sh` | FAIL |

## Feature Coverage

| Feature | Dedicated evidence | Result |
| --- | --- | --- |
| Manifest-scoped directory Trash and leaf-first order | `test_wp10_manifest_safety_contract.sh` + runtime sibling/order cases | PASS |
| TOCTOU chain and file identity refusal | symlink, same-size replacement, hardlink swap XCTest cases | PASS |
| `fileListJSON` move recovery evidence | `test_wp10_move_recovery.sh` and 8 move XCTest cases | PASS |
| Delete-free bridge/adapter ABI | `test_wp10_delete_free_abi.sh` + direct bridge runners | PASS |
| Pending token restore and read-only IPC | restart/no-auto-resume XCTest + UI contract | PASS |
| Fail-closed journals and convergent settle repair | 3 failpoint cases + repair XCTest + strict static detector | FAIL |
| UI result/pending/retry/banner/localization | `test_wp10_ui_recovery_contract.sh` | PASS (source contract) |
| WP-10 XCTest inventory | `test_wp10_test_inventory.sh` | PASS, 25 methods |

## Environmental Waiver

`test_wp03_legacy_untouched.sh` reports pre-existing Human research changes in
`Legacy/Tauri`: tracked `README.md`, `Cargo.lock`, `Cargo.toml`, `engine.rs`,
`gui.rs`, `gui.rs.fixed`, `app.js`, `styles.css`, and untracked
`Torrentino.command`, `build-macos.sh`, `run-dev.sh`.

Per ADR-013, QA did not read, edit, restore, stage, or commit any
`Legacy/Tauri/` path. This failure is environmental and does not change the
WP-10 functional finding above.

## Verification Commands

- `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh` -> 110/112;
  two failures listed above.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh` -> PASS.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh` -> PASS.
- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'` -> 252/252 PASS.

No product fix, git commit, or git push was performed.

---

# BUG REPORT - WP-08 Native UX Completeness (historical record)

Date: 2026-08-04
Role: Test Engineer (detect and report only)
Verdict: NO CURRENT PRODUCT BUGS; historical findings superseded

The current WP-08 run is PRODUCT GREEN. All 16 WP-08 scripts, the full scheme
XCTest run (201/201), and both bridge runners pass. The only full-suite failure
is the environmental `test_wp03_legacy_untouched.sh` check caused by Human
research dirt in `Legacy/Tauri`; it is waived and was not touched by QA.

The findings below are retained for traceability from the 2026-08-03 run and
are not current defects.

## Historical Findings (Superseded)

## Execution Summary

| Layer | Result |
| --- | --- |
| WP-01..WP-07 regression | 84/84 PASS |
| WP-08 new QA scripts | 1/13 PASS, 12/13 FAIL |
| `xcodebuild build` | BUILD SUCCEEDED |
| Full `xcodebuild test` | TEST SUCCEEDED |
| Product changes made by QA | None |

The regression suite remains green. The WP-08 gate is red because the new
feature checks detect missing behavior and missing test coverage.

## Findings

### WP08-BUG-001 - Finder associations are absent (P1)

Detected by: `test_wp08_dnd_association.sh`

Evidence:

- `Native/Torrentino.xcodeproj/project.pbxproj:1171,1196` uses generated Info.plist.
- The project has no `CFBundleDocumentTypes` or `CFBundleURLTypes` entries.
- `TorrentinoApp.swift:21,100-109` has `.onOpenURL`, but the OS has no declared
  `.torrent` document type or `magnet` URL scheme to route into it.

Impact: Finder open and external magnet URL delivery are not registered even
though the Swift handler exists.

### WP08-BUG-002 - Settings UI and agent bypass SettingsTransaction (P1)

Detected by: `test_wp08_settings_transaction.sh`,
`test_wp08_settings_sections.sh`

Evidence:

- `SettingsView.swift:262-308` calls `SettingsRules.validate` and then sends
  `applySettings` directly; it never calls `SettingsTransaction.run`.
- `TransferCoordinator.swift:923-945` directly writes the candidate and
  revision. There is no rollback if the second persistence write fails.
- `Settings.swift:77-90` validates only download directory and bandwidth
  limits; `listenPort` is not validated.
- `SettingsView.swift:268` converts invalid port text with
  `UInt16(listenPort) ?? 6881`, silently replacing invalid input with a valid
  default instead of reporting an inline error.

Impact: invalid port input can be persisted as 6881, and apply failures can
leave partially persisted settings.

### WP08-BUG-003 - Per-torrent limits are not applied or round-tripped (P1)

Detected by: `test_wp08_per_torrent_limits.sh`

Evidence:

- `State.swift:115-130` declares `ratioLimit` and `seedTimeSeconds`.
- `TransferCoordinator.swift:915-921` checks only that the record exists,
  bumps the engine revision, and ignores `request.limits`.
- `InspectorView.swift:205-227` has only bandwidth text fields; there are no
  ratio or seed-time controls.
- No dedicated happy/error/edge XCTest cases exist for these fields.

Impact: seed goals and ratio limits are accepted by the command surface but
are not stored, applied, normalized, or returned.

### WP08-BUG-004 - Reannounce has no rate limit (P1)

Detected by: `test_wp08_trackers_reannounce.sh`

Evidence:

- `TransferCoordinator.swift:947-952` only checks record existence and returns
  `.ack`.
- There is no cooldown, last-reannounce timestamp, or throttling check.
- No dedicated `fetchTrackers`, `editTrackers`, or `reannounce` unit axes exist.

Impact: repeated reannounce requests are not bounded and the required tracker
command coverage is absent.

### WP08-BUG-005 - All-complete notification branch is unreachable (P1)

Detected by: `test_wp08_notifications.sh`

Evidence:

- `NotificationManager.swift:38-40` sets `allFinished = false` whenever an
  active torrent exists and sets `hasActive = true` for that same condition.
- `NotificationManager.swift:67` requires `hasActive && allFinished`.

These two values cannot be true together, so the all-complete notification is
never posted. No dedicated completion/all-complete/error notification tests
exist. Launch and toggle authorization calls are present.

### WP08-BUG-006 - Sorting, search shortcut, and batch remove are incomplete (P1)

Detected by: `test_wp08_sorting_search.sh`,
`test_wp08_menus_shortcuts.sh`

Evidence:

- `TorrentListView.swift:113-117` defines the State column without a
  `KeyPathComparator` value key path, so it is not sortable like the other
  columns.
- `TorrentinoApp.swift` has no explicit Cmd+F command shortcut.
- `TorrentListViewModel.swift:281-287` removes selected rows only from the UI
  array and never submits an engine command.

Impact: the required keyboard-only filtering and authoritative batch remove
flow are not implemented, and one visible table column is not sortable.

### WP08-BUG-007 - Edit/View menus are missing (P1)

Detected by: `test_wp08_menus_shortcuts.sh`

Evidence: `TorrentinoApp.swift:43-86` declares File and Torrent command menus,
but no explicit Edit or View command menu. Cmd+N, Cmd+Shift+N, Cmd+., Cmd+/,
Cmd+Delete, Cmd+R, and Cmd+I are present; Cmd+F is absent.

Impact: the required File/Edit/Torrent/View menu contract is incomplete.

### WP08-BUG-008 - Source localization references are missing from the catalog (P1)

Detected by: `test_wp08_localization_full.sh`

The catalog itself has 139 entries with non-empty EN and RU values, but source
reference coverage found these absent keys:

- `menu.torrent`
- `torrents.action.remove`
- `notification.complete.body \(torrent.displayName\)`
- `notification.error.body \(torrent.displayName\)`

Impact: these UI strings fall back to source keys instead of guaranteed
localized values. The older catalog-only WP-03 check does not catch this class
of missing key.

### WP08-BUG-009 - Reduce Motion, contrast, and one VoiceOver control are not wired (P1)

Detected by: `test_wp08_accessibility.sh`

Evidence:

- `TorrentListView.swift:13-14` declares `reduceMotion` and `contrast` but
  never uses either value.
- `InspectorView.swift:14-15` declares the same environment values but does
  not use `reduceMotion` to alter behavior.
- `TorrentListView.swift:441-446` uses an empty-label checkbox with
  `.labelsHidden()` and no accessibility label.

Impact: Reduce Motion and Increase Contrast settings have no observable UI
behavior, and file selection is not fully VoiceOver-addressable.

### WP08-BUG-010 - 500-row fixture performance is untested (P2)

Detected by: `test_wp08_fixture_perf.sh`

Evidence:

- `TorrentListViewModel.swift:379-427` has a generic `snapshot(count:)` and the
  fallback calls it with 100.
- No test executes `FixtureLibrary.snapshot(count: 100)` or `count: 500`.
- No XCTest performance measurement covers these fixture sizes.

Impact: the source can theoretically generate 500 rows, but the required
100/500 performance gate is not verified.

### WP08-BUG-011 - Keychain API test coverage is below ADR-010 (P2)

Detected by: `test_wp08_keychain.sh`

The implementation passes the static security checks: `SecItemAdd`,
`SecItemCopyMatching`, `SecItemDelete`, generic-password class,
`kSecAttrAccessibleAfterFirstUnlock`, pinned service/account, no production
`UserDefaults`, and one KeychainStore file are present. However,
`TorrentinoAppTests.swift:187-193` contains one combined test instead of at
least three dedicated save/load/delete tests with explicit negative coverage.

## Passing WP-08 Surface

`test_wp08_inspector_tabs.sh` PASS:

- General, Activity, Files, and Settings tabs are present and tagged.
- Inspector receives `selectedTorrent`.
- Cmd+I is declared.

The drag/drop source filtering and `.onOpenURL` handler are present as code,
but the Finder association test remains FAIL because the generated Info.plist
does not declare the OS associations.

## Gate Status

| Gate | Status | Evidence |
| --- | --- | --- |
| Keyboard-only core flow | FAIL | Cmd+F and Edit/View menu checks fail |
| VoiceOver audit | FAIL | unlabeled hidden checkbox; missing dedicated audit tests |
| Light/Dark | PASS at source level | dynamic AppKit colors are used |
| Increase Contrast | FAIL | `contrast` environment values unused |
| Reduce Motion | FAIL | `reduceMotion` environment values unused |
| Focus restoration after sheet/reconnect | PARTIAL | selection projection exists; no dedicated runtime gate |
| VoiceOver table navigation | FAIL | State column is not sortable; no runtime audit |
| Zero missing String Catalog keys | FAIL | four source references absent |
| Russian long-string layout | PARTIAL | catalog has long RU values; no UI snapshot |
| No routine modal alerts | PASS at source level | no `.alert` in app source |
| UI snapshots/localization checks | FAIL | no WP-08 snapshot target |
| 100-500 row performance | FAIL | no 500-row execution or measurement |

## Regression Matrix

| Bucket | Result |
| --- | --- |
| Existing WP-01..WP-07 scripts | 84/84 PASS |
| New WP-08 scripts | 1/13 PASS |
| Build | BUILD SUCCEEDED |
| Full XCTest | TEST SUCCEEDED |

No product code was modified. No git commit or push was performed.
