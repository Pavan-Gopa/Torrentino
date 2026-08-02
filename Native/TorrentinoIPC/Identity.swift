// Layer: IPC (identity model, plan §7.1).
// Role: authoritative identifiers crossing the UI ↔ agent boundary.
// Must-not: be created by the wrong side — the UI creates RequestID,
// IdempotencyKey and AddOperationID only; TorrentRecordID is minted by the
// agent inside the durable commitAdd transaction.
// Invariants: immutable, Sendable, Codable wrappers over UUID/Data; equality
// is value equality; no session-local handle IDs ever cross this boundary.

import Foundation

/// Authoritative torrent record identity, minted by the agent during a
/// durable commitAdd. Stable across restarts; duplicates are detected via
/// ContentIdentity, never by display name or path.
public struct TorrentRecordID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Content fingerprint of a torrent: v1 (BEP-9) and/or v2 (BEP-52) info hash.
/// Hybrid torrents carry both; a magnet before metadata may carry neither.
public struct ContentIdentity: Codable, Hashable, Sendable, CustomStringConvertible {
    public let infoHashV1: Data?
    public let infoHashV2: Data?

    public init(infoHashV1: Data?, infoHashV2: Data?) {
        self.infoHashV1 = infoHashV1
        self.infoHashV2 = infoHashV2
    }

    /// True when at least one info hash is known.
    public var isKnown: Bool { infoHashV1 != nil || infoHashV2 != nil }

    public var description: String {
        let v1 = infoHashV1?.map { String(format: "%02x", $0) }.joined() ?? "-"
        let v2 = infoHashV2?.map { String(format: "%02x", $0) }.joined() ?? "-"
        return "v1:\(v1) v2:\(v2)"
    }
}

/// UI-created identity for a magnet that has not yet produced a
/// TorrentRecordID. Ties inspectAddSource → commitAdd → cancelAdd.
public struct AddOperationID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String { rawValue.uuidString }
}

/// Agent-created identity for a long-running operation (recheck, move,
/// removal, create). Referenced by operationProgress/operationCompleted.
public struct OperationID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String { rawValue.uuidString }
}

/// UI-created correlation identity for every request envelope. The same
/// requestID plus the same idempotency key must yield the same result
/// (idempotent replay, plan §6.2).
public struct RequestID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String { rawValue.uuidString }
}

/// UI-created dedup key for mutating commands (commitAdd, pause, resume,
/// setFileSelection, setLimits, applySettings, moveStorage, prepareRemoval,
/// commitRemoval, cancelOperation, commitCreate, restartEngineSafely, …).
/// Replaying a mutating command with the same key must not apply twice.
public struct IdempotencyKey: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String { rawValue.uuidString }
}
