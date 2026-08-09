// Layer: Engine Agent (Diagnostics & Observability).
// Role: Rotating log file manager that enforces size and count limits while
//       scrubbing all sensitive data (user home paths, passwords, magnet tokens)
//       before writing to log files.
// Must-not: leak raw passwords, secret tokens, or user home paths to disk.
// Invariants: thread-safe actor; bounded file size (default 2 MB) and file count
//             (default 5); fail-safe IO operations.

import Foundation

public actor RedactedLogFileManager {
    public static let shared = RedactedLogFileManager()

    private let fileManager: FileManager
    private let logDirectory: URL
    private let maxFileSize: Int64
    private let maxFileCount: Int

    private var currentFileHandle: FileHandle?
    private var currentFileURL: URL?

    public init(
        logDirectory: URL? = nil,
        maxFileSize: Int64 = 2 * 1024 * 1024,
        maxFileCount: Int = 5,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.maxFileSize = max(1, maxFileSize)
        self.maxFileCount = max(1, maxFileCount)

        if let logDirectory {
            self.logDirectory = logDirectory
        } else {
            self.logDirectory = Self.defaultLogDirectory(fileManager: fileManager)
        }

        try? fileManager.createDirectory(at: self.logDirectory, withIntermediateDirectories: true)
    }

    public nonisolated static func defaultLogDirectory(fileManager: FileManager = .default) -> URL {
        if let override = ProcessInfo.processInfo.environment["TORRENTINO_LOG_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("com.torrentino.app.engine-agent", isDirectory: true)
            ?? URL(fileURLWithPath: "/tmp/torrentino-logs", isDirectory: true)
    }

    deinit {
        try? currentFileHandle?.close()
    }

    // MARK: - Redaction Logic

    /// Scrubs sensitive fields (user paths, proxy passwords, auth/passkey tokens)
    /// from a log message string.
    public static func redact(_ text: String) -> String {
        var redacted = text

        // 1. Redact complete absolute user/volume paths, not only the username.
        // The log must not reveal the Human's directory layout to diagnostics.
        let userHomeRegex = try? NSRegularExpression(pattern: "(?:/Users|/Volumes|/private/var)/[^\\s\"']+", options: [])
        if let userHomeRegex {
            let range = NSRange(location: 0, length: redacted.utf16.count)
            redacted = userHomeRegex.stringByReplacingMatches(in: redacted, options: [], range: range, withTemplate: "~")
        }

        // 2. Redact password parameters (password=..., proxyPassword=...)
        let pwdRegex = try? NSRegularExpression(pattern: "(password|proxyPassword|secret|passkey|token)=[^&\\s\"']+", options: [.caseInsensitive])
        if let pwdRegex {
            let range = NSRange(location: 0, length: redacted.utf16.count)
            redacted = pwdRegex.stringByReplacingMatches(in: redacted, options: [], range: range, withTemplate: "$1=<redacted>")
        }

        // 2b. The same fields commonly arrive as JSON diagnostics rather than
        // query parameters. Keep the field name while removing its value.
        let jsonSecretRegex = try? NSRegularExpression(
            pattern: "(\\\"(?:password|proxyPassword|secret|passkey|token)\\\"\\s*:\\s*)\\\"[^\\\"]*\\\"",
            options: [.caseInsensitive]
        )
        if let jsonSecretRegex {
            let range = NSRange(location: 0, length: redacted.utf16.count)
            redacted = jsonSecretRegex.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: range,
                withTemplate: "$1\"<redacted>\""
            )
        }

        // 3. Redact Authorization headers (Bearer <token>)
        let authHeaderRegex = try? NSRegularExpression(pattern: "Authorization:\\s*Bearer\\s+[^\\s\"']+", options: [.caseInsensitive])
        if let authHeaderRegex {
            let range = NSRange(location: 0, length: redacted.utf16.count)
            redacted = authHeaderRegex.stringByReplacingMatches(in: redacted, options: [], range: range, withTemplate: "Authorization: Bearer <redacted>")
        }

        return redacted
    }

    // MARK: - Log Writing & Rotation

    /// Writes a redacted log entry to disk, performing rotation if size exceeds limit.
    public func writeLog(category: String, level: String, message: String) {
        let cleanMessage = Self.redact(message)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formattedLine = "[\(timestamp)] [\(category)] [\(level.uppercased())] \(cleanMessage)\n"
        guard let data = formattedLine.data(using: .utf8) else { return }

        do {
            let handle = try prepareCurrentFileHandle()
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()

            // Check if rotation is needed
            let offset = try handle.offset()
            if Int64(offset) >= maxFileSize {
                rotateLogs()
            }
        } catch {
            // Ignore logging errors fail-safe
        }
    }

    /// Actor hop used as a deterministic barrier by disposable observability
    /// tests. Log writes are serialized before this no-op returns.
    public func flush() {}

    /// Fetches all active and rotated log file URLs.
    public func allLogFileURLs() -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix("engine_log") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reads up to `maxCount` recent log lines across active log files.
    public func fetchRecentLogLines(maxCount: Int = 1000) -> [String] {
        var lines: [String] = []
        let urls = allLogFileURLs()
        for url in urls {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                lines.append(contentsOf: content.components(separatedBy: .newlines).filter { !$0.isEmpty })
            }
        }
        if lines.count > maxCount {
            return Array(lines.suffix(maxCount))
        }
        return lines
    }

    /// Clears all log files in logDirectory.
    public func clearAllLogs() {
        try? currentFileHandle?.close()
        currentFileHandle = nil
        currentFileURL = nil
        let urls = allLogFileURLs()
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Private Helpers

    private func prepareCurrentFileHandle() throws -> FileHandle {
        if let handle = currentFileHandle {
            return handle
        }
        let activeURL = logDirectory.appendingPathComponent("engine_log_current.log")
        if !fileManager.fileExists(atPath: activeURL.path) {
            fileManager.createFile(atPath: activeURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: activeURL)
        self.currentFileHandle = handle
        self.currentFileURL = activeURL
        return handle
    }

    private func rotateLogs() {
        try? currentFileHandle?.close()
        currentFileHandle = nil
        currentFileURL = nil

        let activeURL = logDirectory.appendingPathComponent("engine_log_current.log")
        guard fileManager.fileExists(atPath: activeURL.path) else { return }

        // Shift old logs: log_4 -> remove, log_3 -> log_4, log_2 -> log_3, log_1 -> log_2, current -> log_1
        for idx in (1..<maxFileCount).reversed() {
            let src = logDirectory.appendingPathComponent(idx == 1 ? "engine_log_current.log" : "engine_log_\(idx - 1).log")
            let dst = logDirectory.appendingPathComponent("engine_log_\(idx).log")
            if fileManager.fileExists(atPath: dst.path) {
                try? fileManager.removeItem(at: dst)
            }
            if fileManager.fileExists(atPath: src.path) {
                try? fileManager.moveItem(at: src, to: dst)
            }
        }
    }
}
