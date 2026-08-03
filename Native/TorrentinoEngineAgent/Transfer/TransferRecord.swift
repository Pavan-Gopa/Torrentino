// Layer: EngineAgent (Transfer).
// Role: the agent's authoritative in-memory torrent record and the engine
// abstraction the TransferCoordinator talks to. The coordinator is the only
// writer; records are immutable once built so snapshots can be derived safely.
// Must-not: perform I/O, mutate itself, or hold engine handles.
// Invariants: Sendable value types; engineID is the bridge's torrent id
// (v1 info-hash hex); revision is the per-record monotonic counter.

import Foundation
import TorrentinoIPC

/// Per-file desired selection (v1: skip | normal). Kept on the record so
/// fetchFiles can report it and a re-add can re-apply it.
public struct RecordFileSelection: Sendable, Equatable {
    public let relativePath: String
    public let priority: FileSelectionPriority

    public init(relativePath: String, priority: FileSelectionPriority) {
        self.relativePath = relativePath
        self.priority = priority
    }
}

/// One authoritative torrent record inside the agent.
public struct TransferRecord: Sendable, Equatable, Identifiable {
    public let id: TorrentRecordID
    public let contentIdentity: ContentIdentity
    public let displayName: String
    public let desiredState: DesiredTorrentState
    public let activity: TorrentActivity
    public let health: TorrentHealth
    public let totalBytes: Int64
    public let downloadedBytes: Int64
    public let uploadedBytes: Int64
    public let downloadBytesPerSec: Int64
    public let uploadBytesPerSec: Int64
    public let peersConnected: Int
    public let seedsTotal: Int
    public let engineID: String?
    public let metainfoData: Data?
    public let trackers: [String]
    public let limits: TorrentinoIPC.TransferLimits
    public let fileSelection: [RecordFileSelection]
    public let saveLocation: PersistedLocation
    public let addedAt: Int64
    public let revision: UInt64

    public init(
        id: TorrentRecordID,
        contentIdentity: ContentIdentity,
        displayName: String,
        desiredState: DesiredTorrentState,
        activity: TorrentActivity,
        health: TorrentHealth,
        totalBytes: Int64,
        downloadedBytes: Int64,
        uploadedBytes: Int64,
        downloadBytesPerSec: Int64,
        uploadBytesPerSec: Int64,
        peersConnected: Int,
        seedsTotal: Int,
        engineID: String?,
        metainfoData: Data?,
        trackers: [String],
        fileSelection: [RecordFileSelection],
        saveLocation: PersistedLocation,
        addedAt: Int64,
        revision: UInt64,
        limits: TorrentinoIPC.TransferLimits = TorrentinoIPC.TransferLimits()
    ) {
        self.id = id
        self.contentIdentity = contentIdentity
        self.displayName = displayName
        self.desiredState = desiredState
        self.activity = activity
        self.health = health
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
        self.downloadBytesPerSec = downloadBytesPerSec
        self.uploadBytesPerSec = uploadBytesPerSec
        self.peersConnected = peersConnected
        self.seedsTotal = seedsTotal
        self.engineID = engineID
        self.metainfoData = metainfoData
        self.trackers = trackers
        self.limits = limits
        self.fileSelection = fileSelection
        self.saveLocation = saveLocation
        self.addedAt = addedAt
        self.revision = revision
    }

    public var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    public var isCompleted: Bool { totalBytes > 0 && downloadedBytes >= totalBytes }

    public func snapshot(revision: UInt64) -> TorrentSnapshot {
        TorrentSnapshot(
            id: id,
            contentIdentity: contentIdentity,
            displayName: displayName,
            desiredState: desiredState,
            activity: activity,
            health: health,
            progress: TransferProgress(
                fraction: progressFraction,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes,
                uploadedBytes: uploadedBytes
            ),
            rates: TransferRates(
                downloadBytesPerSec: downloadBytesPerSec,
                uploadBytesPerSec: uploadBytesPerSec
            ),
            peers: PeerSummary(connected: peersConnected, halfOpen: 0, total: peersConnected + seedsTotal),
            limits: limits,
            saveLocation: saveLocation,
            revision: revision
        )
    }
}

/// Engine-wide aggregate counters for the status bar.
public struct TransferAggregateStats: Sendable, Equatable {
    public let downloadBytesPerSec: Int64
    public let uploadBytesPerSec: Int64
    public let totalSizeBytes: Int64
    public let activeCount: Int
    public let totalCount: Int

    public init(downloadBytesPerSec: Int64, uploadBytesPerSec: Int64, totalSizeBytes: Int64, activeCount: Int, totalCount: Int) {
        self.downloadBytesPerSec = downloadBytesPerSec
        self.uploadBytesPerSec = uploadBytesPerSec
        self.totalSizeBytes = totalSizeBytes
        self.activeCount = activeCount
        self.totalCount = totalCount
    }

    public static let zero = TransferAggregateStats(
        downloadBytesPerSec: 0, uploadBytesPerSec: 0, totalSizeBytes: 0, activeCount: 0, totalCount: 0
    )
}

/// Per-torrent live engine status, as reported by the engine's status pump.
public struct TransferTorrentStatus: Sendable, Equatable {
    /// Bridge torrent id: v1 info-hash hex (matches record.engineID).
    public let engineID: String
    public let progressFraction: Double
    public let downloadedBytes: Int64
    public let uploadedBytes: Int64
    public let downloadBytesPerSec: Int64
    public let uploadBytesPerSec: Int64
    public let peersConnected: Int
    public let seedsTotal: Int
    public let activity: TorrentActivity
    public let health: TorrentHealth
    public let etaSeconds: Int64?

    public init(
        engineID: String,
        progressFraction: Double,
        downloadedBytes: Int64,
        uploadedBytes: Int64,
        downloadBytesPerSec: Int64,
        uploadBytesPerSec: Int64,
        peersConnected: Int,
        seedsTotal: Int,
        activity: TorrentActivity,
        health: TorrentHealth,
        etaSeconds: Int64?
    ) {
        self.engineID = engineID
        self.progressFraction = progressFraction
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
        self.downloadBytesPerSec = downloadBytesPerSec
        self.uploadBytesPerSec = uploadBytesPerSec
        self.peersConnected = peersConnected
        self.seedsTotal = seedsTotal
        self.activity = activity
        self.health = health
        self.etaSeconds = etaSeconds
    }
}

/// The engine surface the TransferCoordinator needs. Production is backed by
/// the WP-04 libtorrent bridge; tests use an in-memory stub.
public protocol TransferEngine: Sendable {
    var isStarted: Bool { get async }
    func start(configuration: EngineSettings?) async throws
    func apply(settings: EngineSettings) async throws
    func add(specification: AddSpecificationDTO) async throws -> AddResultDTO
    func pause(torrentID: String) async throws
    func resume(torrentID: String) async throws
    func recheck(torrentID: String) async throws
    func remove(torrentID: String) async throws
    func setLimits(torrentID: String, limits: TorrentinoIPC.TransferLimits) async throws
    func editTrackers(torrentID: String, trackers: [String]) async throws
    func reannounce(torrentID: String) async throws
    /// Live per-torrent status (progress/rates/peers). Called by the pump.
    func statusUpdate() async throws -> [TransferTorrentStatus]
    /// Bounded alert drain variant. The default keeps test engines and older
    /// adapters source-compatible while production bridges honor the budget.
    func statusUpdate(maxAlerts: Int) async throws -> [TransferTorrentStatus]
    /// Engine-wide aggregate health (used when per-torrent rates are
    /// unavailable from the underlying engine).
    func aggregateHealth() async throws -> TransferAggregateStats
}

public extension TransferEngine {
    func statusUpdate(maxAlerts: Int) async throws -> [TransferTorrentStatus] {
        try await statusUpdate()
    }
}

/// Optional, synchronous liveness sink used by the agent's light health lane.
/// It carries counters only; it never owns engine or persistence state.
public protocol EngineHealthReporter: Sendable {
    func noteEngineTick()
    func noteEngineFailure()
    func updateSystemConditions(_ conditions: SystemConditions)
    func updateEventQueueDepth(_ depth: Int)
}
