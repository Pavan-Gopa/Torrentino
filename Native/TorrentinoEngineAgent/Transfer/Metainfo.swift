// Layer: EngineAgent (Transfer).
// Role: parsed, validated metainfo of one .torrent (BEP-3, v1). Everything
// the engine/persistence/UI needs to know about the payload BEFORE any byte
// is written: info hash, name, files, total size, trackers, private flag.
// Must-not: hold engine handles, write payloads, or trust unvalidated input;
// construction runs the full preflight (bounded file count, path validation,
// positive lengths, non-empty name, total size > 0).
// Invariants: immutable Sendable value; file paths are PathValidator-normalized
// relative paths; fileCount <= TransferLimits.maxFiles (10 000).

import Foundation
import CommonCrypto
import TorrentinoDomain

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

    public var description: String {
        switch self {
        case .notADictionary: return "root is not a dictionary"
        case .missingInfo: return "missing 'info' dictionary"
        case .missingName: return "missing or invalid 'name'"
        case .invalidName: return "invalid torrent name"
        case .invalidPieceLength: return "invalid piece length"
        case .missingPieces: return "missing 'pieces'"
        case .invalidPieces: return "invalid 'pieces' payload"
        case .singleFileMissingLength: return "single-file mode missing 'length'"
        case .negativeLength(let n): return "negative length \(n)"
        case .emptyPath: return "empty file path"
        case .invalidPath(let p): return "invalid path '\(p)'"
        case .tooManyFiles(let n): return "too many files (\(n) > \(TransferLimits.maxFiles))"
        case .totalSizeOverflow: return "total size overflow"
        case .invalidTrackerURL(let u): return "invalid tracker URL '\(u)'"
        case .unsupportedFormat: return "unsupported metainfo format (v1 only in this slice)"
        case .duplicateFileName(let n): return "duplicate file path '\(n)'"
        case .invalidField(let f): return "invalid metainfo field '\(f)'"
        }
    }
}

/// One payload file inside the torrent. `path` is validated and normalized
/// (relative to the torrent root); `sizeBytes` is non-negative.
public struct MetainfoFile: Sendable, Equatable {
    public let path: String
    public let sizeBytes: Int64

    public init(path: String, sizeBytes: Int64) {
        self.path = path
        self.sizeBytes = sizeBytes
    }
}

public struct Metainfo: Sendable, Equatable {
    /// Raw v1 info-hash (20 bytes, SHA-1 of the exact bencoded "info" value).
    public let infoHashV1: Data
    public let name: String
    public let pieceLength: Int64
    public let files: [MetainfoFile]
    public let trackers: [String]
    public let isPrivate: Bool
    public let isSingleFile: Bool
    /// Raw bencoded "info" bytes (the engine re-adds a restored torrent from
    /// these exact bytes).
    public let infoDictData: Data

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    public var fileCount: Int { files.count }

    public init(
        infoHashV1: Data,
        name: String,
        pieceLength: Int64,
        files: [MetainfoFile],
        trackers: [String],
        isPrivate: Bool,
        isSingleFile: Bool,
        infoDictData: Data
    ) {
        self.infoHashV1 = infoHashV1
        self.name = name
        self.pieceLength = pieceLength
        self.files = files
        self.trackers = trackers
        self.isPrivate = isPrivate
        self.isSingleFile = isSingleFile
        self.infoDictData = infoDictData
    }

    public var infoHashHex: String {
        infoHashV1.map { String(format: "%02x", $0) }.joined()
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

public enum MetainfoParser {
    /// Parses raw .torrent bytes into validated Metainfo. Throws on every
    /// structural, boundedness or path failure — nothing is ever written
    /// from a rejected metainfo.
    public static func parse(_ data: Data) throws -> Metainfo {
        let root = try BencodeParser.parse(data)
        guard case .dictionary(let top, _) = root else { throw MetainfoError.notADictionary }

        guard let info = top["info"] else { throw MetainfoError.missingInfo }
        guard case .dictionary(let infoDict, let infoSpan) = info else { throw MetainfoError.missingInfo }
        let infoDictData = data.subdata(in: infoSpan)

        guard let pieces = infoDict["pieces"] else { throw MetainfoError.missingPieces }
        guard case .bytes(let piecesData, _) = pieces, piecesData.count % 20 == 0, !piecesData.isEmpty else {
            throw MetainfoError.invalidPieces
        }

        guard let nameValue = infoDict["name.utf-8"] ?? infoDict["name"] else { throw MetainfoError.missingName }
        guard case .bytes(let nameBytes, _) = nameValue,
              let name = String(data: nameBytes, encoding: .utf8),
              !name.isEmpty else { throw MetainfoError.invalidName }

        guard let pieceLengthValue = infoDict["piece length"] else { throw MetainfoError.invalidPieceLength }
        guard case .integer(let pieceLength, _) = pieceLengthValue, pieceLength > 0 else {
            throw MetainfoError.invalidPieceLength
        }

        let isPrivate: Bool
        if let privateValue = infoDict["private"] {
            guard case .integer(let flag, _) = privateValue else { throw MetainfoError.invalidField("private") }
            isPrivate = flag == 1
        } else {
            isPrivate = false
        }

        let trackers = try extractTrackers(top)
        let files = try extractFiles(infoDict: infoDict, fallbackName: name)

        // SHA-1 of the exact bencoded info dictionary (BEP-3 v1 info hash).
        let hashData = Data(SHA1.digest(infoDictData))

        return Metainfo(
            infoHashV1: hashData,
            name: name,
            pieceLength: pieceLength,
            files: files,
            trackers: trackers,
            isPrivate: isPrivate,
            isSingleFile: files.count == 1 && files[0].path == name,
            infoDictData: infoDictData
        )
    }

    // MARK: - Trackers

    private static func extractTrackers(_ top: [String: BencodeValue]) throws -> [String] {
        var result: [String] = []
        if let announce = top["announce"] {
            guard case .bytes(let bytes, _) = announce,
                  let url = String(data: bytes, encoding: .utf8) else {
                throw MetainfoError.invalidTrackerURL("<non-utf8>")
            }
            result.append(url)
        }
        if let tiered = top["announce-list"] {
            guard case .list(let tiers, _) = tiered else { throw MetainfoError.invalidTrackerURL("<non-list>") }
            for tier in tiers {
                guard case .list(let urls, _) = tier else { throw MetainfoError.invalidTrackerURL("<bad-tier>") }
                for urlValue in urls {
                    guard case .bytes(let bytes, _) = urlValue,
                          let url = String(data: bytes, encoding: .utf8),
                          !url.isEmpty,
                          url.count <= 2048 else {
                        throw MetainfoError.invalidTrackerURL("<bad-url>")
                    }
                    if !result.contains(url) { result.append(url) }
                    if result.count >= TransferLimits.maxTrackers { break }
                }
            }
        }
        return result
    }

    // MARK: - Files

    private static func extractFiles(infoDict: [String: BencodeValue], fallbackName: String) throws -> [MetainfoFile] {
        var files: [MetainfoFile] = []
        var seen: Set<String> = []

        func append(path: String, length: Int64) throws {
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
            files.append(MetainfoFile(path: normalized, sizeBytes: length))
            if files.count > TransferLimits.maxFiles {
                throw MetainfoError.tooManyFiles(files.count)
            }
        }

        if let fileList = infoDict["files"] {
            // Multi-file mode: "files" = list of { length, path: [parts] }.
            guard case .list(let entries, _) = fileList else { throw MetainfoError.missingInfo }
            for entry in entries {
                guard case .dictionary(let fileDict, _) = entry else { throw MetainfoError.missingInfo }
                guard let lengthValue = fileDict["length"] else { throw MetainfoError.singleFileMissingLength }
                guard case .integer(let length, _) = lengthValue else { throw MetainfoError.singleFileMissingLength }
                let pathValue = fileDict["path.utf-8"] ?? fileDict["path"]
                guard case .list(let parts, _)? = pathValue else { throw MetainfoError.emptyPath }
                var components: [String] = []
                for part in parts {
                    guard case .bytes(let bytes, _) = part,
                          let text = String(data: bytes, encoding: .utf8),
                          !text.isEmpty,
                          !text.contains("/") else { throw MetainfoError.invalidPath("<bad-component>") }
                    components.append(text)
                }
                guard !components.isEmpty else { throw MetainfoError.emptyPath }
                try append(path: components.joined(separator: "/"), length: length)
            }
        } else if let lengthValue = infoDict["length"] {
            // Single-file mode.
            guard case .integer(let length, _) = lengthValue else { throw MetainfoError.singleFileMissingLength }
            try append(path: fallbackName, length: length)
        } else {
            throw MetainfoError.singleFileMissingLength
        }

        var total: Int64 = 0
        for file in files {
            let (sum, overflow) = total.addingReportingOverflow(file.sizeBytes)
            guard !overflow else { throw MetainfoError.totalSizeOverflow }
            total = sum
        }

        guard !files.isEmpty else { throw MetainfoError.emptyPath }
        return files
    }
}

// MARK: - SHA-1 (CommonCrypto; CryptoKit's SHA1 is unavailable on newer SDKs)

enum SHA1 {
    static func digest(_ data: Data) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest
    }
}
