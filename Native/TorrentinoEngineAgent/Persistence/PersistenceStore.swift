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
import os
import TorrentinoDomain
import TorrentinoIPC

// Layer: Engine Agent (Diagnostics & Observability).
// Role: target-shared redacted file sink and OSLog facade.
// Must-not: persist user paths, credentials, tracker passkeys, or raw bridge
//           diagnostics; file growth must remain bounded.

public actor RedactedLogFileManager {
    public static let shared = RedactedLogFileManager()

    private let fileManager: FileManager
    private let requestedLogDirectory: URL?
    private var logDirectory: URL
    private let maxFileSize: Int64
    private let maxFileCount: Int
    private var directoryResolved = false
    private var directoryWasOverride = false
    private var resolvedEnvironmentOverride: URL?
    private var currentFileHandle: FileHandle?

    public init(
        logDirectory: URL? = nil,
        maxFileSize: Int64 = 2 * 1024 * 1024,
        maxFileCount: Int = 5,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.requestedLogDirectory = logDirectory
        self.logDirectory = logDirectory ?? Self.defaultLogDirectory(fileManager: fileManager)
        self.maxFileSize = max(1, maxFileSize)
        self.maxFileCount = max(1, maxFileCount)
    }

    public nonisolated static func defaultLogDirectory(fileManager: FileManager = .default) -> URL {
        Self.environmentLogDirectory() ?? Self.productionLogDirectory(fileManager: fileManager)
    }

    private static func environmentLogDirectory() -> URL? {
        guard let value = getenv("TORRENTINO_LOG_DIRECTORY"),
              let override = String(validatingCString: value),
              !override.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func productionLogDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("com.torrentino.app.engine-agent", isDirectory: true)
            ?? URL(fileURLWithPath: "/tmp/torrentino-logs", isDirectory: true)
    }

    public static func redact(_ text: String) -> String {
        var redacted = text
        // Newline-safety review (SEC-3 line integrity): every value class
        // below excludes \r\n and every separator is the horizontal [ \\t]
        // only, so no rule can consume or bridge material on another line;
        // the unterminated-JSON fallback additionally runs with
        // anchorsMatchLines so `$` is line-bound. When a secret sits in an
        // UNterminated JSON-shaped line (no later quote on THAT line), the
        // balanced rule cannot match; the terminator-tolerant fallback (rule
        // 6) then redacts to end of that line — SEC-4 closure — consuming
        // escape pairs and tolerating a terminal trailing backslash so
        // backslash-bearing truncated secrets are covered too. Both
        // directions fail safe: diagnostics data loss, never a secret leak.
        let patterns: [(String, String, NSRegularExpression.Options)] = [
            // 1. Complete absolute user/volume paths.
            ("(?:/Users|/Volumes|/private/var)/[^\\s\"']+", "~", []),
            // 2. Plain-text credential markers (query params and key=value log
            //    shapes), including private-tracker styles (?key=, ?uid=,
            //    ?authkey=). \b keeps mid-word text like "keyboard=" intact.
            ("\\b(proxyPassword|password|passkey|authkey|secret|token|key|uid)=[^&\\s\"']+", "$1=<redacted>", [.caseInsensitive]),
            // 3. yaml/log-style "field: value" credentials. Separators are
            //    horizontal whitespace only (SEC-3: \s* would bridge a
            //    newline); the value class stops at quotes so quoted JSON
            //    values keep flowing to rule 5.
            ("\\b(proxyPassword|password|passkey|authkey|secret|token)[ \\t]*:[ \\t]*[^\\s\"',;{}()\\[\\]]+", "$1: <redacted>", [.caseInsensitive]),
            // 4. Announce URLs whose FIRST path segment after the host is an
            //    opaque token (≥9 chars from [A-Za-z0-9_-]). SEC-3 policy
            //    (REVIEW-002): INTENTIONALLY BROAD — digits and the leading
            //    character are irrelevant, because real private-tracker
            //    passkeys come in every shape (numeric, underscore-led,
            //    dash-led, plain alphanumeric). Deliberate diagnostic-
            //    fidelity tradeoff: a long ordinary first segment of an
            //    announce path is lost with the passkey it may be, but the
            //    HOST and the /announce(.php)? suffix always survive — enough
            //    to diagnose tracker connectivity while no credential-shaped
            //    token ever reaches logs.
            ("(https?://[^/\\s\"']+)/(?:[_\\-A-Za-z0-9]{9,})/(announce(?:\\.php)?)", "$1/<redacted>/$2", [.caseInsensitive]),
            // 5. Balanced JSON string values for credential fields. The value
            //    class excludes literal \r\n (SEC-3 line integrity: a value
            //    split across lines must never consume the following one);
            //    escaped pairs still match via \\. .
            ("(\\\"(?:password|proxyPassword|secret|passkey|token)\\\"[ \\t]*:[ \\t]*)\\\"(?:[^\\\"\\\\\\r\\n]|\\\\.)*\\\"", "$1\"<redacted>\"", [.caseInsensitive]),
            // 6. Unterminated JSON value (truncated log line): redact to the
            //    end of the current line and re-close the string. Consumes
            //    escape pairs (\\.) so backslash-bearing truncated secrets
            //    match too, and tolerates a terminal trailing backslash;
            //    never crosses \r\n (SEC-4 closure).
            ("(\\\"(?:password|proxyPassword|secret|passkey|token)\\\"[ \\t]*:[ \\t]*)\\\"(?:[^\\\"\\\\\\r\\n]|\\\\.)*\\\\?$", "$1\"<redacted>\"", [.caseInsensitive, .anchorsMatchLines]),
            // 7. Authorization headers (horizontal separators only; SEC-3).
            ("Authorization:[ \\t]*Bearer[ \\t]+[^\\s\"']+", "Authorization: Bearer <redacted>", [.caseInsensitive]),
        ]
        for (pattern, replacement, options) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            let range = NSRange(location: 0, length: redacted.utf16.count)
            redacted = regex.stringByReplacingMatches(in: redacted, options: [], range: range, withTemplate: replacement)
        }
        return redacted
    }

    public func writeLog(category: String, level: String, message: String) {
        let cleanMessage = Self.redact(message)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(category)] [\(level.uppercased())] \(cleanMessage)\n"
        guard let data = line.data(using: .utf8) else { return }

        refreshEnvironmentOverrideIfNeeded()

        do {
            let handle = try prepareCurrentFileHandle()
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            if Int64(try handle.offset()) >= maxFileSize {
                rotateLogs()
            }
        } catch {
            // Diagnostics must never take down the engine.
        }
    }

    public func flush() {}

    public func allLogFileURLs() -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix("engine_log") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func fetchRecentLogLines(maxCount: Int = 1000) -> [String] {
        var lines: [String] = []
        for url in allLogFileURLs() {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                lines.append(contentsOf: content.split(whereSeparator: \.isNewline).map(String.init))
            }
        }
        return lines.count > maxCount ? Array(lines.suffix(maxCount)) : lines
    }

    public func clearAllLogs() {
        try? currentFileHandle?.close()
        currentFileHandle = nil
        for url in allLogFileURLs() {
            try? fileManager.removeItem(at: url)
        }
    }

    private func prepareCurrentFileHandle() throws -> FileHandle {
        if let currentFileHandle { return currentFileHandle }

        do {
            try resolveLogDirectoryIfNeeded()
            return try openCurrentFileHandle()
        } catch {
            guard directoryWasOverride else { throw error }

            let failedDirectory = logDirectory
            let isolatedDirectory = try makeIsolatedLogDirectory()
            logDirectory = isolatedDirectory
            directoryWasOverride = false
            try writeIsolationWarning(
                failedDirectory: failedDirectory,
                reason: error
            )
            return try openCurrentFileHandle()
        }
    }

    private func refreshEnvironmentOverrideIfNeeded() {
        guard requestedLogDirectory == nil else { return }

        let liveOverride = Self.environmentLogDirectory()
        guard liveOverride != resolvedEnvironmentOverride else { return }

        try? currentFileHandle?.close()
        currentFileHandle = nil
        logDirectory = liveOverride
            ?? Self.productionLogDirectory(fileManager: fileManager)
        directoryResolved = false
        directoryWasOverride = false
        resolvedEnvironmentOverride = liveOverride
    }

    private func resolveLogDirectoryIfNeeded() throws {
        guard !directoryResolved else { return }

        let environmentOverride = Self.environmentLogDirectory()
        logDirectory = requestedLogDirectory
            ?? environmentOverride
            ?? Self.productionLogDirectory(fileManager: fileManager)
        directoryWasOverride = requestedLogDirectory != nil || environmentOverride != nil
        resolvedEnvironmentOverride = environmentOverride
        directoryResolved = true
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    private func openCurrentFileHandle() throws -> FileHandle {
        let url = logDirectory.appendingPathComponent("engine_log_current.log")
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.Code.fileWriteUnknown.rawValue,
                    userInfo: [NSFilePathErrorKey: url.path]
                )
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        currentFileHandle = handle
        return handle
    }

    private func makeIsolatedLogDirectory() throws -> URL {
        let template = fileManager.temporaryDirectory
            .appendingPathComponent("TorrentinoLogIsolation.XXXXXX", isDirectory: true)
            .path
        var buffer = Array(template.utf8CString)
        guard let path = buffer.withUnsafeMutableBufferPointer({ pointer -> String? in
            guard let base = pointer.baseAddress, let result = mkdtemp(base) else {
                return nil
            }
            return String(cString: result)
        }) else {
            throw NSError(
                domain: "TorrentinoLogFileManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "mkdtemp failed for \(template)"]
            )
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func writeIsolationWarning(failedDirectory: URL, reason: Error) throws {
        let url = logDirectory.appendingPathComponent("engine_log_current.log")
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.Code.fileWriteUnknown.rawValue,
                    userInfo: [NSFilePathErrorKey: url.path]
                )
            }
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let warning = "[\(timestamp)] [diagnostics] [FAULT] FATAL: log-isolation failed closed; " +
            "TORRENTINO_LOG_DIRECTORY override unusable; " +
            "isolated_directory=\(Self.redact(logDirectory.path)); " +
            "requested_directory=\(Self.redact(failedDirectory.path)); " +
            "reason=\(Self.redact(String(describing: reason)))\n"
        try handle.write(contentsOf: Data(warning.utf8))
        try handle.synchronize()
    }

    private func rotateLogs() {
        try? currentFileHandle?.close()
        currentFileHandle = nil
        let current = logDirectory.appendingPathComponent("engine_log_current.log")
        guard fileManager.fileExists(atPath: current.path) else { return }

        if maxFileCount > 1 {
            for index in stride(from: maxFileCount - 1, through: 1, by: -1) {
                let source = logDirectory.appendingPathComponent(
                    index == 1 ? "engine_log_current.log" : "engine_log_\(index - 1).log"
                )
                let destination = logDirectory.appendingPathComponent("engine_log_\(index).log")
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                if fileManager.fileExists(atPath: source.path) {
                    try? fileManager.moveItem(at: source, to: destination)
                }
            }
        }
    }
}

public struct TorrentinoCategoryLogger: Sendable {
    private let category: String

    fileprivate init(category: String) {
        self.category = category
    }

    public func debug(_ message: String) { TorrentinoLog.record(category: category, level: "debug", message: message) }
    public func info(_ message: String) { TorrentinoLog.record(category: category, level: "info", message: message) }
    public func notice(_ message: String) { TorrentinoLog.record(category: category, level: "notice", message: message) }
    public func warning(_ message: String) { TorrentinoLog.record(category: category, level: "warning", message: message) }
    public func error(_ message: String) { TorrentinoLog.record(category: category, level: "error", message: message) }
}

public enum TorrentinoLog {
    public static let subsystem = "com.torrentino.app.engine-agent"

    public static func logger(category: String) -> TorrentinoCategoryLogger {
        TorrentinoCategoryLogger(category: category)
    }

    private struct BootstrapState: Sendable {
        var initialized = false
        var degraded = false
    }

    private static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    private static let xpc = Logger(subsystem: subsystem, category: "xpc")
    private static let persistence = Logger(subsystem: subsystem, category: "persistence")
    private static let transfer = Logger(subsystem: subsystem, category: "transfer")
    private static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
    private static let bootstrapState = OSAllocatedUnfairLock(initialState: BootstrapState())
    private static let fileQueue = DispatchQueue(label: "com.torrentino.app.engine-agent.log-file")

    public static func redactedDescription(_ error: Error) -> String {
        RedactedLogFileManager.redact(String(describing: error))
    }

    public static var observabilityDegraded: Bool {
        bootstrapState.withLock { $0.degraded }
    }

    /// Performs the only synchronous filesystem operation in diagnostics. The
    /// agent must prove the sink before any asynchronous record can be queued.
    public static func bootstrap() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let startMarker = "agent bootstrap start version=\(version)"
        let bootstrapLogger = Logger(subsystem: subsystem, category: "lifecycle")
        bootstrapLogger.notice("\(startMarker, privacy: .public)")

        do {
            let directory = RedactedLogFileManager.defaultLogDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("engine_log_current.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((startMarker + "\n").utf8))
            let readyMarker = "log sink ready path=\(RedactedLogFileManager.redact(url.path))"
            bootstrapLogger.notice("\(readyMarker, privacy: .public)")
            try handle.write(contentsOf: Data((readyMarker + "\n").utf8))
            try handle.synchronize()
            try handle.close()

            let contents = try String(contentsOf: url, encoding: .utf8)
            guard String(contents.split(whereSeparator: \.isNewline).last ?? "") == readyMarker else {
                throw CocoaError(.fileReadCorruptFile)
            }
            bootstrapState.withLock {
                $0.initialized = true
                $0.degraded = false
            }
        } catch {
            let reason = RedactedLogFileManager.redact(String(describing: error))
            bootstrapState.withLock {
                $0.initialized = true
                $0.degraded = true
            }
            bootstrapLogger.fault("observability=degraded reason=\(reason, privacy: .public)")
            FileHandle.standardError.write(Data("FATAL: diagnostics sink degraded: \(reason)\n".utf8))
        }
    }

    public static func record(category: String, level: String, message: String) {
        let clean = RedactedLogFileManager.redact(message)
        let logger: Logger
        switch category {
        case "lifecycle": logger = lifecycle
        case "xpc": logger = xpc
        case "persistence": logger = persistence
        case "transfer": logger = transfer
        default: logger = diagnostics
        }
        switch level.lowercased() {
        case "error", "fault": logger.error("\(clean, privacy: .public)")
        case "warning": logger.warning("\(clean, privacy: .public)")
        case "debug": logger.debug("\(clean, privacy: .public)")
        case "info": logger.info("\(clean, privacy: .public)")
        default: logger.notice("\(clean, privacy: .public)")
        }

        fileQueue.async {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await RedactedLogFileManager.shared.writeLog(category: category, level: level, message: clean)
                semaphore.signal()
            }
            semaphore.wait()
        }
    }

    public static func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            fileQueue.async {
                Task {
                    await RedactedLogFileManager.shared.flush()
                    continuation.resume()
                }
            }
        }
    }

    /// Used only by fatal bootstrap paths immediately before `exit`.
    public static func flushSynchronously() {
        fileQueue.sync {}
    }
}

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
    static let schemaVersion: Int = 3

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
    private let log = TorrentinoLog.logger(category: "persistence")

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
        TorrentinoLog.record(category: "persistence", level: "info", message: "persistence open start")
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
            log.notice("persistence open \(report.message)")
            TorrentinoLog.record(category: "persistence", level: report.degraded ? "warning" : "notice", message: "persistence open complete report=\(report.message)")
            return report
        } catch let error as PersistenceError {
            switch error {
            case .corruptDatabase, .sqlite:
                // Corruption-class failure during open/pragma/migrate/reconcile:
                // controlled recovery — salvage, rebuild, degrade. Never crash.
                return try recoverFromOpenFailure(original: error)
            default:
                state = .failed
                log.error("persistence open failed: \(TorrentinoLog.redactedDescription(error))")
                TorrentinoLog.record(category: "persistence", level: "error", message: "persistence open failed: \(TorrentinoLog.redactedDescription(error))")
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
            log.error("persistence degraded: \(report.message)")
            TorrentinoLog.record(category: "persistence", level: "warning", message: "persistence rebuilt report=\(report.message)")
            return report
        } catch {
            state = .failed
            log.error("controlled recovery failed: \(TorrentinoLog.redactedDescription(error))")
            TorrentinoLog.record(category: "persistence", level: "error", message: "controlled recovery failed: \(TorrentinoLog.redactedDescription(error))")
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
            TorrentinoLog.record(category: "persistence", level: "warning", message: "unclean close leaves WAL for replay")
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
        try? removeSessionValue(key: Self.torrentLimitsKey(torrentID))
        try? removeSessionValue(key: Self.torrentTrackersKey(torrentID))
        try? removeSessionValue(key: Self.torrentLocationKey(torrentID))
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
            // Keep the durable bytes available for diagnostics and fail closed;
            // restore must not publish a record after a metainfo checksum fault.
            throw PersistenceError.checksumMismatch(
                kind: GenerationKind.metainfo.rawValue,
                torrentID: torrentID,
                generation: row.generation
            )
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

    /// Atomically writes several session values under one SQLite transaction.
    /// Settings use this so a failed second key cannot leave a partial config.
    func setSessionValues(_ values: [(key: String, data: Data)]) throws {
        try requireOpen()
        guard !values.isEmpty else { return }
        let generation = try nextGeneration(.session)
        try withTransaction {
            for value in values {
                try upsertSessionRow(
                    key: value.key,
                    data: value.data,
                    checksum: AtomicGeneration.sha256(value.data),
                    generation: generation
                )
            }
        }
    }

    func setTorrentLimits(torrentID: String, limits: TorrentinoIPC.TransferLimits) throws {
        try requireOpen()
        guard torrentExists(torrentID) else { throw PersistenceError.unknownTorrent(id: torrentID) }
        let data = try JSONEncoder().encode(limits)
        try setSessionValue(key: Self.torrentLimitsKey(torrentID), data: data)
    }

    func torrentLimits(torrentID: String) throws -> TorrentinoIPC.TransferLimits? {
        guard let payload = try sessionValue(key: Self.torrentLimitsKey(torrentID)) else { return nil }
        do {
            return try JSONDecoder().decode(TorrentinoIPC.TransferLimits.self, from: payload.data)
        } catch {
            // Layer: EngineAgent (Persistence).
            // Role: tolerant schema fallback for TransferLimits decoding.
            // Why: records persisted by rejected/future lanes may carry extra or altered keys;
            // fallback to dictionary parsing preserves valid limit values without discarding the record.
            if let dict = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any] {
                let maxDownload = (dict["maxDownloadBytesPerSec"] as? NSNumber)?.int64Value
                let maxUpload = (dict["maxUploadBytesPerSec"] as? NSNumber)?.int64Value
                let ratio = (dict["ratioLimit"] as? NSNumber)?.doubleValue
                let seedTime = (dict["seedTimeSeconds"] as? NSNumber)?.int64Value
                return TorrentinoIPC.TransferLimits(
                    maxDownloadBytesPerSec: maxDownload,
                    maxUploadBytesPerSec: maxUpload,
                    ratioLimit: ratio,
                    seedTimeSeconds: seedTime
                )
            }
            TorrentinoLog.record(
                category: "persistence",
                level: "warning",
                message: "tolerant decode failed table=torrent_limits record=\(torrentID) error=\(TorrentinoLog.redactedDescription(error))"
            )
            throw PersistenceError.sqlite("tolerant decode failed for torrent limits")
        }
    }

    // MARK: - Structured tracker topology (schema v3)

    private struct TrackerTopologyEnvelope: Codable {
        let version: Int
        let tiers: [[String]]

        enum CodingKeys: String, CodingKey {
            case version
            case tiers
        }

        init(version: Int, tiers: [[String]]) {
            self.version = version
            self.tiers = tiers
        }

        init(from decoder: Decoder) throws {
            // Layer: EngineAgent (Persistence).
            // Role: tolerant decode for tracker topology envelope.
            // Why: missing/unknown keys across versions default cleanly to version 1 and empty tiers.
            let container = try decoder.container(keyedBy: CodingKeys.self)
            do {
                self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            } catch {
                self.version = 1
            }
            do {
                self.tiers = try container.decodeIfPresent([[String]].self, forKey: .tiers) ?? []
            } catch {
                self.tiers = []
            }
        }
    }
    private struct TrackerTopologyRow {
        let data: Data
        let checksum: String
        let generation: UInt64
    }

    private static let trackerTopologyVersion = 1
    private static let trackerTopologyDiagnosticPrefix = "torrent_tracker_topology."

    /// Persists the only lifecycle representation of tracker topology. The
    /// versioned JSON bytes, not a decoded set or flat projection, are covered
    /// by the checksum and generation discipline.
    func setTorrentTrackerTiers(
        torrentID: String,
        tiers: [[String]],
        isPrivate: Bool
    ) throws {
        try requireOpen()
        guard torrentExists(torrentID) else { throw PersistenceError.unknownTorrent(id: torrentID) }
        do {
            try MetainfoParser.validateTrackerTiers(tiers, isPrivate: isPrivate)
        } catch {
            throw PersistenceError.sqlite("invalid tracker topology: \(error)")
        }
        let envelope = TrackerTopologyEnvelope(version: Self.trackerTopologyVersion, tiers: tiers)
        let data: Data
        do {
            // Declaration order intentionally produces the stable UTF-8
            // envelope: {"version":1,"tiers":[...]}.
            data = try JSONEncoder().encode(envelope)
        } catch {
            throw PersistenceError.sqlite("tracker topology encoding failed: \(error)")
        }
        let generation = try nextGeneration(.session)
        try withTransaction {
            try upsertTrackerTopologyRow(
                torrentID: torrentID,
                data: data,
                checksum: AtomicGeneration.sha256(data),
                generation: generation
            )
            try persistGenerationCounter(.session, generation)
        }
    }

    /// Reads and validates the structured row only. Legacy flat state is not
    /// consulted here; migration has its own explicitly named path below.
    func torrentTrackerTiers(torrentID: String) throws -> [[String]]? {
        try requireOpen()
        guard let row = try trackerTopologyRow(torrentID: torrentID) else { return nil }
        return try decodeTrackerTopology(row, torrentID: torrentID, isPrivate: false)
    }

    /// Captures the verified bytes for an edit rollback. This is intentionally
    /// separate from the public structured projection so rollback can restore
    /// the exact prior JSON payload, not merely an equivalent Swift value.
    func torrentTrackerTopologyJSON(torrentID: String) throws -> Data? {
        try requireOpen()
        guard let row = try trackerTopologyRow(torrentID: torrentID) else { return nil }
        _ = try decodeTrackerTopology(row, torrentID: torrentID, isPrivate: false)
        return row.data
    }

    /// Restores a previously verified JSON payload during edit rollback while
    /// advancing the same generation/checksum discipline as a normal write.
    func restoreTorrentTrackerTopologyJSON(
        torrentID: String,
        data: Data,
        isPrivate: Bool
    ) throws {
        try requireOpen()
        guard torrentExists(torrentID) else { throw PersistenceError.unknownTorrent(id: torrentID) }
        let checksum = AtomicGeneration.sha256(data)
        _ = try decodeTrackerTopology(
            TrackerTopologyRow(data: data, checksum: checksum, generation: 0),
            torrentID: torrentID,
            isPrivate: isPrivate
        )
        let generation = try nextGeneration(.session)
        try withTransaction {
            try upsertTrackerTopologyRow(
                torrentID: torrentID,
                data: data,
                checksum: checksum,
                generation: generation
            )
            try persistGenerationCounter(.session, generation)
        }
    }

    /// Reconciles durable structured topology with authoritative metainfo.
    /// A missing v3 row may be backfilled only from valid metainfo; a legacy
    /// flat row is classified and preserved, never mapped to singleton tiers.
    func restoreTorrentTrackerTiers(
        torrentID: String,
        metainfoTiers: [[String]]?,
        isPrivate: Bool
    ) throws -> [[String]] {
        try requireOpen()
        guard torrentExists(torrentID) else { throw PersistenceError.unknownTorrent(id: torrentID) }

        if let row = try trackerTopologyRow(torrentID: torrentID) {
            let stored = try decodeTrackerTopology(row, torrentID: torrentID, isPrivate: isPrivate)
            if let metainfoTiers {
                do {
                    try MetainfoParser.validateTrackerTiers(metainfoTiers, isPrivate: isPrivate)
                } catch {
                    throw PersistenceError.corruptDatabase(
                        reason: "authoritative metainfo tracker topology is invalid: \(error)"
                    )
                }
                guard stored == metainfoTiers else {
                    throw PersistenceError.corruptDatabase(
                        reason: "structured tracker topology does not match durable metainfo"
                    )
                }
            }
            return stored
        }

        if let metainfoTiers {
            do {
                try MetainfoParser.validateTrackerTiers(metainfoTiers, isPrivate: isPrivate)
            } catch {
                throw PersistenceError.corruptDatabase(
                    reason: "metainfo topology backfill is invalid: \(error)"
                )
            }
            try setTorrentTrackerTiers(torrentID: torrentID, tiers: metainfoTiers, isPrivate: isPrivate)
            return metainfoTiers
        }

        // This is the sole legacy-read path. It only distinguishes an
        // unsupported flat record for diagnostics; it never reconstructs it.
        if try legacyFlatTrackerRowExists(torrentID: torrentID) {
            throw PersistenceError.corruptDatabase(
                reason: "legacy flat tracker representation cannot recover tier boundaries"
            )
        }
        throw PersistenceError.corruptDatabase(
            reason: "structured tracker topology is missing without authoritative metainfo"
        )
    }

    /// Stores the canonical destination and optional volume identity in the
    /// session table. Missing/detached volumes therefore remain durable data,
    /// not a reason to synthesize a new directory on the next boot.
    func setTorrentLocation(torrentID: String, location: PersistedLocation) throws {
        try requireOpen()
        guard torrentExists(torrentID) else { throw PersistenceError.unknownTorrent(id: torrentID) }
        let data = try JSONEncoder().encode(location)
        try setSessionValue(key: Self.torrentLocationKey(torrentID), data: data)
    }

    func torrentLocation(torrentID: String) throws -> PersistedLocation? {
        guard let payload = try sessionValue(key: Self.torrentLocationKey(torrentID)) else { return nil }
        do {
            return try JSONDecoder().decode(PersistedLocation.self, from: payload.data)
        } catch {
            // Layer: EngineAgent (Persistence).
            // Role: tolerant schema fallback for PersistedLocation decoding.
            // Why: extra fields in location JSON should not prevent reading the target path.
            if let dict = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any],
               let path = dict["path"] as? String {
                let volumeID = dict["volumeIdentifier"] as? String
                return PersistedLocation(path: path, volumeIdentifier: volumeID)
            }
            TorrentinoLog.record(
                category: "persistence",
                level: "warning",
                message: "tolerant decode failed table=torrent_location record=\(torrentID) error=\(TorrentinoLog.redactedDescription(error))"
            )
            throw PersistenceError.sqlite("tolerant decode failed for torrent location")
        }
    }

    // MARK: - Engine settings (SEC-1 credential-free at-rest projection)

    /// At-rest shape of the `engine_settings` session row. The settings value
    /// is a projection whose proxy credential is ALWAYS stripped; the presence
    /// marker records that the live configuration had one so the UI can
    /// re-supply it from the Keychain. The secret itself never reaches SQLite
    /// (nor its WAL/-shm sidecars).
    private struct PersistedSettingsRecord: Codable {
        var version: Int
        var hasProxyPassword: Bool
        var settings: EngineSettings
    }

    private static let persistedSettingsVersion = 1

    /// Proxy copy with the credential value removed. `withheld` decides how a
    /// load reconstructs it: `false` reads as absent (nil); `true` reads as
    /// present-but-withheld ("") until applySettings re-supplies it.
    private static func credentialFreeProxy(_ proxy: ProxyConfiguration, withheld: Bool) -> ProxyConfiguration {
        ProxyConfiguration(
            kind: proxy.kind,
            host: proxy.host,
            port: proxy.port,
            username: proxy.username,
            password: withheld ? "" : nil
        )
    }

    /// The credential-free at-rest projection of a live configuration: the
    /// proxy password value is removed (never encoded) while the presence
    /// marker records that the live configuration had one.
    private static func atRestEnvelope(of settings: EngineSettings, hadProxyPassword: Bool) -> PersistedSettingsRecord {
        PersistedSettingsRecord(
            version: Self.persistedSettingsVersion,
            hasProxyPassword: hadProxyPassword,
            settings: EngineSettings(
                downloadDirectory: settings.downloadDirectory,
                maxDownloadBytesPerSec: settings.maxDownloadBytesPerSec,
                maxUploadBytesPerSec: settings.maxUploadBytesPerSec,
                listenPort: settings.listenPort,
                dhtEnabled: settings.dhtEnabled,
                lsdEnabled: settings.lsdEnabled,
                upnpEnabled: settings.upnpEnabled,
                natPmpEnabled: settings.natPmpEnabled,
                encryptionEnabled: settings.encryptionEnabled,
                proxy: Self.credentialFreeProxy(settings.proxy, withheld: false)
            )
        )
    }

    private static func atRestEnvelope(of settings: EngineSettings) -> PersistedSettingsRecord {
        atRestEnvelope(of: settings, hadProxyPassword: !(settings.proxy.password ?? "").isEmpty)
    }

    /// `hadProxyPassword` lets the caller pin the presence marker to the
    /// DELIVERED/live configuration instead of the passed projection (SEC-1
    /// boot re-supply invariant, WP13-SEC-HARDEN-001 REVIEW-002): an apply
    /// that delivered a credential persists marker=true with ZERO secret
    /// bytes even though the credential-free candidate carries none. When
    /// nil, the marker is derived from the settings' own proxy password
    /// (rollback paths re-persisting the live configuration).
    func persistSettings(
        _ settings: EngineSettings,
        revision: SettingsRevision,
        hadProxyPassword: Bool? = nil
    ) throws {
        try setSessionValues([
            (key: "engine_settings", data: try JSONEncoder().encode(
                Self.atRestEnvelope(
                    of: settings,
                    hadProxyPassword: hadProxyPassword ?? !(settings.proxy.password ?? "").isEmpty
                )
            )),
            (key: "engine_settings_revision", data: Data("\(revision)".utf8)),
        ])
    }

    func loadSettings() throws -> (settings: EngineSettings, revision: SettingsRevision)? {
        guard let settingsPayload = try sessionValue(key: "engine_settings") else {
            return nil
        }
        guard let revisionPayload = try sessionValue(key: "engine_settings_revision") else {
            // SEC-1-LEGACY: a credential-bearing row without its revision
            // companion still gets scrubbed; the historical result (nil)
            // stays unchanged so restore semantics never shift under this fix.
            _ = try scrubLegacySettingsRowAtRest(settingsPayload.data)
            return nil
        }
        let settings: EngineSettings
        if let record = try? JSONDecoder().decode(PersistedSettingsRecord.self, from: settingsPayload.data) {
            settings = EngineSettings(
                downloadDirectory: record.settings.downloadDirectory,
                maxDownloadBytesPerSec: record.settings.maxDownloadBytesPerSec,
                maxUploadBytesPerSec: record.settings.maxUploadBytesPerSec,
                listenPort: record.settings.listenPort,
                dhtEnabled: record.settings.dhtEnabled,
                lsdEnabled: record.settings.lsdEnabled,
                upnpEnabled: record.settings.upnpEnabled,
                natPmpEnabled: record.settings.natPmpEnabled,
                encryptionEnabled: record.settings.encryptionEnabled,
                proxy: Self.credentialFreeProxy(record.settings.proxy, withheld: record.hasProxyPassword)
            )
        } else {
            // Legacy/damaged rows are sanitized in memory AND rewritten at
            // rest by the same load (SEC-1-LEGACY), so the credential-bearing
            // bytes leave the database trio on first contact.
            settings = try scrubLegacySettingsRowAtRest(settingsPayload.data)
        }
        let revision: SettingsRevision
        if let text = String(data: revisionPayload.data, encoding: .utf8),
           let parsed = SettingsRevision(text) {
            revision = parsed
        } else {
            log.warning("settings revision decode fallback")
            revision = 1
        }
        return (settings, revision)
    }

    /// SEC-1-LEGACY at-rest scrub: sanitizes a pre-projection (or damaged)
    /// engine_settings payload in memory, atomically rewrites the row with its
    /// credential-free envelope, and collapses byte-level residue — VACUUM
    /// rebuilds the main database so no slack copy of the superseded record
    /// survives between pages, then the TRUNCATE checkpoint drains -wal of
    /// every pre-scrub frame (-shm is only a wal-index and never holds row
    /// bytes). Quarantined corrupt-* forensic copies are intentionally NOT
    /// touched: they are pre-existing incident artifacts whose retention is a
    /// documented residual (see WP-13 SEC-1 notes). Returns the sanitized
    /// settings the caller would have obtained from the old decode paths.
    private func scrubLegacySettingsRowAtRest(_ payload: Data) throws -> EngineSettings {
        let settings: EngineSettings
        let envelope: PersistedSettingsRecord
        if let legacy = try? JSONDecoder().decode(EngineSettings.self, from: payload) {
            log.warning("settings legacy row sanitized on load")
            settings = EngineSettings(
                downloadDirectory: legacy.downloadDirectory,
                maxDownloadBytesPerSec: legacy.maxDownloadBytesPerSec,
                maxUploadBytesPerSec: legacy.maxUploadBytesPerSec,
                listenPort: legacy.listenPort,
                dhtEnabled: legacy.dhtEnabled,
                lsdEnabled: legacy.lsdEnabled,
                upnpEnabled: legacy.upnpEnabled,
                natPmpEnabled: legacy.natPmpEnabled,
                encryptionEnabled: legacy.encryptionEnabled,
                proxy: Self.credentialFreeProxy(
                    legacy.proxy,
                    withheld: !(legacy.proxy.password ?? "").isEmpty
                )
            )
            envelope = Self.atRestEnvelope(of: legacy)
        } else {
            log.warning("settings tolerant decode fallback during at-rest scrub")
            let tolerant = tolerantSettings(from: payload)
            settings = tolerant?.settings ?? .default
            // An undecodable payload cannot be projected faithfully; it
            // already read back as defaults, so replacing it with the
            // sanitized default envelope leaves nothing unknowable at rest.
            envelope = tolerant.map { Self.atRestEnvelope(of: $0.settings, hadProxyPassword: $0.hasProxyPassword) }
                ?? PersistedSettingsRecord(
                    version: Self.persistedSettingsVersion,
                    hasProxyPassword: false,
                    settings: .default
                )
        }
        // Atomic rewrite through the store's own transaction machinery.
        try setSessionValues([(key: "engine_settings", data: try JSONEncoder().encode(envelope))])
        // Residue cleanup is best-effort: the security control above is the
        // atomic rewrite; VACUUM/checkpoint only remove forensic remnants.
        do {
            try exec("VACUUM")
            let statement = try prepare("PRAGMA wal_checkpoint(TRUNCATE)")
            while try statement.step() == .row {}
        } catch {
            log.warning("settings at-rest residue cleanup failed: \(TorrentinoLog.redactedDescription(error))")
        }
        return settings
    }

    /// Tolerant reconstruction of a damaged settings row. Also reports
    /// whether the damaged payload carried a proxy password so the at-rest
    /// scrub can preserve the presence marker (the value itself is stripped).
    private func tolerantSettings(from data: Data) -> (settings: EngineSettings, hasProxyPassword: Bool)? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let defaults = EngineSettings.default
        let listenPort = UInt16(clamping: (dict["listenPort"] as? NSNumber)?.intValue ?? Int(defaults.listenPort))
        // Reconstruct whatever proxy metadata survives in the damaged row,
        // minus any credential material (SEC-1).
        let proxy: ProxyConfiguration
        var hasProxyPassword = false
        if let proxyDict = dict["proxy"] as? [String: Any] {
            hasProxyPassword = !(proxyDict["password"] as? String ?? "").isEmpty
            proxy = Self.credentialFreeProxy(
                ProxyConfiguration(
                    kind: ProxyConfiguration.Kind(rawValue: proxyDict["kind"] as? String ?? "") ?? defaults.proxy.kind,
                    host: proxyDict["host"] as? String ?? "",
                    port: UInt16(clamping: (proxyDict["port"] as? NSNumber)?.intValue ?? 0),
                    username: proxyDict["username"] as? String
                ),
                withheld: hasProxyPassword
            )
        } else {
            proxy = defaults.proxy
        }
        return (
            EngineSettings(
                downloadDirectory: dict["downloadDirectory"] as? String ?? defaults.downloadDirectory,
                maxDownloadBytesPerSec: (dict["maxDownloadBytesPerSec"] as? NSNumber)?.int64Value ?? defaults.maxDownloadBytesPerSec,
                maxUploadBytesPerSec: (dict["maxUploadBytesPerSec"] as? NSNumber)?.int64Value ?? defaults.maxUploadBytesPerSec,
                listenPort: listenPort == 0 ? defaults.listenPort : listenPort,
                dhtEnabled: (dict["dhtEnabled"] as? NSNumber)?.boolValue ?? defaults.dhtEnabled,
                lsdEnabled: (dict["lsdEnabled"] as? NSNumber)?.boolValue ?? defaults.lsdEnabled,
                upnpEnabled: (dict["upnpEnabled"] as? NSNumber)?.boolValue ?? defaults.upnpEnabled,
                natPmpEnabled: (dict["natPmpEnabled"] as? NSNumber)?.boolValue ?? defaults.natPmpEnabled,
                encryptionEnabled: (dict["encryptionEnabled"] as? NSNumber)?.boolValue ?? defaults.encryptionEnabled,
                proxy: proxy
            ),
            hasProxyPassword
        )
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
        let topologyDiagnosticKey = torrentID.flatMap { value in
            value.hasPrefix(Self.trackerTopologyDiagnosticPrefix) ? value : nil
        }
        let payload: Data? = try {
            guard let owner = torrentID else { return nil }
            if let topologyDiagnosticKey {
                let statement = try prepare("""
                    SELECT topology_json FROM torrent_tracker_topology
                    WHERE torrent_id = ? AND generation = ?
                    """)
                try statement.bindText(
                    String(topologyDiagnosticKey.dropFirst(Self.trackerTopologyDiagnosticPrefix.count)),
                    index: 1
                )
                try statement.bindInt64(Int64(generation), index: 2)
                guard try statement.step() == .row else { return nil }
                return statement.columnData(0)
            }
            guard kind != .session else { return nil }
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
            try insert.bindText(topologyDiagnosticKey == nil ? kind.rawValue : "tracker_topology", index: 2)
            try insert.bindText(topologyDiagnosticKey == nil ? torrentID : String(topologyDiagnosticKey!), index: 3)
            try insert.bindInt64(Int64(generation), index: 4)
            try insert.bindText(reason, index: 5)
            try insert.bindBlob(payload, index: 6)
            _ = try insert.step()
        }
        if topologyDiagnosticKey != nil {
            // Leave the structured row in place for diagnostics. Restore will
            // still fail closed on its checksum, so this cannot publish health.
            return
        } else if let torrentID, kind != .session {
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
        let sessionCount = Int(statement.columnInt64(0))
        let topology = try prepare("SELECT COUNT(*) FROM torrent_tracker_topology")
        guard try topology.step() == .row else { return sessionCount }
        return sessionCount + Int(topology.columnInt64(0))
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
        // Structured topology uses the same checksum discipline but has its
        // own table. The diagnostic key keeps this legacy reconciler API
        // source-compatible without treating topology as session state.
        let topology = try prepare("""
            SELECT torrent_id, generation, topology_json, checksum
            FROM torrent_tracker_topology
            """)
        while try topology.step() == .row {
            let torrentID = topology.columnText(0) ?? ""
            let generation = UInt64(topology.columnInt64(1))
            let data = topology.columnData(2) ?? Data()
            let storedChecksum = topology.columnText(3) ?? ""
            if AtomicGeneration.sha256(data) != storedChecksum {
                failures.append(RecordCorruption(
                    kind: .session,
                    torrentID: Self.trackerTopologyDiagnosticKey(torrentID),
                    generation: generation,
                    reason: "tracker topology checksum mismatch at startup"
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
        log.error("controlled recovery: \(reason)")
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

    // WP-10: the RemovalJournal extension (separate file) shares these helpers;
    // keep them internal (not private) for that file's store extension.
    func requireOpen() throws {
        guard connection != nil, state != .closed, state != .unopened else {
            throw PersistenceError.notOpen
        }
    }

    private static func torrentLimitsKey(_ torrentID: String) -> String {
        "torrent_limits.\(torrentID)"
    }

    private static func torrentTrackersKey(_ torrentID: String) -> String {
        "torrent_trackers.\(torrentID)"
    }

    private static func trackerTopologyDiagnosticKey(_ torrentID: String) -> String {
        "\(trackerTopologyDiagnosticPrefix)\(torrentID)"
    }

    private static func torrentLocationKey(_ torrentID: String) -> String {
        "torrent_location.\(torrentID)"
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

    private func trackerTopologyRow(torrentID: String) throws -> TrackerTopologyRow? {
        let statement = try prepare("""
            SELECT topology_json, checksum, generation
            FROM torrent_tracker_topology
            WHERE torrent_id = ?
            """)
        try statement.bindText(torrentID, index: 1)
        guard try statement.step() == .row else { return nil }
        return TrackerTopologyRow(
            data: statement.columnData(0) ?? Data(),
            checksum: statement.columnText(1) ?? "",
            generation: UInt64(statement.columnInt64(2))
        )
    }

    private func decodeTrackerTopology(
        _ row: TrackerTopologyRow,
        torrentID: String,
        isPrivate: Bool
    ) throws -> [[String]] {
        let computed = AtomicGeneration.sha256(row.data)
        guard computed == row.checksum else {
            throw PersistenceError.checksumMismatch(
                kind: "tracker_topology",
                torrentID: torrentID,
                generation: row.generation
            )
        }
        let envelope: TrackerTopologyEnvelope
        do {
            envelope = try JSONDecoder().decode(TrackerTopologyEnvelope.self, from: row.data)
        } catch {
            throw PersistenceError.corruptDatabase(
                reason: "tracker topology JSON decode failed for \(torrentID): \(error)"
            )
        }
        guard envelope.version == Self.trackerTopologyVersion else {
            throw PersistenceError.corruptDatabase(
                reason: "unsupported tracker topology envelope version \(envelope.version)"
            )
        }
        do {
            try MetainfoParser.validateTrackerTiers(envelope.tiers, isPrivate: isPrivate)
        } catch {
            throw PersistenceError.corruptDatabase(
                reason: "stored tracker topology is invalid: \(error)"
            )
        }
        return envelope.tiers
    }

    private func upsertTrackerTopologyRow(
        torrentID: String,
        data: Data,
        checksum: String,
        generation: UInt64
    ) throws {
        let statement = try prepare("""
            INSERT INTO torrent_tracker_topology
                (torrent_id, topology_json, checksum, generation)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(torrent_id) DO UPDATE SET
                topology_json = excluded.topology_json,
                checksum = excluded.checksum,
                generation = excluded.generation
            """)
        try statement.bindText(torrentID, index: 1)
        try statement.bindBlob(data, index: 2)
        try statement.bindText(checksum, index: 3)
        try statement.bindInt64(Int64(generation), index: 4)
        _ = try statement.step()
    }

    private func legacyFlatTrackerRowExists(torrentID: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM session_state WHERE key = ? LIMIT 1")
        try statement.bindText(Self.torrentTrackersKey(torrentID), index: 1)
        return try statement.step() == .row
    }

    // WP-10: shared with the RemovalJournal store extension (separate file).
    func prepare(_ sql: String) throws -> SQLiteStatement {
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
        // WP-10: durable two-phase removal tokens + per-item Trash journal +
        // same/cross-volume move journal. Tokens and journal rows are written
        // BEFORE any payload mutation; they are deleted only after the record
        // is durably removed or the move is durably committed.
        (2, [
            """
            CREATE TABLE removal_tokens (
                token TEXT PRIMARY KEY NOT NULL,
                record_id TEXT NOT NULL,
                delete_files INTEGER NOT NULL DEFAULT 0,
                manifest_json TEXT NOT NULL,
                shared_paths_json TEXT NOT NULL DEFAULT '[]',
                status TEXT NOT NULL DEFAULT 'pending',
                created_at INTEGER NOT NULL,
                completed_at INTEGER,
                outcome_json TEXT
            )
            """,
            """
            CREATE TABLE trash_journal (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                token TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                absolute_path TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'file',
                size_bytes INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'pending',
                failure_code TEXT,
                failure_message TEXT,
                updated_at INTEGER NOT NULL
            )
            """,
            """
            CREATE TABLE move_journal (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                record_id TEXT NOT NULL,
                from_path TEXT NOT NULL,
                to_path TEXT NOT NULL,
                file_list_json TEXT NOT NULL DEFAULT '[]',
                stage TEXT NOT NULL DEFAULT 'prepared',
                status TEXT NOT NULL DEFAULT 'pending',
                started_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                failure_reason TEXT
            )
            """,
        ]),
        (3, [
            """
            CREATE TABLE torrent_tracker_topology (
                torrent_id TEXT PRIMARY KEY NOT NULL REFERENCES torrents(id) ON DELETE CASCADE,
                topology_json BLOB NOT NULL,
                checksum TEXT NOT NULL,
                generation INTEGER NOT NULL
            )
            """
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
