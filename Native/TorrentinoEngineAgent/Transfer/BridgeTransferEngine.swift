// Layer: EngineAgent (Transfer).
// Role: production TransferEngine conformance over the WP-04 EngineCoordinator
// bridge. Settings and torrent mutations are routed through this actor rather
// than being acknowledged by the in-memory coordinator. Per-torrent live status is derived from the bridge's alert stream
// (the bridge exposes no dedicated per-torrent status call): the latest
// progress/state per torrent id is cached between drains so the pump sees a
// stable picture even though drainAlerts consumes the queue.
// Must-not: hold C++ pointers, block on the bridge forever (EngineCoordinator
// bounds calls), or invent numbers — alert.error degrades the record health.
// Invariants: engineID is the bridge torrent id (v1 info-hash hex); start()
// is idempotent; remove() maps to the two-phase prepare+commit removal.

import Foundation
import TorrentinoIPC

public actor BridgeTransferEngine: TransferEngine {
    private let coordinator: EngineCoordinator
    private var started = false
    private var latestPerTorrent: [String: (fraction: Double, state: Int, error: String?)] = [:]

    public init(coordinator: EngineCoordinator) {
        self.coordinator = coordinator
    }

    public var isStarted: Bool {
        started
    }

    public func start(configuration: EngineSettings? = nil) async throws {
        guard !started else { return }
        // Bridge defaults: ephemeral loopback port, DHT off (WP-01 hermetic).
        if let configuration {
            _ = try await coordinator.start(configuration: Self.sessionConfiguration(for: configuration))
        } else {
            _ = try await coordinator.start()
        }
        started = true
    }

    public func apply(settings: EngineSettings) async throws {
        do {
            try await coordinator.apply(settings: settings)
            latestPerTorrent.removeAll(keepingCapacity: true)
            started = true
        } catch {
            started = false
            throw error
        }
    }

    public func add(specification: AddSpecificationDTO) async throws -> AddResultDTO {
        try await coordinator.add(specification: specification)
    }

    public func pause(torrentID: String) async throws {
        try await coordinator.pause(torrentID: torrentID)
    }

    public func resume(torrentID: String) async throws {
        try await coordinator.resume(torrentID: torrentID)
    }

    public func recheck(torrentID: String) async throws {
        try await coordinator.recheck(torrentID: torrentID)
    }

    public func remove(torrentID: String) async throws {
        let token = try await coordinator.prepareRemoval(torrentID: torrentID, deleteFiles: false)
        _ = try await coordinator.commitRemoval(token: token)
    }

    public func setLimits(torrentID: String, limits: TorrentinoIPC.TransferLimits) async throws {
        try await coordinator.setLimits(torrentID: torrentID, limits: limits)
    }

    public func editTrackers(torrentID: String, trackers: [String]) async throws {
        try await coordinator.editTrackers(torrentID: torrentID, trackers: trackers)
    }

    public func reannounce(torrentID: String) async throws {
        try await coordinator.reannounce(torrentID: torrentID)
    }

    /// Drains the alert queue, folds the latest per-torrent progress/state
    /// into the cache, and reports one status per known torrent.
    public func statusUpdate() async throws -> [TransferTorrentStatus] {
        let alerts = try await coordinator.drainAlerts(maxCount: 200)
        for alert in alerts {
            guard let torrentID = alert.torrentID else { continue }
            latestPerTorrent[torrentID] = (alert.progress, alert.state, alert.error)
        }
        return latestPerTorrent.map { torrentID, snapshot in
            TransferTorrentStatus(
                engineID: torrentID,
                progressFraction: max(0, min(1, snapshot.fraction)),
                downloadedBytes: 0, // coordinator derives bytes from fraction + record size
                uploadedBytes: 0,
                downloadBytesPerSec: 0,
                uploadBytesPerSec: 0,
                peersConnected: 0,
                seedsTotal: 0,
                activity: Self.activity(from: snapshot.state),
                health: snapshot.error != nil ? .recoverableError(.internalError) : .healthy,
                etaSeconds: nil
            )
        }
    }

    public func aggregateHealth() async throws -> TransferAggregateStats {
        let health = try await coordinator.health()
        return TransferAggregateStats(
            downloadBytesPerSec: Int64(health.downloadRate),
            uploadBytesPerSec: Int64(health.uploadRate),
            totalSizeBytes: 0,
            activeCount: health.activeTorrents,
            totalCount: 0
        )
    }

    /// libtorrent torrent_status state → TorrentActivity (v1 subset).
    private static func activity(from state: Int) -> TorrentActivity {
        switch state {
        case 3: return .fetchingMetadata // downloading_metadata
        case 4: return .downloading
        case 5, 6: return .seeding // finished / seeding
        case 1, 2, 7, 8: return .checking // queued_for_checking, checking_files, allocating, checking_resume_data
        default: return .idle
        }
    }

    private static func sessionConfiguration(for settings: EngineSettings) -> SessionConfigurationDTO {
        SessionConfigurationDTO(
            listenPort: Int(settings.listenPort),
            downloadDir: settings.downloadDirectory,
            enableDHT: settings.dhtEnabled,
            maxDownloadBytesPerSec: settings.maxDownloadBytesPerSec,
            maxUploadBytesPerSec: settings.maxUploadBytesPerSec,
            proxy: SessionProxyDTO(
                kind: settings.proxy.kind.rawValue,
                host: settings.proxy.host,
                port: settings.proxy.port,
                username: settings.proxy.username
            )
        )
    }
}
