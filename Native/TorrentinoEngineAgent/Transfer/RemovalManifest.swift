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

        // Validate the torrent name: must be a single relative component staying inside saveLocation.
        let validatedName = try validateName(metainfo.name, under: saveURL)
        let isSingle = metainfo.isSingleFile
        let payloadRoot = isSingle ? saveURL : RemovalManifest.join(saveURL, validatedName)

        var fileEntries: [RemovalManifestItem] = []
        var directories: [String] = []
        var seenDirectories = Set<String>()
        for file in metainfo.files {
            guard file.sizeBytes >= 0 else { continue }
            let relativePath = isSingle ? file.path : "\(validatedName)/\(file.path)"
            let absolute = RemovalManifest.join(saveURL, relativePath)
            guard isContained(absolute, under: saveURL) else {
                throw RemovalManifestError.pathOutsideSaveLocation(file.path)
            }
            if !isSingle {
                guard isContained(absolute, under: payloadRoot) else {
                    throw RemovalManifestError.pathOutsideSaveLocation(file.path)
                }
            }
            let shared = otherPayloadFiles.contains(absolute)
            fileEntries.append(RemovalManifestItem(
                relativePath: relativePath,
                sizeBytes: file.sizeBytes,
                kind: .file,
                isShared: shared,
                fileIdentity: FileSafetyValidator.captureIdentity(
                    absolutePath: absolute
                )
            ))
            var parent = (relativePath as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." && parent != "/" {
                if seenDirectories.insert(parent).inserted {
                    directories.append(parent)
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }

        if !isSingle {
            // Ensure the name directory itself is in the manifest so it can be
            // trashed when empty after its files.
            if seenDirectories.insert(validatedName).inserted {
                directories.append(validatedName)
            }
        }

        // Directory entries: shared when another torrent owns a file inside or shares the root.
        var directoryEntries: [RemovalManifestItem] = []
        for directory in directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            let absolute = RemovalManifest.join(saveURL, directory)
            let shared = otherPayloadFiles.contains { other in
                isContained(other, under: absolute)
            } || otherPayloadRoots.contains { otherRoot in
                isContained(otherRoot, under: absolute)
            }
            directoryEntries.append(RemovalManifestItem(
                relativePath: directory,
                sizeBytes: 0,
                kind: .directory,
                isShared: shared
            ))
        }

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
        guard let validatedName = try? validateName(metainfo.name, under: saveURL) else {
            return []
        }
        let isSingle = metainfo.isSingleFile
        return Set(metainfo.files.map { file in
            let relative = isSingle ? file.path : "\(validatedName)/\(file.path)"
            return RemovalManifest.join(saveURL, relative)
        })
    }

    /// The payload root of a record: for single-file it is saveLocation; for
    /// multi-file it is saveLocation/metainfo.name. Returns nil when metainfo is
    /// unavailable or name is invalid.
    static func payloadRoot(of record: TransferRecord) -> String? {
        guard let metainfoData = record.metainfoData,
              let metainfo = try? Preflight.validateTorrentData(metainfoData) else {
            return nil
        }
        let saveLocation = (record.saveLocation.path as NSString).expandingTildeInPath
        let saveURL = URL(fileURLWithPath: saveLocation).standardizedFileURL.path
        guard let validatedName = try? validateName(metainfo.name, under: saveURL) else {
            return nil
        }
        if metainfo.isSingleFile {
            return saveURL
        } else {
            return RemovalManifest.join(saveURL, validatedName)
        }
    }

    private static func validateName(_ name: String, under saveURL: String) throws -> String {
        if PathValidator.validationError(name) != nil {
            throw RemovalManifestError.pathOutsideSaveLocation(name)
        }
        let normalized = PathValidator.normalizedPath(name)
        guard !normalized.isEmpty, !normalized.contains("/") else {
            throw RemovalManifestError.pathOutsideSaveLocation(name)
        }
        let absolute = RemovalManifest.join(saveURL, normalized)
        guard isContained(absolute, under: saveURL), absolute != saveURL else {
            throw RemovalManifestError.pathOutsideSaveLocation(name)
        }
        return normalized
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
        case permissionDenied(String)
        case unavailableRoot(String)
    }

    /// Verifies the full component chain of `absolutePath` under `root`
    /// INCLUDING the root leaf itself (a symlinked or missing root redirects
    /// every child mutation). Returns nil when the chain is safe (no symlinks)
    /// and the leaf exists.
    static func verifyChain(root: String, absolutePath: String) -> Issue? {
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        guard normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/") else {
            return .symlink(normalizedPath) // outside root: treat as unsafe
        }
        // Root-leaf check (Gate 7): the save location itself must be a real
        // directory. Ancestors ABOVE the root are ambient filesystem structure
        // (e.g. /var → /private/var), not attacker-controlled save locations.
        var rootStat = Darwin.stat()
        if normalizedRoot.withCString({ Darwin.lstat($0, &rootStat) }) != 0 {
            let err = Darwin.errno
            if err == EACCES || err == EPERM {
                return .permissionDenied(normalizedRoot)
            }
            return .unavailableRoot(normalizedRoot)
        }
        let rootMode = rootStat.st_mode
        if (rootMode & S_IFMT) == S_IFLNK {
            return .symlink(normalizedRoot)
        }
        guard (rootMode & S_IFMT) == S_IFDIR else {
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
            var stat = Darwin.stat()
            if cursor.withCString({ Darwin.lstat($0, &stat) }) != 0 {
                let err = Darwin.errno
                if err == EACCES || err == EPERM {
                    return .permissionDenied(cursor)
                }
                return .missing
            }
            if (stat.st_mode & S_IFMT) == S_IFLNK {
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
        expectedIdentity: FileIdentity? = nil,
        allowPartial: Bool = false
    ) -> Issue? {
        let fd = absolutePath.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            let err = Darwin.errno
            if err == ELOOP {
                return .symlink(absolutePath)
            }
            if err == EACCES || err == EPERM {
                return .permissionDenied(absolutePath)
            }
            return .missing
        }
        defer { Darwin.close(fd) }
        var stat = Darwin.stat()
        guard Darwin.fstat(fd, &stat) == 0 else {
            let err = Darwin.errno
            if err == EACCES || err == EPERM {
                return .permissionDenied(absolutePath)
            }
            return .missing
        }
        guard (stat.st_mode & S_IFMT) == S_IFREG else { return .wrongKind }
        if allowPartial {
            guard stat.st_size >= 0 && stat.st_size <= expectedSize else {
                return .sizeMismatch(expected: expectedSize, actual: Int64(stat.st_size))
            }
        } else {
            guard stat.st_size == expectedSize else {
                return .sizeMismatch(expected: expectedSize, actual: Int64(stat.st_size))
            }
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
        } else {
            // Newly created between prepare and commit: must not be hardlinked elsewhere.
            guard stat.st_nlink == 1 else {
                return .identityChanged(absolutePath)
            }
        }
        return nil
    }

    /// Verifies the leaf is a real directory (lstat: not a symlink).
    static func verifyDirectoryIdentity(absolutePath: String) -> Issue? {
        var stat = Darwin.stat()
        if absolutePath.withCString({ Darwin.lstat($0, &stat) }) != 0 {
            let err = Darwin.errno
            if err == EACCES || err == EPERM {
                return .permissionDenied(absolutePath)
            }
            return .missing
        }
        if (stat.st_mode & S_IFMT) == S_IFLNK { return .symlink(absolutePath) }
        guard (stat.st_mode & S_IFMT) == S_IFDIR else { return .wrongKind }
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
            let err = Darwin.errno
            if err == ELOOP {
                return .symlink(absolutePath)
            }
            if err == EACCES || err == EPERM {
                return .permissionDenied(absolutePath)
            }
            return .missing
        }
        // fdopendir takes ownership of fd; closedir releases it.
        guard let dirStream = Darwin.fdopendir(fd) else {
            let err = Darwin.errno
            Darwin.close(fd)
            if err == EACCES || err == EPERM {
                return .permissionDenied(absolutePath)
            }
            return .missing
        }
        defer { Darwin.closedir(dirStream) }
        var stat = Darwin.stat()
        guard Darwin.fstat(fd, &stat) == 0 else {
            let err = Darwin.errno
            if err == EACCES || err == EPERM {
                return .permissionDenied(absolutePath)
            }
            return .missing
        }
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
