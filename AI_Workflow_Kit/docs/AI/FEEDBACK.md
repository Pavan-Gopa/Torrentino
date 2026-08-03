# FEEDBACK — WP-07 Review (Core transfer vertical slice)

**Reviewer:** Verification Engineer
**Date:** 2026-08-03
**RESULT:** CHANGES_REQUESTED

---

### 1. Build & Tests Status

- **Xcode build:** `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=438UQRF7JV`
  - **Result:** **BUILD SUCCEEDED** (0 warnings, Swift 6 strict concurrency complete).
- **Xcode tests:** `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=438UQRF7JV`
  - **Result:** **TEST SUCCEEDED** (25 new `TransferSmokeTests` passing).
- **QA Suite:** `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`
  - **Result:** **SUITE RESULT: FAIL** (69 PASS / 2 FAIL out of 71 scripts).
  - Failed scripts:
    1. `test_wp03_string_catalog.sh` — 45 newly added keys in `Localizable.xcstrings` miss Russian (`ru`) localizations.
    2. `test_wp03_empty_state.sh` — `ContentView.swift` moved `emptyState` to `TorrentListView.swift`, breaking the `test_wp03_empty_state.sh` static structural assertions on `ContentView.swift`.

---

### 2. Gate Checklist (WP-07)

- [x] **UI не polling full list (event-driven snapshots/deltas из WP-05 protocol)**
  - Evidence: `TorrentListViewModel.swift:L99-L155` (`subscribe()` registers XPC listener; `apply(_ events:)` receives `torrentDelta` with contiguous revision check `delta.engineRevision == engineRevision + 1` and updates in-memory list).
  - Evidence: `TransferEventBus.swift:L46-L58` (50ms coalescing window for delta batches, immediate flush for `snapshotRequired`).
  - Evidence: `TransferCoordinator.swift:L708-L744` (`publishDelta()` diffs changes since `publishedRevision` and publishes `TorrentDeltaEvent`).

- [x] **Row identity/focus/scroll стабильны (stable TorrentRecordID)**
  - Evidence: `TorrentListView.swift:L75` (`Table(filteredTorrents, selection: $viewModel.selection)` keyed by `TorrentRecordID`).
  - Evidence: `Identity.swift:L14` (`TorrentRecordID` is a stable UUID-backed type conforming to `Identifiable`, `Hashable`, `Codable`, `Sendable`).
  - Evidence: `TorrentListViewModel.swift:L26` (`selection: Set<TorrentRecordID>` preserves selection across delta updates).

- [x] **100-row fixture**
  - Evidence: `TorrentListViewModel.swift:L92` (`FixtureLibrary.snapshot(count: 100)` fallback when agent is unreachable).
  - Evidence: `TorrentListViewModel.swift:L322-L376` (`FixtureLibrary` generates 100 deterministic sorted `TorrentSnapshot` entries across diverse states and progress values).

- [x] **Metadata/file list не блокирует MainActor (async, pagination)**
  - Evidence: `TorrentListViewModel.swift:L275-L291` (`loadFiles` sends async XPC `fetchFiles` request with `PageCursor` and `pageSize: 200`).
  - Evidence: `TransferCoordinator.swift:L454-L540` (`files(request:)` pages through directory/file rows using an opaque little-endian byte token cursor).
  - Evidence: `TorrentListViewModel.swift:L194-L196` (`addTorrentFile` reads file bytes off MainActor via `Task.detached(priority: .userInitiated)`).

- [x] **Restart сохраняет flow (persistence integration с WP-06)**
  - Evidence: `TransferCoordinator.swift:L89-L137` (`restoreFromPersistence()` queries `persistence.allTorrents()`, restores `StoredTorrent` rows sorted by `addedAt`, re-loads metainfo, and rebuilds coordinator records).
  - Evidence: `TransferCoordinator.swift:L628-L644` (`pumpOnce()` automatically re-adds non-engine-registered restored records to the engine).

- [x] **Один torrent error не блокирует другие (per-record faults)**
  - Evidence: `TransferCoordinator.swift:L342-L347` (Engine add failure during `commitAdd` sets record health to `.recoverableError(.engineBusy)` without aborting coordinator state).
  - Evidence: `TransferCoordinator.swift:L406-L408` (Pause/resume failure marks record health as `.recoverableError(.engineBusy)` for that record only).
  - Evidence: `TransferCoordinator.swift:L637-L643` (`pumpOnce()` catches per-record add failures and isolates degradation to the single record).

- [x] **Untrusted source не может создать путь вне validated torrent root (PathValidator: traversal rejection)**
  - Evidence: `Metainfo.swift:L220` (`PathValidator.validatedRelativePath(path)` enforced on every metainfo file component).
  - Evidence: `PathValidator.swift:L67-L102` (`validatedRelativePath` rejects absolute paths, `..`, `.`, backslashes, null bytes, reserved Windows device names, and overlong components/paths).
  - Evidence: `TorrentAdder.swift:L114-L117` (`validateSelection` validates all selection paths through `PathValidator.validatedRelativePath`).

---

### 3. Security / Hardening Verification

- **BencodeParser (`BencodeParser.swift`):**
  - Nesting depth bounded: `maxDepth = 64` (`BencodeParser.swift:L59`, depth check at `L79`).
  - Input size bounded: `maxInputBytes = 16 * 1024 * 1024` (16 MiB, `BencodeParser.swift:L63`, `L69`).
  - Strict integer grammar (`BencodeParser.swift:L95-L128`): no leading zeros except `0`, no `-0`, overflow check, digit count <= 19.
  - Strict dictionary key check (`BencodeParser.swift:L180-L185`): duplicate keys and non-UTF-8 keys strictly rejected.

- **Metainfo (`Metainfo.swift`):**
  - Input size capped at 10 MiB (`TransferLimits.maxTorrentFileBytes = 10 * 1024 * 1024`, `Metainfo.swift:L120`, `Preflight.swift:L29`).
  - Max files capped at 10,000 (`TransferLimits.maxFiles = 10_000`, `Metainfo.swift:L118`, `L228`).
  - Max trackers capped at 512 (`TransferLimits.maxTrackers = 512`, `Metainfo.swift:L123`, `L203`).
  - Path length <= 4096 / component length <= 255 (`PathValidator.swift:L51-L52`).

- **Magnet (`MagnetParser.swift`):**
  - Hash validation: 40-hex v1 hash or 32-char base32 decoded to exact 20-byte SHA-1 hash (`MagnetParser.swift:L110-L141`).
  - URI length capped at 8 KiB (`TransferLimits.maxMagnetLength = 8 * 1024`, `MagnetParser.swift:L52`).

- **HTTPSourceFetcher (`HTTPSourceFetcher.swift`):**
  - Scheme restricted: `http` / `https` only (`HTTPSourceFetcher.swift:L68`, `L163`).
  - Max redirects <= 5 (`HTTPSourceFetcher.maxRedirects = 5`, `HTTPSourceFetcher.swift:L155`).
  - Max body size 10 MiB (`HTTPSourceFetcher.maxBodyBytes = 10 * 1024 * 1024`, `HTTPSourceFetcher.swift:L187`, `L200`).
  - Deadline 30 seconds (`HTTPSourceFetcher.deadline = 30`, `HTTPSourceFetcher.swift:L77-L78`).
  - Content-Type allowlist: `application/x-bittorrent`, `application/octet-stream` (`HTTPSourceFetcher.swift:L47-L50`, `L182-L185`).

- **PathValidator (`PathValidator.swift`):**
  - Rejects `../`, absolute paths (`/` or volume `C:`), null bytes (`\0`), backslashes (`\`), reserved Windows names (`CON`, `PRN`, `AUX`, `NUL`, etc.), overlong paths/components (`PathValidator.swift:L74-L101`).

- **Negative Corpus Execution:**
  - Negative corpora defined in `NegativeCorpus.swift` (bencode, metainfo, magnet, path negatives).
  - Evaluated in `TransferSmokeTests.swift:L38-L42`, `L69-L73`, `L107-L111`, `L121-L125` before any payload write or persistence step.

- **SHA-1 Info Hash Computation:**
  - `Metainfo.swift:L137`, `L166`: Bencode parser records exact byte span of `"info"` dictionary (`infoSpan`). Digest computed over exact raw bencoded bytes via CommonCrypto `CC_SHA1`.

---

### 4. Code Quality & Concurrency

- **Sendable / Actor Isolation:** All public types conform to `Sendable`. Actor isolation enforced (`TransferCoordinator`, `TransferEventBus`, `BridgeTransferEngine`).
- **commitAdd Durability Order:** Journal and metainfo persistence occur BEFORE updating in-memory records or adding to the engine (`TransferCoordinator.swift:L308-L323`).
- **Idempotency:** Duplicate detection by `ContentIdentity` (`TransferCoordinator.swift:L283-L287`), replay by `IdempotencyKey` (`TransferCoordinator.swift:L275-L277`).
- **Delta Continuity:** Gap check `from + 1 < firstLogRevision` triggers `snapshotRequired` (`TransferCoordinator.swift:L712-L718`).
- **Error Contract:** Typed `EngineFault` with `FaultCode` and `redactedContext` (`TransferCoordinator.swift:L781-L792`).

---

### 5. Required Changes (Concrete List)

#### 1. [HIGH] Russian Localizations in `Localizable.xcstrings`
- **File:** `Native/TorrentinoApp/Resources/Localizable.xcstrings`
- **Problem:** 45 new localization keys (`torrents.title`, `torrents.add`, `torrents.col.name`, `torrents.filter.*`, `torrents.status.*`, `torrents.files.*`, `torrents.action.*`, etc.) have `"en"` localizations but miss `"ru"` localizations.
- **Impact:** `test_wp03_string_catalog.sh` fails in QA suite.
- **Required Action:** Add `"ru"` translations for all newly added string keys in `Localizable.xcstrings`.

#### 2. [HIGH] Fix QA Assertion Breakage in `test_wp03_empty_state.sh`
- **Files:** `Native/TorrentinoApp/Features/ContentView.swift` & `Native/TorrentinoEngineBridge/scripts/qa/test_wp03_empty_state.sh`
- **Problem:** `test_wp03_empty_state.sh` statically checks `ContentView.swift` for `emptyState`, `empty.no_torrents`, `empty.subtitle`, and `square.stack.3d.up.slash`. Moving `emptyState` into `TorrentListView.swift` removed those symbols from `ContentView.swift`.
- **Impact:** `test_wp03_empty_state.sh` fails in QA suite (`[FAIL] emptyState view present: missing 'emptyState'`).
- **Required Action:** Maintain backwards compatibility for `test_wp03_empty_state.sh` (e.g. keep or reference `emptyState` in `ContentView.swift` or update `test_wp03_empty_state.sh` if authorized).

---

### Conclusion

The code implementation for WP-07 core transfer vertical slice is architecturally sound and security controls are fully verified. However, changes are requested to resolve the 2 QA suite script failures.

**VERDICT: CHANGES_REQUESTED**
