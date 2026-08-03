// Layer: IPC (event schema v1, plan §7.5).
// Role: the agent → UI push surface. Events carry real authoritative data
// only; nothing here is synthesized or estimated.
// Must-not: deliver fake progress or invented revisions.
// Invariants: every event payload is Codable + Sendable + immutable; case
// names are the wire discriminators and are frozen for major version 1.

import Foundation

/// Agent lifecycle transition (plan §8.1 state machine).
public struct EngineLifecycleChangedEvent: Codable, Sendable, Equatable {
    public let from: EngineLifecycleState
    public let to: EngineLifecycleState
    public let degradedReason: String?
    public let revision: UInt64

    public init(from: EngineLifecycleState, to: EngineLifecycleState, degradedReason: String?, revision: UInt64) {
        self.from = from
        self.to = to
        self.degradedReason = degradedReason
        self.revision = revision
    }
}

/// A torrent became durable (commitAdd persisted).
public struct TorrentAddedEvent: Codable, Sendable, Equatable {
    public let snapshot: TorrentSnapshot
    public let engineRevision: UInt64

    public init(snapshot: TorrentSnapshot, engineRevision: UInt64) {
        self.snapshot = snapshot
        self.engineRevision = engineRevision
    }
}

/// A batch of changes since the last delivered delta. engineRevision must be
/// exactly lastSeen + 1, otherwise the UI must fetch a full snapshot.
public struct TorrentDeltaEvent: Codable, Sendable, Equatable {
    public let delta: TorrentDelta

    public init(delta: TorrentDelta) {
        self.delta = delta
    }
}

/// A torrent finished the removal state machine (durable record deleted).
public struct TorrentRemovedEvent: Codable, Sendable, Equatable {
    public let recordID: TorrentRecordID
    public let engineRevision: UInt64

    public init(recordID: TorrentRecordID, engineRevision: UInt64) {
        self.recordID = recordID
        self.engineRevision = engineRevision
    }
}

public enum OperationPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case started
    case running
    case persisted
    case completing
}

/// Long-running operation progress (recheck, move, removal, create, …).
public struct OperationProgressEvent: Codable, Sendable, Equatable {
    public let operationID: OperationID
    public let phase: OperationPhase
    public let fraction: Double
    public let timestamp: Date

    public init(operationID: OperationID, phase: OperationPhase, fraction: Double, timestamp: Date) {
        self.operationID = operationID
        self.phase = phase
        self.fraction = fraction
        self.timestamp = timestamp
    }
}

public enum OperationOutcome: Codable, Sendable, Equatable {
    case succeeded
    case cancelled
    case failed(EngineFault)
}

/// An operation finished; the UI may only show "completed" after this event
/// (plan §8.3: UI reports Completed only after persisted).
public struct OperationCompletedEvent: Codable, Sendable, Equatable {
    public let operationID: OperationID
    public let outcome: OperationOutcome
    public let timestamp: Date

    public init(operationID: OperationID, outcome: OperationOutcome, timestamp: Date) {
        self.operationID = operationID
        self.outcome = outcome
        self.timestamp = timestamp
    }
}

/// A recoverable condition (disk full, permission, tracker trouble) — the
/// torrent degrades but keeps running or waits.
public struct RecoverableIssueEvent: Codable, Sendable, Equatable {
    public let fault: EngineFault

    public init(fault: EngineFault) {
        self.fault = fault
    }
}

/// Engine-wide health changed (plan §8.4 heartbeat lane).
public struct EngineHealthChangedEvent: Codable, Sendable, Equatable {
    public let healthy: Bool
    public let reason: String?
    public let engineRevision: UInt64

    public init(healthy: Bool, reason: String?, engineRevision: UInt64) {
        self.healthy = healthy
        self.reason = reason
        self.engineRevision = engineRevision
    }
}

public enum SnapshotRequiredReason: String, Codable, Sendable, Equatable, CaseIterable {
    case initialConnection
    case engineInstanceChanged
    case droppedDelta
    case reconnect
}

/// The agent tells the UI to discard deltas and refetch a full snapshot.
public struct SnapshotRequiredEvent: Codable, Sendable, Equatable {
    public let reason: SnapshotRequiredReason
    public let afterRevision: UInt64

    public init(reason: SnapshotRequiredReason, afterRevision: UInt64) {
        self.reason = reason
        self.afterRevision = afterRevision
    }
}

public enum InspectionScope: String, Codable, Sendable, Equatable, CaseIterable {
    case files
    case peers
    case trackers
    case all
}

/// A previously fetched inspection (files/peers/trackers) is stale and must be
/// refetched; the payload names the scope and the revision it was invalidated at.
public struct InspectionInvalidatedEvent: Codable, Sendable, Equatable {
    public let recordID: TorrentRecordID
    public let scope: InspectionScope
    public let revision: UInt64

    public init(recordID: TorrentRecordID, scope: InspectionScope, revision: UInt64) {
        self.recordID = recordID
        self.scope = scope
        self.revision = revision
    }
}

/// Settings were published at a new revision (from this UI or another client).
public struct SettingsChangedEvent: Codable, Sendable, Equatable {
    public let revision: SettingsRevision

    public init(revision: SettingsRevision) {
        self.revision = revision
    }
}

/// The agent's system condition snapshot changed (network/thermal/memory/
/// Low Power/sleep). Lets the UI surface recovery states without polling.
public struct SystemConditionEvent: Codable, Sendable, Equatable {
    public let conditions: SystemConditions

    public init(conditions: SystemConditions) {
        self.conditions = conditions
    }
}

/// The complete v1 push surface (plan §7.5). Case names are wire discriminators.
public enum EngineEventV1: Codable, Sendable, Equatable {
    case engineLifecycleChanged(EngineLifecycleChangedEvent)
    case torrentAdded(TorrentAddedEvent)
    case torrentDelta(TorrentDeltaEvent)
    case torrentRemoved(TorrentRemovedEvent)
    case operationProgress(OperationProgressEvent)
    case operationCompleted(OperationCompletedEvent)
    case recoverableIssue(RecoverableIssueEvent)
    case engineHealthChanged(EngineHealthChangedEvent)
    case snapshotRequired(SnapshotRequiredEvent)
    case inspectionInvalidated(InspectionInvalidatedEvent)
    case settingsChanged(SettingsChangedEvent)
    case systemCondition(SystemConditionEvent)

    /// Every v1 event, once, with minimal payloads. Enumeration/diagnostics only.
    public static let allCases: [EngineEventV1] = {
        let recordID = TorrentRecordID(rawValue: UUID())
        let emptySnapshot = TorrentSnapshot(
            id: recordID,
            contentIdentity: nil,
            displayName: "",
            desiredState: .paused,
            activity: .idle,
            health: .healthy,
            progress: TransferProgress(fraction: 0, totalBytes: 0, downloadedBytes: 0, uploadedBytes: 0),
            rates: TransferRates(downloadBytesPerSec: 0, uploadBytesPerSec: 0),
            peers: PeerSummary(connected: 0, halfOpen: 0, total: 0),
            saveLocation: PersistedLocation(path: ""),
            revision: 0
        )
        let now = Date(timeIntervalSince1970: 0)
        return [
            .engineLifecycleChanged(EngineLifecycleChangedEvent(from: .unregistered, to: .ready, degradedReason: nil, revision: 0)),
            .torrentAdded(TorrentAddedEvent(snapshot: emptySnapshot, engineRevision: 0)),
            .torrentDelta(TorrentDeltaEvent(delta: TorrentDelta(added: [], updated: [], removed: [], engineRevision: 0))),
            .torrentRemoved(TorrentRemovedEvent(recordID: recordID, engineRevision: 0)),
            .operationProgress(OperationProgressEvent(operationID: OperationID(), phase: .started, fraction: 0, timestamp: now)),
            .operationCompleted(OperationCompletedEvent(operationID: OperationID(), outcome: .succeeded, timestamp: now)),
            .recoverableIssue(RecoverableIssueEvent(fault: EngineFault(code: .networkUnavailable, severity: .warning))),
            .engineHealthChanged(EngineHealthChangedEvent(healthy: true, reason: nil, engineRevision: 0)),
            .snapshotRequired(SnapshotRequiredEvent(reason: .initialConnection, afterRevision: 0)),
            .inspectionInvalidated(InspectionInvalidatedEvent(recordID: recordID, scope: .all, revision: 0)),
            .settingsChanged(SettingsChangedEvent(revision: 0)),
            .systemCondition(SystemConditionEvent(conditions: .normal)),
        ]
    }()
}

extension EngineEventV1 {
    /// Stable wire discriminator for this event.
    public var name: String {
        switch self {
        case .engineLifecycleChanged: return "engineLifecycleChanged"
        case .torrentAdded: return "torrentAdded"
        case .torrentDelta: return "torrentDelta"
        case .torrentRemoved: return "torrentRemoved"
        case .operationProgress: return "operationProgress"
        case .operationCompleted: return "operationCompleted"
        case .recoverableIssue: return "recoverableIssue"
        case .engineHealthChanged: return "engineHealthChanged"
        case .snapshotRequired: return "snapshotRequired"
        case .inspectionInvalidated: return "inspectionInvalidated"
        case .settingsChanged: return "settingsChanged"
        case .systemCondition: return "systemCondition"
        }
    }
}
