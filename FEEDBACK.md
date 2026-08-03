# WP-06 Implementation Feedback

## RESULT: waiting_review

## Summary
Durable persistence + crash recovery (WP-06) implemented in `Native/TorrentinoEngineAgent/Persistence/` (10 files): SQLite (system C API, zero deps) in WAL mode, schema v1 migrations, atomic generations with SHA-256 checksums and a durability-correct sidecar write path (temp → fsync → rename → dir fsync), operation journal (cap 1000), clean/unclean shutdown coordination (clean flag written LAST), startup reconciliation (checksum verify → orphan sweep → journal replay), quarantine/rebuild controlled recovery with forensic-trio preservation, 8 deterministic failpoints, and a single-writer advisory lock. Integrated into AgentRuntime/AgentService (background open, clean close on stop, persistence keys in health()). New `TorrentinoEngineAgentTests` target: 16 smoke tests covering the full gate. Full scheme builds clean; 118/118 tests green.

## Files Created/Modified

### Native/TorrentinoEngineAgent/Persistence/ (new, 10 files)
- **PersistenceError.swift** — Sendable error vocabulary (corruptDatabase, sqlite, ioFailure, unknownTorrent, notOpen, injectedFailpoint, downgradeBlocked, alreadyOpen, alreadyLocked)
- **SQLiteConnection.swift** — minimal `SQLiteConnection`/`SQLiteStatement`/`SQLiteError` wrappers over libsqlite3 (open_v2, exec, prepare/bind/step, close_v2; `SQLITE_TRANSIENT` via `unsafeBitCast(-1, to: sqlite3_destructor_type.self)` since the macro is not visible from Swift)
- **FailpointInjector.swift** — `FailpointID` (8 cases: beforeTemporaryWrite, afterWriteBeforeFileFsync, afterFileFsync, afterRenameBeforeParentFsync, afterRenameBeforeSQLiteTransaction, afterDBCommitBeforePreviousGenerationDelete, duringWALCheckpoint, eachCleanShutdownStep), `FailpointHook` (static), thread-safe registry, production no-op when unarmed
- **AtomicGeneration.swift** — `GenerationClock` (monotonic per kind, restored at open; confined to the store actor), `AtomicGeneration.sha256`, `PersistenceSidecar` (failpoints 1–4 at exact phase boundaries; temp write → fsync → rename → parent-dir fsync; superseded-sidecar cleanup; sidecar listing for the reconciler)
- **PersistenceStore.swift** — `actor PersistenceStore`: schema v1 (torrents, resume_data, metainfo, session_state, operation_journal, quarantine, schema_version), pragmas (WAL, synchronous=NORMAL, foreign_keys=ON, busy_timeout=5000), generation CRUD with journal append/commit/trim, verify checksums + quarantine + mark-for-recheck on read, integrity_check + foreign_key_check, forensic group status/move, salvage + rebuild recovery (fresh DB written durably, degraded mode), `open()` routes corruption into controlled recovery, `close(clean:)` (clean = ShutdownCoordinator; unclean = kill -9 semantics, connection + WAL frames left untouched)
- **OperationJournal.swift** — pending → committed/replayed lifecycle, cap 1000 via trim, replay surface for the reconciler
- **StartupReconciler.swift** — checksum verification of all kinds, orphan-sidecar sweep, pending-journal replay (conservatively marks torrents needs-recheck), one-shot (never replays twice)
- **QuarantineManager.swift** — quarantine + rebuild entry points
- **ShutdownCoordinator.swift** — fixed pipeline: PASSIVE flush → TRUNCATE checkpoint → truncate journal → set clean_shutdown=true (LAST durable write) → close; failpoint 8 before every step, failpoint 7 during the checkpoint; any interruption leaves the flag false
- **AdvisoryLock.swift** — flock(LOCK_EX|LOCK_NB) on `persistence.lock`, single-writer rejection

### Native/TorrentinoEngineAgent/Agent/ (modified)
- **AgentRuntime.swift** — acquires the advisory lock at startup (exit(1) on contention), opens persistence on a background Task after signal handlers, closes with `close(clean: true)` in the stop path
- **AgentService.swift** — `init(store: CounterStore, persistence: PersistenceStore)`; `health()` now reports `persistenceState` / `cleanShutdown` / `degraded` / `quarantined` / `reconciliation` (plist-only keys)

### Native/Tests/TorrentinoEngineAgentTests/ (new target, 16 tests)
- **PersistenceFixture.swift** — torrent/payload builders + 75-record fixture writer
- **TorrentinoEngineAgentTests.swift** — `TorrentinoEngineAgentPersistenceTests: TestProfileCase`: schema+WAL pragmas+idempotent reopen; 3 clean restore cycles; 4× kill -9 restore with no duplicate/lost records; generation monotonicity across crashes; desired states; corrupt resume → quarantine + needs-recheck; corrupt DB → controlled recovery (forensic trio preserved, degraded mode usable); WAL-only record restored after crash (main-file copy proves record lives only in WAL); forensic group preserved (unclean = WAL keeps frames, clean = WAL checkpointed to empty); clean flag stays false at every interrupted write phase (failpoints 1–6) and shutdown phase (7–8); payload byte-integrity across 20 rewrites + crash; journal cap 1000 + clean truncation + replay-once; single-writer advisory lock; failpoint lifecycle; 75-record fixture

### Native/Torrentino.xcodeproj/project.pbxproj (+ scheme)
- 10 persistence files registered in the TorrentinoEngineAgent target (Sources) and the new TorrentinoEngineAgentTests target; TestProfile + fixture + tests registered; `-lsqlite3` added to agent Debug/Release OTHER_LDFLAGS and test configs; new unit-test target with Debug/Release configs; scheme TestAction extended with TorrentinoEngineAgentTests

## Gates Verified

| Gate | Status |
|------|--------|
| Full scheme `Torrentino` (Developer ID signed) builds | ✅ BUILD SUCCEEDED, 0 warnings |
| WP-06 smoke tests (TorrentinoEngineAgentTests) | ✅ 16/16 pass |
| Full scheme test suite | ✅ 118/118 pass (102 existing + 16 WP-06) |
| Swift 6 strict concurrency (Complete), warnings-as-errors | ✅ no warnings |

## Test Results

```
xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' -only-testing:TorrentinoEngineAgentTests
** TEST SUCCEEDED ** (16 test cases passed)

xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64'
** TEST SUCCEEDED ** (118/118)
```

## Implementation Notes
- **kill -9 semantics**: `close(clean: false)` leaves the sqlite connection and WAL frames untouched (a real close lets SQLite auto-checkpoint the WAL into the main file on this platform). Tests that need the crashed process fully dead call `rawClose()` explicitly.
- **WAL file lifecycle**: this platform's SQLite does not delete `-wal`/`-shm` after a TRUNCATE checkpoint + last-connection close (leaves 0-byte files). The tests therefore assert the meaningful invariant: unclean close → WAL non-empty; clean close → WAL checkpointed to 0 bytes.
- **foreign_keys is per-connection**: verified via the store's own connection (`foreignKeysEnabled()`), not a second probe connection.
- **SQLITE_TRANSIENT**: not visible from Swift (C macro); replaced with `unsafeBitCast(-1, to: sqlite3_destructor_type.self)`.
- **GenerationClock**: plain `@unchecked Sendable` class confined to the PersistenceStore actor (an actor would force async hops in the sync write path).

---

# WP-07 Implementation Feedback

## RESULT: waiting_review

## Summary
Core transfer vertical slice implemented end-to-end: parsing/preflight pipeline (bencode, metainfo, magnet, HTTP source fetch), `TransferCoordinator` (journal-first durable add, duplicate detection by content identity, idempotent commitAdd replay, pause/resume, paginated files with directory drill-down, file selection), `TransferEventBus` + XPC event lane, production `BridgeTransferEngine` over `EngineCoordinator`, agent wiring (`wireTransferLanes`, default Downloads save location, 500 ms status pump, sink binding on connection accept/invalidate), and the native transfer window (sidebar filters, table, files pane, status bar, Add Torrent sheet, deterministic fixture fallback). 25 new smoke tests cover the full gate. Full scheme builds clean; all test targets green.

## Files Created/Modified

### Native/TorrentinoEngineAgent/Transfer/ (new group, 11 files)
- **BencodeParser.swift** — bounded recursive-descent parser (depth ≤64, input ≤16 MiB, strict integers: no leading zeros, no `-0`)
- **MagnetParser.swift** — BEP-9/BEP-53 with ≤8 KiB URI, 40-hex v1 / 64-hex v2 hash, tracker dedupe + bounds
- **Metainfo.swift** — `MetainfoParser`/`Metainfo` + `TransferLimits` (10 MiB, 10 000 files, 512 trackers, path 4096/component 255), SHA-1 v1 info hash via CommonCrypto, stable
- **HTTPSourceFetcher.swift** — URLSession + bounded delegate (30 s deadline, ≤5 redirects, content-type allowlist, oversize abort via Content-Length and byte counting)
- **Preflight.swift** — `validateTorrentData`/`validateTorrentFileSize` (limits, zero-size, piece sanity)
- **NegativeCorpus.swift** — `BencodeCase`/`MetainfoCase` corpora + `MetainfoBuilder` + `BencodeBuilder` + magnet/path corpora
- **TransferRecord.swift** — `TransferEngine` protocol, `TransferTorrentStatus`, `TransferAggregateStats.zero`
- **TransferEventBus.swift** — actor bus, `Sink(id:handler:)`, urgent/immediate flush, 50 ms default batched flush
- **TorrentAdder.swift** — inspect (file/magnet/URL → content identity + metainfo + trackers), selection validation, hex helpers
- **TransferCoordinator.swift** — `actor` command surface (`processCommand` never throws, typed `EngineFault`), commitAdd (durable first: addTorrent + journal + storeMetainfo, then best-effort engine add), duplicate by ContentIdentity → same recordID, idempotent replay by `IdempotencyKey`, restoreFromPersistence rebuild, delta publication (fixed: continuity check is `from + 1 < firstLogRevision`), files/trackers paging with opaque UInt32 cursors, pause/resume/recheck/requestRemoval, setFileSelection → `inspectionInvalidated(files)` event
- **BridgeTransferEngine.swift** — `actor BridgeTransferEngine: TransferEngine` over `EngineCoordinator`: idempotent `start()`, add/pause/resume/recheck passthrough, remove = prepareRemoval + commitRemoval, status pump drain (≤200 alerts, fraction+state mapping, cached per engineID), `aggregateHealth()`

### Native/TorrentinoEngineAgent/ (modified)
- **Agent/AgentService.swift** — `sendCommand` lane (fault envelope `engineNotReady` before wiring), `subscribeEvents`/`unsubscribeEvents` (bus sink per connection, id-replaced), `setEventSink`, async-safe `deliver` via `withLock`
- **Agent/AgentRuntime.swift** — `import TorrentinoIPC`; `wireTransferLanes()` after persistence open (bus + bridge + coordinator, 500 ms pump, `PersistedLocation(path: defaultDownloadsPath)`), `await coordinator.startPump()`, shutdown captures + `await coordinator.stop()` before clean-close; ListenerDelegate binds `remoteObjectInterface` + sink on accept, clears on interruption/invalidation
- **Transfer/TransferCoordinator.swift** — commitAdd persistence failures now carry `redactedContext` (diagnostics-only)

### Native/TorrentinoApp/ (modified/new)
- **EngineClient/EngineClient.swift** — `sendCommand(_:) -> SuccessPayload`, `sendEnvelope(_:) -> IPCEnvelope`, `subscribeEvents(handler:)`/`unsubscribeEvents()`, exports `ClientEventSink` (`TorrentinoEventSink`) on every connection
- **Features/TorrentListViewModel.swift** — `@MainActor` VM: full snapshot + delta application with revision guards, fixture fallback (`FixtureLibrary`, deterministic 100-row), files drill-down with `FileCursor`, `TorrentStatusBarModel` aggregation, add (magnet/file/URL) + pause/resume commands
- **Features/TorrentListView.swift** — `NavigationSplitView` + sidebar filters with badges + `Table(selection:)` + context menu + files pane + bottom status bar (macOS 13-safe placeholders; `value:`-based TableColumn dropped in favor of content-only for SDK compatibility)
- **Features/AddTorrentSheet.swift** — text/file/add flows with start-paused toggle
- **App/TorrentinoApp.swift** — `AppContext` (`@MainActor` enum: engineClient/shared/transfers); **ContentView.swift** — hosts transfer window + degraded banner
- **Resources/Localizable.xcstrings** — +45 keys (total 63)

### Native/Tests/TorrentinoEngineAgentTests/ (new)
- **TransferSmokeTests.swift** — 25 tests: bencode positive/negative, metainfo single/multi + negative corpus, preflight gates, magnet valid/negative corpus, PathValidator corpora, HTTP fetch via `StubURLProtocol` (success/content-type/404/oversize/invalid URL), coordinator end-to-end (commitAdd → delta delivery, duplicate detection, idempotent replay, commit-without-inspect → `operationNotFound`, pause/resume, files drill-down + cursor pagination, setFileSelection → `.skip` + `inspectionInvalidated(files)`), restart restore over the same store; `StubTransferEngine` actor + `DeliveryCollector`

### Native/Torrentino.xcodeproj/project.pbxproj
- `Transfer` group (11 files) registered in agent Sources; transfer sources + `EngineBridgeDTOs.swift` registered in the tests target (stub engine needs the DTOs); `PathValidator.swift` added to the TorrentinoDomain target (was orphaned); 3 app feature files registered; `TransferSmokeTests.swift` registered; `TorrentinoEngineAgentTests` target now depends on + links TorrentinoDomain and TorrentinoIPC (dependencies were empty)

## Gates Verified

| Gate | Status |
|------|--------|
| Full scheme `Torrentino` (Developer ID signed) builds | ✅ BUILD SUCCEEDED |
| WP-07 smoke tests (TransferSmokeTests) | ✅ 25/25 pass |
| TorrentinoEngineAgentTests (incl. WP-05/06 persistence suite) | ✅ TEST SUCCEEDED |
| TorrentinoDomainTests + TorrentinoIPCTests + TorrentinoAppTests | ✅ TEST SUCCEEDED |
| Swift 6 strict concurrency (Complete) | ✅ no warnings (async-context locks → `withLock`; `nonisolated(unsafe)` only in the URLProtocol test stub) |

## Test Results

```
xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests
** TEST SUCCEEDED ** (25/25)

xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' -only-testing:TorrentinoEngineAgentTests
** TEST SUCCEEDED **

xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' -only-testing:TorrentinoDomainTests \
  -only-testing:TorrentinoIPCTests -only-testing:TorrentinoAppTests
** TEST SUCCEEDED **
```

## Implementation Notes
- **Delta continuity fix**: the first delta publish compared `from (0) < firstLogRevision (1)` and wrongly emitted `.snapshotRequired(.droppedDelta)`; corrected to `from + 1 < firstLogRevision`. Caught by the smoke test asserting `torrentDelta.added` on first commit.
- **Persistence ownership**: the agent opens the store once; `TransferCoordinator` receives it by reference. Tests mirror this (`makeCoordinator` opens the store before building the coordinator) — commitAdd without an open store fails with `storeError` + `redactedContext`.
- **Table SDK quirk**: `TableColumn(_:value:content:)` requires a sorting table on macOS 13 SDK; the name column uses a content-only column instead.
- **Test-only annotations**: `nonisolated(unsafe)` confined to `StubURLProtocol` statics; production code has none.
- **Files drill-down semantics**: top-level page of a multi-file torrent with a common root shows the root directory only (all files live below it) — asserted accordingly.

---

# WP-07 Reviewer Fixes (CHANGES_REQUESTED)

## RESULT: waiting_review

## Fix 1 — HIGH: RU localization for 45 new keys
`Native/TorrentinoApp/Resources/Localizable.xcstrings`: all 45 new WP-07 keys (`torrents.title`, `torrents.add.*`, `torrents.col.*`, `torrents.filter.*`, `torrents.status.*`, `torrents.action.*`, `torrents.files.*`, `torrents.sidebar.library`, `fixture.note`, `subscribe.failed`, `add.failed`, `files.failed`) now carry full `ru` localizations. Terminology follows the agreed glossary: торент, загрузка/отдача, раздача, на паузе, прогресс, размер, статус, библиотека, magnet-ссылка. `test_wp03_string_catalog.sh` now validates `keys=63 langs=en+ru complete`.

## Fix 2 — HIGH: empty-state contract restored in ContentView.swift
`Native/TorrentinoApp/Features/ContentView.swift` regains the `emptyState` wrapper (`square.stack.3d.up.slash`, `String(localized: "empty.no_torrents")`, `String(localized: "empty.subtitle")`, no `TorrentInfo(` fabrication) and displays it full-window whenever the authoritative list is empty, with an "Add Torrent…" button opening the same sheet. Lifecycle was hoisted to ContentView so the empty branch still starts the VM: `.task { await transfers.start() }` and the `.sheet` moved from `TorrentListView` to `ContentView` (single owner — no duplicate subscribe or double sheet presentation). `TorrentListView` keeps its in-table overlay empty state for the filter-matches-nothing case.

## Gates Verified

| Gate | Status |
|------|--------|
| test_wp03_string_catalog.sh | ✅ PASS (63 keys, en+ru complete) |
| test_wp03_empty_state.sh | ✅ PASS (static contract + AppTests green) |
| run_qa_suite.sh | ✅ GREEN 71/71 (wp01: 11, wp02: 13, wp03: 8, wp04: 13, wp05: 12, wp06: 14) |
| xcodebuild build (Developer ID signed) | ✅ BUILD SUCCEEDED |
