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
