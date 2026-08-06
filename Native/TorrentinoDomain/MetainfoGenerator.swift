// Layer: Domain
// Role: Metainfo dictionary generator for v1, v2, and hybrid BitTorrent files.
// Must-not: generate unvalidated bencode or missing info dictionary keys.
// Invariants: lexicographically sorted bencode dictionaries; Sendable.

import Foundation
#if canImport(TorrentinoIPC)
import TorrentinoIPC
#endif

public enum MetainfoGenerator {
    public static func buildTorrentFile(
        scanResult: SourceScanResult,
        options: CreateOptions,
        hashingResult: HashingResult,
        creationDate: Date = Date()
    ) throws -> Data {
        let isV1 = options.format == .v1 || options.format == .hybrid
        let isV2 = options.format == .v2 || options.format == .hybrid

        var infoPairs: [(String, BencodeEncoder.Value)] = []
        infoPairs.append(("name", .string(scanResult.rootName)))
        infoPairs.append(("piece length", .integer(scanResult.pieceSizeBytes)))

        if options.isPrivate {
            infoPairs.append(("private", .integer(1)))
        }

        if let source = options.source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            infoPairs.append(("source", .string(source.trimmingCharacters(in: .whitespacesAndNewlines))))
        }

        if isV1 {
            infoPairs.append(("pieces", .bytes(hashingResult.v1PiecesData)))
        }

        // Handle single file vs multi-file for v1
        if isV1 {
            if !scanResult.isDirectory && scanResult.files.count == 1 {
                infoPairs.append(("length", .integer(scanResult.files[0].sizeBytes)))
            } else {
                var filesList: [BencodeEncoder.Value] = []
                let padding = CreatorLayout.v1PaddingBytes(
                    files: scanResult.files,
                    pieceSizeBytes: scanResult.pieceSizeBytes,
                    format: options.format
                )
                for (index, file) in scanResult.files.enumerated() {
                    let pathParts = file.relativePath.split(separator: "/").map { String($0) }
                    filesList.append(.dictionary([
                        ("length", .integer(file.sizeBytes)),
                        ("path", .list(pathParts.map { .string($0) })),
                    ]))
                    // BEP-47 alignment padding: a zero-byte entry in the same
                    // directory, present only in the v1 address space.
                    if index < padding.count, padding[index] > 0 {
                        filesList.append(.dictionary([
                            ("length", .integer(padding[index])),
                            ("path", .list(paddingPathParts(for: file, index: index))),
                            ("attr", .string("p")),
                        ]))
                    }
                }
                infoPairs.append(("files", .list(filesList)))
            }
        }

        // Handle v2 file tree
        var pieceLayersDict: [Data: BencodeEncoder.Value] = [:]

        if isV2 {
            var fileTreeRoot: [Data: BencodeEncoder.Value] = [:]

            for file in scanResult.files {
                let v2Entry = hashingResult.v2FileTrees[file.relativePath]
                if file.sizeBytes > 0, v2Entry == nil {
                    throw MetainfoError.invalidPiecesRoot(file.relativePath)
                }

                // If piece layers are present, add to piece layers dictionary.
                // BEP-52 keys are the 32-byte pieces-root hashes (raw bytes);
                // libtorrent's parser requires exactly sha256_hash::size().
                if let v2Entry, !v2Entry.pieceLayers.isEmpty {
                    pieceLayersDict[v2Entry.piecesRoot] = .bytes(v2Entry.pieceLayers)
                }

                let pathParts: [String]
                if !scanResult.isDirectory && scanResult.files.count == 1 {
                    // BEP-52 single-file: the tree root key IS the file name.
                    pathParts = [scanResult.rootName]
                } else {
                    // BEP-52 multi-file trees are rooted by the info name at
                    // the engine boundary; the bencoded tree itself contains
                    // only paths below that root. Adding the name here would
                    // make libtorrent resolve the payload as name/name/path.
                    pathParts = file.relativePath.split(separator: "/").map { String($0) }
                }

                insertIntoFileTree(
                    tree: &fileTreeRoot,
                    components: pathParts,
                    fileSize: file.sizeBytes,
                    piecesRoot: v2Entry?.piecesRoot
                )
            }

            infoPairs.append(("file tree", .dictionary(fileTreeRoot)))
            // BEP-52: "meta version" is 2 for v2 AND hybrid torrents.
            infoPairs.append(("meta version", .integer(2)))
        }

        var topPairs: [(String, BencodeEncoder.Value)] = []
        topPairs.append(("info", .dictionary(infoPairs)))

        // Validate before encoding so a private seed admission cannot be
        // bypassed by malformed or unsupported topology. Reusing the value
        // after validation prevents generation from becoming a normalization
        // pass that drops duplicate URLs or changes tier boundaries.
        try MetainfoParser.validateTrackerTiers(options.trackers, isPrivate: options.isPrivate)
        let validatedTiers = options.trackers
        let trackers = validatedTiers.flatMap { $0 }
        if !trackers.isEmpty {
            topPairs.append(("announce", .string(trackers[0])))
            var announceList: [BencodeEncoder.Value] = []
            for tier in validatedTiers {
                announceList.append(.list(tier.map { .string($0) }))
            }
            if !announceList.isEmpty {
                topPairs.append(("announce-list", .list(announceList)))
            }
        }

        if let comment = options.comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            topPairs.append(("comment", .string(comment.trimmingCharacters(in: .whitespacesAndNewlines))))
        }

        topPairs.append(("created by", .string("Torrentino Native 1.0")))
        topPairs.append(("creation date", .integer(Int64(creationDate.timeIntervalSince1970))))
        topPairs.append(("encoding", .string("UTF-8")))

        if isV2 {
            // BEP-52 requires the field for created v2 metadata even when no
            // file spans more than one piece; an empty dictionary is the
            // canonical representation in that case.
            topPairs.append(("piece layers", .dictionary(pieceLayersDict)))
        }
        return BencodeEncoder.encode(.dictionary(topPairs))
    }

    /// BEP-47 padding file path: same directory as the padded file, name
    /// `_____padding_file_<n>_<sha1>` (SHA-1 of the padded file's relative
    /// path — deterministic, no extra I/O).
    private static func paddingPathParts(for file: ScannedFileEntry, index: Int) -> [BencodeEncoder.Value] {
        var parts = file.relativePath.split(separator: "/").dropLast().map { String($0) }
        let digest = SHA1.digest(Data(file.relativePath.utf8)).map { String(format: "%02x", $0) }.joined()
        parts.append("_____padding_file_\(index)_\(digest)")
        return parts.map { .string($0) }
    }

    private static func insertIntoFileTree(
        tree: inout [Data: BencodeEncoder.Value],
        components: [String],
        fileSize: Int64,
        piecesRoot: Data?
    ) {
        guard !components.isEmpty else { return }

        let head = Data(components[0].utf8)
        if components.count == 1 {
            var leafPairs: [(String, BencodeEncoder.Value)] = [("length", .integer(fileSize))]
            if let piecesRoot, fileSize > 0 {
                leafPairs.append(("pieces root", .bytes(piecesRoot)))
            }

            var leaf: [Data: BencodeEncoder.Value] = [:]
            leaf[Data()] = .dictionary(leafPairs)
            tree[head] = .dictionary(leaf)
        } else {
            var childTree: [Data: BencodeEncoder.Value] = [:]
            if case .dictionary(let existing)? = tree[head] {
                childTree = existing
            }
            insertIntoFileTree(
                tree: &childTree,
                components: Array(components.dropFirst()),
                fileSize: fileSize,
                piecesRoot: piecesRoot
            )
            tree[head] = .dictionary(childTree)
        }
    }
}
