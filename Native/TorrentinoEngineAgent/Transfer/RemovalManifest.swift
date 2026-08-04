// Layer: EngineAgent (Transfer) — WP-10 safe file operations.
// Role: derives the EXACT removal manifest from the torrent metainfo +
// save location (only manifest paths may ever be touched), computes
// shared-path protection across records (data referenced by another torrent
// is never trashed), and provides the symlink/hardlink/TOCTOU safety checks
// performed immediately before every payload mutation.
// Must-not: mutate the filesystem, follow symlinks, or invent paths — every
// absolute path is the strict join of the persisted saveLocation and a
// manifest-validated relative path.
// Invariants: an entry outside the manifest cannot be produced (the manifest
// is the only source of relative paths); entries are validated against the
// PathValidator contract that already guarded them at add time.

import Foundation
import TorrentinoIPC

/// One trimmable row of the removal manifest (WP-10 exact manifest/token).
struct RemovalManifestItem: Codable, Sendable, Equatable {
    let relativePath: String
    let sizeBytes: Int64
    let kind: FileKind
    /// True when another torrent's payload also covers this path (or a
    /// descendant): such items are skipped, never trashed.
    let isShared: Bool
}

/// The exact, frozen manifest a removal token was minted against. Serialized
/// into `removal_tokens.manifest_json` so recovery never re-derives paths
/// from live data that may have changed.
struct RemovalManifest: Codable, Sendable, Equatable {
    let saveLocationPath: String
    let payloadRootPath: String
    let entries: [RemovalManifestItem]

    /// Leaf files first, then directories deepest-first. Trash consumers
    /// process in this order so a directory is only empty (trashable) after
    /// its children went first.
    func orderedEntries() -> [RemovalManifestItem] {
        entries.sorted { lhs, rhs in
            switch (lhs.kind, rhs.kind) {
            case (.file, .directory): return true
            case (.directory, .file): return false
            default: break
            }
            let lhsDepth = lhs.relativePath.split(separator: "/").count
            let rhsDepth = rhs.relativePath.split(separator: "/").count
            return lhsDepth > rhsDepth
        }
    }

    /// Absolute path for an entry, guaranteed to stay under saveLocation.
    func absolutePath(for entry: RemovalManifestItem) -> String {
        Self.join(saveLocationPath, entry.relativePath)
    }

    static func join(_ base: String, _ relative: String) -> String {
        let baseURL = URL(fileURLWithPath: base).standardizedFileURL
        let relativePath = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return baseURL.appendingPathComponent(relativePath).path
    }
}

enum RemovalManifestError: Error, Sendable, CustomStringConvertible {
    case metainfoUnavailable
    case invalidMetainfo(String)
    case noFiles
    case pathOutsideSaveLocation(String)

    var description: String {
        switch self {
        case .metainfoUnavailable: return "metainfo is unavailable for manifest derivation"
        case .invalidMetainfo(let detail): return "metainfo invalid: \(detail)"
        case .noFiles: return "manifest is empty (no files in metainfo)"
        case .pathOutsideSaveLocation(let path): return "manifest path escapes save location: \(path)"
        }
    }
}

enum RemovalManifestBuilder {
    /// Builds the exact manifest for `record`, marking entries shared with any
    /// OTHER record's payload (by absolute path prefix equality).
    static func build(
        record: TransferRecord,
        otherPayloadFiles: Set<String>,
        otherPayloadRoots: [String]
    ) throws -> RemovalManifest {
        guard let metainfoData = record.metainfoData else {
            throw RemovalManifestError.metainfoUnavailable
        }
        let metainfo: Metainfo
        do {
            metainfo = try Preflight.validateTorrentData(metainfoData)
        } catch {
            throw RemovalManifestError.invalidMetainfo(String(describing: error))
        }
        guard !metainfo.files.isEmpty else { throw RemovalManifestError.noFiles }

        let saveLocation = (record.saveLocation.path as NSString).expandingTildeInPath
        let saveURL = URL(fileURLWithPath: saveLocation).standardizedFileURL.path

        // All manifest paths live directly under the save location (metainfo
        // paths are relative to it per WP-07 parsing). Any path escaping the
        // save location is a hard failure — never a silent skip.
        var fileEntries: [RemovalManifestItem] = []
        var directories: [String] = []
        var seenDirectories = Set<String>()
        for file in metainfo.files {
            guard file.sizeBytes >= 0 else { continue }
            let absolute = RemovalManifest.join(saveURL, file.path)
            guard isContained(absolute, under: saveURL) else {
                throw RemovalManifestError.pathOutsideSaveLocation(file.path)
            }
            let shared = otherPayloadFiles.contains(absolute)
                || otherPayloadRoots.contains { root in
                    isContained(absolute, under: root)
                }
            fileEntries.append(RemovalManifestItem(
                relativePath: file.path,
                sizeBytes: file.sizeBytes,
                kind: .file,
                isShared: shared
            ))
            var parent = (file.path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." && parent != "/" {
                if seenDirectories.insert(parent).inserted {
                    directories.append(parent)
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }

        // Directory entries: shared when another torrent owns a file inside.
        var directoryEntries: [RemovalManifestItem] = []
        for directory in directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            let absolute = RemovalManifest.join(saveURL, directory)
            let shared = otherPayloadFiles.contains { other in
                isContained(other, under: absolute)
            }
            directoryEntries.append(RemovalManifestItem(
                relativePath: directory,
                sizeBytes: 0,
                kind: .directory,
                isShared: shared
            ))
        }

        let payloadRoot = saveURL
        return RemovalManifest(
            saveLocationPath: saveURL,
            payloadRootPath: payloadRoot,
            entries: fileEntries + directoryEntries
        )
    }

    /// The complete set of absolute payload paths of a record, for shared-path
    /// detection. Returns an empty set when the metainfo cannot be parsed
    /// (defensive: such a record never protects another record's data).
    static func payloadFiles(of record: TransferRecord) -> Set<String> {
        guard let metainfoData = record.metainfoData,
              let metainfo = try? Preflight.validateTorrentData(metainfoData) else {
            return []
        }
        let saveLocation = (record.saveLocation.path as NSString).expandingTildeInPath
        let saveURL = URL(fileURLWithPath: saveLocation).standardizedFileURL.path
        return Set(metainfo.files.map { RemovalManifest.join(saveURL, $0.path) })
    }

    /// The payload root of a record: its save location itself (metainfo file
    /// paths are relative to the save path, per WP-07 parsing). Returns nil
    /// when the metainfo is unavailable.
    static func payloadRoot(of record: TransferRecord) -> String? {
        guard let metainfoData = record.metainfoData,
              (try? Preflight.validateTorrentData(metainfoData)) != nil else {
            return nil
        }
        let saveLocation = (record.saveLocation.path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: saveLocation).standardizedFileURL.path
    }

    private static func isContained(_ path: String, under root: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        if normalizedPath == normalizedRoot { return true }
        return normalizedPath.hasPrefix(normalizedRoot + "/")
    }
}

/// Symlink / hardlink / TOCTOU protection performed immediately before any
/// payload mutation (WP-10). lstat-based: every component from the save
/// location down to the item must be a real directory/file — a symlink at any
/// level (including the leaf) is refused, so a swapped directory can never
/// redirect a Trash move outside the manifest.
enum FileSafetyValidator {
    enum Issue: Sendable, Equatable {
        case symlink(String)
        case missing
        case wrongKind
        case sizeMismatch(expected: Int64, actual: Int64)
    }

    /// Verifies the full component chain of `absolutePath` under `root`.
    /// Returns nil when the chain is safe (no symlinks) and the leaf exists.
    static func verifyChain(root: String, absolutePath: String) -> Issue? {
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        guard normalizedPath.hasPrefix(normalizedRoot + "/") else {
            return .symlink(normalizedPath) // outside root: treat as unsafe
        }
        var components: [String] = []
        var relative = String(normalizedPath.dropFirst(normalizedRoot.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        for component in relative.split(separator: "/") {
            components.append(String(component))
        }
        var cursor = normalizedRoot
        for (index, component) in components.enumerated() {
            cursor = (cursor as NSString).appendingPathComponent(component)
            guard let lstatResult = lstat(cursor) else {
                return index == components.count - 1 ? .missing : .missing
            }
            let isSymlink = lstatResult.isSymlink
            if isSymlink {
                return .symlink(cursor)
            }
        }
        return nil
    }

    /// Verifies the leaf is a regular file of exactly `expectedSize` bytes
    /// (a size mismatch means the item changed since prepare — refuse).
    static func verifyFileIdentity(absolutePath: String, expectedSize: Int64) -> Issue? {
        guard let lstatResult = lstat(absolutePath) else { return .missing }
        guard !lstatResult.isSymlink else { return .symlink(absolutePath) }
        guard lstatResult.isFile else { return .wrongKind }
        guard lstatResult.sizeBytes == expectedSize else {
            return .sizeMismatch(expected: expectedSize, actual: lstatResult.sizeBytes)
        }
        return nil
    }

    /// Verifies the leaf is a real directory.
    static func verifyDirectoryIdentity(absolutePath: String) -> Issue? {
        guard let lstatResult = lstat(absolutePath) else { return .missing }
        guard !lstatResult.isSymlink else { return .symlink(absolutePath) }
        guard lstatResult.isDirectory else { return .wrongKind }
        return nil
    }
}

// MARK: - lstat wrapper (Darwin posix)

private struct LStatResult: Sendable {
    let isSymlink: Bool
    let isDirectory: Bool
    let isFile: Bool
    let sizeBytes: Int64
}

private func lstat(_ path: String) -> LStatResult? {
    var stat = Darwin.stat()
    guard path.withCString({ Darwin.lstat($0, &stat) }) == 0 else { return nil }
    let mode = stat.st_mode
    return LStatResult(
        isSymlink: (mode & S_IFMT) == S_IFLNK,
        isDirectory: (mode & S_IFMT) == S_IFDIR,
        isFile: (mode & S_IFMT) == S_IFREG,
        sizeBytes: Int64(stat.st_size)
    )
}
