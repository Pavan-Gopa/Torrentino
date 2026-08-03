# Torrentino Coverage Matrix — Test Engineer

## WP-08 Coverage Update

**WP:** WP-08 — Native UX completeness
**Updated:** 2026-08-04
**Principle:** monotonic coverage; prior WP-01..WP-07 scripts remain in the regression base.
**Suite:** `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
**Result:** 99/100 QA scripts pass. The only failure is `test_wp03_legacy_untouched.sh` caused by pre-existing Human research dirt under `Legacy/Tauri`; this is ENVIRONMENTAL and waived.
**XCTest:** 201/201 pass.
**Bridge:** `test_bridge_headless.sh` PASS; `test_bridge_swift.sh` PASS.

### Feature -> dedicated coverage

| # | WP-08 feature | Test evidence | Result |
|---|---|---|---|
| 1 | Inspector tabs, selection sync, Cmd+I | `test_wp08_inspector_tabs.sh`; projection XCTest | PASS |
| 2 | Sorting, columns, search, multi-selection, batch actions | `test_wp08_sorting_search.sh`; projection/search XCTest | PASS |
| 3 | Drag/drop and Finder document/URL association | `test_wp08_dnd_association.sh`; source Info.plist UTI/scheme assertions | PASS |
| 4 | File/Edit/Torrent/View menus and shortcuts | `test_wp08_menus_shortcuts.sh` | PASS |
| 5 | Settings sections and transaction | `test_wp08_settings_sections.sh`, `test_wp08_settings_transaction.sh`, IPC transaction tests | PASS |
| 6 | Session settings live apply and revision fetch | `test_wp08_session_settings.sh`; 4 coordinator XCTest axes; native bridge smoke | PASS |
| 7 | Tracker edit/replace/reannounce | `test_wp08_trackers_reannounce.sh`; tracker XCTest axes; bridge harness | PASS |
| 8 | Real per-torrent limits and typed unsupported goals | `test_wp08_per_torrent_limits.sh`; limit XCTest axes; bridge harness | PASS |
| 9 | Completion/all-complete/error notifications | `test_wp08_notifications.sh`; notification transition XCTest axes | PASS |
| 10 | Full EN/RU catalog and long Russian strings | `test_wp08_localization_full.sh` (183 keys, 18 long RU cases) | PASS |
| 11 | Accessibility modes and reconnect focus restoration | `test_wp08_accessibility.sh`, `test_wp08_focus_reconnect.sh` | PASS at source level; runtime UI audit residual |
| 12 | Keychain off MainActor and credential boundary | `test_wp08_keychain.sh`; save/load/delete/missing XCTest | PASS |
| 13 | 100/500 row fixture projection/performance | `test_wp08_fixture_perf.sh`; 2 measured AppTests | PASS |
| 14 | Native invalidArgument and malformed tracker IPC | `test_wp08_bridge_integration.sh`; `bridge_swift_test.swift` | PASS |
| 15 | Real bridge bandwidth/unsupported/reannounce/tracker replacement | `test_wp08_bridge_integration.sh`; both bridge runners | PASS |

### WP-08 gate mapping

| Gate | Evidence | Status |
|---|---|---|
| Keyboard-only core flow | menu shortcuts, Cmd+F, Cmd+I, selection source contracts | PASS (source minimum) |
| VoiceOver audit | explicit labels, labeled checkbox, source accessibility contract | PASS (source minimum; runtime residual) |
| Light/Dark/Increase Contrast/Reduce Motion | dynamic colors plus contrast/reduce-motion behavior checks | PASS (source minimum) |
| Focus restoration after sheet/reconnect | `connectionGeneration`, full snapshot recovery, AppKit first responder hook | PASS (source minimum; runtime residual) |
| Zero missing String Catalog keys | complete EN/RU source-reference scan | PASS |
| Russian long-string layout | catalog length evidence and fixed window sizing | PASS (source evidence; no pixel snapshot) |
| No routine modal alerts | source scan rejects `.alert` | PASS |
| 100-500 row performance | fixture/projection XCTest `measure` | PASS |
| Settings transaction/live engine apply | session settings XCTest and native bridge | PASS |
| Limits/trackers/reannounce typed engine path | XCTest and Swift/C++ bridge | PASS |
| Keychain credentials boundary | detached Security calls, no UserDefaults, negative delete/load | PASS |
| Legacy product tree clean in history | approved product range clean; dirty Human tree waived | PASS (environmental waiver) |

### New test deliverables

| File | Coverage added |
|---|---|
| `Native/Tests/TorrentinoEngineAgentTests/TransferSmokeTests.swift` | fetch/apply settings, live-engine application, persistence, revision conflict, invalid no-mutation, rollback |
| `Native/Tests/TorrentinoAppTests/TorrentinoAppTests.swift` | case-insensitive search, filter, sort projection behavior |
| `Native/TorrentinoEngineBridge/scripts/qa/test_wp08_session_settings.sh` | UI/IPC/agent/native settings mapping contract |
| `Native/TorrentinoEngineBridge/scripts/qa/test_wp08_focus_reconnect.sh` | sheet/reconnect focus and generation contract |
| `Native/TorrentinoEngineBridge/scripts/qa/test_wp08_bridge_integration.sh` | real bridge harness scenario retention and typed fault contract |

### Residuals

- Runtime VoiceOver and AppKit focus automation were not run in this headless cycle; source-level minimum passes.
- `test_wp03_legacy_untouched.sh` remains an environmental failure only. Do not touch `Legacy/`.

---

## Historical WP-01 Coverage Matrix

**WP:** WP-01 — libtorrent arm64 bakeoff
**Updated:** 2026-08-02 (this run)
**Principle:** monotonic coverage — scripts are never deleted; WP-02+ adds to this base.
**Location of scripts:** `Native/TorrentinoEngineBridge/scripts/qa/`
**Suite runner:** `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`

This is the FIRST WP with a QA suite, so there is no prior regression base. Every
script below is **new this run** and becomes the regression base for WP-02+.

## Feature → test coverage (all "new this run")

| Area | Feature (from kick) | Test script | Scenarios covered | Status |
|------|---------------------|-------------|-------------------|--------|
| Build | build.sh static arm64 build; rebuild idempotent; artifact arm64; SHA-256 == lock | `test_wp01_build_idempotent.sh` | repeat build exits 0; object-content hash stable across rebuilds; arm64; cached-archive SHA-256 == lock; manifest valid JSON | new this run |
| Deps | versions.lock pin file validity | `test_wp01_versions_lock_valid.sh` | valid shell fragment; all pins present; SHA-256=64hex, commit=40hex; default∈supported; arm64/13.0 contract; cached archives match pins; prefixes exist | new this run |
| Harness | run_tests.sh — 11 scenarios | `test_wp01_harness_all_scenarios.sh` | all 11 PASS, 0 FAIL, "11 passed, 0 failed", each named scenario PASS | new this run |
| Harness | fallback libtorrent 2.0.13 | `test_wp01_fallback_2013.sh` | binary reports 2.0.13; 11/11 PASS on 2.0.13 | new this run |
| Sanitizers | run_sanitizers.sh ASan+UBSan | `test_wp01_sanitizers_clean.sh` | exit 0; "sanitizer reports: 0"; clean banner; no ASan/UBSan diagnostics in log | new this run |
| Soak | run_soak.sh status/start/stop + 30s smoke | `test_wp01_soak_smoke.sh` | `status` parses (RUNNING/NOT running); isolated 25s soak exits 0; report JSON valid; status=ok; iterations>0; error_alerts=0; no ERROR/FATAL | new this run |
| Deps/Gate | verify_no_homebrew.sh positive | `test_wp01_no_homebrew_positive.sh` | default + fallback binaries CLEAN (arm64, 13.0, no Homebrew//usr/local links or rpaths) | new this run |
| Deps/Gate | verify_no_homebrew.sh negative | `test_wp01_no_homebrew_negative.sh` | poisoned binary (Homebrew dylib + rpath) rejected; missing file rejected; correct diagnostics fire | new this run |
| Firewall | C-ABI exception containment | `test_wp01_exception_firewall.sh` | exception_containment PASS; set_terminate + catch(...) + run_guarded present; misuse (unknown scenario / missing arg / unknown flag) → exit 6, no terminate | new this run |
| Persistence/Gate | crash_restore (SIGKILL + restore) | `test_wp01_crash_restore.sh` | scenario PASS; child spawned + SIGKILLed; partial data restored; restore genuinely partial (0<restored<total); registry survival enforced by in-scenario TH_REQUIRE | new this run |
| Soak/Gate | flush_cache barrier / digest verification | `test_wp01_flush_barrier_smoke.sh` | flush_cache()+cache_flushed_alert+sha256_file_hex present; isolated 25s soak: 0 "payload digest mismatch", status=ok, error_alerts=0, N digests verified | new this run |

## Gate → test mapping (WP-01 gate bullets)

| Gate | Covered by | N/A? |
|------|------------|------|
| Restore без потери registry/partial data | `test_wp01_crash_restore.sh` (+ `crash_restore` scenario TH_REQUIRE) | — |
| Нет Homebrew runtime links | `test_wp01_no_homebrew_positive.sh` + `test_wp01_no_homebrew_negative.sh` | — |
| Точный dependency lock (versions.lock) | `test_wp01_versions_lock_valid.sh` + `test_wp01_build_idempotent.sh` | — |
| Все C++ exceptions остаются внутри harness | `test_wp01_exception_firewall.sh` | — |
| ASan/UBSan clean | `test_wp01_sanitizers_clean.sh` | — |
| 24h soak без crash/hang (smoke 30s, errors=0) | `test_wp01_soak_smoke.sh` + `test_wp01_flush_barrier_smoke.sh` (smoke); full 24h is wall-clock, observed via `run_soak.sh status` | full 24h not assertable in CI time — smoke covers correctness; live burn-in observed separately |

## Regression base for WP-02+

All 11 scripts + `run_qa_suite.sh` + `qa_common.sh`. The runner auto-discovers
`test_wp01_*.sh` (and future `test_wpNN_*.sh` can be added alongside).
