// Layer: Agent durable persistence (WP-06).
// Role: single-writer advisory lock on the data directory. flock(LOCK_EX |
// LOCK_NB) on a dedicated lock file: a second agent (or any second writer)
// trying to open the same data directory is rejected with a clear error
// instead of corrupting the WAL database.
// Must-not: run two writers on one directory, or block waiting for the lock
// (the lock is non-blocking by design — the UI should never queue writers).
// Invariants: the lock file lives INSIDE the data directory (so a second
// writer sees the same inode); the handle holds the descriptor and releases
// it on release()/deinit; the lock is orthogonal to the launchd instance
// lock in AgentRuntime (that one guards the process, this one guards the DB).

import Foundation

enum AdvisoryLockError: Error, CustomStringConvertible, Sendable {
    case alreadyLocked(url: String)
    case ioFailure(reason: String)

    var description: String {
        switch self {
        case .alreadyLocked(let url):
            return "data directory already locked by another writer (\(url))"
        case .ioFailure(let reason):
            return "advisory lock IO failure: \(reason)"
        }
    }
}

/// An acquired advisory lock. Release via release() (or deinit); the handle
/// is not Sendable and must stay on the acquiring thread.
final class AdvisoryLockHandle: @unchecked Sendable {
    private let url: URL
    private var descriptor: CInt

    fileprivate init(url: URL, descriptor: CInt) {
        self.url = url
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    /// Unlocks and closes. Idempotent.
    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        descriptor = -1
        try? FileManager.default.removeItem(at: url)
    }
}

enum AdvisoryLock {
    static let lockFileName = "persistence.lock"

    /// Acquires the single-writer lock for a data directory. Throws
    /// AdvisoryLockError.alreadyLocked when another writer holds it.
    static func acquire(dataDirectory: URL) throws -> AdvisoryLockHandle {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let lockURL = dataDirectory.appendingPathComponent(lockFileName, isDirectory: false)
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        }
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw AdvisoryLockError.ioFailure(reason: "open(\(lockURL.lastPathComponent)) errno=\(errno)")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw AdvisoryLockError.alreadyLocked(url: lockURL.path)
        }
        return AdvisoryLockHandle(url: lockURL, descriptor: descriptor)
    }
}
