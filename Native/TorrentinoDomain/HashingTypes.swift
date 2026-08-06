// Layer: Domain
// Role: Hashing types for BitTorrent v1, v2, and hybrid torrent creation.
// Must-not: hold mutable reference state or non-Sendable C++ handles.
// Invariants: immutable Sendable values; hashes represented as raw Data.

import Foundation
#if canImport(TorrentinoIPC)
import TorrentinoIPC
#else
// Standalone WP-04 bridge builds compile Domain sources without the Xcode IPC
// module. These value-only shims keep the CPU/domain boundary identical while
// leaving the production target dependent on the real TorrentinoIPC DTOs.
public struct CreatorPlanToken: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct IdempotencyKey: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String { rawValue.uuidString }
}

public enum EngineErrorCode: String, Codable, Sendable, Equatable {
    case invalidPayload
    case storageFailure
    case storeError
    case corruptData
    case volumeUnavailable
    case operationCancelled
    case idempotencyConflict
    case internalError
}

public struct EngineFault: Error, Codable, Sendable, Equatable, LocalizedError {
    public let code: EngineErrorCode
    public let localizationKey: String
    public let recoveryActions: [String]
    public let affectedVolume: String?
    public let redactedContext: String?

    public init(
        code: EngineErrorCode,
        details: String? = nil,
        localizationKey: String? = nil,
        recoveryActions: [String] = [],
        affectedVolume: String? = nil
    ) {
        self.code = code
        self.localizationKey = localizationKey ?? "fault.\(code.rawValue)"
        self.recoveryActions = recoveryActions
        self.affectedVolume = affectedVolume
        self.redactedContext = details
    }

    // Fallback faults are compile-time mirrors only; diagnostics never become
    // user-facing text when the Domain module is built without IPC.
    public var errorDescription: String? { localizationKey }

    public static func invalidPayload(details: String) -> EngineFault {
        EngineFault(code: .invalidPayload, details: details)
    }

    public static func storageFailure(details: String) -> EngineFault {
        EngineFault(code: .storageFailure, details: details)
    }

    public static func corruptData(details: String) -> EngineFault {
        EngineFault(code: .corruptData, details: details)
    }

    public static func volumeUnavailable(details: String) -> EngineFault {
        EngineFault(code: .volumeUnavailable, details: details)
    }

    public static func operationCancelled(details: String) -> EngineFault {
        EngineFault(code: .operationCancelled, details: details)
    }

    public static func internalError(details: String) -> EngineFault {
        EngineFault(code: .internalError, details: details)
    }

    public static func creatorPrivateTrackerMissing() -> EngineFault {
        EngineFault(
            code: .invalidPayload,
            details: "private torrent has no validated tracker",
            localizationKey: "creator.fault.private_tracker_missing",
            recoveryActions: ["add_tracker", "reinspect_source"]
        )
    }

    public static func creatorStalePlan(details: String = "creator plan is stale") -> EngineFault {
        EngineFault(
            code: .invalidPayload,
            details: details,
            localizationKey: "creator.fault.stale_plan",
            recoveryActions: ["reinspect_source"]
        )
    }

    public static func creatorAssertionMissing(
        details: String = "creator options assertion is missing"
    ) -> EngineFault {
        EngineFault(
            code: .invalidPayload,
            details: details,
            localizationKey: "creator.fault.assertion_mismatch",
            recoveryActions: ["reinspect_source"]
        )
    }

    public static func creatorAssertionMismatch(
        details: String = "creator options differ from the inspected plan"
    ) -> EngineFault {
        EngineFault(
            code: .invalidPayload,
            details: details,
            localizationKey: "creator.fault.assertion_mismatch",
            recoveryActions: ["reinspect_source"]
        )
    }

    public static func creatorOperationConflict(details: String) -> EngineFault {
        EngineFault(
            code: .idempotencyConflict,
            details: details,
            localizationKey: "creator.fault.operation_conflict",
            recoveryActions: ["start_new_creation"]
        )
    }

    public static func creatorInvalidOptions(
        details: String = "creator options are invalid"
    ) -> EngineFault {
        EngineFault(
            code: .invalidPayload,
            details: details,
            localizationKey: "creator.fault.invalid_options",
            recoveryActions: ["review_options", "reinspect_source"]
        )
    }

    public static func creatorCancelled(
        details: String = "creator operation cancelled"
    ) -> EngineFault {
        EngineFault(
            code: .operationCancelled,
            details: details,
            localizationKey: "creator.fault.cancelled"
        )
    }

    public static func creatorStorageFailure(
        details: String,
        volumeIdentifier: String? = nil
    ) -> EngineFault {
        EngineFault(
            code: .storeError,
            details: details,
            localizationKey: "creator.fault.storage",
            recoveryActions: ["choose_storage", "retry_op"],
            affectedVolume: volumeIdentifier
        )
    }

    public static func creatorUnavailable(details: String) -> EngineFault {
        EngineFault(
            code: .internalError,
            details: details,
            localizationKey: "creator.fault.unavailable",
            recoveryActions: ["retry_op", "restart_engine_safely"]
        )
    }
}

public struct ContentIdentity: Codable, Hashable, Sendable, CustomStringConvertible {
    public let infoHashV1: Data?
    public let infoHashV2: Data?

    public init(infoHashV1: Data?, infoHashV2: Data?) {
        self.infoHashV1 = infoHashV1
        self.infoHashV2 = infoHashV2
    }

    public var description: String { "content identity" }
}

public enum TorrentFormat: String, Codable, Sendable, Equatable, CaseIterable {
    case hybrid
    case v1
    case v2
}

public struct CreateOptions: Codable, Sendable, Equatable {
    public let outputPath: String?
    public let format: TorrentFormat
    public let trackers: [[String]]
    public let isPrivate: Bool
    public let pieceSizeKiB: Int64?
    public let comment: String?
    public let source: String?
    public let seedWhileDownloading: Bool
    public let includeHiddenFiles: Bool

    public init(
        outputPath: String? = nil,
        format: TorrentFormat = .hybrid,
        trackers: [[String]] = [],
        isPrivate: Bool = false,
        pieceSizeKiB: Int64? = nil,
        comment: String? = nil,
        source: String? = nil,
        seedWhileDownloading: Bool = true,
        includeHiddenFiles: Bool = true
    ) {
        self.outputPath = outputPath
        self.format = format
        self.trackers = trackers
        self.isPrivate = isPrivate
        self.pieceSizeKiB = pieceSizeKiB
        self.comment = comment
        self.source = source
        self.seedWhileDownloading = seedWhileDownloading
        self.includeHiddenFiles = includeHiddenFiles
    }

    public var canonicalSnapshot: CreateOptions {
        CreateOptions(
            outputPath: outputPath.flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            },
            format: format,
            trackers: trackers,
            isPrivate: isPrivate,
            pieceSizeKiB: pieceSizeKiB,
            comment: canonicalText(comment),
            source: canonicalText(source),
            seedWhileDownloading: seedWhileDownloading,
            includeHiddenFiles: includeHiddenFiles
        )
    }

    private func canonicalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum FileKind: String, Codable, Sendable, Equatable, CaseIterable {
    case file
    case directory
}

public struct PageCursor: Codable, Sendable, Equatable, Hashable {
    public let token: Data

    public init(token: Data) {
        self.token = token
    }
}

public struct Page<T: Codable & Sendable>: Codable, Sendable, Equatable where T: Equatable {
    public let items: [T]
    public let nextCursor: PageCursor?
    public let totalCount: Int
    public let revision: UInt64

    public init(items: [T], nextCursor: PageCursor?, totalCount: Int, revision: UInt64) {
        self.items = items
        self.nextCursor = nextCursor
        self.totalCount = totalCount
        self.revision = revision
    }
}

public struct CreatorManifestEntry: Codable, Sendable, Equatable {
    public let relativePath: String
    public let sizeBytes: Int64
    public let kind: FileKind

    public init(relativePath: String, sizeBytes: Int64, kind: FileKind) {
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.kind = kind
    }
}

public struct OperationProgressDetail: Codable, Sendable, Equatable {
    public let stage: String?
    public let backend: String?
    public let processedBytes: Int64?
    public let totalBytes: Int64?
    public let fileCount: Int?
    public let totalFileCount: Int?
    public let etaSeconds: Int64?
    public let isCancelled: Bool

    public init(
        stage: String? = nil,
        backend: String? = nil,
        processedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        fileCount: Int? = nil,
        totalFileCount: Int? = nil,
        etaSeconds: Int64? = nil,
        isCancelled: Bool = false
    ) {
        self.stage = stage
        self.backend = backend
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.totalFileCount = totalFileCount
        self.etaSeconds = etaSeconds
        self.isCancelled = isCancelled
    }
}

public struct CreateSummary: Codable, Sendable, Equatable {
    public let fileCount: Int
    public let totalBytes: Int64
    public let pieceSizeBytes: Int64
    public let willSeed: Bool
    public let skippedSymlinksCount: Int
    public let hardlinkCount: Int

    public init(fileCount: Int, totalBytes: Int64, pieceSizeBytes: Int64, willSeed: Bool, skippedSymlinksCount: Int = 0, hardlinkCount: Int = 0) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.pieceSizeBytes = pieceSizeBytes
        self.willSeed = willSeed
        self.skippedSymlinksCount = skippedSymlinksCount
        self.hardlinkCount = hardlinkCount
    }
}

public struct CreateSourceInspection: Codable, Sendable, Equatable {
    public let token: CreatorPlanToken
    public let summary: CreateSummary
    public let warnings: [String]
    public let sourceIdentity: ContentIdentity?
    public let exclusions: [String]

    public init(token: CreatorPlanToken, summary: CreateSummary, warnings: [String], sourceIdentity: ContentIdentity?, exclusions: [String]) {
        self.token = token
        self.summary = summary
        self.warnings = warnings
        self.sourceIdentity = sourceIdentity
        self.exclusions = exclusions
    }
}
#endif

public struct MerkleNode: Sendable, Equatable {
    public let hash: Data // 32 bytes SHA-256

    public init(hash: Data) {
        self.hash = hash
    }
}

public struct V2FileTreeEntry: Sendable, Equatable {
    public let piecesRoot: Data // 32 bytes SHA-256 Merkle root
    public let pieceLayers: Data // Concatenated 32-byte SHA-256 hashes of piece_length layers
    public let sizeBytes: Int64

    public init(piecesRoot: Data, pieceLayers: Data, sizeBytes: Int64) {
        self.piecesRoot = piecesRoot
        self.pieceLayers = pieceLayers
        self.sizeBytes = sizeBytes
    }
}

public struct HashingResult: Sendable, Equatable {
    /// Concatenated 20-byte SHA-1 piece hashes for v1
    public let v1PiecesData: Data
    /// v2 file tree entries keyed by relative path
    public let v2FileTrees: [String: V2FileTreeEntry]
    public let totalBytesHashed: Int64
    public let totalFilesHashed: Int

    public init(
        v1PiecesData: Data,
        v2FileTrees: [String: V2FileTreeEntry] = [:],
        totalBytesHashed: Int64,
        totalFilesHashed: Int
    ) {
        self.v1PiecesData = v1PiecesData
        self.v2FileTrees = v2FileTrees
        self.totalBytesHashed = totalBytesHashed
        self.totalFilesHashed = totalFilesHashed
    }
}

/// Expected identities derived from the exact raw bencoded `info` value. This
/// is intentionally separate from `HashingResult`: piece hashing cannot claim
/// an info hash before metadata exists.
public struct MetainfoIdentityExpectation: Sendable, Equatable {
    public let v1: Data?
    public let v2: Data?
    public let infoBytes: Data

    public init(v1: Data?, v2: Data?, infoBytes: Data) {
        self.v1 = v1
        self.v2 = v2
        self.infoBytes = infoBytes
    }
}

/// Identities returned by the independent pinned libtorrent verifier. The
/// bridge returns values only; no native handle or pointer crosses this type.
public struct IndependentMetainfoIdentity: Sendable, Equatable {
    public let v1: Data?
    public let v2: Data?

    public init(v1: Data?, v2: Data?) {
        self.v1 = v1
        self.v2 = v2
    }
}

public enum MetainfoIdentity {
    /// Hashes the exact byte span of the top-level `info` value. The requested
    /// format controls which identities must be present; no Swift metainfo
    /// model is used to reconstruct or re-encode the bytes.
    public static func expected(
        from torrentBytes: Data,
        format: TorrentFormat
    ) throws -> MetainfoIdentityExpectation {
        let root = try BencodeParser.parse(torrentBytes)
        guard case .dictionary(let top, _) = root,
              let info = top.value(for: "info"),
              case .dictionary(_, let infoSpan) = info,
              infoSpan.lowerBound >= 0,
              infoSpan.upperBound <= torrentBytes.count else {
            throw MetainfoError.missingInfo
        }

        let infoBytes = torrentBytes.subdata(in: infoSpan)
        let expectsV1 = format == .v1 || format == .hybrid
        let expectsV2 = format == .v2 || format == .hybrid
        return MetainfoIdentityExpectation(
            v1: expectsV1 ? Data(SHA1.digest(infoBytes)) : nil,
            v2: expectsV2 ? Data(SHA256.digest(infoBytes)) : nil,
            infoBytes: infoBytes
        )
    }
}

public enum HasherError: Error, Sendable, Equatable, CustomStringConvertible {
    case fileNotFound(String)
    case unreadableFile(String)
    case sourceModified(String)
    case cancelled
    case hashingFailed(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path): return "file not found during hashing: \(path)"
        case .unreadableFile(let path): return "file unreadable during hashing: \(path)"
        case .sourceModified(let path): return "source file modified during hashing: \(path)"
        case .cancelled: return "hashing operation cancelled"
        case .hashingFailed(let msg): return "hashing failed: \(msg)"
        }
    }
}

/// BEP-52 piece-alignment layout for hybrid torrents: the v1 piece stream of
/// a multi-file hybrid torrent interleaves zero padding after every file
/// (except the last) so that each file starts on a piece boundary and the v2
/// per-file piece grids align with the v1 stream. Padding files are BEP-47
/// entries that exist only in the v1 address space.
public enum CreatorLayout {
    public static let v2BlockSize: Int64 = 16 * 1024

    /// Zero padding bytes to emit AFTER each file (index-aligned with
    /// `files`; last entry is always 0). Only multi-file hybrid torrents pad.
    public static func v1PaddingBytes(
        files: [ScannedFileEntry],
        pieceSizeBytes: Int64,
        format: TorrentFormat
    ) -> [Int64] {
        let isHybridMultiFile = format == .hybrid && files.count > 1
        guard isHybridMultiFile, pieceSizeBytes > 0 else {
            return Array(repeating: 0, count: files.count)
        }
        var padding: [Int64] = []
        for (index, file) in files.enumerated() {
            guard index < files.count - 1 else {
                padding.append(0)
                continue
            }
            let remainder = file.sizeBytes % pieceSizeBytes
            padding.append(remainder == 0 ? 0 : pieceSizeBytes - remainder)
        }
        return padding
    }

    /// Full size of the v1 address space (real bytes + interleaved padding).
    public static func v1AddressSpaceBytes(files: [ScannedFileEntry], padding: [Int64]) -> Int64 {
        var total: Int64 = 0
        for (index, file) in files.enumerated() {
            let (bytes, overflow) = total.addingReportingOverflow(file.sizeBytes)
            guard !overflow else { return Int64.max }
            total = bytes
            let pad = index < padding.count ? padding[index] : 0
            let (padded, padOverflow) = total.addingReportingOverflow(pad)
            guard !padOverflow else { return Int64.max }
            total = padded
        }
        return total
    }
}
