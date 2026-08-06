// Layer: Domain
// Role: File system source scanner for Torrent Creator (scan, exclusions, piece size, identity snapshot).
// Must-not: follow symlinks, mutate source files, or block main actor.
// Invariants: immutable scan results; default exclusions applied; file
// resource ID (device + inode), size, and high-resolution mtime captured;
// every relative path PathValidator-validated; unreadable subtrees fail the
// scan; file count bounded by TransferLimits.maxFiles. Root directory mtime is
// diagnostic only, never source-generation equality evidence.

import Foundation
import Darwin

public struct ScannedFileEntry: Sendable, Equatable {
    public let relativePath: String
    public let fullPath: String
    public let sizeBytes: Int64
    public let deviceID: UInt64
    public let fileResourceID: UInt64
    public let mtimeSeconds: Int64
    public let mtimeNanos: Int64

    public init(
        relativePath: String,
        fullPath: String,
        sizeBytes: Int64,
        deviceID: UInt64 = 0,
        fileResourceID: UInt64,
        mtimeSeconds: Int64,
        mtimeNanos: Int64
    ) {
        self.relativePath = relativePath
        self.fullPath = fullPath
        self.sizeBytes = sizeBytes
        self.deviceID = deviceID
        self.fileResourceID = fileResourceID
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanos = mtimeNanos
    }
}

public struct SourceScanResult: Sendable, Equatable {
    public let isDirectory: Bool
    public let rootName: String
    public let rootDeviceID: UInt64
    public let rootResourceID: UInt64
    public let rootMtimeSeconds: Int64
    public let rootMtimeNanos: Int64
    public let files: [ScannedFileEntry]
    public let totalSizeBytes: Int64
    public let pieceSizeBytes: Int64
    public let skippedSymlinksCount: Int
    public let skippedSpecialCount: Int
    public let hardlinkCount: Int
    public let exclusions: [String]
    public let warnings: [String]

    public init(
        isDirectory: Bool,
        rootName: String,
        rootDeviceID: UInt64 = 0,
        rootResourceID: UInt64 = 0,
        rootMtimeSeconds: Int64 = 0,
        rootMtimeNanos: Int64 = 0,
        files: [ScannedFileEntry],
        totalSizeBytes: Int64,
        pieceSizeBytes: Int64,
        skippedSymlinksCount: Int,
        skippedSpecialCount: Int,
        hardlinkCount: Int,
        exclusions: [String],
        warnings: [String]
    ) {
        self.isDirectory = isDirectory
        self.rootName = rootName
        self.rootDeviceID = rootDeviceID
        self.rootResourceID = rootResourceID
        self.rootMtimeSeconds = rootMtimeSeconds
        self.rootMtimeNanos = rootMtimeNanos
        self.files = files
        self.totalSizeBytes = totalSizeBytes
        self.pieceSizeBytes = pieceSizeBytes
        self.skippedSymlinksCount = skippedSymlinksCount
        self.skippedSpecialCount = skippedSpecialCount
        self.hardlinkCount = hardlinkCount
        self.exclusions = exclusions
        self.warnings = warnings
    }
}

public enum SourceScannerError: Error, Sendable, Equatable, CustomStringConvertible {
    case sourceNotFound(String)
    case sourceUnreadable(String)
    case unreadableSubtree(String)
    case emptySource
    case invalidPieceSize(Int64)
    case tooManyFiles(Int)
    case invalidPath(String)
    case pathCollision(String)

    public var description: String {
        switch self {
        case .sourceNotFound(let path): return "source path not found: \(path)"
        case .sourceUnreadable(let path): return "source unreadable: \(path)"
        case .unreadableSubtree(let path): return "unreadable directory in source tree: \(path)"
        case .emptySource: return "source contains no valid readable files"
        case .invalidPieceSize(let size): return "invalid piece size: \(size) bytes (must be power of 2 between 16 KiB and 16 MiB)"
        case .tooManyFiles(let count): return "source file count \(count) exceeds limit (\(TransferLimits.maxFiles))"
        case .invalidPath(let p): return "source file path invalid: \(p)"
        case .pathCollision(let p): return "source contains paths that collide after Unicode normalization: \(p)"
        }
    }
}

public enum SourceScanner {
    public static let defaultExclusions: Set<String> = [
        ".DS_Store",
        ".Spotlight-V100",
        ".Trashes"
    ]

    /// Canonical path spelling shared with CreatorPlanStore. This normalizes
    /// lexical components and the fixed macOS /tmp and /var aliases without
    /// resolving user-controlled symlinks; no-follow checks remain the safety
    /// boundary for every filesystem object.
    public static func canonicalAbsolutePath(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        let standardized = (absolute as NSString).standardizingPath
        if standardized == "/var" || standardized.hasPrefix("/var/") {
            return "/private\(standardized)"
        }
        if standardized == "/tmp" || standardized.hasPrefix("/tmp/") {
            return "/private\(standardized)"
        }
        return standardized
    }

    public static func scan(
        sourcePath: String,
        outputPath: String? = nil,
        includeHiddenFiles: Bool = true,
        manualPieceSizeKiB: Int64? = nil
    ) throws -> SourceScanResult {
        let fm = FileManager.default
        let canonicalSource = canonicalAbsolutePath(sourcePath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: canonicalSource, isDirectory: &isDir) else {
            throw SourceScannerError.sourceNotFound(sourcePath)
        }

        // CreatorPlanStore passes the already resolved output leaf here. The
        // same exact canonical path is excluded on inspect and every rescan.
        let canonicalOutput = outputPath.map(canonicalAbsolutePath)
        var rootStat = stat()
        guard lstat(canonicalSource, &rootStat) == 0 else {
            throw SourceScannerError.sourceUnreadable(canonicalSource)
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR || (rootStat.st_mode & S_IFMT) == S_IFREG else {
            throw SourceScannerError.sourceUnreadable(canonicalSource)
        }

        var scannedFiles: [ScannedFileEntry] = []
        var skippedSymlinks = 0
        var skippedSpecial = 0
        var recordedExclusions: Set<String> = []
        var warnings: [String] = []

        var seenInodes: [UInt64: String] = [:]
        var hardlinksFound = 0
        var totalBytes: Int64 = 0

        let rootName = (canonicalSource as NSString).lastPathComponent
        guard !rootName.isEmpty, PathValidator.validationError(rootName) == nil else {
            throw SourceScannerError.invalidPath(rootName)
        }

        if !isDir.boolValue {
            // Single file scan
            let fileURL = URL(fileURLWithPath: canonicalSource)
            let res = try inspectFile(
                fileURL: fileURL,
                relativePath: rootName,
                canonicalOutput: canonicalOutput,
                skippedSymlinks: &skippedSymlinks,
                skippedSpecial: &skippedSpecial
            )
            if let entry = res {
                scannedFiles.append(entry)
                let (newTotal, overflow) = totalBytes.addingReportingOverflow(entry.sizeBytes)
                guard !overflow else { throw SourceScannerError.sourceUnreadable("source size overflow") }
                totalBytes = newTotal
            }
        } else {
            // Directory scan using enumerator without resolving symlinks
            let rootURL = URL(fileURLWithPath: canonicalSource)
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
            
            guard fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsSubdirectoryDescendants],
                errorHandler: nil
            ) != nil else {
                throw SourceScannerError.sourceUnreadable(sourcePath)
            }

            // Manual recursive traversal to enforce non-symlink-following
            func traverseDirectory(dirURL: URL, currentRelativePrefix: String) throws {
                let contents: [URL]
                do {
                    contents = try fm.contentsOfDirectory(
                        at: dirURL,
                        includingPropertiesForKeys: keys,
                        options: []
                    )
                } catch {
                    // A source subtree we cannot read is a hard failure: a
                    // torrent that silently omits files would seed wrong data.
                    throw SourceScannerError.unreadableSubtree(dirURL.path)
                }

                for itemURL in contents {
                    let filename = itemURL.lastPathComponent
                    let canonicalItemPath = canonicalAbsolutePath(itemURL.path)

                    // Default exclusions
                    if defaultExclusions.contains(filename) || filename.hasPrefix("._") {
                        recordedExclusions.insert(filename)
                        continue
                    }

                    // Hidden files rule (opt-out default in WP-11: only the
                    // specific macOS junk above is excluded by default)
                    if !includeHiddenFiles && filename.hasPrefix(".") {
                        recordedExclusions.insert(filename)
                        continue
                    }

                    // Output file inside source tree exclusion
                    if let canonicalOutput, canonicalItemPath == canonicalOutput {
                        warnings.append("Excluded output file \(filename) from source input tree.")
                        continue
                    }

                    // Symlink & Special file checks
                    var statBuf = stat()
                    if lstat(canonicalItemPath, &statBuf) != 0 {
                        throw SourceScannerError.unreadableSubtree(canonicalItemPath)
                    }

                    let fileMode = statBuf.st_mode
                    if (fileMode & S_IFMT) == S_IFLNK {
                        skippedSymlinks += 1
                        continue
                    }

                    let relativePath = currentRelativePrefix.isEmpty ? filename : "\(currentRelativePrefix)/\(filename)"

                    if (fileMode & S_IFMT) == S_IFDIR {
                        try traverseDirectory(
                            dirURL: URL(fileURLWithPath: canonicalItemPath),
                            currentRelativePrefix: relativePath
                        )
                    } else if (fileMode & S_IFMT) == S_IFREG {
                        try registerFile(
                            relativePath: relativePath,
                            fullPath: canonicalItemPath,
                            statBuf: statBuf,
                            seenInodes: &seenInodes,
                            hardlinksFound: &hardlinksFound,
                            scannedFiles: &scannedFiles,
                            totalBytes: &totalBytes,
                            warnings: &warnings
                        )
                    } else {
                        skippedSpecial += 1
                    }
                }
            }

            try traverseDirectory(dirURL: rootURL, currentRelativePrefix: "")
        }

        guard !scannedFiles.isEmpty else {
            throw SourceScannerError.emptySource
        }

        // Sort files by relative path for deterministic metainfo ordering
        scannedFiles.sort {
            Data($0.relativePath.utf8).lexicographicallyPrecedes(Data($1.relativePath.utf8))
        }

        // Every relative path must pass the full path policy (length,
        // components, traversal, control chars) — a torrent must never be
        // built from a path the downloader would reject.
        for file in scannedFiles {
            if PathValidator.validationError(file.relativePath) != nil {
                throw SourceScannerError.invalidPath(file.relativePath)
            }
        }

        // Unicode normalization collisions: two distinct paths must not fold
        // onto the same NFC form (APFS normalizes names; such a torrent would
        // have ambiguous file identities).
        try detectPathCollisions(scannedFiles.map(\.relativePath))

        // Calculate piece size
        let pieceSizeBytes: Int64
        if let manualKiB = manualPieceSizeKiB {
            let (product, overflow) = manualKiB.multipliedReportingOverflow(by: 1024)
            guard manualKiB > 0, !overflow, isValidPieceSize(product) else {
                // Do not multiply again in the failure path: an IPC value such
                // as Int64.max must be rejected without trapping or wrapping.
                throw SourceScannerError.invalidPieceSize(overflow ? Int64.max : product)
            }
            pieceSizeBytes = product
        } else {
            pieceSizeBytes = calculateAutomaticPieceSize(totalSizeBytes: totalBytes)
        }

        return SourceScanResult(
            isDirectory: isDir.boolValue,
            rootName: rootName,
            rootDeviceID: UInt64(rootStat.st_dev),
            rootResourceID: UInt64(rootStat.st_ino),
            rootMtimeSeconds: Int64(rootStat.st_mtimespec.tv_sec),
            rootMtimeNanos: Int64(rootStat.st_mtimespec.tv_nsec),
            files: scannedFiles,
            totalSizeBytes: totalBytes,
            pieceSizeBytes: pieceSizeBytes,
            skippedSymlinksCount: skippedSymlinks,
            skippedSpecialCount: skippedSpecial,
            hardlinkCount: hardlinksFound,
            exclusions: Array(recordedExclusions).sorted(),
            warnings: warnings
        )
    }

    /// Unicode normalization collision detector: two distinct paths must not
    /// fold onto the same NFC form (APFS normalizes names; such a torrent
    /// would have ambiguous file identities). Exposed for adversarial tests —
    /// the detector is order-independent and path-bytes-exact.
    public static func detectPathCollisions(_ paths: [String]) throws {
        var normalizedSeen: [String: String] = [:]
        for path in paths {
            let folded = path.precomposedStringWithCanonicalMapping
            if let first = normalizedSeen[folded] {
                throw SourceScannerError.pathCollision("'\(path)' collides with '\(first)'")
            }
            normalizedSeen[folded] = path
        }
    }

    /// Shared file registration: hardlink-alias accounting, identity
    /// snapshot (device + inode + mtime), size accumulation with overflow
    /// and file-count bounds.
    private static func registerFile(
        relativePath: String,
        fullPath: String,
        statBuf: stat,
        seenInodes: inout [UInt64: String],
        hardlinksFound: inout Int,
        scannedFiles: inout [ScannedFileEntry],
        totalBytes: inout Int64,
        warnings: inout [String]
    ) throws {
        let ino = UInt64(statBuf.st_ino)
        if let firstPath = seenInodes[ino] {
            hardlinksFound += 1
            warnings.append("Hardlink alias detected: '\(relativePath)' shares inode with '\(firstPath)'")
        } else {
            seenInodes[ino] = relativePath
        }

        let size = Int64(statBuf.st_size)
        guard size >= 0 else {
            throw SourceScannerError.sourceUnreadable(fullPath)
        }
        let mtimeSec = Int64(statBuf.st_mtimespec.tv_sec)
        let mtimeNsec = Int64(statBuf.st_mtimespec.tv_nsec)

        // A successful directory listing is not proof that a file can be
        // consumed. Probe the exact file without following a symlink so an
        // unreadable regular file fails the scan instead of becoming a
        // misleadingly incomplete torrent.
        let descriptor = open(fullPath, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SourceScannerError.sourceUnreadable(fullPath) }
        guard Darwin.close(descriptor) == 0 else {
            throw SourceScannerError.sourceUnreadable(fullPath)
        }

        let entry = ScannedFileEntry(
            relativePath: relativePath,
            fullPath: fullPath,
            sizeBytes: size,
            deviceID: UInt64(statBuf.st_dev),
            fileResourceID: ino,
            mtimeSeconds: mtimeSec,
            mtimeNanos: mtimeNsec
        )
        scannedFiles.append(entry)
        if scannedFiles.count > TransferLimits.maxFiles {
            throw SourceScannerError.tooManyFiles(scannedFiles.count)
        }
        let (newTotal, overflow) = totalBytes.addingReportingOverflow(size)
        if overflow {
            throw SourceScannerError.sourceUnreadable("Total source size overflowed 64-bit integer")
        }
        totalBytes = newTotal
    }

    private static func inspectFile(
        fileURL: URL,
        relativePath: String,
        canonicalOutput: String?,
        skippedSymlinks: inout Int,
        skippedSpecial: inout Int
    ) throws -> ScannedFileEntry? {
        let canonicalFilePath = canonicalAbsolutePath(fileURL.path)
        if let canonicalOutput, canonicalFilePath == canonicalOutput {
            return nil
        }
        // WP-11: default exclusions apply to single-file sources exactly like
        // directory scans (a .DS_Store named as a source is not torrent data).
        // The includeHiddenFiles toggle governs directory scans; a single
        // file the user explicitly picked is not filtered by the "." rule.
        let filename = fileURL.lastPathComponent
        if defaultExclusions.contains(filename) || filename.hasPrefix("._") {
            return nil
        }
        var statBuf = stat()
        if lstat(canonicalFilePath, &statBuf) != 0 {
            throw SourceScannerError.sourceUnreadable(canonicalFilePath)
        }
        let fileMode = statBuf.st_mode
        if (fileMode & S_IFMT) == S_IFLNK {
            skippedSymlinks += 1
            return nil
        }
        guard (fileMode & S_IFMT) == S_IFREG else {
            skippedSpecial += 1
            return nil
        }
        if PathValidator.validationError(relativePath) != nil {
            throw SourceScannerError.invalidPath(relativePath)
        }
        let descriptor = open(canonicalFilePath, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SourceScannerError.sourceUnreadable(canonicalFilePath) }
        guard Darwin.close(descriptor) == 0 else {
            throw SourceScannerError.sourceUnreadable(canonicalFilePath)
        }
        return ScannedFileEntry(
            relativePath: relativePath,
            fullPath: canonicalFilePath,
            sizeBytes: Int64(statBuf.st_size),
            deviceID: UInt64(statBuf.st_dev),
            fileResourceID: UInt64(statBuf.st_ino),
            mtimeSeconds: Int64(statBuf.st_mtimespec.tv_sec),
            mtimeNanos: Int64(statBuf.st_mtimespec.tv_nsec)
        )
    }

    public static func isValidPieceSize(_ bytes: Int64) -> Bool {
        guard bytes >= 16 * 1024 && bytes <= 16 * 1024 * 1024 else { return false }
        // Must be power of 2
        return (bytes & (bytes - 1)) == 0
    }

    public static func calculateAutomaticPieceSize(totalSizeBytes: Int64) -> Int64 {
        // Standard piece size calculation aiming for ~1000 pieces:
        // Clamped between 16 KiB (16384) and 16 MiB (16777216)
        if totalSizeBytes <= 0 { return 16 * 1024 }
        let targetPieceCount: Int64 = 1000
        let candidate = totalSizeBytes / targetPieceCount

        // Power of 2 rounding up
        var pieceSize: Int64 = 16 * 1024
        while pieceSize < candidate && pieceSize < 16 * 1024 * 1024 {
            pieceSize *= 2
        }
        return min(max(pieceSize, 16 * 1024), 16 * 1024 * 1024)
    }
}
