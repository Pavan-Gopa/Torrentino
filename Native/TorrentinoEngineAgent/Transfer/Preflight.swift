// Layer: EngineAgent (Transfer).
// Role: WP-07 preflight gate — the checks that run BEFORE anything is
// persisted or handed to the engine. MetainfoParser already enforces the
// structural + path rules; this file adds the cross-cutting policy checks
// (source size, total size > 0) and produces human-readable warnings.
// Must-not: perform I/O, persist, or mutate engine state.
// Invariants: every rejection here is a typed PreflightError; warnings are
// advisory only (add still proceeds).

import Foundation
import TorrentinoIPC

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

/// Result of checking the destination before handing it to libtorrent. The
/// probe never creates a directory: a missing external mount must remain an
/// honest unavailable state rather than turning `/Volumes/OldName` into an
/// ordinary folder.
public enum StorageAvailabilityState: Sendable, Equatable {
    case available(volumeIdentifier: String?, availableBytes: Int64?)
    case volumeUnavailable(volumeIdentifier: String?)
    case unknown(volumeIdentifier: String?)
    case permissionDenied(volumeIdentifier: String?)
    case insufficientSpace(volumeIdentifier: String?, availableBytes: Int64)
}

public enum StorageLocationProbe {
    /// A one-byte reserve catches a genuinely full filesystem while allowing
    /// tiny test fixtures and normal users to use their available space. A
    /// product-level reserve can be added to settings without changing the
    /// fault classification contract.
    public static let minimumFreeSpaceReserveBytes: Int64 = 1

    public static func assess(
        location: PersistedLocation,
        requiredBytes: Int64 = 0,
        minimumFreeSpaceReserveBytes: Int64 = Self.minimumFreeSpaceReserveBytes,
        fileManager: FileManager = .default,
        volumeIdentifierProvider: ((URL) -> String?)? = nil
    ) -> StorageAvailabilityState {
        let expanded = (location.path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            return .volumeUnavailable(volumeIdentifier: location.volumeIdentifier)
        }

        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard fileManager.fileExists(atPath: url.path) else {
            // Do not call createDirectory here. In particular, a detached
            // `/Volumes/<name>` path must not be recreated as a local folder.
            return .volumeUnavailable(volumeIdentifier: location.volumeIdentifier)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .permissionDenied(volumeIdentifier: location.volumeIdentifier)
        }
        if let expected = location.volumeIdentifier, !expected.isEmpty {
            let actual: String?
            if let volumeIdentifierProvider {
                actual = volumeIdentifierProvider(url)
            } else {
                actual = Self.mountedVolumeIdentifier(for: url)
            }
            guard actual == expected else {
                return .volumeUnavailable(volumeIdentifier: expected)
            }
        }
        guard fileManager.isWritableFile(atPath: url.path) else {
            return .permissionDenied(volumeIdentifier: location.volumeIdentifier)
        }

        let available = (try? fileManager.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value
        guard let available else {
            // Unknown free space is not proof of availability. Refusing to
            // start is safer than accepting a full or detached volume.
            return .unknown(volumeIdentifier: location.volumeIdentifier)
        }
        if available < max(0, requiredBytes) + max(0, minimumFreeSpaceReserveBytes) {
            return .insufficientSpace(
                volumeIdentifier: location.volumeIdentifier,
                availableBytes: available
            )
        }
        return .available(volumeIdentifier: location.volumeIdentifier, availableBytes: available)
    }

    /// Pure classification entry point used by the fault matrix tests.
    public static func classify(
        exists: Bool,
        isDirectory: Bool,
        writable: Bool,
        availableBytes: Int64?,
        requiredBytes: Int64 = 0,
        minimumFreeSpaceReserveBytes: Int64 = Self.minimumFreeSpaceReserveBytes,
        volumeIdentifier: String? = nil
    ) -> StorageAvailabilityState {
        guard exists, isDirectory else { return .volumeUnavailable(volumeIdentifier: volumeIdentifier) }
        guard writable else { return .permissionDenied(volumeIdentifier: volumeIdentifier) }
        guard let availableBytes else { return .unknown(volumeIdentifier: volumeIdentifier) }
        if availableBytes < max(0, requiredBytes) + max(0, minimumFreeSpaceReserveBytes) {
            return .insufficientSpace(volumeIdentifier: volumeIdentifier, availableBytes: availableBytes)
        }
        return .available(volumeIdentifier: volumeIdentifier, availableBytes: availableBytes)
    }

    private static func mountedVolumeIdentifier(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]) else { return nil }
        return values.volumeUUIDString
    }
}
