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
