# FEEDBACK — WP-03 Review

**Reviewer:** Verification Engineer  
**Date:** 2026-08-02  
**Commit:** `5b7beea` — feat(torrentino): WP-03 — native project skeleton + strict concurrency  
**RESULT:** APPROVED

### 1. Build & tests

| Check | Result | Evidence |
|-------|--------|----------|
| `Torrentino` scheme build | **BUILD SUCCEEDED** | `xcodebuild build -scheme Torrentino -destination 'platform=macOS,arch=arm64'` + Developer ID / team `438UQRF7JV` |
| Compiler/Swift warnings (app) | **0** | `grep -E "warning:"` after excluding `appintentsmetadataprocessor` noise → 0. Sole log line is toolchain: `Metadata extraction skipped. No AppIntents.framework dependency found` (not a Swift/clang diagnostic; does not trip warnings-as-errors). |
| `TorrentinoEngineAgent` scheme build | **BUILD SUCCEEDED** | same destination/signing |
| Compiler warnings (agent) | **0** | `grep -cE "warning:"` → 0 |
| Unit tests | **TEST SUCCEEDED** | Domain 4/4 + IPC 6/6 passed (`-only-testing:TorrentinoDomainTests -only-testing:TorrentinoIPCTests`) |
| Strict concurrency resolved | **complete** | `xcodebuild -showBuildSettings` on Domain/IPC/Torrentino: `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_VERSION = 6.0`, `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`, `GCC_TREAT_WARNINGS_AS_ERRORS = YES` |
| Warnings-as-errors on compile line | **YES** | `swiftc … -warnings-as-errors -swift-version 6` for Domain, IPC, App, Agent |

### 2. Gate checklist

- [x] **PASS — Clean build без warnings (все targets)**  
  App + Agent **BUILD SUCCEEDED**; 0 compiler warnings; Shared.xcconfig enforces complete concurrency + treat-warnings-as-errors for all targets via Debug/Release `#include "Shared.xcconfig"`.

- [x] **PASS — Unit test target запускается (`xcodebuild test`)**  
  `** TEST SUCCEEDED **`  
  - `TorrentinoDomainTests`: state cases, TorrentInfo Codable round-trip, EngineError descriptions, TestProfile isolation  
  - `TorrentinoIPCTests`: version 1.0, ordering, EngineCommand WP-02 surface, event placeholders, envelope round-trip + major-compat, isolation  

- [x] **PASS — App показывает native empty state**  
  Code evidence: `ContentView` is pure SwiftUI empty state (`square.stack.3d.up.slash` + `String(localized: "empty.no_torrents")` / `"empty.subtitle"`); no invented torrent list; degraded banner uses catalog `error.xpc_unavailable`. Settings scene wired via `Settings { SettingsView() }` + ⌘, menu.

- [x] **PASS — Старая версия не затронута (Legacy/ untouched)**  
  `git show 5b7beea --name-only` → no `Legacy/` paths; `git diff 5b7beea^..5b7beea -- Legacy/` empty.

### 3. Code quality

**Swift 6 / concurrency**

- `Native/Config/Shared.xcconfig`: `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`, `GCC_TREAT_WARNINGS_AS_ERRORS = YES`.
- Build settings inheritance verified for Domain, IPC, and app targets.
- Domain/IPC types are `Sendable` value types/enums; no shared mutable state in new modules.

**TorrentinoDomain**

- Pure DTOs: `TorrentState`, `TorrentInfo`, `EngineError`.
- Imports: only `Foundation` on `TorrentInfo`; no AppKit/SwiftUI/UIKit.
- All public fields `let`; no I/O; role headers present (Layer/Role/Must-not/Invariants).
- `EngineError` is domain taxonomy (`Error & Sendable`), mapped from transport at IPC edge (`EngineClientError.domainError`) — appropriate for WP-03.

**TorrentinoIPC**

- `IPCEnvelope<T: Codable & Sendable>` versioned; `isCompatibleWithCurrent` on major.
- `IPCVersion.current = 1.0`; `Comparable` for ordering tests.
- `EngineCommand` mirrors WP-02 surface (`hello`, `health`, `increment`, `getCounter`, `shutdown`).
- `EngineEvent` placeholders only (`stateChanged`, `progressUpdated`) — no synthetic progress streams.
- Role headers present; Foundation-only imports.

**Test targets / TestProfile**

- `TestProfile` uses `mkdtemp` under `FileManager.temporaryDirectory` (`torrentino-test.XXXXXX`).
- Hard guard: `precondition(!path.contains("Application Support/com.torrentino.app"))`.
- `TestProfileCase` sets up in `setUpWithError`, tears down in `tearDown` (`removeItem`).
- `TestProfile.swift` compiled into DomainTests, IPCTests, AppTests (pbxproj Sources).
- Isolation covered by unit tests.

**String Catalog**

- `Localizable.xcstrings`: 18 keys, **all have EN + RU** translated (`missing_en_ru=none`).
- UI surfaces use `String(localized:)` for empty state, settings tabs, menus, XPC error banner.
- Catalog-only keys `app.name` / `app.quit` / `settings.title` are unused in Swift yet — acceptable for WP-03 shell (not a gate failure).

**Settings & empty state**

- `SettingsView`: TabView with General / Downloads / Connection placeholders; content from catalog; no persistence.
- `TorrentinoApp`: Settings scene + `openSettingsWindow` bridge for ⌘,.
- Empty state native SwiftUI, catalog-driven, no fake torrents.

**Comments**

- Role headers on Domain, IPC, TestSupport, ContentView, SettingsView, Shared.xcconfig.
- Why-comments where non-obvious (TestProfile mkdtemp, envelope compatibility, Settings bridge, event placeholders “TBD later WPs”).

**Nits (non-blocking)**

1. Diagnostic `statusText` / CLI / log strings remain English (pre-existing EngineViewModel/CLI path) — user-facing shell strings are cataloged.
2. `AgentService` remains `@unchecked Sendable` NSObject XPC surface (WP-02 pattern); only schema linkage (`import TorrentinoIPC`, `IPCVersion.current` in health) added — correct for this WP.

### 4. Architecture compliance

| Rule | Status |
|------|--------|
| target_files / Native-only delta | **PASS** — commit touches `Native/**` + FEEDBACK only |
| Legacy/ untouched | **PASS** |
| No future WP work | **PASS** — no libtorrent, no real torrent list, no persistence rewrite, no magnet/add_torrent APIs in Domain/IPC/Tests; EngineEvent/Command stay schema placeholders |
| App/Agent depend on Domain/IPC | **PASS** — frameworks linked; `EngineClient` imports IPC; `EngineClientTypes` maps to `EngineError`; `AgentService` imports IPC |
| Frameworks stay pure | **PASS** — Domain/IPC have no UI imports, no network, no XPC transport |
| Graphify context | FOUNDATION Track (WP-00..03) → precedes ENGINE (WP-04..06); Swift 6 Strict Concurrency + XPC Protocol v1 alignment confirmed |

### 5. If CHANGES_REQUESTED — concrete list

*(none — RESULT is APPROVED)*

---

**Summary for orchestrator:** WP-03 gates all **PASS**. Clean Developer ID builds (0 compiler warnings), unit tests green, native empty state + Settings shell + String Catalog EN/RU, strict concurrency complete + warnings-as-errors, Legacy untouched, no scope creep into WP-04+.
