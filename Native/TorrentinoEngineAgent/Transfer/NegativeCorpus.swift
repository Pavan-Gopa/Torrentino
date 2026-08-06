// Layer: EngineAgent (Transfer).
// Role: WP-07 negative corpus — deterministic adversarial inputs for the
// bencode parser, metainfo builder, magnet parser and path validator, plus a
// minimal bencode writer for building VALID fixture torrents. Everything here
// must be rejected BEFORE the first payload write; tests iterate the corpus
// and assert typed rejection (and, where applicable, that no persistence row
// was created).
// Must-not: be used as production data; contains only test fixtures.

import Foundation
import TorrentinoDomain
public enum NegativeCorpus {
    // MARK: - Bencode negatives

    public struct BencodeCase: Sendable {
        public let label: String
        public let data: Data
        public init(_ label: String, _ data: Data) {
            self.label = label
            self.data = data
        }
    }

    public static let bencodeNegatives: [BencodeCase] = [
        BencodeCase("empty input", Data()),
        BencodeCase("truncated dict", Data("d4:infod".utf8)),
        BencodeCase("truncated string payload", Data("5:ab".utf8)),
        BencodeCase("unterminated integer", Data("i42".utf8)),
        BencodeCase("empty integer", Data("ie".utf8)),
        BencodeCase("negative zero integer", Data("i-0e".utf8)),
        BencodeCase("leading zero integer", Data("i01e".utf8)),
        BencodeCase("leading zero length", Data("03:abc".utf8)),
        BencodeCase("negative length", Data("-5:abcde".utf8)),
        BencodeCase("non-digit in length", Data("3x:abc".utf8)),
        BencodeCase("huge length overflow", Data("99999999999999999999:abc".utf8)),
        BencodeCase("non-digit in integer", Data("i12x3e".utf8)),
        BencodeCase("trailing garbage", Data("i1ei1e".utf8)),
        BencodeCase("unexpected token", Data("x".utf8)),
        BencodeCase("nested too deep", Data((String(repeating: "l", count: 80) + String(repeating: "e", count: 80)).utf8)),
        BencodeCase("integer dict key", Data("di1e1:ae".utf8)),
        BencodeCase("duplicate dict keys", Data("d1:a1:bc1:a1:de".utf8)),
        BencodeCase("non-utf8 dict key", Data([0x64, 0x01, 0xFF, 0x65])),
        BencodeCase("unterminated list", Data("li1e".utf8)),
        BencodeCase("empty", Data("e".utf8)),
        BencodeCase("truncated second string", Data("1:a2:b".utf8)),
        BencodeCase("missing colon", Data("3abc".utf8)),
    ]

    // MARK: - Metainfo negatives

    public struct MetainfoCase: Sendable {
        public let label: String
        public let data: Data
        public init(_ label: String, _ data: Data) {
            self.label = label
            self.data = data
        }
    }

    public static let metainfoNegatives: [MetainfoCase] = [
        MetainfoCase("root not a dict", BencodeBuilder.encode(integer: 5)),
        MetainfoCase("missing info dict", BencodeBuilder.encode(dictionary: ["announce": BencodeBuilder.encode(string: "udp://tracker:80")])),
        MetainfoCase("info not a dict", BencodeBuilder.encode(dictionary: ["info": BencodeBuilder.encode(integer: 1)])),
        MetainfoCase("missing pieces", MetainfoBuilder.singleFile(piecesCount: 0)),
        MetainfoCase("pieces not multiple of 20", MetainfoBuilder.withRawPieces(Data(repeating: 0xAA, count: 30))),
        MetainfoCase("missing piece length", MetainfoBuilder.withoutPieceLength),
        MetainfoCase("zero piece length", MetainfoBuilder.singleFile(name: "a.bin", size: 40, pieceLength: 0, piecesCount: 1)),
        MetainfoCase("missing name", MetainfoBuilder.withoutName),
        MetainfoCase("empty name", MetainfoBuilder.singleFile(name: "", size: 1, pieceLength: 16, piecesCount: 1)),
        MetainfoCase("negative file length", MetainfoBuilder.singleFile(name: "a.bin", size: -1, pieceLength: 16, piecesCount: 1)),
        MetainfoCase("zero total size", MetainfoBuilder.singleFile(name: "a.bin", size: 0, pieceLength: 16, piecesCount: 1)),
        MetainfoCase("empty path list", MetainfoBuilder.multiFile(files: [("", 10)], pieceLength: 16, piecesCount: 1)),
        MetainfoCase("empty path component", MetainfoBuilder.multiFile(files: [("a//b.txt", 10)], pieceLength: 16, piecesCount: 1)),
        MetainfoCase("traversal path", MetainfoBuilder.multiFile(files: [("../escape.txt", 10)], pieceLength: 16, piecesCount: 1)),
        MetainfoCase("absolute path", MetainfoBuilder.multiFile(files: [("/etc/passwd", 10)], pieceLength: 16, piecesCount: 1)),
        MetainfoCase("backslash path", MetainfoBuilder.multiFile(files: [("..\\escape", 10)], pieceLength: 16, piecesCount: 1)),
        MetainfoCase("null byte in path", MetainfoBuilder.multiFile(files: [("a\u{0}b.txt", 10)], pieceLength: 16, piecesCount: 1)),
        MetainfoCase("too many files", MetainfoBuilder.multiFile(files: (0...(TransferLimits.maxFiles + 1)).map { ("f\($0).bin", 1) }, pieceLength: 16, piecesCount: 1)),
        MetainfoCase("duplicate file path", MetainfoBuilder.multiFile(files: [("dup.txt", 10), ("dup.txt", 20)], pieceLength: 16, piecesCount: 1)),
    ]

    // MARK: - Magnet negatives

    public static let magnetNegatives: [String] = [
        "",
        "http://example.com/not-a-magnet",
        "magnet:?",
        "magnet:?xt=urn:btih:zzz",
        "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef0123456789abcdef0",
        "magnet:?xt=urn:btmh:1220cafebabe",
        "magnet:?dn=onlyname",
        String(repeating: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567", count: 150),
    ]

    // MARK: - Path negatives

    public static let pathNegatives: [String] = [
        "../escape.txt",
        "a/../../escape.txt",
        "/etc/passwd",
        "/absolute/name",
        "a//b.txt",
        "a/./b.txt",
        ".",
        "..",
        "",
        "a\\..\\escape",
        "con.txt",
        "C:foo/bar",
        "a/\u{0}b.txt",
        String(repeating: "x", count: 300),
        String(repeating: "a/", count: 600) + "b",
    ]

    /// Positive controls — these must NOT be rejected (used to prove the
    /// validator is not over-eager).
    public static let pathPositives: [String] = [
        "a.txt",
        "dir/file.bin",
        "dir/nested/file with spaces.dat",
        "console.txt",
        "nulllike",
        "file.",
        "name.with.dots",
        ".hidden",
        "café/Ünïcode.txt",
    ]
}

// MARK: - Bencode writer (fixtures only)

public enum BencodeBuilder {
    public static func encode(integer: Int64) -> Data {
        Data("i\(integer)e".utf8)
    }

    public static func encode(string: String) -> Data {
        let utf8 = Data(string.utf8)
        return Data("\(utf8.count):".utf8) + utf8
    }

    public static func encode(bytes: Data) -> Data {
        Data("\(bytes.count):".utf8) + bytes
    }

    public static func encode(list: [Data]) -> Data {
        Data("l".utf8) + list.reduce(Data(), +) + Data("e".utf8)
    }

    public static func encode(dictionary: [(String, Data)]) -> Data {
        var data = Data("d".utf8)
        for (key, value) in dictionary.sorted(by: { $0.0 < $1.0 }) {
            data += encode(string: key)
            data += value
        }
        return data + Data("e".utf8)
    }

    public static func encode(dictionary: [String: Data]) -> Data {
        encode(dictionary: dictionary.map { ($0.key, $0.value) })
    }

    public static func pieceHashes(count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }
}

/// Builds syntactically valid fixture .torrent files (v1).
public enum MetainfoBuilder {
    public struct FixtureFile {
        public let path: String
        public let size: Int64
        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
    }

    public static func singleFile(name: String = "fixture.bin", size: Int64 = 1024, pieceLength: Int64 = 256, piecesCount: Int = 1, trackers: [String] = ["udp://tracker.example:80/announce"]) -> Data {
        let requiredPieces = size > 0 && pieceLength > 0
            ? Int((size + pieceLength - 1) / pieceLength)
            : 0
        let effectivePieces = piecesCount == 0 ? 0 : max(piecesCount, requiredPieces)
        let info: [String: Data] = [
            "name": BencodeBuilder.encode(string: name),
            "length": BencodeBuilder.encode(integer: size),
            "piece length": BencodeBuilder.encode(integer: pieceLength),
            "pieces": BencodeBuilder.encode(bytes: BencodeBuilder.pieceHashes(count: effectivePieces * 20)),
        ]
        var top: [String: Data] = [
            "info": BencodeBuilder.encode(dictionary: info),
        ]
        if let announce = trackers.first {
            top["announce"] = BencodeBuilder.encode(string: announce)
        }
        return BencodeBuilder.encode(dictionary: top)
    }

    /// Single-file torrent whose "pieces" payload is exactly `pieces`.
    public static func withRawPieces(_ pieces: Data, name: String = "a.bin", size: Int64 = 40) -> Data {
        let info: [String: Data] = [
            "name": BencodeBuilder.encode(string: name),
            "length": BencodeBuilder.encode(integer: size),
            "piece length": BencodeBuilder.encode(integer: 16),
            "pieces": BencodeBuilder.encode(bytes: pieces),
        ]
        return BencodeBuilder.encode(dictionary: ["info": BencodeBuilder.encode(dictionary: info)])
    }

    public static func multiFile(files: [(String, Int64)], pieceLength: Int64 = 256, piecesCount: Int = 1, name: String = "fixture-dir", trackers: [String] = ["udp://tracker.example:80/announce"]) -> Data {
        let totalSize = files.reduce(Int64(0)) { $0 + $1.1 }
        let requiredPieces = totalSize > 0 && pieceLength > 0
            ? Int((totalSize + pieceLength - 1) / pieceLength)
            : 0
        let effectivePieces = piecesCount == 0 ? 0 : max(piecesCount, requiredPieces)
        var entries: [Data] = []
        for (path, size) in files {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let info: [String: Data] = [
                "length": BencodeBuilder.encode(integer: size),
                "path": BencodeBuilder.encode(list: parts.map { BencodeBuilder.encode(string: $0) }),
            ]
            entries.append(BencodeBuilder.encode(dictionary: info))
        }
        let info: [String: Data] = [
            "name": BencodeBuilder.encode(string: name),
            "files": BencodeBuilder.encode(list: entries),
            "piece length": BencodeBuilder.encode(integer: pieceLength),
            "pieces": BencodeBuilder.encode(bytes: BencodeBuilder.pieceHashes(count: effectivePieces * 20)),
        ]
        var top: [String: Data] = ["info": BencodeBuilder.encode(dictionary: info)]
        if let announce = trackers.first {
            top["announce"] = BencodeBuilder.encode(string: announce)
        }
        return BencodeBuilder.encode(dictionary: top)
    }

    public static var withoutPieceLength: Data {
        let info: [String: Data] = [
            "name": BencodeBuilder.encode(string: "x.bin"),
            "length": BencodeBuilder.encode(integer: 10),
            "pieces": BencodeBuilder.encode(bytes: BencodeBuilder.pieceHashes(count: 20)),
        ]
        return BencodeBuilder.encode(dictionary: ["info": BencodeBuilder.encode(dictionary: info)])
    }

    public static var withoutName: Data {
        let info: [String: Data] = [
            "length": BencodeBuilder.encode(integer: 10),
            "piece length": BencodeBuilder.encode(integer: 16),
            "pieces": BencodeBuilder.encode(bytes: BencodeBuilder.pieceHashes(count: 20)),
        ]
        return BencodeBuilder.encode(dictionary: ["info": BencodeBuilder.encode(dictionary: info)])
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}
