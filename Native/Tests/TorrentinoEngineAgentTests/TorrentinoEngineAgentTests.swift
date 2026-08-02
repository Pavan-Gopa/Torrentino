// Layer: WP-06 smoke tests (durable persistence/recovery).
// Role: covers the plan gate — clean restore cycles, repeated kill -9
// restore, no duplicate/lost records, desired states, corrupt resume
// quarantine/recheck, corrupt DB controlled recovery, WAL-only record
// restoration, forensic group preservation, clean flag stays false at every
// interrupted phase, payload integrity, journal cap/truncation/replay,
// single-writer advisory lock, generation monotonicity, failpoint lifecycle,
// and the 50-100 record fixture.
// Must-not: touch production ~/Library/Application Support (TestProfile only),
// or leave failpoints armed between tests.
// Invariants: each test restarts the store by creating a fresh instance on
// the same directory — the in-process equivalent of a process restart.

import Foundation
import XCTest

final class TorrentinoEngineAgentPersistenceTests: TestProfileCase {

    override func setUp() {
        super.setUp()
        FailpointInjector.disarmAll()
    }

    override func tearDown() {
        FailpointInjector.disarmAll()
        super.tearDown()
    }

    private func makeStore() -> PersistenceStore {
        PersistenceStore(dataDirectory: profile.rootURL)
    }

    // MARK: - Schema, WAL, migrations

    func testOpenCreatesSchemaWithWAL() async throws {
        let store = makeStore()
        let report = try await store.open()
        XCTAssertTrue(report.integrityOK)
        XCTAssertFalse(report.rebuilt)
        XCTAssertFalse(report.cleanShutdown)

        let probe = SQLiteConnection(path: store.databaseURL.path)
        try probe.open()
        let mode = try scalar("PRAGMA journal_mode", connection: probe)
        XCTAssertEqual(mode, "wal", "engine must run in WAL mode")
        let synchronous = try scalar("PRAGMA synchronous", connection: probe)
        XCTAssertEqual(synchronous, "1", "synchronous=NORMAL (WAL-safe)")
        let schemaVersion = try scalar("SELECT MAX(version) FROM schema_version", connection: probe)
        XCTAssertEqual(schemaVersion, "1")
        probe.close()
        let foreignKeys = try await store.foreignKeysEnabled()
        XCTAssertTrue(foreignKeys, "foreign_keys=ON on the store connection")

        // Reopen is idempotent: migrations must not re-run or conflict.
        try await store.close(clean: true)
        let reopened = makeStore()
        let second = try await reopened.open()
        XCTAssertTrue(second.integrityOK)
        XCTAssertFalse(second.rebuilt)
    }

    private func scalar(_ sql: String, connection: SQLiteConnection) throws -> String {
        let statement = try connection.prepare(sql)
        guard try statement.step() == .row else { return "" }
        return statement.columnText(0) ?? ""
    }

    // MARK: - Clean restore cycles

    func testThreeCleanRestoreCycles() async throws {
        for cycle in 0..<3 {
            let store = makeStore()
            let report = try await store.open()
            XCTAssertFalse(report.rebuilt)
            try await PersistenceFixture.write(store: store, count: 30, seed: cycle * 100)
            try await store.close(clean: true)
        }
        let final = makeStore()
        let report = try await final.open()
        XCTAssertTrue(report.cleanShutdown, "last shutdown was clean")
        let torrents = try await final.allTorrents()
        XCTAssertEqual(torrents.count, 90, "all three cycles must survive")
        for torrent in torrents {
            let resume = try await final.resumeData(torrentID: torrent.id)
            XCTAssertNotNil(resume)
            let metainfo = try await final.metainfo(torrentID: torrent.id)
            XCTAssertNotNil(metainfo)
        }
    }

    // MARK: - Repeated kill -9 restore

    func testRepeatedKillNineRestore() async throws {
        for cycle in 0..<4 {
            let store = makeStore()
            let report = try await store.open()
            XCTAssertFalse(report.rebuilt)
            try await PersistenceFixture.write(store: store, count: 20, seed: cycle * 100)
            // kill -9: no clean shutdown, WAL left uncheckpointed.
            try await store.close(clean: false)
        }
        let final = makeStore()
        let report = try await final.open()
        XCTAssertFalse(report.cleanShutdown, "kill -9 must leave the flag false")
        let finalTorrents = try await final.allTorrents()
        XCTAssertEqual(finalTorrents.count, 80, "no records lost across crashes")
        let resumeCount = try await final.recordCount(kind: .resume)
        XCTAssertEqual(resumeCount, 80, "no duplicates")
        let metainfoCount = try await final.recordCount(kind: .metainfo)
        XCTAssertEqual(metainfoCount, 80, "no duplicates")
    }

    // MARK: - No duplicate/lost records + generations

    func testNoDuplicateOrLostRecordsWithGenerations() async throws {
        let store = makeStore()
        _ = try await store.open()
        try await PersistenceFixture.write(store: store, count: 25, seed: 1)
        let torrent = try await store.allTorrents()[0]

        let g1 = try await store.storeResumeData(torrentID: torrent.id, data: PersistenceFixture.payload(1))
        let g2 = try await store.storeResumeData(torrentID: torrent.id, data: PersistenceFixture.payload(2))
        XCTAssertGreaterThan(g2, g1, "generations must be strictly increasing")
        let loaded = try await store.resumeData(torrentID: torrent.id)
        XCTAssertEqual(loaded?.generation, g2, "read path returns the latest generation")
        XCTAssertEqual(loaded?.data, PersistenceFixture.payload(2))

        let resumeCount = try await store.recordCount(kind: .resume)
        XCTAssertEqual(resumeCount, 25, "superseded generations are deleted")
        let metainfoCount = try await store.recordCount(kind: .metainfo)
        XCTAssertEqual(metainfoCount, 25)

        try await store.close(clean: false)
        let reopened = makeStore()
        _ = try await reopened.open()
        let g3 = try await reopened.storeResumeData(torrentID: torrent.id, data: PersistenceFixture.payload(3))
        XCTAssertGreaterThan(g3, g2, "generation clock must never be reused after a crash")
    }

    // MARK: - Desired states

    func testDesiredStatesPersisted() async throws {
        let store = makeStore()
        _ = try await store.open()
        let torrent = StoredTorrent(id: "state-torrent-1", infoHashV1: "abc123", infoHashV2: nil,
                                    name: "state-test", state: "paused", addedAt: 42, quarantined: false)
        try await store.addTorrent(torrent)
        try await store.updateTorrentState(torrentID: torrent.id, state: "seeding")
        try await store.close(clean: true)

        let reopened = makeStore()
        _ = try await reopened.open()
        let loaded = try await reopened.torrent(withID: torrent.id)
        XCTAssertEqual(loaded?.state, "seeding")
        XCTAssertEqual(loaded?.infoHashV1, "abc123")
        XCTAssertEqual(loaded?.addedAt, 42)
        XCTAssertEqual(loaded?.name, "state-test")
    }

    // MARK: - Corrupt resume -> quarantine/recheck, never crash

    func testCorruptResumeQuarantinedAndTorrentRechecked() async throws {
        let store = makeStore()
        _ = try await store.open()
        try await PersistenceFixture.write(store: store, count: 5, seed: 7)
        let target = try await store.allTorrents()[0]
        let other = try await store.allTorrents()[1]
        try await store.close(clean: false)

        // Bit rot / torn write: corrupt the stored checksum of one record.
        let probe = SQLiteConnection(path: store.databaseURL.path)
        try probe.open()
        try probe.exec("UPDATE resume_data SET checksum = '0000000000000000000000000000000000000000000000000000000000000000' WHERE torrent_id = '\(target.id)'")
        probe.close()

        let reopened = makeStore()
        let report = try await reopened.open()
        XCTAssertGreaterThanOrEqual(report.checksumFailures, 1)
        XCTAssertGreaterThanOrEqual(report.quarantined, 1)

        let quarantine = try await reopened.quarantineRecords()
        XCTAssertTrue(quarantine.contains { $0.torrentID == target.id && $0.kind == "resume" },
                      "corrupt record must be quarantined with payload preserved")
        let targetState = try await reopened.torrent(withID: target.id)?.state
        XCTAssertEqual(targetState, "needs-recheck")
        let targetResume = try await reopened.resumeData(torrentID: target.id)
        XCTAssertNil(targetResume)

        let otherResume = try await reopened.resumeData(torrentID: other.id)
        XCTAssertNotNil(otherResume, "other records unaffected")
        let all = try await reopened.allTorrents()
        XCTAssertEqual(all.count, 5, "store keeps serving")
    }

    // MARK: - Corrupt database -> controlled recovery / degraded mode

    func testCorruptDatabaseControlledRecovery() async throws {
        let store = makeStore()
        _ = try await store.open()
        try await PersistenceFixture.write(store: store, count: 10, seed: 3)
        try await store.close(clean: false)
        // Release the crashed session's fds before overwriting the file.
        await store.rawClose()

        // Overwrite the main database with garbage; the forensic trio stays.
        let garbage = Data(repeating: 0xAB, count: 4096 * 40)
        try garbage.write(to: store.databaseURL)

        let reopened = makeStore()
        let report = try await reopened.open()
        XCTAssertTrue(report.rebuilt, "corrupt DB must trigger controlled recovery, not a crash")
        XCTAssertTrue(report.degraded)
        XCTAssertFalse(report.cleanShutdown)

        // Forensic trio moved aside together.
        let contents = try FileManager.default.contentsOfDirectory(atPath: profile.rootURL.path)
        let corruptDirs = contents.filter { $0.hasPrefix("corrupt-") }
        XCTAssertEqual(corruptDirs.count, 1, "corrupt group must be preserved aside")
        let preservedMain = profile.rootURL.appendingPathComponent(corruptDirs[0]).appendingPathComponent("engine.sqlite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedMain.path))

        // Store is usable in degraded mode.
        let fresh = StoredTorrent(id: "post-rebuild-1", infoHashV1: nil, infoHashV2: nil,
                                  name: "post", state: "queued", addedAt: 1, quarantined: false)
        try await reopened.addTorrent(fresh)
        _ = try await reopened.storeResumeData(torrentID: fresh.id, data: Data("hello".utf8))
        let restored = try await reopened.resumeData(torrentID: fresh.id)?.data
        XCTAssertEqual(restored, Data("hello".utf8))
    }

    // MARK: - Record existing only in WAL is restored

    func testRecordOnlyInWALRestoredAfterCrash() async throws {
        let store = makeStore()
        _ = try await store.open()
        let torrent = StoredTorrent(id: "wal-only-1", infoHashV1: nil, infoHashV2: nil,
                                    name: "wal", state: "downloading", addedAt: 0, quarantined: false)
        try await store.addTorrent(torrent)
        _ = try await store.storeResumeData(torrentID: torrent.id, data: Data("wal-record".utf8))
        try await store.close(clean: false)

        let walURL = await store.walURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path),
                      "unclean close must leave the WAL on disk")
        XCTAssertGreaterThan(try fileSize(walURL), 0, "unclean close must leave WAL frames un-checkpointed")

        // Prove the record is NOT in the main file yet: a COPY of the main
        // database has no -wal/-shm siblings, so SQLite reads main alone.
        // The whole session (schema + records) lives in WAL frames, so the
        // copy contains no tables at all.
        let mainCopy = profile.rootURL.appendingPathComponent("main-copy.db")
        try FileManager.default.copyItem(at: store.databaseURL, to: mainCopy)
        let probe = SQLiteConnection(path: mainCopy.path)
        try probe.open()
        let tables = try probe.prepare("SELECT COUNT(*) FROM sqlite_master WHERE name = 'resume_data'")
        guard try tables.step() == .row else {
            XCTFail("unreadable main file")
            return
        }
        XCTAssertEqual(tables.columnInt64(0), 0, "record exists only in the WAL (main file has no schema)")
        probe.close()

        // Reopen: SQLite replays the WAL and restores the record.
        let reopened = makeStore()
        _ = try await reopened.open()
        let restored = try await reopened.resumeData(torrentID: torrent.id)?.data
        XCTAssertEqual(restored, Data("wal-record".utf8))
        let all = try await reopened.allTorrents()
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - Forensic group

    func testForensicGroupPreserved() async throws {
        let store = makeStore()
        _ = try await store.open()
        try await PersistenceFixture.write(store: store, count: 10, seed: 5)
        try await store.close(clean: false)

        let uncleanStatus = await store.forensicGroupStatus()
        XCTAssertTrue(uncleanStatus.mainExists)
        XCTAssertTrue(uncleanStatus.walExists, "unclean close must preserve the WAL for replay/forensics")
        let uncleanSize = try fileSize(await store.walURL)
        XCTAssertGreaterThan(uncleanSize, 0, "unclean close must leave WAL frames un-checkpointed")

        // The crashed process's fds are released (kernel does this on SIGKILL).
        await store.rawClose()

        // Clean shutdown checkpoints the WAL into main; the WAL is emptied.
        let reopened = makeStore()
        _ = try await reopened.open()
        try await reopened.close(clean: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.databaseURL.path))
        let cleanSize = try fileSize(await reopened.walURL)
        XCTAssertEqual(cleanSize, 0, "clean shutdown must checkpoint the WAL to empty")
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? 0
    }

    // MARK: - clean_shutdown stays false at every interrupted phase

    func testCleanShutdownFlagStaysFalseAtEveryInterruptedPhase() async throws {
        // Phase A: interrupt the write pipeline (failpoints 1-6).
        let writeFailpoints: [FailpointID] = [
            .beforeTemporaryWrite, .afterWriteBeforeFileFsync, .afterFileFsync,
            .afterRenameBeforeParentFsync, .afterRenameBeforeSQLiteTransaction,
            .afterDBCommitBeforePreviousGenerationDelete,
        ]
        for id in writeFailpoints {
            FailpointInjector.disarmAll()
            let store = makeStore()
            _ = try await store.open()
            try await PersistenceFixture.write(store: store, count: 5, seed: 1)
            let torrent = try await store.allTorrents()[0]
            FailpointInjector.arm(id) { thrown in throw PersistenceError.injectedFailpoint(thrown) }
            do {
                _ = try await store.storeResumeData(torrentID: torrent.id, data: PersistenceFixture.payload(123))
                XCTFail("failpoint \(id) must interrupt the write")
            } catch {
                // expected interruption
            }
            let cleanFlag = try await store.cleanShutdownFlag()
            XCTAssertFalse(cleanFlag, "flag stays false after \(id)")
            FailpointInjector.disarm(id)
            let generation = try await store.storeResumeData(torrentID: torrent.id, data: PersistenceFixture.payload(124))
            XCTAssertGreaterThan(generation, 0, "store must keep serving after \(id)")
            try await store.close(clean: false)
        }

        // Phase B: interrupt the clean-shutdown pipeline (failpoints 7-8).
        // Phase A left 5 torrents (seed 1); every Phase B iteration adds 5
        // more with a distinct seed, so the expected total grows monotonically.
        let shutdownFailpoints: [FailpointID] = [.duringWALCheckpoint, .eachCleanShutdownStep]
        var expected = 5
        var phase = 2
        for id in shutdownFailpoints {
            FailpointInjector.disarmAll()
            let store = makeStore()
            _ = try await store.open()
            try await PersistenceFixture.write(store: store, count: 5, seed: phase * 100)
            expected += 5
            FailpointInjector.arm(id) { thrown in throw PersistenceError.injectedFailpoint(thrown) }
            do {
                try await store.close(clean: true)
                XCTFail("failpoint \(id) must interrupt clean shutdown")
            } catch {
                // expected interruption
            }
            FailpointInjector.disarmAll()
            let reopened = makeStore()
            let report = try await reopened.open()
            XCTAssertFalse(report.cleanShutdown, "flag stays false after interrupted phase \(id)")
            let all = try await reopened.allTorrents()
            XCTAssertEqual(all.count, expected, "records intact after \(id)")
            try await reopened.close(clean: false)
            phase += 1
        }
        FailpointInjector.disarmAll()
    }

    // MARK: - Payload integrity

    func testPayloadUnchangedAcrossCycles() async throws {
        let store = makeStore()
        _ = try await store.open()
        let torrent = StoredTorrent(id: "payload-1", infoHashV1: nil, infoHashV2: nil,
                                    name: "p", state: "downloading", addedAt: 0, quarantined: false)
        try await store.addTorrent(torrent)
        let payload = PersistenceFixture.payload(77, size: 8192)
        for _ in 0..<20 {
            _ = try await store.storeResumeData(torrentID: torrent.id, data: payload)
        }
        let stored = try await store.resumeData(torrentID: torrent.id)?.data
        XCTAssertEqual(stored, payload)
        try await store.close(clean: false)

        let reopened = makeStore()
        _ = try await reopened.open()
        let restored = try await reopened.resumeData(torrentID: torrent.id)?.data
        XCTAssertEqual(restored, payload,
                       "payload must be byte-identical after a crash")
    }

    // MARK: - Journal cap, truncation, replay

    func testJournalCapAndCleanTruncation() async throws {
        let store = makeStore()
        _ = try await store.open()
        for index in 0..<1100 {
            _ = try await store.journalAppend(command: "synthetic-\(index)", torrentID: nil, timestamp: Int64(index))
        }
        try await OperationJournal.trim(store: store)
        let count = try await store.journalCount()
        XCTAssertEqual(count, 1000, "journal is capped at 1000 entries")

        let pending = try await OperationJournal.pending(store: store)
        XCTAssertEqual(pending.count, 1000, "synthetic entries are pending replay candidates")

        try await store.close(clean: true)
        let reopened = makeStore()
        _ = try await reopened.open()
        let reopenedCount = try await reopened.journalCount()
        XCTAssertEqual(reopenedCount, 0, "clean shutdown truncates the journal")
    }

    func testJournalReplayMarksTorrentsForRecheck() async throws {
        let store = makeStore()
        _ = try await store.open()
        let torrent = StoredTorrent(id: "replay-1", infoHashV1: nil, infoHashV2: nil,
                                    name: "replay", state: "downloading", addedAt: 0, quarantined: false)
        try await store.addTorrent(torrent)
        // An operation that journaled but never committed (crash window).
        let seq = try await store.journalAppend(command: "store-resume-data", torrentID: torrent.id, timestamp: 1)
        XCTAssertGreaterThan(seq, 0)
        try await store.close(clean: false)

        let reopened = makeStore()
        let report = try await reopened.open()
        XCTAssertGreaterThanOrEqual(report.journalReplayed, 1)
        let state = try await reopened.torrent(withID: torrent.id)?.state
        XCTAssertEqual(state, "needs-recheck",
                       "replayed operation conservatively marks the torrent for recheck")
        try await reopened.close(clean: false)

        let again = makeStore()
        let second = try await again.open()
        XCTAssertEqual(second.journalReplayed, 0, "replayed entries are never replayed twice")
        let entries = try await again.journalAllEntries()
        XCTAssertTrue(entries.allSatisfy { $0.status != "pending" })
    }

    // MARK: - Advisory lock (single writer)

    func testAdvisoryLockSingleWriter() throws {
        let first = try AdvisoryLock.acquire(dataDirectory: profile.rootURL)
        do {
            _ = try AdvisoryLock.acquire(dataDirectory: profile.rootURL)
            XCTFail("a second writer must be rejected")
        } catch let error as AdvisoryLockError {
            guard case .alreadyLocked = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        }
        first.release()
        let second = try AdvisoryLock.acquire(dataDirectory: profile.rootURL)
        second.release()
    }

    // MARK: - Failpoint lifecycle

    func testFailpointLifecycle() throws {
        for id in FailpointID.allCases {
            FailpointInjector.disarmAll()
            try FailpointInjector.fire(id) // unarmed: no-op in production

            FailpointInjector.arm(id) { thrown in throw PersistenceError.injectedFailpoint(thrown) }
            do {
                try FailpointInjector.fire(id)
                XCTFail("armed failpoint \(id) must throw")
            } catch let error as PersistenceError {
                guard case .injectedFailpoint(let fired) = error else {
                    XCTFail("unexpected error: \(error)")
                    return
                }
                XCTAssertEqual(fired, id)
            }

            FailpointInjector.disarm(id)
            try FailpointInjector.fire(id) // disarmed: no-op again
        }
    }

    // MARK: - 50-100 record fixture

    func testFixtureSeventyFiveRecords() async throws {
        let store = makeStore()
        let report = try await store.open()
        XCTAssertTrue(report.integrityOK)
        try await PersistenceFixture.write(store: store, count: 75, seed: 42)
        let all = try await store.allTorrents()
        XCTAssertEqual(all.count, 75)
        let resumeCount = try await store.recordCount(kind: .resume)
        XCTAssertEqual(resumeCount, 75)
        let metainfoCount = try await store.recordCount(kind: .metainfo)
        XCTAssertEqual(metainfoCount, 75)
        let quarantineCount = try await store.quarantineCount()
        XCTAssertEqual(quarantineCount, 0)
    }
}
