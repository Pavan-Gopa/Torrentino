// Layer: EngineAgent (Transfer).
// Role: WP-07 preflight gate — the checks that run BEFORE anything is
// persisted or handed to the engine. MetainfoParser already enforces the
// structural + path rules; this file adds the cross-cutting policy checks
// (source size, total size > 0) and produces human-readable warnings.
// Must-not: perform I/O, persist, or mutate engine state.
// Invariants: every rejection here is a typed PreflightError; warnings are
// advisory only (add still proceeds).

import Foundation

public enum PreflightError: Error, Sendable, Equatable, CustomStringConvertible {
    case torrentFileTooLarge(Int)
    case zeroTotalSize
    case emptySource

    public var description: String {
        switch self {
        case .torrentFileTooLarge(let n): return "torrent file too large (\(n) bytes > \(TransferLimits.maxTorrentFileBytes))"
        case .zeroTotalSize: return "torrent payload size is zero"
        case .emptySource: return "empty source"
        }
    }
}

public enum Preflight {
    /// Source size gate: no .torrent payload may exceed 10 MiB.
    public static func validateTorrentFileSize(_ data: Data) throws {
        guard data.count <= TransferLimits.maxTorrentFileBytes else {
            throw PreflightError.torrentFileTooLarge(data.count)
        }
    }

    /// Post-parse policy gate (WP-07 "size > 0").
    public static func validatePolicy(_ metainfo: Metainfo) throws {
        guard metainfo.totalSize > 0 else { throw PreflightError.zeroTotalSize }
    }

    /// Full pipeline for a local .torrent file: size → parse → policy.
    public static func validateTorrentData(_ data: Data) throws -> Metainfo {
        try validateTorrentFileSize(data)
        let metainfo = try MetainfoParser.parse(data)
        try validatePolicy(metainfo)
        return metainfo
    }

    /// Advisory warnings, never blocking. Callers may display them.
    public static func warnings(for metainfo: Metainfo) -> [String] {
        var warnings: [String] = []
        if metainfo.trackers.isEmpty {
            warnings.append("no_trackers")
        }
        if metainfo.isPrivate && metainfo.trackers.isEmpty {
            warnings.append("private_no_trackers")
        }
        if metainfo.files.count > 1000 {
            warnings.append("many_files")
        }
        if metainfo.name.count > 255 {
            warnings.append("long_name")
        }
        return warnings
    }
}
