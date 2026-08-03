// Layer: IPC (snapshots, plan §7.3).
// Role: the immutable whole-engine and per-torrent projections the agent
// publishes; the UI renders these and only these.
// Must-not: embed peer-level arrays or the full file tree (they are paginated
// on demand); snapshots are always derived from agent state, never invented.
// Invariants: Codable + Sendable + immutable; revisions are UInt64 counters
// owned by the agent; instanceID changes invalidate the whole snapshot.

import Foundation

/// One torrent as observed by the agent. revision bumps on every authoritative
/// change of this torrent; the UI uses it for delta detection.
public struct TorrentSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: TorrentRecordID
    public let contentIdentity: ContentIdentity?
    public let displayName: String
    public let desiredState: DesiredTorrentState
    public let activity: TorrentActivity
    public let health: TorrentHealth
    public let progress: TransferProgress
    public let rates: TransferRates
    public let peers: PeerSummary
    public let limits: TransferLimits
    public let saveLocation: PersistedLocation
    public let revision: UInt64

    public var stateSortKey: String {
        "\(desiredState.rawValue)-\(activity.rawValue)"
    }

    public init(
        id: TorrentRecordID,
        contentIdentity: ContentIdentity?,
        displayName: String,
        desiredState: DesiredTorrentState,
        activity: TorrentActivity,
        health: TorrentHealth,
        progress: TransferProgress,
        rates: TransferRates,
        peers: PeerSummary,
        limits: TransferLimits = TransferLimits(),
        saveLocation: PersistedLocation,
        revision: UInt64
    ) {
        self.id = id
        self.contentIdentity = contentIdentity
        self.displayName = displayName
        self.desiredState = desiredState
        self.activity = activity
        self.health = health
        self.progress = progress
        self.rates = rates
        self.peers = peers
        self.limits = limits
        self.saveLocation = saveLocation
        self.revision = revision
    }
}

/// Full engine projection. `instanceID` changes whenever the agent process
/// (re)starts; the UI must then discard deltas and request a full snapshot.
public struct EngineSnapshot: Codable, Sendable, Equatable {
    public let torrents: [TorrentSnapshot]
    public let engineRevision: UInt64
    public let instanceID: UUID

    public init(torrents: [TorrentSnapshot], engineRevision: UInt64, instanceID: UUID) {
        self.torrents = torrents
        self.engineRevision = engineRevision
        self.instanceID = instanceID
    }
}

/// Incremental engine change. Delivered only when engineRevision is exactly
/// lastSeen + 1; any gap means the UI dropped events and must request a full
/// snapshot (reconciliation, see SnapshotReconciliation).
public struct TorrentDelta: Codable, Sendable, Equatable {
    public let added: [TorrentSnapshot]
    public let updated: [TorrentSnapshot]
    public let removed: [TorrentRecordID]
    public let engineRevision: UInt64

    public init(added: [TorrentSnapshot], updated: [TorrentSnapshot], removed: [TorrentRecordID], engineRevision: UInt64) {
        self.added = added
        self.updated = updated
        self.removed = removed
        self.engineRevision = engineRevision
    }

    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }
}
