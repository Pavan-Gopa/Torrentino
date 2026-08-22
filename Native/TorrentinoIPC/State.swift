// Layer: IPC (shared state vocabulary, plan §7.2).
// Role: the desired/activity/health split plus progress/rates/peer summary
// value types every torrent snapshot carries.
// Must-not: carry file trees, peer lists, or engine internals; those live in
// paginated/on-demand queries.
// Invariants: all Codable + Sendable + immutable; desired state, activity and
// health are deliberately separate enums so no single mega-enum can contradict
// itself.

import Foundation

/// What the UI wants the torrent to do. The agent is the authority that
/// reconciles desired → actual and reports the outcome via activity/health.
public enum DesiredTorrentState: String, Codable, Sendable, Equatable, CaseIterable {
    case running
    case paused
    /// One-shot: the agent runs the durable removal state machine.
    case removed
}

/// What the torrent is actually doing, independent of what was requested.
public enum TorrentActivity: String, Codable, Sendable, Equatable, CaseIterable {
    case pendingAdd
    case fetchingMetadata
    case queued
    case checking
    case downloading
    case seeding
    case moving
    case removing
    case idle
}

/// Why a torrent is not healthy. "No peers" is NOT an error — it is a normal
/// swarm condition and maps to .healthy.
public enum TorrentHealth: Codable, Sendable, Equatable {
    case healthy
    case waitingForNetwork
    case waitingForVolume
    case waitingForSpace
    case permissionDenied
    case recoverableError(EngineErrorCode)
    case fatalError(EngineErrorCode)

    // Keep the shared API shape for the existing inspector while the rejected
    // lane's localized health presentation is rolled back.
    public var localizedDescription: String? { nil }
}

/// Byte accounting for a torrent. fraction is 0.0...1.0.
public struct TransferProgress: Codable, Sendable, Equatable {
    public let fraction: Double
    public let totalBytes: Int64
    public let downloadedBytes: Int64
    public let uploadedBytes: Int64

    public init(fraction: Double, totalBytes: Int64, downloadedBytes: Int64, uploadedBytes: Int64) {
        self.fraction = fraction
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
    }
}

/// Instantaneous transfer rates in bytes/second (agent-computed averages).
public struct TransferRates: Codable, Sendable, Equatable {
    public let downloadBytesPerSec: Int64
    public let uploadBytesPerSec: Int64

    public init(downloadBytesPerSec: Int64, uploadBytesPerSec: Int64) {
        self.downloadBytesPerSec = downloadBytesPerSec
        self.uploadBytesPerSec = uploadBytesPerSec
    }
}

/// Peer connectivity counts. No per-peer arrays — those are paginated.
public struct PeerSummary: Codable, Sendable, Equatable {
    public let connected: Int
    public let halfOpen: Int
    public let total: Int

    public init(connected: Int, halfOpen: Int, total: Int) {
        self.connected = connected
        self.halfOpen = halfOpen
        self.total = total
    }
}

/// Per-file selection priority in v1.0 (plan §7.4: skip | normal only).
public enum FileSelectionPriority: String, Codable, Sendable, Equatable, CaseIterable {
    case skip
    case normal
}

/// One row of a setFileSelection payload.
public struct FileSelectionItem: Codable, Sendable, Equatable {
    public let relativePath: String
    public let priority: FileSelectionPriority

    public init(relativePath: String, priority: FileSelectionPriority) {
        self.relativePath = relativePath
        self.priority = priority
    }
}

/// Where torrent data lives. volumeIdentifier is the agent-side volume UUID
/// when known (empty string when the volume has none).
public struct PersistedLocation: Codable, Sendable, Equatable {
    public let path: String
    public let volumeIdentifier: String?

    public init(path: String, volumeIdentifier: String? = nil) {
        self.path = path
        self.volumeIdentifier = volumeIdentifier
    }
}

/// Per-torrent bandwidth limits and seed goals. nil means "not supplied";
/// zero is the explicit unlimited value accepted by the engine for a field.
public struct TransferLimits: Codable, Sendable, Equatable {
    public let maxDownloadBytesPerSec: Int64?
    public let maxUploadBytesPerSec: Int64?
    public let ratioLimit: Double?
    public let seedTimeSeconds: Int64?

    public init(
        maxDownloadBytesPerSec: Int64? = nil,
        maxUploadBytesPerSec: Int64? = nil,
        ratioLimit: Double? = nil,
        seedTimeSeconds: Int64? = nil
    ) {
        self.maxDownloadBytesPerSec = maxDownloadBytesPerSec
        self.maxUploadBytesPerSec = maxUploadBytesPerSec
        self.ratioLimit = ratioLimit
        self.seedTimeSeconds = seedTimeSeconds
    }

    /// The native bridge passes bandwidth limits to a signed C++ `int`.
    /// Keeping this bound in the shared value type prevents an overflowing
    /// Swift value from being persisted before the bridge can reject it.
    public static let maxBandwidthBytesPerSec = Int64(Int32.max)

    public var validationError: TransferLimitsValidationError? {
        if let maxDownloadBytesPerSec {
            if maxDownloadBytesPerSec < 0 {
                return .negative(field: "maxDownloadBytesPerSec")
            }
            if maxDownloadBytesPerSec > Self.maxBandwidthBytesPerSec {
                return .exceedsEngineRange(field: "maxDownloadBytesPerSec")
            }
        }
        if let maxUploadBytesPerSec {
            if maxUploadBytesPerSec < 0 {
                return .negative(field: "maxUploadBytesPerSec")
            }
            if maxUploadBytesPerSec > Self.maxBandwidthBytesPerSec {
                return .exceedsEngineRange(field: "maxUploadBytesPerSec")
            }
        }
        if let ratioLimit {
            if !ratioLimit.isFinite {
                return .nonFinite(field: "ratioLimit")
            }
            if ratioLimit < 0 {
                return .negative(field: "ratioLimit")
            }
        }
        if let seedTimeSeconds, seedTimeSeconds < 0 {
            return .negative(field: "seedTimeSeconds")
        }
        return nil
    }
}

public enum TransferLimitsValidationError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    case negative(field: String)
    case nonFinite(field: String)
    case exceedsEngineRange(field: String)

    public var description: String {
        switch self {
        case .negative(let field): return "\(field) must be non-negative"
        case .nonFinite(let field): return "\(field) must be finite"
        case .exceedsEngineRange(let field): return "\(field) exceeds the engine range"
        }
    }
}

/// An add source the UI hands to inspectAddSource / commitAdd.
public enum AddSource: Codable, Sendable, Equatable {
    case magnet(String)
    case torrentFileData(Data)
    case torrentFileURL(String)
}

/// Proxy settings for testProxy and (in later WPs) the session config.
public struct ProxyConfiguration: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case none
        case socks5
        case http
    }

    public let kind: Kind
    public let host: String
    public let port: UInt16
    public let username: String?
    public let password: String?

    public init(kind: Kind, host: String, port: UInt16, username: String? = nil, password: String? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

/// String and debug representations never carry the password: diagnostics,
/// logs, and export bundles may stringify proxy settings (WP-13 threat model;
/// see also the WP-09 secret-hygiene residual note).
extension ProxyConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ProxyConfiguration(kind: \(kind.rawValue), host: \(host), port: \(port), "
            + "username: \(username ?? "nil"), password: \(password == nil ? "nil" : "<redacted>"))"
    }

    public var debugDescription: String { description }
}

/// Agent lifecycle states (plan §8.1). A degraded state carries its reason in
/// the event payload rather than in the enum raw value.
public enum EngineLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    case unregistered
    case registering
    case starting
    case openingStore
    case migratingStore
    case restoringSession
    case reconcilingRecords
    case ready
    case degraded
    case checkpointing
    case stopping
    case stopped
}
