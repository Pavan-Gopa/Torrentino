// Layer: Agent process lifecycle.
// Role: bounded durable start history used to enter and explicitly clear crash
// loop safe recovery. It never restarts a process or deletes user data.

import Foundation

final class CrashLoopGuard: @unchecked Sendable {
    static let window: TimeInterval = 5 * 60
    static let threshold = 3

    private let fileURL: URL
    let isSafeRecovery: Bool

    private init(fileURL: URL, isSafeRecovery: Bool) {
        self.fileURL = fileURL
        self.isSafeRecovery = isSafeRecovery
    }

    static func begin(in engineDirectory: URL) -> CrashLoopGuard {
        let fileURL = engineDirectory.appendingPathComponent("crash-history.json", isDirectory: false)
        let now = Date().timeIntervalSince1970
        let previous = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([Double].self, from: $0) }
            ?? []
        let recent = previous.filter { now - $0 < Self.window }
        let starts = recent + [now]
        let safe = starts.count >= Self.threshold
        if let data = try? JSONEncoder().encode(starts) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        return CrashLoopGuard(fileURL: fileURL, isSafeRecovery: safe)
    }

    /// Explicit user-approved recovery clears only the bounded start history.
    /// The coordinator has already restarted the engine before calling this.
    func clearHistory() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func markClean() {
        clearHistory()
    }
}
