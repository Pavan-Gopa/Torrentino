// Layer: Domain
// Role: parsed, validated metainfo of one .torrent (BEP-3 v1, BEP-52 v2 and
// hybrid). Everything the engine/persistence/UI needs to know about the
// payload BEFORE any byte is written: info hashes (v1 SHA-1 + v2 SHA-256),
// name, files, total size, tracker topology, private flag.
// Must-not: hold engine handles, write payloads, or trust unvalidated input;
// construction runs the full preflight (bounded file count, path validation,
// positive lengths, non-empty name, total size > 0, v1 pieces sanity, v2 file
// tree structure, v1/v2 file-set agreement for hybrid).
// Invariants: immutable Sendable value; file paths are PathValidator-normalized
// relative paths; fileCount <= TransferLimits.maxFiles (10 000); for hybrid
// metainfo the v1 "files"/"length" list and the v2 "file tree" describe the
// exact same file set (BEP-52 §"hybrid torrents").

import Foundation
import CommonCrypto

public enum MetainfoError: Error, Sendable, Equatable, CustomStringConvertible {
    case notADictionary
    case missingInfo
    case missingName
    case invalidName
    case invalidPieceLength
    case missingPieces
    case invalidPieces
    case singleFileMissingLength
    case negativeLength(Int64)
    case emptyPath
    case invalidPath(String)
    case tooManyFiles(Int)
    case totalSizeOverflow
    case invalidTrackerURL(String)
    case unsupportedFormat
    case duplicateFileName(String)
    case invalidField(String)
    case missingFileTree
    case invalidPiecesRoot(String)
    case invalidPieceLayers(String)
    case hybridMismatch(String)

    public var description: String {
        switch self {
        case .notADictionary: return "not a bencoded dictionary"
        case .missingInfo: return "missing info dictionary"
        case .missingName: return "missing or empty torrent name"
        case .invalidName: return "invalid torrent name"
        case .invalidPieceLength: return "invalid piece length"
        case .missingPieces: return "missing pieces field"
        case .invalidPieces: return "invalid pieces field length (must be non-empty and a multiple of 20)"
        case .singleFileMissingLength: return "single-file mode missing length"
        case .negativeLength(let len): return "negative file length: \(len)"
        case .emptyPath: return "empty file path"
        case .invalidPath(let p): return "invalid file path: \(p)"
        case .tooManyFiles(let count): return "file count \(count) exceeds limit (\(TransferLimits.maxFiles))"
        case .totalSizeOverflow: return "total size exceeds 64-bit integer limit"
        case .invalidTrackerURL(let url): return "invalid tracker URL: \(url)"
        case .unsupportedFormat: return "unsupported torrent format"
        case .duplicateFileName(let name): return "duplicate relative file path: \(name)"
        case .invalidField(let f): return "invalid field '\(f)'"
        case .missingFileTree: return "meta version 2 requires a file tree"
        case .invalidPiecesRoot(let p): return "invalid v2 pieces root: \(p)"
        case .invalidPieceLayers(let detail): return "invalid v2 piece layers: \(detail)"
        case .hybridMismatch(let detail): return "hybrid v1/v2 file-set mismatch: \(detail)"
        }
    }
}

/// One payload file inside the torrent. `path` is validated and normalized
/// (relative to the torrent root); `sizeBytes` is non-negative.
/// `v2PiecesRoot` is the 32-byte BEP-52 merkle root, present only for
/// non-empty files of v2/hybrid metainfo.
public struct MetainfoFile: Sendable, Equatable {
    public let path: String
    public let sizeBytes: Int64
    public let v2PiecesRoot: Data?

    public init(path: String, sizeBytes: Int64, v2PiecesRoot: Data? = nil) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.v2PiecesRoot = v2PiecesRoot
    }
}

public struct Metainfo: Sendable, Equatable {
    /// Raw v1 info-hash (20 bytes, SHA-1 of the exact bencoded "info" value).
    /// It is nil for v2-only metadata; inventing a v1 identity would make
    /// duplicate detection and restart re-add incorrect.
    public let infoHashV1: Data?
    /// Raw v2 info-hash (32 bytes, SHA-256 of the exact bencoded "info"
    /// value), nil for v1-only metainfo.
    public let infoHashV2: Data?
    public let name: String
    public let pieceLength: Int64
    public let files: [MetainfoFile]
    /// Validated BEP-12 tiers in asserted order. Repeated URLs are meaningful
    /// input and therefore remain repeated here rather than being normalized.
    public let trackerTiers: [[String]]
    /// Flat compatibility projection of `trackerTiers`; it is never used as
    /// the source of truth for a structured tracker edit.
    public let trackers: [String]
    public let isPrivate: Bool
    public let isSingleFile: Bool
    /// Raw bencoded "info" bytes (the engine re-adds a restored torrent from
    /// these exact bytes).
    public let infoDictData: Data
    /// BEP-52 "meta version": 1 for v1-only, 2 for v2/hybrid.
    public let metaVersion: Int
    /// Raw v1 "pieces" payload (concatenated SHA-1 digests), nil for v2-only.
    /// The creator verifies the written file re-parses to these exact bytes.
    public let v1PiecesData: Data?
    /// Raw BEP-52 piece-layer values keyed by binary pieces-root hashes.
    public let v2PieceLayers: [Data: Data]

    public var isV2: Bool { metaVersion == 2 }
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    public var fileCount: Int { files.count }

    public init(
        infoHashV1: Data?,
        infoHashV2: Data?,
        name: String,
        pieceLength: Int64,
        files: [MetainfoFile],
        trackerTiers: [[String]],
        isPrivate: Bool,
        isSingleFile: Bool,
        infoDictData: Data,
        metaVersion: Int,
        v1PiecesData: Data? = nil,
        v2PieceLayers: [Data: Data] = [:]
    ) {
        self.infoHashV1 = infoHashV1
        self.infoHashV2 = infoHashV2
        self.name = name
        self.pieceLength = pieceLength
        self.files = files
        self.trackerTiers = trackerTiers
        self.trackers = trackerTiers.flatMap { $0 }
        self.isPrivate = isPrivate
        self.isSingleFile = isSingleFile
        self.infoDictData = infoDictData
        self.metaVersion = metaVersion
        self.v1PiecesData = v1PiecesData
        self.v2PieceLayers = v2PieceLayers
    }

    public var infoHashHex: String {
        (infoHashV1 ?? infoHashV2 ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    public var infoHashV2Hex: String? {
        infoHashV2.map { $0.map { String(format: "%02x", $0) }.joined() }
    }

    /// Metainfo file whose path is exactly `relativePath`, if any.
    public func file(atPath relativePath: String) -> MetainfoFile? {
        files.first { $0.path == relativePath }
    }
}

/// Shared transfer limits (WP-07 bounded counts).
public enum TransferLimits: Sendable {
    /// Max payload file count (plan: 10 000).
    public static let maxFiles = 10_000
    /// Max .torrent size accepted from any source (HTTP limit is identical).
    public static let maxTorrentFileBytes = 10 * 1024 * 1024
    /// Max magnet URI length.
    public static let maxMagnetLength = 8 * 1024
    /// Max trackers recorded per torrent.
    public static let maxTrackers = 512
}

/// One tracker URL policy shared by magnet parsing, metainfo parsing and
/// creator generation. Keeping this at the domain boundary prevents a UI-only
/// scheme check from producing metadata that the engine cannot use.
public enum TrackerURLValidator {
    public static func isSupported(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 2048,
              !value.contains(where: { character in
                  character.isWhitespace || character.unicodeScalars.contains {
                      $0.value < 0x20 || $0.value == 0x7F
                  }
              }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "udp"].contains(scheme),
              components.host != nil else {
            return false
        }
        return true
    }
}

public enum MetainfoParser {
    /// Parses raw .torrent bytes into validated Metainfo. Throws on every
    /// structural, boundedness or path failure — nothing is ever written
    /// from a rejected metainfo.
    public static func parse(_ data: Data) throws -> Metainfo {
        let root = try BencodeParser.parse(data)
        guard case .dictionary(let top, _) = root else { throw MetainfoError.notADictionary }

        guard let info = top.value(for: "info") else { throw MetainfoError.missingInfo }
        guard case .dictionary(let infoDict, let infoSpan) = info else { throw MetainfoError.missingInfo }
        let infoDictData = data.subdata(in: infoSpan)

        let isPrivate: Bool
        if let privateValue = infoDict.value(for: "private") {
            guard case .integer(let flag, _) = privateValue else { throw MetainfoError.invalidField("private") }
            isPrivate = flag == 1
        } else {
            isPrivate = false
        }

        guard let nameValue = infoDict.value(for: "name.utf-8") ?? infoDict.value(for: "name") else {
            throw MetainfoError.missingName
        }
        guard case .bytes(let nameBytes, _) = nameValue,
              let name = String(data: nameBytes, encoding: .utf8),
              !name.isEmpty else { throw MetainfoError.invalidName }

        guard let pieceLengthValue = infoDict.value(for: "piece length") else { throw MetainfoError.invalidPieceLength }
        guard case .integer(let pieceLength, _) = pieceLengthValue, pieceLength > 0 else {
            throw MetainfoError.invalidPieceLength
        }

        let hasFiles = infoDict.value(for: "files") != nil
        let hasLength = infoDict.value(for: "length") != nil
        guard !(hasFiles && hasLength) else {
            throw MetainfoError.invalidField("length and files are mutually exclusive")
        }

        // BEP-52: "meta version" is 2 for v2/hybrid; anything else is rejected.
        let metaVersion: Int
        if let versionValue = infoDict.value(for: "meta version") {
            guard case .integer(let version, _) = versionValue, version == 2 else {
                throw MetainfoError.unsupportedFormat
            }
            metaVersion = 2
        } else {
            metaVersion = 1
        }

        let isV2 = metaVersion == 2
        if isV2 && infoDict.value(for: "file tree") == nil { throw MetainfoError.missingFileTree }
        if !isV2 && infoDict.value(for: "file tree") != nil {
            throw MetainfoError.unsupportedFormat
        }
        // BEP-52 requires a power-of-two piece length of at least one 16 KiB
        // block. v1 uses the same creator range so a plan cannot produce a
        // format that the shared engine later rejects.
        if isV2 {
            guard pieceLength >= CreatorLayout.v2BlockSize,
                  pieceLength % CreatorLayout.v2BlockSize == 0,
                  SourceScanner.isValidPieceSize(pieceLength) else {
                throw MetainfoError.invalidPieceLength
            }
        }

        // v1 pieces: mandatory for v1/hybrid, must be non-empty and a whole
        // number of SHA-1 digests.
        let v1PiecesData: Data?
        let piecesValue = infoDict.value(for: "pieces")
        if let pieces = piecesValue {
            guard case .bytes(let piecesData, _) = pieces else { throw MetainfoError.invalidPieces }
            guard !piecesData.isEmpty, piecesData.count % 20 == 0 else { throw MetainfoError.invalidPieces }
            v1PiecesData = piecesData
        } else if !isV2 || hasFiles || hasLength {
            throw MetainfoError.missingPieces
        } else {
            v1PiecesData = nil
        }
        // A pure v2 info dictionary has no v1 address space. Accepting a
        // stray pieces value would create a hybrid-looking torrent without
        // the corresponding files/length layout.
        if isV2 && !hasFiles && !hasLength && piecesValue != nil {
            throw MetainfoError.invalidPieces
        }

        let trackerTiers = try extractTrackers(top)
        try validateTrackerTiers(trackerTiers, isPrivate: isPrivate)
        let extraction = try extractFiles(
            infoDict: infoDict,
            fallbackName: name,
            isV2: isV2,
            hasV1Layout: hasFiles || hasLength
        )
        let files = extraction.files

        if let piecesData = v1PiecesData, let v1AddressSpaceBytes = extraction.v1AddressSpaceBytes {
            let (rounded, overflow) = v1AddressSpaceBytes.addingReportingOverflow(pieceLength - 1)
            guard !overflow else { throw MetainfoError.totalSizeOverflow }
            let expectedPieceCount = rounded / pieceLength
            guard expectedPieceCount > 0,
                  expectedPieceCount <= Int64(Int.max / 20),
                  piecesData.count == Int(expectedPieceCount) * 20 else {
                throw MetainfoError.invalidPieces
            }
        }

        let v2PieceLayers = try extractPieceLayers(
            top: top,
            files: files,
            pieceLength: pieceLength,
            isV2: isV2
        )

        // SHA-1 of the exact bencoded info dictionary (BEP-3 v1 info hash);
        // SHA-256 of the same bytes is the BEP-52 v2 info hash.
        let hashData = v1PiecesData == nil ? nil : Data(SHA1.digest(infoDictData))
        let hashV2Data = isV2 ? Data(SHA256.digest(infoDictData)) : nil

        return Metainfo(
            infoHashV1: hashData,
            infoHashV2: hashV2Data,
            name: name,
            pieceLength: pieceLength,
            files: files,
            trackerTiers: trackerTiers,
            isPrivate: isPrivate,
            isSingleFile: files.count == 1 && files[0].path == name,
            infoDictData: infoDictData,
            metaVersion: metaVersion,
            v1PiecesData: v1PiecesData,
            v2PieceLayers: v2PieceLayers
        )
    }

    // MARK: - Trackers

    private static func extractTrackers(_ top: [Data: BencodeValue]) throws -> [[String]] {
        let scalarAnnounce: String?
        if let announce = top.value(for: "announce") {
            guard case .bytes(let bytes, _) = announce,
                  let url = String(data: bytes, encoding: .utf8),
                  TrackerURLValidator.isSupported(url) else {
                throw MetainfoError.invalidTrackerURL("<non-utf8>")
            }
            scalarAnnounce = url
        } else {
            scalarAnnounce = nil
        }

        if let tiered = top.value(for: "announce-list") {
            guard case .list(let tiers, _) = tiered else { throw MetainfoError.invalidTrackerURL("<non-list>") }
            var topology: [[String]] = []
            for tier in tiers {
                guard case .list(let urls, _) = tier else { throw MetainfoError.invalidTrackerURL("<bad-tier>") }
                guard !urls.isEmpty else { throw MetainfoError.invalidTrackerURL("<empty-tier>") }
                var validatedTier: [String] = []
                for urlValue in urls {
                    guard case .bytes(let bytes, _) = urlValue,
                          let url = String(data: bytes, encoding: .utf8),
                          TrackerURLValidator.isSupported(url) else {
                        throw MetainfoError.invalidTrackerURL("<bad-url>")
                    }
                    validatedTier.append(url)
                }
                topology.append(validatedTier)
            }
            try validateTrackerTiers(topology)
            if let scalarAnnounce, topology.first?.first != scalarAnnounce {
                throw MetainfoError.invalidField("announce does not match the first announce-list URL")
            }
            return topology
        }

        if let scalarAnnounce {
            return [[scalarAnnounce]]
        }
        return []
    }

    /// Validates a structured topology without changing its order or content.
    /// This is shared by parser, Creator admission, and later edits so a valid
    /// asserted sequence cannot be silently rewritten at another boundary.
    public static func validateTrackerTiers(_ tiers: [[String]], isPrivate: Bool = false) throws {
        var trackerCount = 0
        for tier in tiers {
            guard !tier.isEmpty else { throw MetainfoError.invalidTrackerURL("<empty-tier>") }
            for url in tier {
                guard TrackerURLValidator.isSupported(url) else {
                    throw MetainfoError.invalidTrackerURL("<bad-url>")
                }
                trackerCount += 1
                guard trackerCount <= TransferLimits.maxTrackers else {
                    throw MetainfoError.invalidTrackerURL("<too-many-trackers>")
                }
            }
        }
        if isPrivate && trackerCount == 0 {
            throw MetainfoError.invalidTrackerURL("<private-without-tracker>")
        }
    }

    /// Replaces only top-level tracker fields while preserving the original
    /// raw value bytes for `info` and every unrelated field. This keeps the
    /// content identity stable when a persisted torrent's trackers are edited.
    public static func replacingTrackerTiers(in data: Data, with tiers: [[String]]) throws -> Data {
        let root = try BencodeParser.parse(data)
        guard case .dictionary(let top, _) = root else { throw MetainfoError.notADictionary }
        let parsed = try parse(data)
        try validateTrackerTiers(tiers, isPrivate: parsed.isPrivate)

        let announceKey = Data("announce".utf8)
        let announceListKey = Data("announce-list".utf8)
        var values: [Data: Data] = [:]
        for (key, value) in top where key != announceKey && key != announceListKey {
            values[key] = data.subdata(in: value.span)
        }
        if let firstURL = tiers.first?.first {
            values[announceKey] = BencodeEncoder.encode(.string(firstURL))
            values[announceListKey] = BencodeEncoder.encode(.list(
                tiers.map { .list($0.map { .string($0) }) }
            ))
        }

        var result = Data([0x64]) // d
        for key in values.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            result.append(BencodeEncoder.encode(.bytes(key)))
            if let value = values[key] {
                result.append(value)
            }
        }
        result.append(0x65) // e
        return result
    }

    // MARK: - Files

    private struct FileExtraction {
        let files: [MetainfoFile]
        let v1AddressSpaceBytes: Int64?
    }

    private struct V1LayoutEntry {
        let path: String?
        let length: Int64
        let isPadding: Bool
    }

    private static func extractFiles(
        infoDict: [Data: BencodeValue],
        fallbackName: String,
        isV2: Bool,
        hasV1Layout: Bool
    ) throws -> FileExtraction {
        var files: [MetainfoFile] = []
        var seen: Set<String> = []

        func append(path: String, length: Int64, v2PiecesRoot: Data?) throws {
            guard length >= 0 else { throw MetainfoError.negativeLength(length) }
            let normalized: String
            do {
                normalized = try PathValidator.validatedRelativePath(path)
            } catch {
                throw MetainfoError.invalidPath("\(path): \(error)")
            }
            guard !normalized.isEmpty else { throw MetainfoError.emptyPath }
            guard !seen.contains(normalized) else { throw MetainfoError.duplicateFileName(normalized) }
            seen.insert(normalized)
            files.append(MetainfoFile(path: normalized, sizeBytes: length, v2PiecesRoot: v2PiecesRoot))
            if files.count > TransferLimits.maxFiles {
                throw MetainfoError.tooManyFiles(files.count)
            }
        }

        // v1 file list (BEP-3 "files"/"length"). Keep padding entries in
        // the address-space total even though they are not payload files.
        var v1Entries: [V1LayoutEntry] = []
        if let fileList = infoDict.value(for: "files") {
            guard case .list(let entries, _) = fileList else { throw MetainfoError.missingInfo }
            for entry in entries {
                guard case .dictionary(let fileDict, _) = entry else { throw MetainfoError.missingInfo }
                guard let lengthValue = fileDict.value(for: "length") else { throw MetainfoError.singleFileMissingLength }
                guard case .integer(let length, _) = lengthValue else { throw MetainfoError.singleFileMissingLength }
                guard length >= 0 else { throw MetainfoError.negativeLength(length) }
                let paddingByAttribute: Bool
                if case .bytes(let attrBytes, _)? = fileDict.value(for: "attr") {
                    paddingByAttribute = String(data: attrBytes, encoding: .utf8)?.contains("p") == true
                } else {
                    paddingByAttribute = false
                }
                let pathValue = fileDict.value(for: "path.utf-8") ?? fileDict.value(for: "path")
                var components: [String] = []
                if case .list(let parts, _)? = pathValue {
                    for part in parts {
                        guard case .bytes(let bytes, _) = part,
                              let text = String(data: bytes, encoding: .utf8),
                              !text.isEmpty,
                              !text.contains("/") else { throw MetainfoError.invalidPath("<bad-component>") }
                        components.append(text)
                    }
                }
                let isPadding = paddingByAttribute || isPaddingFile(components: components)
                if !isPadding && components.isEmpty {
                    throw MetainfoError.emptyPath
                }
                v1Entries.append(V1LayoutEntry(
                    path: components.isEmpty ? nil : components.joined(separator: "/"),
                    length: length,
                    isPadding: isPadding
                ))
            }
        } else if let lengthValue = infoDict.value(for: "length") {
            guard case .integer(let length, _) = lengthValue else { throw MetainfoError.singleFileMissingLength }
            guard length >= 0 else { throw MetainfoError.negativeLength(length) }
            v1Entries.append(V1LayoutEntry(path: fallbackName, length: length, isPadding: false))
        }

        var v1PayloadFiles: [(path: String, length: Int64)] = []
        var v1AddressSpaceBytes: Int64 = 0
        for entry in v1Entries {
            let (newTotal, overflow) = v1AddressSpaceBytes.addingReportingOverflow(entry.length)
            guard !overflow else { throw MetainfoError.totalSizeOverflow }
            v1AddressSpaceBytes = newTotal
            if let path = entry.path, !entry.isPadding {
                v1PayloadFiles.append((path, entry.length))
            }
        }
        if hasV1Layout && v1Entries.isEmpty {
            throw MetainfoError.emptyPath
        }
        var seenV1Paths: Set<String> = []
        for file in v1PayloadFiles {
            guard seenV1Paths.insert(file.path).inserted else {
                throw MetainfoError.duplicateFileName(file.path)
            }
        }

        if isV2 {
            guard case .dictionary(let tree, _) = infoDict.value(for: "file tree") else {
                throw MetainfoError.invalidField("file tree")
            }
            var treeFileCount = 0
            let v2Files = try parseFileTree(tree, fileCountBound: &treeFileCount)
            if hasV1Layout {
                // Hybrid: the v1 file set and the v2 file set must describe
                // the exact same payload, order, and sizes. The order check is
                // what proves that both address spaces have identical piece
                // boundaries; a set comparison alone misses reordering.
                guard v1PayloadFiles.count == v2Files.count else {
                    throw MetainfoError.hybridMismatch("file counts differ")
                }
                for (v1, v2) in zip(v1PayloadFiles, v2Files) {
                    guard v1.path == v2.path, v1.length == v2.sizeBytes else {
                        throw MetainfoError.hybridMismatch("file order or size differs at '\(v2.path)'")
                    }
                }
            }
            for v2 in v2Files {
                try append(path: v2.path, length: v2.sizeBytes, v2PiecesRoot: v2.v2PiecesRoot)
            }
        } else {
            for v1 in v1PayloadFiles {
                try append(path: v1.path, length: v1.length, v2PiecesRoot: nil)
            }
        }

        var total: Int64 = 0
        for file in files {
            let (sum, overflow) = total.addingReportingOverflow(file.sizeBytes)
            guard !overflow else { throw MetainfoError.totalSizeOverflow }
            total = sum
        }

        guard !files.isEmpty, total > 0 else { throw MetainfoError.invalidField("zero total size") }
        return FileExtraction(
            files: files,
            v1AddressSpaceBytes: hasV1Layout ? v1AddressSpaceBytes : nil
        )
    }

    // MARK: - v2 file tree (BEP-52)

    /// Walks a BEP-52 "file tree": dict keys are path elements (raw bytes,
    /// UTF-8); a leaf file is a dict containing the empty-string key whose
    /// value carries "length" and "pieces root". A dict with the "" key must
    /// not contain any other key. Returns files with relative paths joined
    /// by "/" in deterministic (byte-sorted) order.
    ///
    /// The root dictionary may contain one or more path elements: BEP-52
    /// supports both a rootless multi-file tree and a tree rooted below a
    /// directory. Paths are retained relative to that tree, which is the same
    /// coordinate system used by the v1 "files" list in a hybrid torrent.
    private static func parseFileTree(
        _ tree: [Data: BencodeValue],
        fileCountBound: inout Int
    ) throws -> [MetainfoFile] {
        // The tree itself must be a directory. An empty key at this level
        // would describe a file at the root and violates BEP-52.
        guard !tree.isEmpty, tree[Data()] == nil else { throw MetainfoError.invalidField("file tree") }
        var result: [MetainfoFile] = []
        for keyData in tree.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard case .dictionary(let node, _) = tree[keyData] else {
                throw MetainfoError.invalidField("file tree")
            }
            let element = try decodePathElement(keyData, label: "file tree element")
            try walk(node: node, prefix: element, into: &result, fileCountBound: &fileCountBound)
        }
        return result
    }

    private static func walk(
        node: [Data: BencodeValue],
        prefix: String,
        into result: inout [MetainfoFile],
        fileCountBound: inout Int
    ) throws {
        if let fileLeaf = node[Data()] {
            // A file: the "" key must be the only key in the node.
            guard node.count == 1 else { throw MetainfoError.invalidField("file tree") }
            guard let lengthValue = fileLeaf.value(for: "length") else { throw MetainfoError.singleFileMissingLength }
            guard case .integer(let length, _) = lengthValue else { throw MetainfoError.singleFileMissingLength }
            guard length >= 0 else { throw MetainfoError.negativeLength(length) }
            let piecesRoot: Data?
            if let rootValue = fileLeaf.value(for: "pieces root") {
                guard case .bytes(let rootBytes, _) = rootValue, rootBytes.count == 32 else {
                    throw MetainfoError.invalidPiecesRoot("expected 32 bytes for '\(prefix)'")
                }
                piecesRoot = rootBytes
            } else {
                piecesRoot = nil
            }
            if length > 0 {
                // Non-empty files must carry a real (non-all-zero) root.
                guard let root = piecesRoot,
                      !root.allSatisfy({ $0 == 0 }) else {
                    throw MetainfoError.invalidPiecesRoot("'\(prefix)' is non-empty but has no valid pieces root")
                }
            }
            result.append(MetainfoFile(path: prefix, sizeBytes: length, v2PiecesRoot: piecesRoot))
            fileCountBound += 1
            if fileCountBound > TransferLimits.maxFiles {
                throw MetainfoError.tooManyFiles(fileCountBound)
            }
        } else {
            for keyData in node.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let element = try decodePathElement(keyData, label: "file tree element")
                guard case .dictionary(let childNode, _) = node[keyData] else {
                    throw MetainfoError.invalidField("file tree")
                }
                let fullPath = prefix.isEmpty ? element : "\(prefix)/\(element)"
                try walk(node: childNode, prefix: fullPath, into: &result, fileCountBound: &fileCountBound)
            }
        }
    }

    private static func decodePathElement(_ bytes: Data, label: String) throws -> String {
        guard let text = String(data: bytes, encoding: .utf8),
              !text.isEmpty,
              !text.contains("/") else {
            throw MetainfoError.invalidPath("<\(label) not valid UTF-8 path element>")
        }
        return text
    }

    /// BEP-47 padding files exist only in the v1 address space. The `attr=p`
    /// marker is handled by the caller; these exact legacy names preserve
    /// compatibility with older creators that omitted the marker.
    private static func isPaddingFile(components: [String]) -> Bool {
        if let last = components.last {
            if last.hasPrefix("_____padding_file_") || last.hasPrefix("____padding_file_") {
                return true
            }
        }
        return components.first == ".pad"
    }

    private static func extractPieceLayers(
        top: [Data: BencodeValue],
        files: [MetainfoFile],
        pieceLength: Int64,
        isV2: Bool
    ) throws -> [Data: Data] {
        guard isV2 else { return [:] }
        guard case .dictionary(let layerDict, _)? = top.value(for: "piece layers") else {
            throw MetainfoError.invalidPieceLayers("missing dictionary")
        }

        var layers: [Data: Data] = [:]
        for (root, value) in layerDict {
            guard root.count == 32,
                  case .bytes(let bytes, _) = value,
                  bytes.count % 32 == 0 else {
                throw MetainfoError.invalidPieceLayers("binary root or layer length is invalid")
            }
            layers[root] = bytes
        }

        let omittedPieceHash = zeroHashForPieceLayer(pieceLength: pieceLength)
        var expectedRoots: Set<Data> = []
        for file in files where file.sizeBytes > pieceLength {
            guard let root = file.v2PiecesRoot, root.count == 32 else {
                throw MetainfoError.invalidPiecesRoot(file.path)
            }
            let (rounded, overflow) = file.sizeBytes.addingReportingOverflow(pieceLength - 1)
            guard !overflow else { throw MetainfoError.totalSizeOverflow }
            let pieceCount = rounded / pieceLength
            guard pieceCount > 0, pieceCount <= Int64(Int.max / 32) else {
                throw MetainfoError.totalSizeOverflow
            }
            guard let layer = layers[root], layer.count == Int(pieceCount) * 32 else {
                throw MetainfoError.invalidPieceLayers("wrong piece count for '\(file.path)'")
            }
            var pieceRoots: [Data] = []
            pieceRoots.reserveCapacity(Int(pieceCount))
            for index in 0..<Int(pieceCount) {
                let start = index * 32
                pieceRoots.append(layer.subdata(in: start..<(start + 32)))
            }
            guard merkleRoot(pieceRoots, paddingHash: omittedPieceHash) == root else {
                throw MetainfoError.invalidPieceLayers("layer does not reconstruct '\(file.path)' root")
            }
            expectedRoots.insert(root)
        }
        guard Set(layers.keys) == expectedRoots else {
            throw MetainfoError.invalidPieceLayers("extra or missing file layer")
        }
        return layers
    }

    /// Reconstructs the file root from the piece layer. BEP-52 omits hashes
    /// covering only bytes beyond EOF, but those omitted piece hashes are the
    /// roots of all-zero 16 KiB leaf subtrees — not 32 zero bytes.
    private static func merkleRoot(_ leaves: [Data], paddingHash: Data) -> Data {
        guard !leaves.isEmpty else { return paddingHash }
        var targetCount = 1
        while targetCount < leaves.count { targetCount *= 2 }
        var layer = leaves + Array(repeating: paddingHash, count: targetCount - leaves.count)
        while layer.count > 1 {
            var next: [Data] = []
            next.reserveCapacity(layer.count / 2)
            for index in stride(from: 0, to: layer.count, by: 2) {
                next.append(hashPair(layer[index], layer[index + 1]))
            }
            layer = next
        }
        return layer[0]
    }

    private static func zeroHashForPieceLayer(pieceLength: Int64) -> Data {
        var hash = Data(repeating: 0, count: 32)
        var blocks = pieceLength / CreatorLayout.v2BlockSize
        while blocks > 1 {
            hash = hashPair(hash, hash)
            blocks /= 2
        }
        return hash
    }

    private static func hashPair(_ left: Data, _ right: Data) -> Data {
        var input = Data()
        input.reserveCapacity(64)
        input.append(left)
        input.append(right)
        return Data(SHA256.digest(input))
    }
}

// MARK: - SHA-1 / SHA-256 (CommonCrypto; CryptoKit's SHA1 is unavailable on newer SDKs)

enum SHA1 {
    static func digest(_ data: Data) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            if let ptr = buffer.baseAddress {
                CC_SHA1(ptr, CC_LONG(data.count), &digest)
            }
        }
        return digest
    }
}

enum SHA256 {
    static func digest(_ data: Data) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            if let ptr = buffer.baseAddress {
                CC_SHA256(ptr, CC_LONG(data.count), &digest)
            }
        }
        return digest
    }
}
