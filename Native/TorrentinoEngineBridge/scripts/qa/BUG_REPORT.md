# BUG REPORT - WP-08 Native UX Completeness

Date: 2026-08-03
Role: Test Engineer (detect and report only)
Verdict: FAIL

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
