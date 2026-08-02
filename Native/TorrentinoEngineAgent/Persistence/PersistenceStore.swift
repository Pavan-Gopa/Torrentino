// Layer: Agent durable persistence (WP-06).
// Role: the authoritative SQLite store. Owns the single connection (WAL mode,
// synchronous=NORMAL, foreign_keys=ON), the schema/migration runner, the
// generation-based record CRUD (resume/metainfo/session), the integrity and
// forensic-group plumbing, and the controlled-recovery rebuild path.
// Must-not: touch the main actor, block XPC queues with file IO, or crash on
// corrupt data (every corrupt path degrades: quarantine, recheck, rebuild).
// Invariants: one writer per data directory (AdvisoryLock); a payload reaches
// SQLite only after its sidecar file is durable; every read verifies the
// SHA-256 checksum; clean_shutdown=true is the LAST durable write of a clean
// shutdown, so any interrupted phase leaves it false; the main DB, -wal and
// -shm files are moved/preserved together as one forensic group.

import Foundation
import OSLog

// MARK: - Value types (all Sendable)

struct StoredTorrent: Sendable, Equatable {
    let id: String
    let infoHashV1: String?
    let infoHashV2: String?
    let name: String
    let state: String
    let addedAt: Int64
    let quarantined: Bool
}

struct StoredPayload: Sendable, Equatable {
    let generation: UInt64
    let data: Data
}

struct IntegrityReport: Sendable, Equatable {
    let ok: Bool
    let detail: String
}

struct ForensicGroupStatus: Sendable, Equatable {
    let mainExists: Bool
    let walExists: Bool
    let shmExists: Bool

    /// The three files must travel together: losing one invalidates recovery.
    var isCompleteTrio: Bool { mainExists && walExists && shmExists }
}

struct StartupReport: Sendable, Equatable {
    let cleanShutdown: Bool
    let integrityOK: Bool
    let checksumsVerified: Int
    let checksumFailures: Int
    let quarantined: Int
    let journalReplayed: Int
    let orphanSidecarsRemoved: Int
    let degraded: Bool
    let rebuilt: Bool
    let message: String
}

struct RebuildReport: Sendable, Equatable {
    let preservedGroupURL: URL?
    let salvagedTorrents: Int
    let salvagedMetainfo: Int
}

struct RecordCorruption: Sendable {
    let kind: GenerationKind
    let torrentID: String?
    let generation: UInt64
    let reason: String
}

struct JournalEntry: Sendable, Equatable {
    let seq: Int64
    let timestamp: Int64
    let command: String
    let torrentID: String?
    let status: String
}

struct QuarantineRecord: Sendable, Equatable {
    let seq: Int64
    let quarantinedAt: Int64
    let kind: String
    let torrentID: String?
    let generation: UInt64
    let reason: String
    let payload: Data?
}

struct PersistenceHealthSnapshot: Sendable, Equatable {
    let state: String
    let cleanShutdown: Bool
    let degraded: Bool
    let quarantinedCount: Int
    let reconciliation: String
}

// MARK: - Store

actor PersistenceStore {
    enum StoreState: String, Sendable {
        case unopened, opening, ready, degraded, closed, failed
    }

    /// Current schema version. The migration runner applies every migration
    /// above the stored version; a stored version ABOVE this blocks the open.
    static let schemaVersion: Int = 1

    /// Session keys. clean_shutdown is the last durable write of a clean stop.
    static let cleanShutdownKey = "clean_shutdown"

    let dataDirectory: URL
    let databaseName: String
    let databaseURL: URL
    private(set) var state: StoreState = .unopened

    private var connection: SQLiteConnection?
    private var generationCounters: [GenerationKind: UInt64] = [:]
    private let sessionClock = GenerationClock(initial: 0)
    private var lastReport: StartupReport?
    private let log = Logger(subsystem: "com.torrentino.app.engine-agent", category: "persistence")

    /// Maximum journal rows kept. Older entries are trimmed after each append.
    static let journalLimit = 1000

    /// SQLite appends "-wal"/"-shm" to the main database path.
    var walURL: URL { URL(fileURLWithPath: databaseURL.path + "-wal") }
    var shmURL: URL { URL(fileURLWithPath: databaseURL.path + "-shm") }

    init(dataDirectory: URL, databaseName: String = "engine.sqlite3") {
        self.dataDirectory = dataDirectory
        self.databaseName = databaseName
        self.databaseURL = dataDirectory.appendingPathComponent(databaseName, isDirectory: false)
    }

    // MARK: - Open / close lifecycle

    /// Opens the database (creating it on first boot), applies pragmas and
    /// migrations, then runs startup reconciliation. On an unrecoverable
    /// database it performs controlled recovery (salvage + rebuild) and
    /// returns a report marked degraded instead of throwing.
    func open() async throws -> StartupReport {
        guard state == .unopened else { throw PersistenceError.alreadyOpen }
        state = .opening
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let database = SQLiteConnection(path: databaseURL.path)
            try database.open()
            try applyPragmas(database)
            try migrate(database)
            connection = database
            try restoreGenerationCounters()
            let report = try await StartupReconciler.reconcile(store: self)
            lastReport = report
            state = report.degraded ? .degraded : .ready
            log.notice("persistence open \(report.message, privacy: .public)")
            return report
        } catch let error as PersistenceError {
            switch error {
            case .corruptDatabase, .sqlite:
                // Corruption-class failure during open/pragma/migrate/reconcile:
                // controlled recovery — salvage, rebuild, degrade. Never crash.
                return try recoverFromOpenFailure(original: error)
            default:
                state = .failed
                log.error("persistence open failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        } catch let error as SQLiteError {
            return try recoverFromOpenFailure(original: error)
        }
    }

    /// Routes any corruption-class open failure into controlled recovery.
    private func recoverFromOpenFailure(original: Error) throws -> StartupReport {
        do {
            let rebuild = try recoverFromCorruptDatabase(reason: "\(original)")
            let report = StartupReport(
                cleanShutdown: false,
                integrityOK: false,
                checksumsVerified: 0,
                checksumFailures: 0,
                quarantined: 0,
                journalReplayed: 0,
                orphanSidecarsRemoved: 0,
                degraded: true,
                rebuilt: true,
                message: "rebuilt from salvage after corrupt database (\(original)); "
                    + "preserved=\(rebuild.preservedGroupURL?.lastPathComponent ?? "-") "
                    + "torrents=\(rebuild.salvagedTorrents) metainfo=\(rebuild.salvagedMetainfo)"
            )
            lastReport = report
            state = .degraded
            log.error("persistence degraded: \(report.message, privacy: .public)")
            return report
        } catch {
            state = .failed
            log.error("controlled recovery failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Closes the store. clean=true runs the full clean-shutdown pipeline
    /// (WAL flush, TRUNCATE checkpoint, journal truncation, clean flag); the
    /// flag is written LAST so any interrupted phase leaves it false.
    func close(clean: Bool) async throws {
        guard state != .closed, state != .unopened else { return }
        if clean {
            try await ShutdownCoordinator.performCleanShutdown(store: self)
        } else {
            // kill -9 semantics: leave the connection and the WAL untouched.
            // The forensic trio keeps its frames and the next open replays the
            // WAL exactly like a process restart after SIGKILL. (A real close
            // would let SQLite checkpoint the WAL into the main file.)
            log.notice("unclean close: connection left open (kill -9 semantics)")
        }
        state = .closed
    }

    /// Health snapshot for the XPC health() reply (strings/numbers only).
    func healthSnapshot() -> PersistenceHealthSnapshot {
        PersistenceHealthSnapshot(
            state: state.rawValue,
            cleanShutdown: (try? cleanShutdownFlag()) ?? false,
            degraded: state == .degraded,
            quarantinedCount: (try? quarantineCount()) ?? 0,
            reconciliation: lastReport?.message ?? "none"
        )
    }

    // MARK: - Torrent records

    func addTorrent(_ torrent: StoredTorrent) throws {
        try requireOpen()
        let statement = try prepare("""
            INSERT OR REPLACE INTO torrents (id, info_hash, info_hash_v2, name, state, added_at, quarantined)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        try statement.bindText(torrent.id, index: 1)
        try statement.bindText(torrent.infoHashV1, index: 2)
        try statement.bindText(torrent.infoHashV2, index: 3)
        try statement.bindText(torrent.name, index: 4)
        try statement.bindText(torrent.state, index: 5)
        try statement.bindInt64(torrent.addedAt, index: 6)
        try statement.bindInt64(torrent.quarantined ? 1 : 0, index: 7)
        _ = try statement.step()
    }

    func updateTorrentState(torrentID: String, state newState: String) throws {
        try requireOpen()
        guard torrentExists(torrentID) else { throw PersistenceError.unknownTorrent(id: torrentID) }
        let statement = try prepare("UPDATE torrents SET state = ? WHERE id = ?")
        try statement.bindText(newState, index: 1)
        try statement.bindText(torrentID, index: 2)
        _ = try statement.step()
    }

    func torrent(withID id: String) throws -> StoredTorrent? {
        try requireOpen()
        let statement = try prepare("""
            SELECT id, info_hash, info_hash_v2, name, state, added_at, quarantined
            FROM torrents WHERE id = ?
            """)
        try statement.bindText(id, index: 1)
        guard try statement.step() == .row else { return nil }
        return readTorrent(statement)
    }

    func allTorrents() throws -> [StoredTorrent] {
        try requireOpen()
        let statement = try prepare("""
            SELECT id, info_hash, info_hash_v2, name, state, added_at, quarantined FROM torrents
            """)
        var result: [StoredTorrent] = []
        while try statement.step() == .row {
            result.append(readTorrent(statement))
        }
        return result
    }

    func removeTorrent(torrentID: String) throws {
        try requireOpen()
        let statement = try prepare("DELETE FROM torrents WHERE id = ?")
        try statement.bindText(torrentID, index: 1)
        _ = try statement.step()
        PersistenceSidecar.removeAll(kind: .resume, owner: torrentID, dataDirectory: dataDirectory)
        PersistenceSidecar.removeAll(kind: .metainfo, owner: torrentID, dataDirectory: dataDirectory)
    }

    func markTorrentForRecheck(torrentID: String) throws {
        try requireOpen()
        let statement = try prepare("UPDATE torrents SET state = 'needs-recheck', quarantined = 1 WHERE id = ?")
        try statement.bindText(torrentID, index: 1)
        _ = try statement.step()
    }

    // MARK: - Resume data (atomic generation write path)

    /// Stores resume data. Sequence: journal -> sidecar (temp->fsync->rename->
    /// dir fsync) -> SQLite transaction (insert row, bump generation counter,
    /// mark journal committed) -> delete previous generation (row + sidecar).
    /// Failpoints 1-5 fire before/inside the durable phases, 6 after commit.
    func storeResumeData(torrentID: String, data: Data) throws -> UInt64 {
        try requireOpen()
        guard torrentExists(torrentID) else { throw PersistenceError.unknownTorrent(id: torrentID) }
        let seq = try journalAppend(command: "store-resume-data", torrentID: torrentID,
                                    timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        let generation = try nextGeneration(.resume)
        let prepared = try PersistenceSidecar.prepare(data: data, kind: .resume, owner: torrentID,
                                                      generation: generation, dataDirectory: dataDirectory)
        try FailpointInjector.fire(.afterRenameBeforeSQLiteTransaction)
        try withTransaction {
            try insertGenerationRow(kind: .resume, torrentID: torrentID, generation: generation,
                                    data: data, checksum: prepared.checksum)
            try persistGenerationCounter(.resume, generation)
            try journalMarkCommitted(seq: seq)
        }
        try FailpointInjector.fire(.afterDBCommitBeforePreviousGenerationDelete)
        try deletePreviousGenerations(kind: .resume, torrentID: torrentID, upTo: generation)
        try journalTrim(limit: Self.journalLimit)
        return generation
    }

    /// Reads the latest committed resume data, verifying the checksum.
    /// A corrupt payload is quarantined and the torrent marked for recheck —
    /// the store keeps serving and returns nil for that record.
    func resumeData(torrentID: String) throws -> StoredPayload? {
        try requireOpen()
        guard let row = try latestGenerationRow(kind: .resume, owner: torrentID) else { return nil }
        let digest = AtomicGeneration.sha256(row.data)
        guard digest == row.checksum else {
            try quarantineCorruptRecord(kind: .resume, torrentID: torrentID,
                                        generation: row.generation,
                                        reason: "checksum mismatch on read (stored=\(row.checksum) computed=\(digest))")
            return nil
        }
        return StoredPayload(generation: row.generation, data: row.data)
    }

    func removeResumeData(torrentID: String) throws {
        try requireOpen()
        try deleteAllGenerations(kind: .resume, owner: torrentID)
    }

    // MARK: - Metainfo (same atomic generation path)

    func storeMetainfo(torrentID: String, data: Data) throws -> UInt64 {
        try requireOpen()
        guard torrentExists(torrentID) else { throw PersistenceError.unknownTorrent(id: torrentID) }
        let seq = try journalAppend(command: "store-metainfo", torrentID: torrentID,
                                    timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        let generation = try nextGeneration(.metainfo)
        let prepared = try PersistenceSidecar.prepare(data: data, kind: .metainfo, owner: torrentID,
                                                      generation: generation, dataDirectory: dataDirectory)
        try FailpointInjector.fire(.afterRenameBeforeSQLiteTransaction)
        try withTransaction {
            try insertGenerationRow(kind: .metainfo, torrentID: torrentID, generation: generation,
                                    data: data, checksum: prepared.checksum)
            try persistGenerationCounter(.metainfo, generation)
            try journalMarkCommitted(seq: seq)
        }
        try FailpointInjector.fire(.afterDBCommitBeforePreviousGenerationDelete)
        try deletePreviousGenerations(kind: .metainfo, torrentID: torrentID, upTo: generation)
        try journalTrim(limit: Self.journalLimit)
        return generation
    }

    func metainfo(torrentID: String) throws -> StoredPayload? {
        try requireOpen()
        guard let row = try latestGenerationRow(kind: .metainfo, owner: torrentID) else { return nil }
        let digest = AtomicGeneration.sha256(row.data)
        guard digest == row.checksum else {
            try quarantineCorruptRecord(kind: .metainfo, torrentID: torrentID,
                                        generation: row.generation,
                                        reason: "checksum mismatch on read (stored=\(row.checksum) computed=\(digest))")
            return nil
        }
        return StoredPayload(generation: row.generation, data: row.data)
    }

    func removeMetainfo(torrentID: String) throws {
        try requireOpen()
        try deleteAllGenerations(kind: .metainfo, owner: torrentID)
    }

    // MARK: - Session state

    func setSessionValue(key: String, data: Data) throws {
        try requireOpen()
        let generation = try nextGeneration(.session)
        let checksum = AtomicGeneration.sha256(data)
        try withTransaction {
            try upsertSessionRow(key: key, data: data, checksum: checksum, generation: generation)
        }
    }

    func sessionValue(key: String) throws -> StoredPayload? {
        try requireOpen()
        let statement = try prepare("SELECT generation, value, checksum FROM session_state WHERE key = ?")
        try statement.bindText(key, index: 1)
        guard try statement.step() == .row else { return nil }
        let generation = UInt64(statement.columnInt64(0))
        let value = statement.columnData(1) ?? Data()
        let checksum = statement.columnText(2) ?? ""
        guard AtomicGeneration.sha256(value) == checksum else {
            try quarantineCorruptRecord(kind: .session, torrentID: nil,
                                        generation: generation,
                                        reason: "session key \(key) checksum mismatch on read")
            return nil
        }
        return StoredPayload(generation: generation, data: value)
    }

    func removeSessionValue(key: String) throws {
        try requireOpen()
        let statement = try prepare("DELETE FROM session_state WHERE key = ?")
        try statement.bindText(key, index: 1)
        _ = try statement.step()
    }

    // MARK: - Shutdown flag

    func cleanShutdownFlag() throws -> Bool {
        guard connection != nil else { return false }
        guard let payload = try sessionValue(key: Self.cleanShutdownKey) else { return false }
        return payload.data == Data("1".utf8)
    }

    func setCleanShutdownFlag(_ value: Bool) throws {
        try setSessionValue(key: Self.cleanShutdownKey, data: Data((value ? "1" : "0").utf8))
    }

    /// foreign_keys is a per-connection pragma; this reports the value on the
    /// store's own connection (applied by applyPragmas at open).
    func foreignKeysEnabled() throws -> Bool {
        try requireOpen()
        let statement = try prepare("PRAGMA foreign_keys")
        guard try statement.step() == .row else { return false }
        return statement.columnInt64(0) != 0
    }

    // MARK: - WAL checkpoint plumbing (ShutdownCoordinator)

    /// Best-effort flush of dirty WAL pages into the main database.
    func checkpointWAL(passive: Bool) throws {
        try requireOpen()
        let mode = passive ? "PASSIVE" : "TRUNCATE"
        try FailpointInjector.fire(.duringWALCheckpoint)
        let statement = try prepare("PRAGMA wal_checkpoint(\(mode))")
        while try statement.step() == .row {}
    }

    /// Truncates the journal (clean shutdown only; called by the coordinator).
    func setJournalTruncatedOnCleanShutdown() throws {
        try journalTruncate()
    }

    // MARK: - Integrity + forensic group

    func integrityCheck() throws -> IntegrityReport {
        try requireOpen()
        var lines: [String] = []
        let statement = try prepare("PRAGMA integrity_check")
        while try statement.step() == .row {
            if let line = statement.columnText(0) { lines.append(line) }
        }
        let ok = lines.allSatisfy { $0 == "ok" }
        var detail = lines.joined(separator: "; ")
        let foreign = try prepare("PRAGMA foreign_key_check")
        var foreignFailures = 0
        while try foreign.step() == .row {
            foreignFailures += 1
            if let table = foreign.columnText(0), let rowID = foreign.columnText(2) {
                detail += " foreign_key(\(table) row \(rowID))"
            }
        }
        if foreignFailures > 0 { return IntegrityReport(ok: false, detail: detail) }
        return IntegrityReport(ok: ok, detail: detail.isEmpty ? "ok" : detail)
    }

    func forensicGroupStatus() -> ForensicGroupStatus {
        ForensicGroupStatus(
            mainExists: FileManager.default.fileExists(atPath: databaseURL.path),
            walExists: FileManager.default.fileExists(atPath: walURL.path),
            shmExists: FileManager.default.fileExists(atPath: shmURL.path)
        )
    }

    /// Moves main + WAL + SHM into a timestamped sibling directory so the
    /// forensic trio is preserved even when the database must be rebuilt.
    func moveForensicGroupAside() -> URL? {
        let fileManager = FileManager.default
        let names = [databaseURL.lastPathComponent,
                     databaseURL.lastPathComponent + "-wal",
                     databaseURL.lastPathComponent + "-shm"]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = dataDirectory.appendingPathComponent("corrupt-\(stamp)", isDirectory: true)
        guard (try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        for name in names {
            let source = dataDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: target.appendingPathComponent(name))
            }
        }
        return target
    }

    // MARK: - Quarantine (QuarantineManager primitives)

    /// Moves a corrupt record into the quarantine table (payload preserved for
    /// forensics), deletes the bad row, and marks the torrent for recheck.
    func quarantineCorruptRecord(kind: GenerationKind, torrentID: String?,
                                 generation: UInt64, reason: String) throws {
        try requireOpen()
        let payload: Data? = try {
            guard let owner = torrentID, kind != .session else { return nil }
            let statement = try prepare("SELECT data FROM \(tableName(kind)) WHERE torrent_id = ? AND generation = ?")
            try statement.bindText(owner, index: 1)
            try statement.bindInt64(Int64(generation), index: 2)
            guard try statement.step() == .row else { return nil }
            return statement.columnData(0)
        }()
        try withTransaction {
            let insert = try prepare("""
                INSERT INTO quarantine (quarantined_at, kind, torrent_id, generation, reason, payload)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            try insert.bindInt64(Int64(Date().timeIntervalSince1970 * 1000), index: 1)
            try insert.bindText(kind.rawValue, index: 2)
            try insert.bindText(torrentID, index: 3)
            try insert.bindInt64(Int64(generation), index: 4)
            try insert.bindText(reason, index: 5)
            try insert.bindBlob(payload, index: 6)
            _ = try insert.step()
        }
        if let torrentID, kind != .session {
            let delete = try prepare("DELETE FROM \(tableName(kind)) WHERE torrent_id = ? AND generation = ?")
            try delete.bindText(torrentID, index: 1)
            try delete.bindInt64(Int64(generation), index: 2)
            _ = try delete.step()
            try markTorrentForRecheck(torrentID: torrentID)
        } else if kind == .session, let key = torrentID {
            let delete = try prepare("DELETE FROM session_state WHERE key = ?")
            try delete.bindText(key, index: 1)
            _ = try delete.step()
        }
    }

    func quarantineRecords() throws -> [QuarantineRecord] {
        try requireOpen()
        let statement = try prepare("""
            SELECT seq, quarantined_at, kind, torrent_id, generation, reason, payload FROM quarantine
            """)
        var result: [QuarantineRecord] = []
        while try statement.step() == .row {
            result.append(QuarantineRecord(
                seq: statement.columnInt64(0),
                quarantinedAt: statement.columnInt64(1),
                kind: statement.columnText(2) ?? "",
                torrentID: statement.columnText(3),
                generation: UInt64(statement.columnInt64(4)),
                reason: statement.columnText(5) ?? "",
                payload: statement.columnData(6)
            ))
        }
        return result
    }

    func quarantineCount() throws -> Int {
        try requireOpen()
        let statement = try prepare("SELECT COUNT(*) FROM quarantine")
        guard try statement.step() == .row else { return 0 }
        return Int(statement.columnInt64(0))
    }

    /// Number of committed generation rows for a kind (reconciler report).
    func recordCount(kind: GenerationKind) throws -> Int {
        try requireOpen()
        let statement = try prepare("SELECT COUNT(*) FROM \(tableName(kind))")
        guard try statement.step() == .row else { return 0 }
        return Int(statement.columnInt64(0))
    }

    /// Number of session_state rows (reconciler report).
    func sessionStateCount() throws -> Int {
        try requireOpen()
        let statement = try prepare("SELECT COUNT(*) FROM session_state")
        guard try statement.step() == .row else { return 0 }
        return Int(statement.columnInt64(0))
    }

    func clearQuarantine(seq: Int64) throws {
        try requireOpen()
        let statement = try prepare("DELETE FROM quarantine WHERE seq = ?")
        try statement.bindInt64(seq, index: 1)
        _ = try statement.step()
    }

    // MARK: - Journal primitives (OperationJournal)

    func journalAppend(command: String, torrentID: String?, timestamp: Int64) throws -> Int64 {
        try requireOpen()
        let statement = try prepare("""
            INSERT INTO operation_journal (timestamp, command, torrent_id, status) VALUES (?, ?, ?, 'pending')
            """)
        try statement.bindInt64(timestamp, index: 1)
        try statement.bindText(command, index: 2)
        try statement.bindText(torrentID, index: 3)
        _ = try statement.step()
        let identity = try prepare("SELECT last_insert_rowid()")
        guard try identity.step() == .row else { return 0 }
        return identity.columnInt64(0)
    }

    func journalMarkCommitted(seq: Int64) throws {
        try requireOpen()
        let statement = try prepare("UPDATE operation_journal SET status = 'committed' WHERE seq = ?")
        try statement.bindInt64(seq, index: 1)
        _ = try statement.step()
    }

    func journalMarkReplayed(seq: Int64) throws {
        try requireOpen()
        let statement = try prepare("UPDATE operation_journal SET status = 'replayed' WHERE seq = ?")
        try statement.bindInt64(seq, index: 1)
        _ = try statement.step()
    }

    func journalPendingEntries() throws -> [JournalEntry] {
        try requireOpen()
        return try journalEntries(status: "pending")
    }

    func journalAllEntries() throws -> [JournalEntry] {
        try requireOpen()
        return try journalEntries(status: nil)
    }

    func journalCount() throws -> Int64 {
        try requireOpen()
        let statement = try prepare("SELECT COUNT(*) FROM operation_journal")
        guard try statement.step() == .row else { return 0 }
        return statement.columnInt64(0)
    }

    func journalTruncate() throws {
        try requireOpen()
        try exec("DELETE FROM operation_journal")
    }

    func journalTrim(limit: Int) throws {
        try requireOpen()
        let statement = try prepare("""
            DELETE FROM operation_journal
            WHERE seq <= (SELECT seq FROM operation_journal ORDER BY seq DESC LIMIT 1 OFFSET ?)
            """)
        try statement.bindInt64(Int64(limit), index: 1)
        _ = try statement.step()
    }

    // MARK: - Verification primitives (StartupReconciler)

    func verifyChecksums(kind: GenerationKind) throws -> [RecordCorruption] {
        try requireOpen()
        let table = tableName(kind)
        let statement = try prepare("SELECT torrent_id, generation, data, checksum FROM \(table)")
        var failures: [RecordCorruption] = []
        while try statement.step() == .row {
            let owner = statement.columnText(0) ?? ""
            let generation = UInt64(statement.columnInt64(1))
            let data = statement.columnData(2) ?? Data()
            let storedChecksum = statement.columnText(3) ?? ""
            if AtomicGeneration.sha256(data) != storedChecksum {
                failures.append(RecordCorruption(
                    kind: kind,
                    torrentID: owner,
                    generation: generation,
                    reason: "checksum mismatch at startup (stored=\(storedChecksum))"
                ))
            }
        }
        return failures
    }

    func verifySessionChecksums() throws -> [RecordCorruption] {
        try requireOpen()
        let statement = try prepare("SELECT key, generation, value, checksum FROM session_state")
        var failures: [RecordCorruption] = []
        while try statement.step() == .row {
            let key = statement.columnText(0) ?? ""
            let generation = UInt64(statement.columnInt64(1))
            let value = statement.columnData(2) ?? Data()
            let storedChecksum = statement.columnText(3) ?? ""
            if AtomicGeneration.sha256(value) != storedChecksum {
                failures.append(RecordCorruption(
                    kind: .session,
                    torrentID: key,
                    generation: generation,
                    reason: "session checksum mismatch at startup"
                ))
            }
        }
        return failures
    }

    /// Sidecar files that do not match any committed generation row. They are
    /// leftovers of writes that never committed (or superseded generations
    /// whose rows were already deleted) — safe to sweep.
    func orphanSidecars(kind: GenerationKind) throws -> [(owner: String, generation: UInt64, file: String)] {
        try requireOpen()
        let table = tableName(kind)
        let statement = try prepare("SELECT torrent_id, generation FROM \(table)")
        var committed = Set<String>()
        while try statement.step() == .row {
            if let owner = statement.columnText(0) {
                committed.insert("\(owner)#\(statement.columnInt64(1))")
            }
        }
        let sidecars = PersistenceSidecar.sidecarFiles(kind: kind, dataDirectory: dataDirectory)
        return sidecars.filter { !committed.contains("\($0.owner)#\($0.generation)") }
            .map { (owner: $0.owner, generation: $0.generation, file: $0.file) }
    }

    func removeOrphanSidecar(kind: GenerationKind, file: String) throws {
        let url = try PersistenceSidecar.directory(in: dataDirectory).appendingPathComponent(file)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Controlled recovery (rebuild)

    /// Salvages what is readable from a corrupt database: torrent records and
    /// metainfo generations (best effort, row by row), so a rebuild never
    /// loses recoverable data.
    private func salvageCorruptDatabase(from url: URL) throws -> (torrents: [StoredTorrent], metainfo: [(owner: String, generation: UInt64, data: Data)]) {
        var torrents: [StoredTorrent] = []
        var metainfo: [(String, UInt64, Data)] = []
        let probe = SQLiteConnection(path: url.path)
        try probe.open(readOnly: true)
        let torrentsStatement = try probe.prepare("""
            SELECT id, info_hash, info_hash_v2, name, state, added_at, quarantined FROM torrents
            """)
        while (try? torrentsStatement.step()) == .row {
            torrents.append(StoredTorrent(
                id: torrentsStatement.columnText(0) ?? "",
                infoHashV1: torrentsStatement.columnText(1),
                infoHashV2: torrentsStatement.columnText(2),
                name: torrentsStatement.columnText(3) ?? "",
                state: "needs-recheck",
                addedAt: torrentsStatement.columnInt64(5),
                quarantined: true
            ))
        }
        let metainfoStatement = try probe.prepare("""
            SELECT torrent_id, generation, data FROM metainfo
            """)
        while (try? metainfoStatement.step()) == .row {
            if let owner = metainfoStatement.columnText(0) {
                let generation = UInt64(metainfoStatement.columnInt64(1))
                let data = metainfoStatement.columnData(2) ?? Data()
                if !data.isEmpty {
                    metainfo.append((owner, generation, data))
                }
            }
        }
        probe.close()
        return (torrents, metainfo)
    }

    /// Controlled recovery: closes the connection, moves the forensic trio
    /// aside, salvages readable rows, writes a fresh database (temp -> fsync
    /// -> rename -> dir fsync), reopens it and restores the salvage.
    func recoverFromCorruptDatabase(reason: String) throws -> RebuildReport {
        log.error("controlled recovery: \(reason, privacy: .public)")
        rawClose()

        let preserved = moveForensicGroupAside()

        var salvage = (torrents: [StoredTorrent](), metainfo: [(String, UInt64, Data)]())
        if let preserved {
            let main = preserved.appendingPathComponent(databaseName)
            if FileManager.default.fileExists(atPath: main.path) {
                salvage = (try? salvageCorruptDatabase(from: main)) ?? (torrents: [], metainfo: [])
            }
        }

        // Fresh database written durably (temp -> fsync -> rename -> dir fsync).
        let fresh = SQLiteConnection(path: databaseURL.path)
        try fresh.open()
        try applyPragmas(fresh)
        try migrate(fresh)
        let inserts = try fresh.prepare("""
            INSERT OR REPLACE INTO torrents (id, info_hash, info_hash_v2, name, state, added_at, quarantined)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        for torrent in salvage.torrents {
            try inserts.bindText(torrent.id, index: 1)
            try inserts.bindText(torrent.infoHashV1, index: 2)
            try inserts.bindText(torrent.infoHashV2, index: 3)
            try inserts.bindText(torrent.name, index: 4)
            try inserts.bindText(torrent.state, index: 5)
            try inserts.bindInt64(torrent.addedAt, index: 6)
            try inserts.bindInt64(torrent.quarantined ? 1 : 0, index: 7)
            _ = try inserts.step()
            inserts.reset()
        }
        let metainfoInserts = try fresh.prepare("""
            INSERT INTO metainfo (torrent_id, generation, data, checksum) VALUES (?, ?, ?, ?)
            """)
        var maxMetainfoGeneration: UInt64 = 0
        for (owner, generation, data) in salvage.metainfo {
            try metainfoInserts.bindText(owner, index: 1)
            try metainfoInserts.bindInt64(Int64(generation), index: 2)
            try metainfoInserts.bindBlob(data, index: 3)
            try metainfoInserts.bindText(AtomicGeneration.sha256(data), index: 4)
            _ = try metainfoInserts.step()
            metainfoInserts.reset()
            maxMetainfoGeneration = max(maxMetainfoGeneration, generation)
        }
        // The rebuilt database starts with clean_shutdown=false.
        let clean = try fresh.prepare("""
            INSERT INTO session_state (key, value, checksum, generation) VALUES (?, ?, ?, ?)
            """)
        try clean.bindText(Self.cleanShutdownKey, index: 1)
        try clean.bindBlob(Data("0".utf8), index: 2)
        try clean.bindText(AtomicGeneration.sha256(Data("0".utf8)), index: 3)
        try clean.bindInt64(1, index: 4)
        _ = try clean.step()
        fresh.close()

        // Reopen the fresh database as the live connection and adopt counters.
        let reopened = SQLiteConnection(path: databaseURL.path)
        try reopened.open()
        try applyPragmas(reopened)
        connection = reopened
        generationCounters = [:]
        try restoreGenerationCounters()
        if maxMetainfoGeneration > 0 {
            generationCounters[.metainfo] = max(generationCounters[.metainfo] ?? 0, maxMetainfoGeneration)
        }

        return RebuildReport(
            preservedGroupURL: preserved,
            salvagedTorrents: salvage.torrents.count,
            salvagedMetainfo: salvage.metainfo.count
        )
    }

    // MARK: - Raw connection control (ShutdownCoordinator / recovery)

    /// Closes the sqlite handle without checkpointing (unclean path and the
    /// pre-rebuild close). The WAL stays on disk for replay or forensics.
    func rawClose() {
        connection?.close()
        connection = nil
    }

    // MARK: - Internal SQL plumbing

    private func requireOpen() throws {
        guard connection != nil, state != .closed, state != .unopened else {
            throw PersistenceError.notOpen
        }
    }

    private func applyPragmas(_ database: SQLiteConnection) throws {
        try database.exec("PRAGMA journal_mode=WAL")
        try database.exec("PRAGMA synchronous=NORMAL")
        try database.exec("PRAGMA foreign_keys=ON")
        try database.exec("PRAGMA busy_timeout=5000")
    }

    private func tableName(_ kind: GenerationKind) -> String {
        switch kind {
        case .resume: return "resume_data"
        case .metainfo: return "metainfo"
        case .session: return "session_state"
        }
    }

    private func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let connection else { throw PersistenceError.notOpen }
        do {
            return try connection.prepare(sql)
        } catch {
            throw PersistenceError.sqlite(String(describing: error))
        }
    }

    private func exec(_ sql: String) throws {
        guard let connection else { throw PersistenceError.notOpen }
        do {
            try connection.exec(sql)
        } catch {
            throw PersistenceError.sqlite(String(describing: error))
        }
    }

    private func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func torrentExists(_ id: String) -> Bool {
        (try? torrent(withID: id)) != nil
    }

    private func readTorrent(_ statement: SQLiteStatement) -> StoredTorrent {
        StoredTorrent(
            id: statement.columnText(0) ?? "",
            infoHashV1: statement.columnText(1),
            infoHashV2: statement.columnText(2),
            name: statement.columnText(3) ?? "",
            state: statement.columnText(4) ?? "",
            addedAt: statement.columnInt64(5),
            quarantined: statement.columnInt64(6) != 0
        )
    }

    // MARK: - Generation plumbing

    private func nextGeneration(_ kind: GenerationKind) throws -> UInt64 {
        let current = generationCounters[kind] ?? 0
        let next = current &+ 1
        generationCounters[kind] = next
        return next
    }

    private func persistGenerationCounter(_ kind: GenerationKind, _ value: UInt64) throws {
        let data = withUnsafeBytes(of: value.bigEndian) { Data($0) }
        let generation = sessionClock.next()
        try upsertSessionRow(key: kind.counterKey, data: data, checksum: AtomicGeneration.sha256(data),
                             generation: generation)
    }

    /// Restores counters from committed state: gen.<kind> values and the max
    /// session generation. Runs once at open so a crashed session can never
    /// reuse a generation number.
    private func restoreGenerationCounters() throws {
        for kind in [GenerationKind.resume, .metainfo, .session] {
            if let payload = try sessionValue(key: kind.counterKey), payload.data.count >= 8 {
                var bigEndian: UInt64 = 0
                payload.data.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        bigEndian = base.loadUnaligned(as: UInt64.self)
                    }
                }
                generationCounters[kind] = UInt64(bigEndian: bigEndian)
            }
        }
        let statement = try prepare("SELECT MAX(generation) FROM session_state")
        if try statement.step() == .row {
            sessionClock.adopt(UInt64(statement.columnInt64(0)))
        }
    }

    private struct GenerationRow {
        let generation: UInt64
        let data: Data
        let checksum: String
    }

    private func latestGenerationRow(kind: GenerationKind, owner: String) throws -> GenerationRow? {
        let statement = try prepare("""
            SELECT generation, data, checksum FROM \(tableName(kind))
            WHERE torrent_id = ? ORDER BY generation DESC LIMIT 1
            """)
        try statement.bindText(owner, index: 1)
        guard try statement.step() == .row else { return nil }
        return GenerationRow(generation: UInt64(statement.columnInt64(0)),
                             data: statement.columnData(1) ?? Data(),
                             checksum: statement.columnText(2) ?? "")
    }

    private func insertGenerationRow(kind: GenerationKind, torrentID: String,
                                     generation: UInt64, data: Data, checksum: String) throws {
        let statement = try prepare("""
            INSERT INTO \(tableName(kind)) (torrent_id, generation, data, checksum) VALUES (?, ?, ?, ?)
            """)
        try statement.bindText(torrentID, index: 1)
        try statement.bindInt64(Int64(generation), index: 2)
        try statement.bindBlob(data, index: 3)
        try statement.bindText(checksum, index: 4)
        _ = try statement.step()
    }

    private func deletePreviousGenerations(kind: GenerationKind, torrentID: String, upTo generation: UInt64) throws {
        let statement = try prepare("DELETE FROM \(tableName(kind)) WHERE torrent_id = ? AND generation < ?")
        try statement.bindText(torrentID, index: 1)
        try statement.bindInt64(Int64(generation), index: 2)
        _ = try statement.step()
        PersistenceSidecar.removePrevious(kind: kind, owner: torrentID, upTo: generation,
                                          dataDirectory: dataDirectory)
    }

    private func deleteAllGenerations(kind: GenerationKind, owner: String) throws {
        let statement = try prepare("DELETE FROM \(tableName(kind)) WHERE torrent_id = ?")
        try statement.bindText(owner, index: 1)
        _ = try statement.step()
        PersistenceSidecar.removeAll(kind: kind, owner: owner, dataDirectory: dataDirectory)
    }

    private func upsertSessionRow(key: String, data: Data, checksum: String, generation: UInt64) throws {
        let statement = try prepare("""
            INSERT INTO session_state (key, value, checksum, generation) VALUES (?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, checksum = excluded.checksum,
                                           generation = excluded.generation
            """)
        try statement.bindText(key, index: 1)
        try statement.bindBlob(data, index: 2)
        try statement.bindText(checksum, index: 3)
        try statement.bindInt64(Int64(generation), index: 4)
        _ = try statement.step()
    }

    private func journalEntries(status: String?) throws -> [JournalEntry] {
        let sql = status.map { _ in "SELECT seq, timestamp, command, torrent_id, status FROM operation_journal WHERE status = ?" }
            ?? "SELECT seq, timestamp, command, torrent_id, status FROM operation_journal"
        let statement = try prepare(sql)
        if let status {
            try statement.bindText(status, index: 1)
        }
        var result: [JournalEntry] = []
        while try statement.step() == .row {
            result.append(JournalEntry(
                seq: statement.columnInt64(0),
                timestamp: statement.columnInt64(1),
                command: statement.columnText(2) ?? "",
                torrentID: statement.columnText(3),
                status: statement.columnText(4) ?? ""
            ))
        }
        return result
    }

    // MARK: - Schema + migrations

    private static let schemaMigrations: [(version: Int, statements: [String])] = [
        (1, [
            """
            CREATE TABLE torrents (
                id TEXT PRIMARY KEY NOT NULL,
                info_hash TEXT NOT NULL DEFAULT '',
                info_hash_v2 TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL DEFAULT '',
                state TEXT NOT NULL DEFAULT 'queued',
                added_at INTEGER NOT NULL DEFAULT 0,
                quarantined INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE resume_data (
                torrent_id TEXT NOT NULL REFERENCES torrents(id) ON DELETE CASCADE,
                generation INTEGER NOT NULL,
                data BLOB NOT NULL,
                checksum TEXT NOT NULL,
                PRIMARY KEY (torrent_id, generation)
            )
            """,
            """
            CREATE TABLE metainfo (
                torrent_id TEXT NOT NULL REFERENCES torrents(id) ON DELETE CASCADE,
                generation INTEGER NOT NULL,
                data BLOB NOT NULL,
                checksum TEXT NOT NULL,
                PRIMARY KEY (torrent_id, generation)
            )
            """,
            """
            CREATE TABLE session_state (
                key TEXT PRIMARY KEY NOT NULL,
                value BLOB NOT NULL,
                checksum TEXT NOT NULL,
                generation INTEGER NOT NULL
            )
            """,
            """
            CREATE TABLE operation_journal (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                command TEXT NOT NULL,
                torrent_id TEXT,
                status TEXT NOT NULL DEFAULT 'pending'
            )
            """,
            """
            CREATE TABLE quarantine (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                quarantined_at INTEGER NOT NULL,
                kind TEXT NOT NULL,
                torrent_id TEXT,
                generation INTEGER NOT NULL DEFAULT 0,
                reason TEXT NOT NULL,
                payload BLOB
            )
            """,
        ]),
    ]

    private func migrate(_ database: SQLiteConnection) throws {
        try database.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL, applied_at TEXT NOT NULL)")
        let stored = try readSchemaVersion(database)
        guard stored <= Self.schemaVersion else {
            throw PersistenceError.downgradeBlocked(found: stored, supported: Self.schemaVersion)
        }
        for migration in Self.schemaMigrations where migration.version > stored {
            try database.exec("BEGIN IMMEDIATE")
            do {
                for statement in migration.statements {
                    try database.exec(statement)
                }
                let stamp = String(Int(Date().timeIntervalSince1970))
                try database.exec("INSERT INTO schema_version (version, applied_at) VALUES (\(migration.version), '\(stamp)')")
                try database.exec("COMMIT")
                log.notice("schema migrated to v\(migration.version)")
            } catch {
                try? database.exec("ROLLBACK")
                throw PersistenceError.sqlite("migration v\(migration.version) failed: \(database.lastErrorMessage)")
            }
        }
    }

    private func readSchemaVersion(_ database: SQLiteConnection) throws -> Int {
        let statement = try database.prepare("SELECT MAX(version) FROM schema_version")
        guard try statement.step() == .row else { return 0 }
        return Int(statement.columnInt64(0))
    }
}
