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
import TorrentinoDomain

/// One trimmable row of the removal manifest (WP-10 exact manifest/token).
struct RemovalManifestItem: Codable, Sendable, Equatable {
    let relativePath: String
    let sizeBytes: Int64
    let kind: FileKind
    /// True when another torrent's payload also covers this path (or a
    /// descendant): such items are skipped, never trashed.
    let isShared: Bool
    /// Filesystem identity captured at prepare time (WP-10 Gate 7). When
    /// present, the trash path re-verifies dev/inode/link-count before the
    /// mutation so a same-size replacement or a hardlink swap is refused.
    /// nil when the file did not exist yet at prepare (e.g. still downloading):
    /// those entries fall back to size + chain verification.
    let fileIdentity: FileIdentity?

    init(
        relativePath: String,
        sizeBytes: Int64,
        kind: FileKind,
        isShared: Bool,
        fileIdentity: FileIdentity? = nil
    ) {
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.kind = kind
        self.isShared = isShared
        self.fileIdentity = fileIdentity
    }
}

/// Stable filesystem identity of a regular file (dev/inode/link-count), used to
/// refuse replacements between prepare and commit (WP-10 Gate 7).
struct FileIdentity: Codable, Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let linkCount: UInt64
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
                isShared: shared,
                fileIdentity: FileSafetyValidator.captureIdentity(
                    absolutePath: RemovalManifest.join(saveURL, file.path)
                )
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
/// payload mutation (WP-10). lstat-based for the component chain: every
/// component from the save location down to the item must be a real
/// directory/file — a symlink at any level (including the leaf) is refused,
/// so a swapped directory can never redirect a Trash move outside the
/// manifest. The LEAF identity (file/dir) is decided with open(O_NOFOLLOW) +
/// fstat on the SAME descriptor as the emptiness scan, which is the tightest
/// TOCTOU the platform Trash primitive (FileManager.trashItem, path-based)
/// allows on macOS: after verification, only the provider call remains.
enum FileSafetyValidator {
    enum Issue: Sendable, Equatable {
        case symlink(String)
        case missing
        case wrongKind
        case sizeMismatch(expected: Int64, actual: Int64)
        case identityChanged(String)
        case notEmpty(String)
    }

    /// Verifies the full component chain of `absolutePath` under `root`
    /// INCLUDING the root leaf itself (a symlinked or missing root redirects
    /// every child mutation). Returns nil when the chain is safe (no symlinks)
    /// and the leaf exists.
    static func verifyChain(root: String, absolutePath: String) -> Issue? {
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        guard normalizedPath.hasPrefix(normalizedRoot + "/") else {
            return .symlink(normalizedPath) // outside root: treat as unsafe
        }
        // Root-leaf check (Gate 7): the save location itself must be a real
        // directory. Ancestors ABOVE the root are ambient filesystem structure
        // (e.g. /var → /private/var), not attacker-controlled save locations.
        guard let rootResult = lstat(normalizedRoot) else {
            return .missing
        }
        guard !rootResult.isSymlink else {
            return .symlink(normalizedRoot)
        }
        guard rootResult.isDirectory else {
            return .wrongKind
        }
        var components: [String] = []
        var relative = String(normalizedPath.dropFirst(normalizedRoot.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        for component in relative.split(separator: "/") {
            components.append(String(component))
        }
        var cursor = normalizedRoot
        for component in components {
            cursor = (cursor as NSString).appendingPathComponent(component)
            guard let lstatResult = lstat(cursor) else {
                return .missing
            }
            if lstatResult.isSymlink {
                return .symlink(cursor)
            }
        }
        return nil
    }

    /// Verifies the leaf is a regular file of exactly `expectedSize` bytes and,
    /// when an identity was captured at prepare time, the SAME dev/inode/link
    /// count (a same-size replacement or hardlink swap is refused). The leaf is
    /// opened with O_NOFOLLOW so a symlink swapped in after the chain check is
    /// still refused, and identity is read from the opened descriptor (fstat).
    static func verifyFileIdentity(
        absolutePath: String,
        expectedSize: Int64,
        expectedIdentity: FileIdentity? = nil
    ) -> Issue? {
        let fd = absolutePath.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            return Darwin.errno == ELOOP ? .symlink(absolutePath) : .missing
        }
        defer { Darwin.close(fd) }
        var stat = Darwin.stat()
        guard Darwin.fstat(fd, &stat) == 0 else { return .missing }
        guard (stat.st_mode & S_IFMT) == S_IFREG else { return .wrongKind }
        guard stat.st_size == expectedSize else {
            return .sizeMismatch(expected: expectedSize, actual: Int64(stat.st_size))
        }
        if let expectedIdentity {
            let actual = FileIdentity(
                device: UInt64(stat.st_dev),
                inode: UInt64(stat.st_ino),
                linkCount: UInt64(stat.st_nlink)
            )
            guard actual == expectedIdentity else {
                return .identityChanged(absolutePath)
            }
        }
        return nil
    }

    /// Verifies the leaf is a real directory (lstat: not a symlink).
    static func verifyDirectoryIdentity(absolutePath: String) -> Issue? {
        guard let lstatResult = lstat(absolutePath) else { return .missing }
        guard !lstatResult.isSymlink else { return .symlink(absolutePath) }
        guard lstatResult.isDirectory else { return .wrongKind }
        return nil
    }

    /// Verifies the directory at `absolutePath` is EMPTY (Gate 1: a directory
    /// is only ever trashed after its manifest children were handled, and only
    /// when nothing unmanifested remains inside). Identity and emptiness are
    /// decided on ONE descriptor: open(O_NOFOLLOW) + fstat + fdopendir/readdir,
    /// so a swap between the checks cannot widen the scope of the trash.
    static func verifyDirectoryEmpty(absolutePath: String) -> Issue? {
        let fd = absolutePath.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            return Darwin.errno == ELOOP ? .symlink(absolutePath) : .missing
        }
        // fdopendir takes ownership of fd; closedir releases it.
        guard let dirStream = Darwin.fdopendir(fd) else {
            Darwin.close(fd)
            return .missing
        }
        defer { Darwin.closedir(dirStream) }
        var stat = Darwin.stat()
        guard Darwin.fstat(fd, &stat) == 0 else { return .missing }
        guard (stat.st_mode & S_IFMT) == S_IFDIR else { return .wrongKind }
        while let entry = Darwin.readdir(dirStream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String in
                let base = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: base)
            }
            if name == "." || name == ".." { continue }
            return .notEmpty(absolutePath)
        }
        return nil
    }

    /// Captures the filesystem identity of a regular file for the manifest
    /// (nil when the file does not exist yet — e.g. still downloading — or is
    /// not a regular file).
    static func captureIdentity(absolutePath: String) -> FileIdentity? {
        guard let result = lstat(absolutePath),
              !result.isSymlink,
              result.isFile else {
            return nil
        }
        return result.identity
    }
}

// MARK: - lstat wrapper (Darwin posix)

private struct LStatResult: Sendable {
    let isSymlink: Bool
    let isDirectory: Bool
    let isFile: Bool
    let sizeBytes: Int64
    let identity: FileIdentity
}

private func lstat(_ path: String) -> LStatResult? {
    var stat = Darwin.stat()
    guard path.withCString({ Darwin.lstat($0, &stat) }) == 0 else { return nil }
    let mode = stat.st_mode
    return LStatResult(
        isSymlink: (mode & S_IFMT) == S_IFLNK,
        isDirectory: (mode & S_IFMT) == S_IFDIR,
        isFile: (mode & S_IFMT) == S_IFREG,
        sizeBytes: Int64(stat.st_size),
        identity: FileIdentity(
            device: UInt64(stat.st_dev),
            inode: UInt64(stat.st_ino),
            linkCount: UInt64(stat.st_nlink)
        )
    )
}
