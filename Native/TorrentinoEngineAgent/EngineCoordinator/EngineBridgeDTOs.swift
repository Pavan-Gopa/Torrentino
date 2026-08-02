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
public struct SessionConfigurationDTO: Codable, Sendable, Equatable {
    /// 0 = ephemeral loopback port (hermetic; WP-01 rule).
    public var listenPort: Int
    public var downloadDir: String?
    public var enableDHT: Bool
    public var maxConnections: Int
    public var peerIDPrefix: String
    public var operationTimeoutMS: UInt32
    public var alertQueueSize: UInt32

    public init(
        listenPort: Int = 0,
        downloadDir: String? = nil,
        enableDHT: Bool = false,
        maxConnections: Int = 120,
        peerIDPrefix: String = "-TT0400-",
        operationTimeoutMS: UInt32 = 10_000,
        alertQueueSize: UInt32 = 8_000
    ) {
        self.listenPort = listenPort
        self.downloadDir = downloadDir
        self.enableDHT = enableDHT
        self.maxConnections = maxConnections
        self.peerIDPrefix = peerIDPrefix
        self.operationTimeoutMS = operationTimeoutMS
        self.alertQueueSize = alertQueueSize
    }

    enum CodingKeys: String, CodingKey {
        case listenPort = "listen-port"
        case downloadDir = "download-dir"
        case enableDHT = "enable-dht"
        case maxConnections = "max-connections"
        case peerIDPrefix = "peer-id-prefix"
        case operationTimeoutMS = "operation-timeout-ms"
        case alertQueueSize = "alert-queue-size"
    }
}

/// Specification for adding a torrent (`AddSpecification`). Exactly one of
/// `torrentFile` / `magnetURI` must be non-nil.
public struct AddSpecificationDTO: Codable, Sendable, Equatable {
    public var torrentFile: Data?
    public var magnetURI: String?
    public var savePath: String
    public var paused: Bool

    public init(torrentFile: Data? = nil, magnetURI: String? = nil, savePath: String, paused: Bool = false) {
        self.torrentFile = torrentFile
        self.magnetURI = magnetURI
        self.savePath = savePath
        self.paused = paused
    }

    enum CodingKeys: String, CodingKey {
        case torrentFile = "torrent-file"
        case magnetURI = "magnet-uri"
        case savePath = "save-path"
        case paused = "paused"
    }
}

/// Boot confirmation returned by `start` (`BootReport`).
public struct BootReportDTO: Codable, Sendable, Equatable {
    public var version: String
    public var peerID: String
    public var listenPort: Int

    enum CodingKeys: String, CodingKey {
        case version = "version"
        case peerID = "peer-id"
        case listenPort = "listen-port"
    }
}

/// Result of adding a torrent (`AddResult`).
public struct AddResultDTO: Codable, Sendable, Equatable {
    public var torrentID: String
    public var infoHash: String
    public var name: String
    /// -1 while metadata is unknown (magnet-added).
    public var totalSize: Int64

    enum CodingKeys: String, CodingKey {
        case torrentID = "torrent-id"
        case infoHash = "info-hash"
        case name = "name"
        case totalSize = "total-size"
    }
}

/// Aggregated alert batch item (`EngineAlertDTO`). A batch may contain zero
/// or more alerts; `kind` is a stable kebab-case name (see bridging header).
public struct EngineAlertDTO: Codable, Sendable, Equatable {
    public var kind: String
    public var torrentID: String?
    public var progress: Double
    public var state: Int
    public var error: String?
    public var message: String?

    public init(kind: String, torrentID: String? = nil, progress: Double = -1, state: Int = -1,
                error: String? = nil, message: String? = nil) {
        self.kind = kind
        self.torrentID = torrentID
        self.progress = progress
        self.state = state
        self.error = error
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case kind = "kind"
        case torrentID = "torrent-id"
        case progress = "progress"
        case state = "state"
        case error = "error"
        case message = "message"
    }
}

/// Health snapshot (`HealthDTO`).
public struct HealthDTO: Codable, Sendable, Equatable {
    public var uptimeSeconds: UInt64
    public var activeTorrents: Int
    public var downloadRate: Int
    public var uploadRate: Int
    public var alertsSeen: UInt64
    public var running: Bool

    enum CodingKeys: String, CodingKey {
        case uptimeSeconds = "uptime-seconds"
        case activeTorrents = "active-torrents"
        case downloadRate = "download-rate"
        case uploadRate = "upload-rate"
        case alertsSeen = "alerts-seen"
        case running = "running"
    }
}

/// Resume data response (`ResumeDataDTO`).
public struct ResumeDataDTO: Codable, Sendable, Equatable {
    public var torrentID: String
    public var resumeData: Data

    enum CodingKeys: String, CodingKey {
        case torrentID = "torrent-id"
        case resumeData = "resume-data"
    }
}

/// Opaque removal token (`RemovalToken`), produced by prepare, consumed by commit.
public struct RemovalTokenDTO: Codable, Sendable, Equatable {
    public var torrentID: String
    public var deleteFiles: Bool
    public var nonce: UInt64

    enum CodingKeys: String, CodingKey {
        case torrentID = "torrent-id"
        case deleteFiles = "delete-files"
        case nonce = "nonce"
    }
}

/// Removal outcome (`RemovalResult`).
public struct RemovalResultDTO: Codable, Sendable, Equatable {
    public var torrentID: String
    public var filesDeleted: Bool

    enum CodingKeys: String, CodingKey {
        case torrentID = "torrent-id"
        case filesDeleted = "files-deleted"
    }
}

/// Parsed result of decoding an adapter DTO envelope.
public enum DTODecodeResult<T: Codable & Sendable>: Sendable {
    case success(T)
    case malformed(String)
}