// Layer: IPC (idempotency, plan §6.2 + §7.4).
// Role: remember mutating command outcomes so a replay (timeout-then-retry)
// returns the SAME result instead of applying twice. The canonical key is
// requestID + idempotencyKey + command name.
// Must-not: hold engine state or perform I/O; this is bookkeeping only.
// Invariants: thread-safe (actor); entries are immutable; replay is exact.

import Foundation

/// In-memory dedup registry for mutating commands. The agent seeds it before
/// executing a mutating command and consults it before executing the same
/// command again (same requestID + idempotencyKey).
public actor IdempotencyTracker {
    public struct Entry: Sendable, Equatable {
        public let commandName: String
        public let requestID: RequestID
        public let outcome: EngineCommandResult
        public let recordedAt: Date

        public init(commandName: String, requestID: RequestID, outcome: EngineCommandResult, recordedAt: Date) {
            self.commandName = commandName
            self.requestID = requestID
            self.outcome = outcome
            self.recordedAt = recordedAt
        }
    }

    private var entries: [String: Entry]
    private let maxEntries: Int
    private var insertionOrder: [String]

    public init(maxEntries: Int = 1024) {
        self.entries = [:]
        self.maxEntries = max(1, maxEntries)
        self.insertionOrder = []
    }

    /// Deterministic dedup key. Same command + same requestID + same
    /// idempotencyKey ⇒ same canonical key ⇒ same replay result.
    public nonisolated static func canonicalKey(
        commandName: String,
        requestID: RequestID,
        idempotencyKey: IdempotencyKey?
    ) -> String {
        "\(commandName)|\(idempotencyKey?.rawValue.uuidString ?? "-")|\(requestID.rawValue.uuidString)"
    }

    /// Stores the outcome of a mutating command.
    public func remember(commandName: String, requestID: RequestID, idempotencyKey: IdempotencyKey?, outcome: EngineCommandResult) {
        let key = Self.canonicalKey(commandName: commandName, requestID: requestID, idempotencyKey: idempotencyKey)
        entries[key] = Entry(commandName: commandName, requestID: requestID, outcome: outcome, recordedAt: Date())
        if let index = insertionOrder.firstIndex(of: key) {
            insertionOrder.remove(at: index)
        }
        insertionOrder.append(key)
        while entries.count > maxEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    /// Returns the previously stored outcome for an identical replay, nil when
    /// this exact (command, requestID, idempotencyKey) was never executed.
    public func replay(commandName: String, requestID: RequestID, idempotencyKey: IdempotencyKey?) -> Entry? {
        entries[Self.canonicalKey(commandName: commandName, requestID: requestID, idempotencyKey: idempotencyKey)]
    }

    /// Removes an entry (e.g. after a bounded retention window).
    public func forget(commandName: String, requestID: RequestID, idempotencyKey: IdempotencyKey?) {
        let key = Self.canonicalKey(commandName: commandName, requestID: requestID, idempotencyKey: idempotencyKey)
        entries.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
    }

    public var count: Int { entries.count }
}
