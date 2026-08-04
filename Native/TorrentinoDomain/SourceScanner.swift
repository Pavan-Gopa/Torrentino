// Layer: Domain
// Role: File system source scanner for Torrent Creator (scan, exclusions, piece size, identity snapshot).
// Must-not: follow symlinks, mutate source files, or block main actor.
// Invariants: immutable scan results; default exclusions applied; file resource ID + mtime captured.

import Foundation

public struct ScannedFileEntry: Sendable, Equatable {
    public let relativePath: String
    public let fullPath: String
    public let sizeBytes: Int64
    public let fileResourceID: UInt64
    public let mtimeSeconds: Int64
    public let mtimeNanos: Int64

    public init(
        relativePath: String,
        fullPath: String,
        sizeBytes: Int64,
        fileResourceID: UInt64,
        mtimeSeconds: Int64,
        mtimeNanos: Int64
    ) {
        self.relativePath = relativePath
        self.fullPath = fullPath
        self.sizeBytes = sizeBytes
        self.fileResourceID = fileResourceID
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanos = mtimeNanos
    }
}

public struct SourceScanResult: Sendable, Equatable {
    public let isDirectory: Bool
    public let rootName: String
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
    case emptySource
    case invalidPieceSize(Int64)

    public var description: String {
        switch self {
        case .sourceNotFound(let path): return "source path not found: \(path)"
        case .sourceUnreadable(let path): return "source unreadable: \(path)"
        case .emptySource: return "source contains no valid readable files"
        case .invalidPieceSize(let size): return "invalid piece size: \(size) bytes (must be power of 2 between 16 KiB and 16 MiB)"
        }
    }
}

public enum SourceScanner {
    public static let defaultExclusions: Set<String> = [
        ".DS_Store",
        ".Spotlight-V100",
        ".Trashes"
    ]

    public static func scan(
        sourcePath: String,
        outputPath: String? = nil,
        includeHiddenFiles: Bool = false,
        manualPieceSizeKiB: Int64? = nil
    ) throws -> SourceScanResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourcePath, isDirectory: &isDir) else {
            throw SourceScannerError.sourceNotFound(sourcePath)
        }

        let canonicalSource = (sourcePath as NSString).standardizingPath
        let canonicalOutput = outputPath != nil ? (outputPath! as NSString).standardizingPath : nil

        var scannedFiles: [ScannedFileEntry] = []
        var skippedSymlinks = 0
        var skippedSpecial = 0
        var recordedExclusions: Set<String> = defaultExclusions
        var warnings: [String] = []

        var seenInodes: [UInt64: String] = [:]
        var hardlinksFound = 0
        var totalBytes: Int64 = 0

        let rootName = (canonicalSource as NSString).lastPathComponent

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
                totalBytes += entry.sizeBytes
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
                    warnings.append("Could not read directory \(dirURL.path): \(error.localizedDescription)")
                    return
                }

                for itemURL in contents {
                    let filename = itemURL.lastPathComponent

                    // Default exclusions
                    if defaultExclusions.contains(filename) || filename.hasPrefix("._") {
                        recordedExclusions.insert(filename)
                        continue
                    }

                    // Hidden files rule
                    if !includeHiddenFiles && filename.hasPrefix(".") {
                        recordedExclusions.insert(filename)
                        continue
                    }

                    // Output file inside source tree exclusion
                    if let canonicalOutput, (itemURL.path as NSString).standardizingPath == canonicalOutput {
                        warnings.append("Excluded output file \(filename) from source input tree.")
                        continue
                    }

                    // Symlink & Special file checks
                    var statBuf = stat()
                    if lstat(itemURL.path, &statBuf) != 0 {
                        warnings.append("Failed to stat item \(itemURL.path)")
                        continue
                    }

                    let fileMode = statBuf.st_mode
                    if (fileMode & S_IFMT) == S_IFLNK {
                        skippedSymlinks += 1
                        continue
                    }

                    let relativePath = currentRelativePrefix.isEmpty ? filename : "\(currentRelativePrefix)/\(filename)"

                    if (fileMode & S_IFMT) == S_IFDIR {
                        try traverseDirectory(dirURL: itemURL, currentRelativePrefix: relativePath)
                    } else if (fileMode & S_IFMT) == S_IFREG {
                        let ino = UInt64(statBuf.st_ino)
                        if let firstPath = seenInodes[ino] {
                            hardlinksFound += 1
                            warnings.append("Hardlink alias detected: '\(relativePath)' shares inode with '\(firstPath)'")
                        } else {
                            seenInodes[ino] = relativePath
                        }

                        let size = Int64(statBuf.st_size)
                        let mtimeSec = Int64(statBuf.st_mtimespec.tv_sec)
                        let mtimeNsec = Int64(statBuf.st_mtimespec.tv_nsec)

                        let entry = ScannedFileEntry(
                            relativePath: relativePath,
                            fullPath: itemURL.path,
                            sizeBytes: size,
                            fileResourceID: ino,
                            mtimeSeconds: mtimeSec,
                            mtimeNanos: mtimeNsec
                        )
                        scannedFiles.append(entry)
                        let (newTotal, overflow) = totalBytes.addingReportingOverflow(size)
                        if overflow {
                            throw SourceScannerError.sourceUnreadable("Total source size overflowed 64-bit integer")
                        }
                        totalBytes = newTotal
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
        scannedFiles.sort { $0.relativePath < $1.relativePath }

        // Calculate piece size
        let pieceSizeBytes: Int64
        if let manualKiB = manualPieceSizeKiB, manualKiB > 0 {
            let bytes = manualKiB * 1024
            guard isValidPieceSize(bytes) else {
                throw SourceScannerError.invalidPieceSize(bytes)
            }
            pieceSizeBytes = bytes
        } else {
            pieceSizeBytes = calculateAutomaticPieceSize(totalSizeBytes: totalBytes)
        }

        return SourceScanResult(
            isDirectory: isDir.boolValue,
            rootName: rootName,
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

    private static func inspectFile(
        fileURL: URL,
        relativePath: String,
        canonicalOutput: String?,
        skippedSymlinks: inout Int,
        skippedSpecial: inout Int
    ) throws -> ScannedFileEntry? {
        if let canonicalOutput, (fileURL.path as NSString).standardizingPath == canonicalOutput {
            return nil
        }
        var statBuf = stat()
        if lstat(fileURL.path, &statBuf) != 0 {
            throw SourceScannerError.sourceUnreadable(fileURL.path)
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
        return ScannedFileEntry(
            relativePath: relativePath,
            fullPath: fileURL.path,
            sizeBytes: Int64(statBuf.st_size),
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
