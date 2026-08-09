// Layer: Engine Agent (Diagnostics & Observability).
// Role: Structured OSLog loggers and OSSignposts across critical paths
//       (lifecycle, XPC, persistence, hashing, transfer).
// Must-not: log sensitive unredacted data to default levels.
// Invariants: Sendable struct/enum; OSLog and OSSignposter initialized with
//             frozen subsystems and categories.

import Foundation
import OSLog
import os

public struct TorrentinoCategoryLogger: Sendable {
    private let category: String

    fileprivate init(category: String) {
        self.category = category
    }

    public func debug(_ message: String) {
        TorrentinoLog.record(category: category, level: "debug", message: message)
    }

    public func info(_ message: String) {
        TorrentinoLog.record(category: category, level: "info", message: message)
    }

    public func notice(_ message: String) {
        TorrentinoLog.record(category: category, level: "notice", message: message)
    }

    public func warning(_ message: String) {
        TorrentinoLog.record(category: category, level: "warning", message: message)
    }

    public func error(_ message: String) {
        TorrentinoLog.record(category: category, level: "error", message: message)
    }
}

public enum TorrentinoLog {
    public static let subsystem = "com.torrentino.app.engine-agent"

    private struct BootstrapState: Sendable {
        var initialized = false
        var degraded = false
    }

    public static func logger(category: String) -> TorrentinoCategoryLogger {
        TorrentinoCategoryLogger(category: category)
    }

    private static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    private static let xpc = Logger(subsystem: subsystem, category: "xpc")
    private static let persistence = Logger(subsystem: subsystem, category: "persistence")
    private static let hashing = Logger(subsystem: subsystem, category: "hashing")
    private static let transfer = Logger(subsystem: subsystem, category: "transfer")
    private static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
    private static let bootstrapState = OSAllocatedUnfairLock(initialState: BootstrapState())
    private static let fileQueue = DispatchQueue(label: "com.torrentino.app.engine-agent.log-file")

    /// Centralizes error formatting so a thrown NSError never bypasses the
    /// same path/token/password sanitizer used by file and OSLog output.
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

    /// Structured logging call that logs to OSLog and appends to the redacted file log manager.
    public static func record(category: String, level: String, message: String) {
        let clean = RedactedLogFileManager.redact(message)
        let logger: Logger
        switch category {
        case "lifecycle": logger = lifecycle
        case "xpc": logger = xpc
        case "persistence": logger = persistence
        case "hashing": logger = hashing
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

    /// Provides a deterministic barrier for disposable QA before it reads the
    /// active log file. The actor hop drains writes already queued by callers.
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

public enum TorrentinoSignposts {
    public static let subsystem = "com.torrentino.app.engine-agent"

    public static let hashing = OSSignposter(subsystem: subsystem, category: "hashing")
    public static let xpc = OSSignposter(subsystem: subsystem, category: "xpc")
    public static let persistence = OSSignposter(subsystem: subsystem, category: "persistence")
    public static let transfer = OSSignposter(subsystem: subsystem, category: "transfer")
    public static let lifecycle = OSSignposter(subsystem: subsystem, category: "lifecycle")
}
