// Layer: Hashing research (WP-12)
// Role: shared value types for the experimental hashing backends. Mirrors the
// production domain contracts (ADR-009 HashingBackend shape, BEP-3/BEP-52
// outputs) with a research-only backend choice; production behaviour is not
// affected by these types.
// Invariants: all types immutable/Sendable; no C++ or Metal objects here.

import Foundation

/// Research mirror of ADR-009 HashingMode. Default remains `automatic`, which
/// must resolve to CPU until (and unless) ADOPT_METAL is decided and wired.
public enum HashingBackendChoice: String, Codable, Sendable {
    case automatic
    case cpu
    case metal

    /// The backend actually executed after gate resolution.
    public var resolvedDefault: HashingBackendChoice {
        self == .automatic ? .cpu : self
    }
}

/// BEP-52 v2 file tree entry (same shape as the production domain value).
public struct V2FileTreeEntry: Sendable, Equatable {
    public let piecesRoot: Data
    public let pieceLayers: Data
    public let sizeBytes: Int64

    public init(piecesRoot: Data, pieceLayers: Data, sizeBytes: Int64) {
        self.piecesRoot = piecesRoot
        self.pieceLayers = pieceLayers
        self.sizeBytes = sizeBytes
    }
}

/// Immutable result of one hashing run (same shape as HashingResult).
public struct HashingOutput: Sendable, Equatable {
    public let v1PiecesData: Data
    public let v2FileTrees: [String: V2FileTreeEntry]
    public let totalBytesHashed: Int64
    public let totalFilesHashed: Int64

    public init(
        v1PiecesData: Data,
        v2FileTrees: [String: V2FileTreeEntry],
        totalBytesHashed: Int64,
        totalFilesHashed: Int64
    ) {
        self.v1PiecesData = v1PiecesData
        self.v2FileTrees = v2FileTrees
        self.totalBytesHashed = totalBytesHashed
        self.totalFilesHashed = totalFilesHashed
    }
}

/// One source file in the hash manifest (research mirror of ScannedFileEntry).
public struct HashSourceFile: Sendable, Equatable {
    public let relativePath: String
    public let fullPath: String
    public let deviceID: UInt64
    public let fileResourceID: UInt64
    public let sizeBytes: Int64
    public let mtimeSeconds: Int64
    public let mtimeNanos: Int64

    public init(
        relativePath: String,
        fullPath: String,
        deviceID: UInt64,
        fileResourceID: UInt64,
        sizeBytes: Int64,
        mtimeSeconds: Int64,
        mtimeNanos: Int64
    ) {
        self.relativePath = relativePath
        self.fullPath = fullPath
        self.deviceID = deviceID
        self.fileResourceID = fileResourceID
        self.sizeBytes = sizeBytes
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanos = mtimeNanos
    }
}

/// Torrent format under test.
public enum ResearchFormat: String, Sendable, Equatable {
    case v1
    case v2
    case hybrid

    public var isV1Needed: Bool { self == .v1 || self == .hybrid }
    public var isV2Needed: Bool { self == .v2 || self == .hybrid }
}

/// Which engine executed the actual digest computation (for reports).
public enum ActualHashEngine: String, Sendable, Equatable {
    case cpu
    case metal
}

/// Per-run observability: fallback counts and staged bytes are the §12.6
/// "fallback count" metric; gpuWallSeconds feeds the cancellation-latency and
/// GPU-time metrics.
public struct BackendRunReport: Sendable, Equatable {
    public let requestedChoice: HashingBackendChoice
    public let actualEngine: ActualHashEngine
    /// How many times a GPU failure forced a CPU recompute of an affected unit.
    public let fallbackCount: Int
    /// Bytes staged into shared Metal buffers (0 when engine == cpu).
    public let stagedBytes: Int64
    /// GPU command-buffer wall time in seconds (0 when engine == cpu).
    public let gpuWallSeconds: Double
    /// Why a Metal path was rejected pre-run (empty when engine == metal).
    public let rejectionReason: String?

    public init(
        requestedChoice: HashingBackendChoice,
        actualEngine: ActualHashEngine,
        fallbackCount: Int,
        stagedBytes: Int64,
        gpuWallSeconds: Double,
        rejectionReason: String?
    ) {
        self.requestedChoice = requestedChoice
        self.actualEngine = actualEngine
        self.fallbackCount = fallbackCount
        self.stagedBytes = stagedBytes
        self.gpuWallSeconds = gpuWallSeconds
        self.rejectionReason = rejectionReason
    }
}

/// Result of one hashing run: output plus run observability.
public struct BackendHashingResult: Sendable, Equatable {
    public let output: HashingOutput
    public let report: BackendRunReport

    public init(output: HashingOutput, report: BackendRunReport) {
        self.output = output
        self.report = report
    }
}

/// Failure semantics shared by both engines.
public enum ResearchHasherError: Error, Sendable, Equatable {
    case hashingFailed(String)
    case fileNotFound(String)
    case unreadableFile(String)
    case sourceModified(String)
    case cancelled
}

/// Metal support report (the §12.8 supported-hook query result).
public struct MetalSupportReport: Sendable, Equatable {
    public let isSupported: Bool
    public let devicePresent: Bool
    public let libraryCompiles: Bool
    public let selfTestPassed: Bool
    public let lowPowerMode: Bool
    public let thermalState: String
    /// Human-readable reason when isSupported == false.
    public let reason: String?

    public init(
        isSupported: Bool,
        devicePresent: Bool,
        libraryCompiles: Bool,
        selfTestPassed: Bool,
        lowPowerMode: Bool,
        thermalState: String,
        reason: String?
    ) {
        self.isSupported = isSupported
        self.devicePresent = devicePresent
        self.libraryCompiles = libraryCompiles
        self.selfTestPassed = selfTestPassed
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.reason = reason
    }
}

/// Experimental flag. The Metal engine never runs unless this is explicitly
/// set; production behaviour is unchanged either way. Read via getenv so
/// tests and QA scripts can set it at runtime (setenv) without a relaunch.
public enum ExperimentalGate {
    public static let flagName = "TORRENTINO_METAL_EXPERIMENTAL"

    public static var isMetalExperimentsEnabled: Bool {
        getenv(flagName).flatMap { String(cString: $0) } == "1"
    }
}
