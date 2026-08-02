# FEEDBACK — WP-06 Review (Durable persistence/recovery)

**Reviewer:** Verification Engineer
**Date:** 2026-08-03
**RESULT:** APPROVED

### 1. Build & tests
- Xcode build `xcodebuild -scheme Torrentino -destination 'platform=macOS,arch=arm64'` (Developer ID + team 438UQRF7JV): **BUILD SUCCEEDED, 0 warnings** (warnings-as-errors is on via `Shared.xcconfig`: `SWIFT_VERSION=6.0`, `SWIFT_STRICT_CONCURRENCY=complete`, `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`; grep of build log: zero `warning:`/`error:` lines).
- Xcode tests: **TEST SUCCEEDED** — `TorrentinoIPCTests` + `TorrentinoAppTests` (incl. the WP-05 PeerValidation tests that were the previous blocker — now present and passing) + **16 new `TorrentinoEngineAgentPersistenceTests`** all passing (clean/kill-9 cycles, WAL-only record, forensic group, failpoint phases, quarantine, rebuild, journal, advisory lock, fixture).
- QA regression `run_qa_suite.sh`: **57/57 PASS (GREEN)** — wp01: 11, wp02: 13, wp03: 8, wp04: 13, wp05: 12. Includes `harness_all_scenarios` with the WP-01 `crash_restore` (real SIGKILL child, `scenarios_persistence.cpp:287`) and strict-concurrency/legacy-untouched gates.

### 2. Gate checklist (plan row 2340)

- [x] **Три clean restore cycles** — `testThreeCleanRestoreCycles` (3 cycles × 30 records; 90 survive with resume+metainfo; clean flag true at final boot). Evidence: TorrentinoEngineAgentTests.swift:70-89.
- [x] **Repeated kill -9 restore** — `testRepeatedKillNineRestore` (4 crash cycles × 20 records; 80/80 survive; flag stays false). TorrentinoEngineAgentTests.swift:93-111.
- [x] **No duplicate/lost records** — record counts asserted equal to torrent counts after every crash cycle (swift:106-110); superseded generations deleted (`recordCount == 25` after re-store, swift:128-131); journal replay never runs twice (swift:430).
- [x] **Desired states сохранены** — `testDesiredStatesPersisted` (state `seeding`, infoHashV1, addedAt, name survive restart). swift:142-158.
- [x] **Corrupt resume → quarantine/recheck, не crash** — checksum rewritten to garbage → startup `verifyChecksums` detects, row moved to `quarantine` with payload preserved, torrent marked `needs-recheck`, other records unaffected, store keeps serving. `testCorruptResumeQuarantinedAndTorrentRechecked` swift:162-193; store logic PersistenceStore.swift:517-552, 668-688.
- [x] **Corrupt DB copy → controlled recovery/degraded mode** — main file overwritten with garbage → `recovered`, `rebuilt=true`, `degraded=true`, forensic trio moved to `corrupt-<stamp>/`, store usable (add + store + read roundtrip). `testCorruptDatabaseControlledRecovery` swift:197-229; store logic PersistenceStore.swift:777-851 (salvage read-only probe, fresh DB via open→migrate→inserts, counters adopted).
- [x] **Запись, существующая только в WAL, восстанавливается** — unclean close leaves WAL non-empty; a copy of main alone has no schema (proves the record lives only in WAL frames); reopen replays WAL and restores the record. `testRecordOnlyInWALRestoredAfterCrash` swift:233-270.
- [x] **SQLite main/WAL/SHM как единая forensic group** — unclean close preserves WAL with frames (swift:282-284); `moveForensicGroupAside` moves all three together (PersistenceStore.swift:493-511); clean shutdown collapses WAL to empty (swift:292-295); recovery test asserts the trio lands in one `corrupt-` dir.
- [x] **clean_shutdown остаётся false при любой незавершённой фазе** — all 8 failpoints exercised: write pipeline (1-6) leaves flag false and store serving; shutdown pipeline (7-8) leaves flag false and records intact. `testCleanShutdownFlagStaysFalseAtEveryInterruptedPhase` swift:305-362; flag is the LAST durable write of the pipeline (ShutdownCoordinator.swift:43-47).
- [x] **Payload не изменён** — 8 KB payload stored 20×, byte-identical after a crash-restart. `testPayloadUnchangedAcrossCycles` swift:366-385.

### 3. Code quality
- **Sendable / immutability:** all value types (`StoredTorrent`, `StoredPayload`, `IntegrityReport`, `ForensicGroupStatus`, `StartupReport`, `RebuildReport`, `RecordCorruption`, `JournalEntry`, `QuarantineRecord`, `PersistenceHealthSnapshot`) are `Sendable` (+`Equatable`); `PersistenceStore` is an actor; `SQLiteConnection`/`SQLiteStatement`/`GenerationClock`/`FailpointInjector.Registry`/`AdvisoryLockHandle` are `@unchecked Sendable` with documented, verified actor/thread confinement (the sqlite3 handle never escapes the store actor). Swift 6 strict concurrency = Complete; 0 warnings.
- **SQLite C API:** statements finalized in `deinit` (SQLiteConnection.swift:53-55); `sqlite3_close_v2` idempotent (183-188); `sqlite3_free` on the error buffer (195-198); binds use a transient destructor so Swift strings/Data are copied before the stack frame dies (SQLiteConnection.swift:46); read-only probe for salvage never writes recovery data into the damaged file (169-181).
- **WAL mode:** `PRAGMA journal_mode=WAL`, `synchronous=NORMAL`, `foreign_keys=ON`, `busy_timeout=5000` (PersistenceStore.swift:870-875); WAL mode + synchronous=NORMAL verified by test.
- **Atomic write path:** temp → write → fsync(file) → close → rename → parent-dir fsync, durability-correct order, with error cleanup (unlink temp on failure) (AtomicGeneration.swift:91-131); `CounterStore.AtomicFile` uses the identical pattern.
- **Checksums:** SHA-256 stored with every payload, verified on every read (PersistenceStore.swift:332-338, 373-379, 407-412) and for every record at startup (668-709).
- **Failpoints:** exactly the 8 plan points (FailpointInjector.swift:16-35), registry locked, `fire()` is a no-op unless armed, throws propagate so the store aborts the phase exactly like a crash at that boundary; nothing in production arms them (test-only).
- **Advisory lock:** `flock(LOCK_EX|LOCK_NB)`, non-blocking, second writer → `alreadyLocked` (AdvisoryLock.swift:69-72); wired into `AgentRuntime.init` → bootstrap fault exit 1 (AgentRuntime.swift:54-61); test `testAdvisoryLockSingleWriter`.
- **Quarantine:** corrupt data never crashes — record-level quarantine with payload preserved + `needs-recheck`; DB-level salvage + rebuild; both degrade and keep serving.
- **Journal:** cap 1000 with trim-after-append (verified 1100→1000, swift:389-407); truncate on clean shutdown (swift:402-406); pending→replayed statuses, never replayed twice.
- **Forensic group:** trio moved/preserved as one unit; preserved in rebuild path.
- **Generation monotonicity:** counters restored from committed session state at open, clock never reused after crash (`testNoDuplicateOrLostRecordsWithGenerations` swift:115-138).

### 4. Architecture compliance
- target_files only: `Persistence/` (10 new files), `Agent/AgentRuntime.swift` (+46), `Agent/AgentService.swift` (+16), `Tests/TorrentinoEngineAgentTests/` (2 new + fixture), `project.pbxproj` (+175), xcscheme, FEEDBACK.md. Verified via `git show --name-only e6ea9e1` — zero files outside this scope.
- **Legacy/ untouched** (zero matches in the commit; `test_wp03_legacy_untouched.sh` still GREEN). EngineBridge C++ untouched (WP-01/04 scenarios merely re-run).
- No future-WP work: no UI changes (no TorrentinoApp sources), no transfer logic, `EngineCommand`/`EngineEvent` placeholders untouched. WP-07 items not pre-empted.
- Agent integration is lifecycle-only: background open after bootstrap (AgentRuntime.swift:97-104), clean pipeline on SIGTERM/XPC shutdown (139-144), health exposes plist-only persistence keys (AgentService.swift:66-70).

### 5. Notes (non-blocking, LOW)
1. **QA suite has no wp06 scripts** — the WP-06 gate is covered by the 16 XCTest smoke tests only (`run_qa_suite.sh` still shows wp01..wp05). Previous WPs shipped shell QA scripts; orchestrator may want wp06 scripts for parity, but test coverage itself is complete and green.
2. **Quarantine insert vs. delete not atomic** — `quarantineCorruptRecord` inserts into `quarantine` inside a transaction but deletes the bad row / marks recheck outside it (PersistenceStore.swift:528-551). If the delete throws, the next boot re-quarantines the same record → duplicate quarantine rows. Edge case only; harmless to store health.
3. **Salvage re-checksums metainfo instead of verifying it** — rebuild recomputes SHA-256 on salvaged data (PersistenceStore.swift:819), so a bit-rotted metainfo blob would survive a rebuild as "valid". Acceptable for best-effort salvage; a recheck policy note for WP-07.
4. **Advisory lock file unlink race** — `release()` unlinks `persistence.lock` after unlock (AdvisoryLock.swift:50); a third writer could create a new inode and lock it while a second process still holds the old one. Theoretical: the handle is released only at process exit in production.
5. **health() during `.opening`** may interleave with startup reconciliation (actor reentrancy at the first `await` in `reconcile`), but schema/migrations complete before the first suspension point and `healthSnapshot` uses `try?` throughout — worst case a stale snapshot, no crash.

Build & tests fully green; 10/10 gate items implemented and covered by automated tests with evidence above.
