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
    private var statusCache = ByteBoundedStatusCache()
    private var resourceBudget = EngineResourceBudget.balanced
    private var activeSettings = EngineSettings.default

    public init(coordinator: EngineCoordinator) {
        self.coordinator = coordinator
    }

    public var isStarted: Bool {
        started
    }

    public var currentResourceBudget: EngineResourceBudget {
        resourceBudget
    }

    public func start(configuration: EngineSettings? = nil) async throws {
        guard !started else { return }
        // Bridge defaults: ephemeral loopback port, DHT off (WP-01 hermetic).
        let bridgeConfiguration: SessionConfigurationDTO
        if let configuration {
            activeSettings = configuration
            bridgeConfiguration = EngineCoordinator.sessionConfiguration(
                for: configuration,
                budget: resourceBudget
            )
        } else {
            bridgeConfiguration = Self.defaultSessionConfiguration(for: resourceBudget)
        }
        _ = try await coordinator.start(configuration: bridgeConfiguration)
        started = true
    }

    public func apply(settings: EngineSettings) async throws {
        do {
            activeSettings = settings
            try await coordinator.apply(configuration: EngineCoordinator.sessionConfiguration(
                for: settings,
                budget: resourceBudget
            ))
            statusCache.removeAll()
            started = true
        } catch {
            started = false
            throw Self.mappedBridgeError(error, operation: "applySettings")
        }
    }

    public func apply(resourceBudget: EngineResourceBudget) async throws {
        self.resourceBudget = resourceBudget
        statusCache.setByteLimit(resourceBudget.cacheBytes)
        guard started else { return }
        do {
            try await coordinator.apply(configuration: EngineCoordinator.sessionConfiguration(
                for: activeSettings,
                budget: resourceBudget
            ))
        } catch {
            throw Self.mappedBridgeError(error, operation: "applyResourceBudget")
        }
    }

    public func restart(configuration: EngineSettings? = nil) async throws {
        await coordinator.shutdown()
        started = false
        statusCache.removeAll()
        try await start(configuration: configuration ?? activeSettings)
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
        do {
            try await coordinator.setLimits(torrentID: torrentID, limits: limits)
        } catch {
            throw Self.mappedBridgeError(error, operation: "setLimits")
        }
    }

    public func editTrackers(torrentID: String, trackers: [String]) async throws {
        do {
            try await coordinator.editTrackers(torrentID: torrentID, trackers: trackers)
        } catch {
            throw Self.mappedBridgeError(error, operation: "editTrackers")
        }
    }

    public func reannounce(torrentID: String) async throws {
        do {
            try await coordinator.reannounce(torrentID: torrentID)
        } catch {
            throw Self.mappedBridgeError(error, operation: "reannounce")
        }
    }

    /// Drains the alert queue, folds the latest per-torrent progress/state
    /// into the cache, and reports one status per known torrent.
    public func statusUpdate() async throws -> [TransferTorrentStatus] {
        try await statusUpdate(maxAlerts: 200)
    }

    public func statusUpdate(maxAlerts: Int) async throws -> [TransferTorrentStatus] {
        let boundedBatch = max(1, min(maxAlerts, resourceBudget.alertDrainBatch))
        let alerts = try await coordinator.drainAlerts(maxCount: boundedBatch)
        for alert in alerts {
            guard let torrentID = alert.torrentID else { continue }
            statusCache.insert(
                CachedTorrentStatus(fraction: alert.progress, state: alert.state, error: alert.error),
                for: torrentID
            )
        }
        return statusCache.entries.map { torrentID, snapshot in
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
                health: Self.health(from: snapshot.error),
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

    private static func health(from error: String?) -> TorrentHealth {
        guard let error else { return .healthy }
        let text = error.lowercased()
        if text.contains("no space") || text.contains("disk full") || text.contains("enospc") {
            return .waitingForSpace
        }
        if text.contains("permission") || text.contains("access denied") || text.contains("read-only") || text.contains("eacces") {
            return .permissionDenied
        }
        if text.contains("network") || text.contains("connection") || text.contains("unreachable") {
            return .waitingForNetwork
        }
        if text.contains("volume") || text.contains("not found") {
            return .waitingForVolume
        }
        return .recoverableError(.internalError)
    }

    private static func mappedBridgeError(_ error: Error, operation: String) -> Error {
        if let coordinatorError = error as? EngineCoordinatorError,
           case .unsupportedOperation(let details) = coordinatorError {
            return EngineFault.unsupportedOperation(operation: operation, details: details)
        }
        if let coordinatorError = error as? EngineCoordinatorError,
           case .invalidArgument = coordinatorError {
            return EngineFault.invalidArgument(details: "operation=\(operation)")
        }
        return error
    }

    private static func sessionConfiguration(for settings: EngineSettings) -> SessionConfigurationDTO {
        EngineCoordinator.sessionConfiguration(for: settings)
    }

    private static func defaultSessionConfiguration(for budget: EngineResourceBudget) -> SessionConfigurationDTO {
        SessionConfigurationDTO(
            listenPort: 0,
            downloadDir: nil,
            enableDHT: false,
            enableLSD: false,
            enableUPnP: false,
            enableNATPMP: false,
            encryptionEnabled: true,
            maxConnections: max(1, budget.maxPeerConnections),
            maxActiveDownloads: max(1, budget.maxActiveDownloads),
            maxActiveSeeds: max(1, budget.maxActiveSeeds),
            maxConnectionAttempts: max(0, budget.maxConnectionAttempts),
            cacheBytes: max(1, budget.cacheBytes),
            alertQueueSize: UInt32(clamping: max(1, budget.alertDrainBatch * 4))
        )
    }
}
