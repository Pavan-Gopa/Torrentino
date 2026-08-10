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
    private var lastProjectedStatuses: [String: TransferTorrentStatus] = [:]
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
            lastProjectedStatuses.removeAll()
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
        lastProjectedStatuses.removeAll()
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
        // WP-10 (Gate 6): the bridge is delete-free — never ask the engine to
        // delete payload bytes. Payload cleanup is the coordinator's
        // manifest-scoped Trash (see handleCommitRemoval).
        let token = try await coordinator.prepareRemoval(torrentID: torrentID)
        _ = try await coordinator.commitRemoval(token: token)
    }

    /// WP-10: async storage move via the bridge (bounded wait, dont_replace).
    public func moveStorage(torrentID: String, destinationPath: String) async throws {
        do {
            try await coordinator.moveStorage(torrentID: torrentID, destinationPath: destinationPath)
        } catch {
            throw Self.mappedBridgeError(error, operation: "moveStorage")
        }
    }

    public func setLimits(torrentID: String, limits: TorrentinoIPC.TransferLimits) async throws {
        do {
            try await coordinator.setLimits(torrentID: torrentID, limits: limits)
        } catch {
            throw Self.mappedBridgeError(error, operation: "setLimits")
        }
    }

    public func editTrackers(torrentID: String, trackerTiers: [[String]]) async throws {
        do {
            try await coordinator.editTrackers(torrentID: torrentID, trackerTiers: trackerTiers)
        } catch {
            throw Self.mappedBridgeError(error, operation: "editTrackers")
        }
    }

    /// Reject-only compatibility stub. Accepted live edits are nested.
    public func editTrackers(torrentID: String, trackers: [String]) async throws {
        throw EngineCoordinatorError.unsupportedOperation("scalar tracker edit")
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
        if let drainMessage = EngineAlertDTO.alertDrainLogMessage(count: alerts.count) {
            TorrentinoLog.record(category: "transfer", level: "debug", message: drainMessage)
        }
        for alert in alerts {
            guard let torrentID = alert.torrentID else { continue }
            let projectedHealth = Self.health(
                from: alert.error ?? (alert.kind == "error" ? alert.message : nil),
                kind: alert.kind
            )
            statusCache.merge(
                CachedTorrentStatus(
                    fraction: alert.progress,
                    state: alert.state,
                    error: alert.error ?? (alert.kind == "error" ? alert.message : nil),
                    health: projectedHealth,
                    downloadRate: alert.downloadRate,
                    uploadRate: alert.uploadRate,
                    downloadedBytes: alert.downloadedBytes,
                    uploadedBytes: alert.uploadedBytes,
                    peersConnected: alert.peersConnected,
                    seedsTotal: alert.seedsTotal,
                    name: alert.name,
                    totalSize: alert.totalSize
                ),
                for: torrentID
            )
            if alert.kind == "removed" {
                statusCache.remove(torrentID)
                lastProjectedStatuses.removeValue(forKey: torrentID)
                continue
            }
            if projectedHealth != .healthy {
                let alertLog = EngineAlertDTO.alertLogMessage(for: alert)
                TorrentinoLog.record(category: "transfer", level: alertLog.severity, message: alertLog.message)
            }
        }
        // A first-ever failed status poll has no prior sample to merge into.
        // Keep the cache's -1 unknown sentinel internal; the coordinator's
        // value types remain non-negative and receive neutral zeroes until a
        // successful sample arrives. Existing live values were preserved above.
        let projected = statusCache.entries.map { torrentID, snapshot in
            TransferTorrentStatus(
                engineID: torrentID,
                progressFraction: max(0, min(1, snapshot.fraction)),
                downloadedBytes: max(0, snapshot.downloadedBytes),
                uploadedBytes: max(0, snapshot.uploadedBytes),
                downloadBytesPerSec: max(0, snapshot.downloadRate),
                uploadBytesPerSec: max(0, snapshot.uploadRate),
                peersConnected: max(0, snapshot.peersConnected),
                seedsTotal: max(0, snapshot.seedsTotal),
                activity: Self.activity(from: snapshot.state),
                health: snapshot.health,
                etaSeconds: nil,
                metadataName: snapshot.name,
                totalBytes: snapshot.totalSize
            )
        }
        for status in projected {
            if let previous = lastProjectedStatuses[status.engineID],
               (previous.activity != status.activity || previous.health != status.health) {
                TorrentinoLog.record(
                    category: "transfer",
                    level: status.health == .healthy ? "notice" : "warning",
                    message: "transfer transition engineID=\(status.engineID) activity=\(previous.activity.rawValue)->\(status.activity.rawValue) health=\(previous.health)->\(status.health)"
                )
            }
            lastProjectedStatuses[status.engineID] = status
        }
        return projected
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
    static func activity(from state: Int) -> TorrentActivity {
        LibtorrentActivityMapper.activity(from: state)
    }

    /// Projects only live/native faults. A warning alert by itself is
    /// transient; the next live status sample carries the healthy clear.
    static func health(from error: String?, kind: String) -> TorrentHealth {
        LibtorrentActivityMapper.health(from: error, kind: kind)
    }

    static func health(from error: String?) -> TorrentHealth {
        health(from: error, kind: "error")
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

extension EngineAlertDTO {
    static func alertDrainLogMessage(count: Int) -> String? {
        count > 0 ? "bridge alerts drained count=\(count)" : nil
    }

    static func alertLogMessage(for alert: EngineAlertDTO) -> (severity: String, message: String) {
        let type: String
        switch alert.kind {
        case "error": type = "torrent_error_alert"
        case "unknown": type = "tracker_announce"
        case "session": type = "storage"
        default: type = alert.kind
        }
        let severity = alert.kind == "session" ? "warning" : "error"
        let message = alert.error ?? alert.message ?? "alert"
        return (
            severity: severity,
            message: "libtorrent alert type=\(type) severity=\(severity) message=\(message)"
        )
    }
}
