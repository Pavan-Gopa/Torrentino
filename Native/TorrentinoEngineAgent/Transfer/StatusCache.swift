// Layer: EngineAgent (Transfer).
// Role: byte-bounded live status retention for the bridge-backed engine.
// Must-not: retain unbounded alert text or claim an entry-count cap is a byte
// cap. The cache measures the retained strings and fixed value payload.

import Foundation
import TorrentinoIPC

enum LibtorrentActivityMapper {
    /// libtorrent 2.1 `torrent_status::state_t` values to the IPC activity
    /// vocabulary. Keep this in a target-shared file so the regression target
    /// exercises the exact mapper used by the production bridge.
    static func activity(from state: Int) -> TorrentActivity {
        switch state {
        case 0: return .queued // queued_for_checking
        case 1, 6, 7: return .checking // checking_files / allocating / resume data
        case 2: return .fetchingMetadata // downloading_metadata
        case 3: return .downloading
        case 4, 5: return .seeding // finished / seeding
        default: return .idle
        }
    }

    static func health(from error: String?, kind: String) -> TorrentHealth {
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
        // Unknown text is a real fault only for an explicit error alert.
        return kind == "error" ? .recoverableError(.internalError) : .healthy
    }
}

struct CachedTorrentStatus: Sendable, Equatable {
    let fraction: Double
    let state: Int
    let error: String?
    let health: TorrentHealth
    let downloadRate: Int64
    let uploadRate: Int64
    let downloadedBytes: Int64
    let uploadedBytes: Int64
    let peersConnected: Int
    let seedsTotal: Int
    let errorObservedAt: Date?

    init(
        fraction: Double,
        state: Int,
        error: String?,
        health: TorrentHealth = .healthy,
        downloadRate: Int64 = 0,
        uploadRate: Int64 = 0,
        downloadedBytes: Int64 = 0,
        uploadedBytes: Int64 = 0,
        peersConnected: Int = 0,
        seedsTotal: Int = 0,
        errorObservedAt: Date? = nil
    ) {
        self.fraction = fraction
        self.state = state
        self.error = error
        self.health = health
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
        self.peersConnected = peersConnected
        self.seedsTotal = seedsTotal
        self.errorObservedAt = errorObservedAt
    }
}

struct ByteBoundedStatusCache: Sendable {
    static let faultTTL: TimeInterval = 30

    private(set) var entries: [String: CachedTorrentStatus] = [:]
    private(set) var byteCount = 0

    private var order: [String] = []
    private let entryLimit: Int
    private var byteLimit: Int64

    init(entryLimit: Int = 1024, byteLimit: Int64 = 64 * 1024 * 1024) {
        self.entryLimit = max(0, entryLimit)
        self.byteLimit = max(0, byteLimit)
    }

    mutating func setByteLimit(_ limit: Int64) {
        byteLimit = max(0, limit)
        trim()
    }

    mutating func insert(_ status: CachedTorrentStatus, for key: String) {
        if let previous = entries[key] {
            byteCount -= Self.estimatedBytes(key: key, status: previous)
        } else {
            order.removeAll { $0 == key }
        }
        entries[key] = status
        order.append(key)
        byteCount += Self.estimatedBytes(key: key, status: status)
        trim()
    }

    /// Applies a partial alert sample without allowing sentinel progress/state
    /// values to erase the last live sample. `error` and `health` are always
    /// replaced because a healthy status is the explicit clear signal for a
    /// previous non-fatal alert.
    mutating func merge(_ status: CachedTorrentStatus, for key: String) {
        guard let previous = entries[key] else {
            insert(status, for: key)
            return
        }
        insert(
            CachedTorrentStatus(
                fraction: status.fraction >= 0 ? status.fraction : previous.fraction,
                state: status.state >= 0 ? status.state : previous.state,
                error: status.error,
                health: status.health,
                downloadRate: status.downloadRate,
                uploadRate: status.uploadRate,
                downloadedBytes: status.downloadedBytes,
                uploadedBytes: status.uploadedBytes,
                peersConnected: status.peersConnected,
                seedsTotal: status.seedsTotal,
                errorObservedAt: status.health == .healthy ? nil : (status.errorObservedAt ?? Date())
            ),
            for: key
        )
    }

    /// A fault alert is evidence, not a permanent record state. If no newer
    /// live sample or alert repeats it within the bounded TTL, clear it.
    mutating func expireFaults(now: Date = Date()) {
        for (key, status) in entries {
            guard status.health != .healthy,
                  let observedAt = status.errorObservedAt,
                  now.timeIntervalSince(observedAt) >= Self.faultTTL else { continue }
            insert(
                CachedTorrentStatus(
                    fraction: status.fraction,
                    state: status.state,
                    error: nil,
                    health: .healthy,
                    downloadRate: status.downloadRate,
                    uploadRate: status.uploadRate,
                    downloadedBytes: status.downloadedBytes,
                    uploadedBytes: status.uploadedBytes,
                    peersConnected: status.peersConnected,
                    seedsTotal: status.seedsTotal,
                    errorObservedAt: nil
                ),
                for: key
            )
        }
    }

    mutating func remove(_ key: String) {
        guard let previous = entries.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        byteCount = max(0, byteCount - Self.estimatedBytes(key: key, status: previous))
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        byteCount = 0
    }

    private mutating func trim() {
        while (entries.count > entryLimit || Int64(byteCount) > byteLimit),
              let oldest = order.first {
            order.removeFirst()
            guard let removed = entries.removeValue(forKey: oldest) else { continue }
            byteCount -= Self.estimatedBytes(key: oldest, status: removed)
        }
        byteCount = max(0, byteCount)
    }

    private static func estimatedBytes(key: String, status: CachedTorrentStatus) -> Int {
        // The fixed portion covers the scalar fields and dictionary storage;
        // UTF-8 counts cover the only variable-size retained payloads.
        64 + key.utf8.count + (status.error?.utf8.count ?? 0)
    }
}
