// Layer: EngineCoordinator (WP-04 bridge DTOs).
// Role:     Swift mirrors of the C++ EngineBridge DTOs, exchanged with the
//           ObjC adapter as JSON envelopes. Every type is immutable, Sendable
//           and Codable so it can cross the actor boundary and be persisted.
// Must not: carry C++ types, mutable state, or engine internals; the CodingKeys
//           below are frozen to the kebab-case wire schema of EngineBridgeAdapter.
// Invariants: decode(from:) is the only entry point for DTOs coming from the
//           adapter; encode() is the reverse. Evolution adds keys, never
//           renames or removes them.

import Foundation

// ---------------------------------------------------------------------------
// Wire schema mirror (kebab-case keys, frozen).
// ---------------------------------------------------------------------------

extension CodingUserInfoKey {
    /// Set by EngineCoordinator.decode(yielding:nil) to allow lenient decoding
    /// of payloads produced by older bridges. Not used by the current adapter
    /// but part of the frozen contract (ADR-005).
    static let allowUnknownKeys = CodingUserInfoKey(rawValue: "com.torrentino.engine-coordinator.allow-unknown")!
}

// ---------------------------------------------------------------------------
// Bridge DTOs
// ---------------------------------------------------------------------------

/// Startup configuration passed to the engine (`SessionConfiguration`).
public struct SessionProxyDTO: Codable, Sendable, Equatable {
    public let kind: String
    public let host: String
    public let port: UInt16
    public let username: String?

    public init(kind: String = "none", host: String = "", port: UInt16 = 0,
                username: String? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
    }
}

public struct SessionConfigurationDTO: Codable, Sendable, Equatable {
    /// 0 = ephemeral loopback port (hermetic; WP-01 rule).
    public let listenPort: Int
    public let downloadDir: String?
    public let enableDHT: Bool
    public let enableLSD: Bool
    public let enableUPnP: Bool
    public let enableNATPMP: Bool
    public let encryptionEnabled: Bool
    public let maxConnections: Int
    public let maxActiveDownloads: Int
    public let maxActiveSeeds: Int
    public let maxConnectionAttempts: Int
    public let cacheBytes: Int64
    public let peerIDPrefix: String
    public let operationTimeoutMS: UInt32
    public let alertQueueSize: UInt32
    /// Settings metadata carried to the bridge configuration boundary. Older
    /// bridge binaries ignore unknown keys; the Swift coordinator still keeps
    /// the complete authoritative candidate together.
    public let maxDownloadBytesPerSec: Int64
    public let maxUploadBytesPerSec: Int64
    public let proxy: SessionProxyDTO

    public init(
        listenPort: Int = 0,
        downloadDir: String? = nil,
        enableDHT: Bool = false,
        enableLSD: Bool = false,
        enableUPnP: Bool = false,
        enableNATPMP: Bool = false,
        encryptionEnabled: Bool = true,
        maxConnections: Int = 120,
        maxActiveDownloads: Int = 4,
        maxActiveSeeds: Int = 8,
        maxConnectionAttempts: Int = 20,
        cacheBytes: Int64 = 64 * 1024 * 1024,
        peerIDPrefix: String = "-TT0400-",
        operationTimeoutMS: UInt32 = 10_000,
        alertQueueSize: UInt32 = 8_000,
        maxDownloadBytesPerSec: Int64 = 0,
        maxUploadBytesPerSec: Int64 = 0,
        proxy: SessionProxyDTO = SessionProxyDTO()
    ) {
        self.listenPort = listenPort
        self.downloadDir = downloadDir
        self.enableDHT = enableDHT
        self.enableLSD = enableLSD
        self.enableUPnP = enableUPnP
        self.enableNATPMP = enableNATPMP
        self.encryptionEnabled = encryptionEnabled
        self.maxConnections = maxConnections
        self.maxActiveDownloads = maxActiveDownloads
        self.maxActiveSeeds = maxActiveSeeds
        self.maxConnectionAttempts = maxConnectionAttempts
        self.cacheBytes = cacheBytes
        self.peerIDPrefix = peerIDPrefix
        self.operationTimeoutMS = operationTimeoutMS
        self.alertQueueSize = alertQueueSize
        self.maxDownloadBytesPerSec = maxDownloadBytesPerSec
        self.maxUploadBytesPerSec = maxUploadBytesPerSec
        self.proxy = proxy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.listenPort = try container.decode(Int.self, forKey: .listenPort)
        self.downloadDir = try container.decodeIfPresent(String.self, forKey: .downloadDir)
        self.enableDHT = try container.decode(Bool.self, forKey: .enableDHT)
        self.enableLSD = try container.decodeIfPresent(Bool.self, forKey: .enableLSD) ?? false
        self.enableUPnP = try container.decodeIfPresent(Bool.self, forKey: .enableUPnP) ?? false
        self.enableNATPMP = try container.decodeIfPresent(Bool.self, forKey: .enableNATPMP) ?? false
        self.encryptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .encryptionEnabled) ?? true
        self.maxConnections = try container.decode(Int.self, forKey: .maxConnections)
        self.maxActiveDownloads = try container.decodeIfPresent(Int.self, forKey: .maxActiveDownloads) ?? 4
        self.maxActiveSeeds = try container.decodeIfPresent(Int.self, forKey: .maxActiveSeeds) ?? 8
        self.maxConnectionAttempts = try container.decodeIfPresent(Int.self, forKey: .maxConnectionAttempts) ?? 20
        self.cacheBytes = try container.decodeIfPresent(Int64.self, forKey: .cacheBytes) ?? 64 * 1024 * 1024
        self.peerIDPrefix = try container.decode(String.self, forKey: .peerIDPrefix)
        self.operationTimeoutMS = try container.decode(UInt32.self, forKey: .operationTimeoutMS)
        self.alertQueueSize = try container.decode(UInt32.self, forKey: .alertQueueSize)
        self.maxDownloadBytesPerSec = try container.decodeIfPresent(Int64.self, forKey: .maxDownloadBytesPerSec) ?? 0
        self.maxUploadBytesPerSec = try container.decodeIfPresent(Int64.self, forKey: .maxUploadBytesPerSec) ?? 0
        self.proxy = try container.decodeIfPresent(SessionProxyDTO.self, forKey: .proxy)
            ?? SessionProxyDTO()
    }

    enum CodingKeys: String, CodingKey {
        case listenPort = "listen-port"
        case downloadDir = "download-dir"
        case enableDHT = "enable-dht"
        case enableLSD = "enable-lsd"
        case enableUPnP = "enable-upnp"
        case enableNATPMP = "enable-natpmp"
        case encryptionEnabled = "encryption-enabled"
        case maxConnections = "max-connections"
        case maxActiveDownloads = "max-active-downloads"
        case maxActiveSeeds = "max-active-seeds"
        case maxConnectionAttempts = "max-connection-attempts"
        case cacheBytes = "cache-bytes"
        case peerIDPrefix = "peer-id-prefix"
        case operationTimeoutMS = "operation-timeout-ms"
        case alertQueueSize = "alert-queue-size"
        case maxDownloadBytesPerSec = "max-download-bytes-per-sec"
        case maxUploadBytesPerSec = "max-upload-bytes-per-sec"
        case proxy = "proxy"
    }
}

/// Specification for adding a torrent (`AddSpecification`). Exactly one of
/// `torrentFile` / `magnetURI` must be non-nil.
public struct AddSpecificationDTO: Codable, Sendable, Equatable {
    public let torrentFile: Data?
    public let magnetURI: String?
    public let savePath: String
    public let paused: Bool
    /// Per-task DHT/PEX/LSD policy (WP-11 private-torrent invariant). nil
    /// leaves the engine default; false explicitly disables the feature for
    /// this torrent (required for private torrents: no tracker-independent
    /// peer discovery).
    public let enableDHT: Bool?
    public let enablePEX: Bool?
    public let enableLSD: Bool?

    public init(
        torrentFile: Data? = nil,
        magnetURI: String? = nil,
        savePath: String,
        paused: Bool = false,
        enableDHT: Bool? = nil,
        enablePEX: Bool? = nil,
        enableLSD: Bool? = nil
    ) {
        self.torrentFile = torrentFile
        self.magnetURI = magnetURI
        self.savePath = savePath
        self.paused = paused
        self.enableDHT = enableDHT
        self.enablePEX = enablePEX
        self.enableLSD = enableLSD
    }

    enum CodingKeys: String, CodingKey {
        case torrentFile = "torrent-file"
        case magnetURI = "magnet-uri"
        case savePath = "save-path"
        case paused = "paused"
        case enableDHT = "enable-dht"
        case enablePEX = "enable-pex"
        case enableLSD = "enable-lsd"
    }
}

/// Complete structured tracker replacement crossing the Swift/ObjC++ value
/// boundary. The scalar compatibility payload is intentionally not modeled.
public struct EditTrackersDTO: Codable, Sendable, Equatable {
    public let torrentID: String
    public let trackerTiers: [[String]]

    public init(torrentID: String, trackerTiers: [[String]]) {
        self.torrentID = torrentID
        self.trackerTiers = trackerTiers
    }

    enum CodingKeys: String, CodingKey {
        case torrentID = "torrent-id"
        case trackerTiers = "tracker-tiers"
    }
}

/// Boot confirmation returned by `start` (`BootReport`).
public struct BootReportDTO: Codable, Sendable, Equatable {
    public let version: String
    public let peerID: String
    public let listenPort: Int

    enum CodingKeys: String, CodingKey {
        case version = "version"
        case peerID = "peer-id"
        case listenPort = "listen-port"
    }
}

/// Result of adding a torrent (`AddResult`).
public struct AddResultDTO: Codable, Sendable, Equatable {
    public let torrentID: String
    public let infoHash: String
    public let name: String
    /// -1 while metadata is unknown (magnet-added).
    public let totalSize: Int64

    enum CodingKeys: String, CodingKey {
        case torrentID = "torrent-id"
        case infoHash = "info-hash"
        case name = "name"
        case totalSize = "total-size"
    }
}

/// Identities returned by the pinned libtorrent parser for a complete
/// .torrent byte buffer. Hash strings are lowercase hex; presence is explicit
/// so v1, v2, and hybrid shapes cannot be inferred from an empty value.
public struct IndependentTorrentIdentityDTO: Codable, Sendable, Equatable {
    public let hasV1: Bool
    public let hasV2: Bool
    public let v1Hash: String
    public let v2Hash: String

    public init(hasV1: Bool, hasV2: Bool, v1Hash: String, v2Hash: String) {
        self.hasV1 = hasV1
        self.hasV2 = hasV2
        self.v1Hash = v1Hash
        self.v2Hash = v2Hash
    }

    enum CodingKeys: String, CodingKey {
        case hasV1 = "has-v1"
        case hasV2 = "has-v2"
        case v1Hash = "v1-hash"
        case v2Hash = "v2-hash"
    }
}

/// Aggregated alert batch item (`EngineAlertDTO`). A batch may contain zero
/// or more alerts; `kind` is a stable kebab-case name (see bridging header).
/// Live scalar fields use -1 when the native handle status could not be read.
/// Zero is a valid observation for idle rates, counters, and peer counts.
public struct EngineAlertDTO: Codable, Sendable, Equatable {
    public let kind: String
    public let torrentID: String?
    public let progress: Double
    public let state: Int
    public let error: String?
    public let message: String?
    public let downloadRate: Int64
    public let uploadRate: Int64
    public let downloadedBytes: Int64
    public let uploadedBytes: Int64
    public let peersConnected: Int
    public let seedsTotal: Int

    public init(
        kind: String,
        torrentID: String? = nil,
        progress: Double = -1,
        state: Int = -1,
        error: String? = nil,
        message: String? = nil,
        downloadRate: Int64 = -1,
        uploadRate: Int64 = -1,
        downloadedBytes: Int64 = -1,
        uploadedBytes: Int64 = -1,
        peersConnected: Int = -1,
        seedsTotal: Int = -1
    ) {
        self.kind = kind
        self.torrentID = torrentID
        self.progress = progress
        self.state = state
        self.error = error
        self.message = message
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
        self.peersConnected = peersConnected
        self.seedsTotal = seedsTotal
    }

    enum CodingKeys: String, CodingKey {
        case kind = "kind"
        case torrentID = "torrent-id"
        case progress = "progress"
        case state = "state"
        case error = "error"
        case message = "message"
        case downloadRate = "download-rate"
        case uploadRate = "upload-rate"
        case downloadedBytes = "downloaded-bytes"
        case uploadedBytes = "uploaded-bytes"
        case peersConnected = "peers-connected"
        case seedsTotal = "seeds-total"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        torrentID = try container.decodeIfPresent(String.self, forKey: .torrentID)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? -1
        state = try container.decodeIfPresent(Int.self, forKey: .state) ?? -1
        error = try container.decodeIfPresent(String.self, forKey: .error)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        downloadRate = try container.decodeIfPresent(Int64.self, forKey: .downloadRate) ?? -1
        uploadRate = try container.decodeIfPresent(Int64.self, forKey: .uploadRate) ?? -1
        downloadedBytes = try container.decodeIfPresent(Int64.self, forKey: .downloadedBytes) ?? -1
        uploadedBytes = try container.decodeIfPresent(Int64.self, forKey: .uploadedBytes) ?? -1
        peersConnected = try container.decodeIfPresent(Int.self, forKey: .peersConnected) ?? -1
        seedsTotal = try container.decodeIfPresent(Int.self, forKey: .seedsTotal) ?? -1
    }
}

/// Health snapshot (`HealthDTO`).
public struct HealthDTO: Codable, Sendable, Equatable {
    public let uptimeSeconds: UInt64
    public let activeTorrents: Int
    public let downloadRate: Int
    public let uploadRate: Int
    public let alertsSeen: UInt64
    public let running: Bool

    enum CodingKeys: String, CodingKey {
        case uptimeSeconds = "uptime-seconds"
        case activeTorrents = "active-torrents"
        case downloadRate = "download-rate"
        case uploadRate = "upload-rate"
        case alertsSeen = "alerts-seen"
        case running = "running"
    }
}

/// Raw per-torrent bandwidth limits reported by libtorrent. `0` means
/// unlimited for the pinned native handle getter.
public struct AppliedTorrentLimitsDTO: Codable, Sendable, Equatable {
    public let maxDownloadBytesPerSec: Int64
    public let maxUploadBytesPerSec: Int64

    enum CodingKeys: String, CodingKey {
        case maxDownloadBytesPerSec = "max-download-bytes-per-sec"
        case maxUploadBytesPerSec = "max-upload-bytes-per-sec"
    }
}

/// Resume data response (`ResumeDataDTO`).
public struct ResumeDataDTO: Codable, Sendable, Equatable {
    public let torrentID: String
    public let resumeData: Data

    enum CodingKeys: String, CodingKey {
        case torrentID = "torrent-id"
        case resumeData = "resume-data"
    }
}

/// Opaque removal token (`RemovalToken`), produced by prepare, consumed by
/// commit. WP-10 (Gate 6): the wire token carries NO delete-files flag — the
/// bridge is permanently delete-free.
public struct RemovalTokenDTO: Codable, Sendable, Equatable {
    public let torrentID: String
    public let nonce: UInt64

    enum CodingKeys: String, CodingKey {
        case torrentID = "torrent-id"
        case nonce = "nonce"
    }
}

/// Removal outcome (`RemovalResult`).
public struct RemovalResultDTO: Codable, Sendable, Equatable {
    public let torrentID: String

    enum CodingKeys: String, CodingKey {
        case torrentID = "torrent-id"
    }
}

/// WP-10 async storage move request (`moveStorage(id, path)`). The bridge
/// performs a bounded wait for storage_moved_alert / storage_moved_failed_alert
/// with dont_replace semantics (destination files are adopted, never
/// overwritten).
public struct MoveStorageRequestDTO: Codable, Sendable, Equatable {
    public let torrentID: String
    public let path: String

    public init(torrentID: String, path: String) {
        self.torrentID = torrentID
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case torrentID = "torrent-id"
        case path = "path"
    }
}

/// Parsed result of decoding an adapter DTO envelope.
public enum DTODecodeResult<T: Codable & Sendable>: Sendable {
    case success(T)
    case malformed(String)
}
