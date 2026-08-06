# WP-12 Research Feedback (Metal hashing experiment)

## RESULT: waiting_review

## Final WP-12 Status

WP-12 (RESEARCH: ADOPT_METAL / REJECT_METAL for Creator piece hashing) is
complete. The experiment produced a measured decision: **REJECT_METAL** per
plan §12.7 gate criteria (documented in ADR-018). This is the plan's defined
normal successful outcome for a failed gate: all correctness gates pass, all
performance gates fail with measured (not N/A) evidence on the eligible >= 4 GiB
line.

## Verification

- `xcodebuild build`: **BUILD SUCCEEDED**; `xcodebuild test` (Torrentino scheme,
  macOS arm64): **TEST SUCCEEDED**.
- `swift test` (Native/TorrentinoHashing): **20/20 PASS** — KnownAnswer 5,
  Correctness 4 (100 + 100 randomized cases), Stress 1 (1000 iterations),
  Failure 7 (all §12.8 fallback paths), Cancellation 3.
- Independent validator (libtorrent 2.0.13): **18/18 cells PASS** — v1 piece
  lists, v2 file-tree roots and piece-layer content byte-equal for tiny/64m x
  piece 256K/1M/4M x v1/v2/hybrid.
- Benchmark matrix (64 MiB/1 GiB/4 GiB x 256K–16M pieces x cpu/metal/libtorrent,
  10 reps, randomized order, 95% CI, no purge): **300/300 rows** valid,
  fallbacks=0, thermal evidence OK. Raw CSV + gate verdicts:
  `Measurements/wp12/`.
- QA: `test_wp12_01_correctness.sh`, `test_wp12_02_benchmarks.sh`,
  `test_wp12_03_fallback.sh`, `test_wp12_04_verifier.sh` — all PASS; wired into
  `run_qa_suite.sh` (`test_wp12_*` find + summary counters).

## Compliance with plan §12 criteria

| Criterion (§12.7) | Result |
| --- | --- |
| G1 bit-for-bit known vectors | PASS (KnownAnswerTests 5/5) |
| G2 v1/v2/hybrid vs CPU reference | PASS (CorrectnessTests) |
| G3 >= 100 randomized cases | PASS (100 + 100 two-file) |
| G4 >= 1000 stress iterations | PASS (1000, zero mismatches) |
| G5 independent BEP validator | PASS (libtorrent 2.0.13 cross-check 18/18) |
| G6 >= 20% median gain on >= 4 GiB | **FAIL — Metal 0.26x–0.48x of CPU** |
| G7 p95 regression <= 5% | **FAIL — 0.26–0.49** |
| G8 memory budget | **FAIL — RSS 22–38x CPU** |
| G9 throughput-per-joule | **FAIL — ~2x CPU-seconds/MiB** |
| G10 no new thermal events | PASS |
| G11 fallbacks == 0 healthy | PASS (300/300 rows) |

## Invariants

- Production hashing paths are untouched: Creator (WP-11) remains CPU-only on
  libtorrent; `Legacy/Tauri/` untouched; no Homebrew; no sudo used.
- Metal is research-only, gated by `TORRENTINO_METAL_EXPERIMENTAL=1`, with the
  §12.8 fallback chain (device/compile/commit/buffer/selftest/thermal) — never
  selected automatically.
- Corpus/benchmark tooling and analysis are deterministic and reproducible
  (seeded corpora, shared CSV schema, scripts committed).

## Comments

- Findings documented for upstream/reporting: libtorrent 2.0.13
  `create_torrent` must not be moved by value (EXC_BAD_ACCESS);
  `info_hashes().v2` is the info-dict hash, not the merkle root; libtorrent
  parse re-derives a v2 root differing from the stored one; two-level piece-root
  v2 tree coincides with strict BEP-52 for piece-aligned/sub-piece single files.
- Corpus rows N/A with reasons: 10 GiB, 10 GiB/10k files, 50–100 GiB (storage),
  external SSD, M1, LPM (hardware/admin). 4 GiB (the eligibility line) measured.
- Detail: `Measurements/wp12/report.md`, `Measurements/wp12/gate-verdict-20260806.md`,
  ADR-018 (`AI_Workflow_Kit/docs/DECISIONS.md`).

---
---

# WP-08 Implementation Feedback

## RESULT: waiting_review

## Final WP-08 Status

All 11 reported WP-08 findings are fixed and covered by the corresponding
source-contract and XCTest checks.

| Bug | Status | Verification |
| --- | --- | --- |
| WP08-BUG-001 Finder associations | FIXED | `Info.plist`, drag/drop, and URL association checks pass |
| WP08-BUG-002 Settings transaction | FIXED | validation, apply/rollback, and transaction checks pass |
| WP08-BUG-003 Per-torrent limits | FIXED | UI, normalization, persistence round-trip, and negative tests pass |
| WP08-BUG-004 Reannounce throttling | FIXED | tracker commands, empty-list handling, cooldown, and tests pass |
| WP08-BUG-005 Completion notifications | FIXED | transition tracking, authorization, and notification tests pass |
| WP08-BUG-006 Sorting/search/removal | FIXED | sortable state, Cmd+F, and authoritative batch removal checks pass |
| WP08-BUG-007 Edit/View menus | FIXED | menu and shortcut checks pass |
| WP08-BUG-008 Localization references | FIXED | 152-key EN/RU catalog and source-reference checks pass |
| WP08-BUG-009 Accessibility and motion | FIXED | labels, contrast, reduce-motion, and keyboard checks pass |
| WP08-BUG-010 Fixture performance | FIXED | 100/500-row fixture and XCTest performance checks pass |
| WP08-BUG-011 Keychain coverage | FIXED | dedicated save/load/delete and negative tests pass |

## Current Verification

- `xcodebuild build`: **BUILD SUCCEEDED**
- `xcodebuild test`: **TEST SUCCEEDED**
- `run_qa_suite.sh`: **84/84 PASS**, **SUITE RESULT: GREEN** (signed build)
- WP-08 scripts: **13/13 PASS**
- `graphify update .`: completed successfully

## Review Fixes (CHANGES_REQUESTED round 2)

1. **HIGH — NotificationManager.requestAuthorization() not called**:
   - `App/AppDelegate.swift`: `requestAuthorization()` now called in `applicationDidFinishLaunching` so macOS grants notification permission at launch.
   - `Features/Settings/SettingsView.swift`: each Notifications tab toggle now calls `requestAuthorization()` when turned ON (in addition to updating `NotificationManager` flags).
2. **MEDIUM — duplicate KeychainStore.swift**:
   - Removed orphan `Native/TorrentinoApp/Settings/KeychainStore.swift` (identical duplicate, not referenced by `project.pbxproj`; the registered path resolves to `Features/Settings/KeychainStore.swift` via the `Features → Settings` group chain).
   - Deleted the now-empty `Native/TorrentinoApp/Settings/` directory.
   - Verified: `xcodebuild build` → **BUILD SUCCEEDED**; QA suite → **84/84 GREEN**.


## Summary
Native UX Completeness (WP-08) implemented end-to-end for Torrentino Native macOS client:
1. **4-Tab Inspector View** (`InspectorView.swift`: General, Activity, Files, Settings synchronized with table selection, accessible via ⌘I).
2. **Sorting, Filtering & Multi-Selection** (`TorrentListView.swift` with `KeyPathComparator` column sorting, ⌘F search filter bar, batch actions pause/resume/remove).
3. **Drag-and-Drop & Finder URL Association** (`TorrentListView.swift` `.onDrop`, `Info.plist` document and URL schemes for `.torrent` / `magnet:`, `.onOpenURL` handling in `TorrentinoApp.swift`).
4. **Native Menus & Shortcuts** (`TorrentinoApp.swift` commands lane: File ⌘N/⌘⇧N, Edit ⌘F, Torrent ⌘./⌘//⌘⌫/⌘R/⌘I, full keyboard navigation).
5. **5-Tab Settings** (`SettingsView.swift`: General, Bandwidth, Network, Transfers, Notifications; connected to `SettingsTransaction` validate -> apply -> rollback).
6. **Trackers & Reannounce** (`FetchTrackersRequest`, `ReannounceRequest`, `EditTrackersRequest` handled in `TransferCoordinator` & displayed in Inspector).
7. **Per-Torrent Limits & Seed Goals** (`TransferLimits` extended with `ratioLimit` & `seedTimeSeconds`, `SetLimitsRequest` command handler).
8. **System Notifications** (`NotificationManager.swift`: `UNUserNotificationCenter` for torrent complete, all complete, and error notifications).
9. **EN/RU Localizations** (`Localizable.xcstrings`: 152 keys with 100% `en` AND `ru` translated coverage, verified by `test_wp03_string_catalog.sh`).
10. **Accessibility & Motion** (`VoiceOver` labels, keyboard focus, high-contrast, `accessibilityReduceMotion` support).
11. **Keychain Credentials** (`KeychainStore.swift`: `SecItem` password storage for generic proxy under service `com.torrentino.app`).
12. **Settings Transaction Integration** (`SettingsTransaction` run in `TransferCoordinator` & `SettingsView`).

Smoke tests added to `TorrentinoAppTests.swift` covering `KeychainStore` save/load/delete and `SettingsTransaction` validation rules.

## Files Created/Modified

### Native/TorrentinoApp/ (new & modified)
- **Features/InspectorView.swift** (new): macOS Inspector (⌘I) with General, Activity, Files, and Settings tabs, synchronized with selection in table.
- **Features/Settings/KeychainStore.swift** (new): `SecItem` wrapper for proxy password storage (`com.torrentino.app`).
- **App/NotificationManager.swift** (new): `UNUserNotificationCenter` manager for system notifications.
- **Features/Settings/SettingsView.swift** (modified): 5-tab Settings connected to `SettingsTransaction` with inline validation errors and Keychain integration.
- **Features/TorrentListViewModel.swift** (modified): added search, inspector state, batch operations (`pauseSelected`, `resumeSelected`, `removeSelected`, `revealSelected`), `reannounce`, `setLimits`.
- **Features/TorrentListView.swift** (modified): table column sorting, search filtering bar, context menu, drag-and-drop `.onDrop` for `.torrent`/`magnet:`, inspector sheet, accessibility labels.
- **App/TorrentinoApp.swift** (modified): main menu commands (⌘N, ⌘⇧N, ⌘., ⌘/, ⌘⌫, ⌘R, ⌘I) and `.onOpenURL` magnet/file handling.
- **Resources/Localizable.xcstrings** (modified): WP-08 localized strings (152 total keys, 100% `en` and `ru` translated).

### Native/TorrentinoEngineAgent/ (modified)
- **Transfer/TransferCoordinator.swift**: added `activeSettings` and `settingsRevision` state, settings persistence restoration, command handlers for `setLimits`, `fetchSettings`, `validateSettings`, `applySettings`, `testProxy`, `testIncomingPort`, `editTrackers`, `reannounce`.

### Native/TorrentinoIPC/ (modified)
- **State.swift**: extended `TransferLimits` with `ratioLimit: Double?` and `seedTimeSeconds: Int64?`.

### Native/Tests/ (modified)
- **TorrentinoAppTests/TorrentinoAppTests.swift**: added `testKeychainStoreOperations` and `testSettingsTransactionValidation` smoke tests.

### Native/Torrentino.xcodeproj/ (modified)
- **project.pbxproj**: registered `KeychainStore.swift`, `NotificationManager.swift`, and `InspectorView.swift` in build phases for `Torrentino` and `TorrentinoAppTests` targets.

## Gates Verified

| Gate | Status |
|------|--------|
| Full scheme `Torrentino` (Developer ID signed) builds | ✅ BUILD SUCCEEDED |
| String Catalog EN+RU Coverage (`test_wp03_string_catalog.sh`) | ✅ PASS (152 keys, 100% en+ru complete) |
| Xcode Unit & Integration Tests (`xcodebuild test`) | ✅ TEST SUCCEEDED (All tests pass) |
| Swift 6 Strict Concurrency | ✅ Clean build, 0 warnings |
