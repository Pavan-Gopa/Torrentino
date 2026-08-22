// Layer: Agent durable persistence (WP-06).
// Role: deterministic fault injection for the persistence write path. Eight
// fixed injection points (plan WP-06) let the test harness interrupt the
// write/checkpoint/shutdown pipeline at exactly one step and observe that the
// store recovers. Production builds never arm anything: trigger() is a no-op
// unless a handler was registered.
// Must-not: be reachable from user input, or inject faults in Release builds
// (arming is test-only by convention; nothing in the product arms it).
// Invariants: the registry is a locked dict keyed by FailpointID; handlers are
// Sendable closures that may throw; trigger() propagates the throw so the
// store aborts the current phase exactly as a crash at that point would.

import Foundation

/// The fixed injection points of the persistence pipeline.
enum FailpointID: String, Sendable, CaseIterable, CustomStringConvertible {
    /// 1. Before the temporary sidecar file is written.
    case beforeTemporaryWrite
    /// 2. After the sidecar payload is written, before the file fsync.
    case afterWriteBeforeFileFsync
    /// 3. After the sidecar file fsync, before rename.
    case afterFileFsync
    /// 4. After rename, before the parent-directory fsync.
    case afterRenameBeforeParentFsync
    /// 5. After the sidecar is durable, before the SQLite transaction.
    case afterRenameBeforeSQLiteTransaction
    /// 6. After the SQLite commit, before deleting the previous generation.
    case afterDBCommitBeforePreviousGenerationDelete
    /// 7. During the WAL checkpoint of a clean shutdown.
    case duringWALCheckpoint
    /// 8. Before every clean-shutdown step.
    case eachCleanShutdownStep
    /// 9. WP-10: before a trash-journal row append (durable removal journal).
    case beforeTrashJournalAppend
    /// 10. WP-10: before a trash-journal row status update.
    case beforeTrashJournalUpdate
    /// 11. WP-10: before a removal token settle (outcome + final status).
    case beforeRemovalTokenSettle
    /// 12. WP-13: after the first successful diagnostics export entry write
    ///     (test-only rollback probe; production never arms it).
    case diagnosticsExportMidWrite

    var description: String { rawValue }
}

/// Callback shape for an armed failpoint. Throwing simulates a crash/fault at
/// that exact phase boundary.
typealias FailpointHandler = @Sendable (FailpointID) throws -> Void

/// FailpointHook protocol (plan WP-06): production wires a no-op, tests wire a
/// handler that throws the injected fault. FailpointInjector IS the shared
/// hook implementation.
protocol FailpointHook: Sendable {
    static func fire(_ id: FailpointID) throws
}

/// Global registry. Production = no handlers = no-op.
enum FailpointInjector: FailpointHook {
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [FailpointID: FailpointHandler] = [:]

        func arm(_ id: FailpointID, handler: @escaping FailpointHandler) {
            lock.withLock { handlers[id] = handler }
        }

        func disarm(_ id: FailpointID) {
            lock.withLock { handlers[id] = nil }
        }

        func disarmAll() {
            lock.withLock { handlers.removeAll() }
        }

        func handler(for id: FailpointID) -> FailpointHandler? {
            lock.withLock { handlers[id] }
        }
    }

    private static let registry = Registry()

    /// Registers a fault handler for one injection point (test-only).
    static func arm(_ id: FailpointID, handler: @escaping FailpointHandler) {
        registry.arm(id, handler: handler)
    }

    /// Removes a single handler.
    static func disarm(_ id: FailpointID) {
        registry.disarm(id)
    }

    /// Removes every handler (XCTest setUp/tearDown hygiene).
    static func disarmAll() {
        registry.disarmAll()
    }

    /// Fires the injection point. No-op in production; throws the handler's
    /// fault in tests.
    static func fire(_ id: FailpointID) throws {
        guard let handler = registry.handler(for: id) else { return }
        try handler(id)
    }
}
