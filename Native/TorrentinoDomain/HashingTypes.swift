// Layer: Domain
// Role: Hashing types for BitTorrent v1, v2, and hybrid torrent creation.
// Must-not: hold mutable reference state or non-Sendable C++ handles.
// Invariants: immutable Sendable values; hashes represented as raw Data.

import Foundation
import TorrentinoIPC

public struct MerkleNode: Sendable, Equatable {
    public let hash: Data // 32 bytes SHA-256

    public init(hash: Data) {
        self.hash = hash
    }
}

public struct V2FileTreeEntry: Sendable, Equatable {
    public let piecesRoot: Data // 32 bytes SHA-256 Merkle root
    public let pieceLayers: Data // Concatenated 32-byte SHA-256 hashes of piece_length layers
    public let sizeBytes: Int64

    public init(piecesRoot: Data, pieceLayers: Data, sizeBytes: Int64) {
        self.piecesRoot = piecesRoot
        self.pieceLayers = pieceLayers
        self.sizeBytes = sizeBytes
    }
}

public struct HashingResult: Sendable, Equatable {
    /// Concatenated 20-byte SHA-1 piece hashes for v1
    public let v1PiecesData: Data
    /// v1 InfoHash (SHA-1 of exact bencoded info dict) computed after bencoding
    public var v1InfoHash: Data?
    /// v2 file tree entries keyed by relative path
    public let v2FileTrees: [String: V2FileTreeEntry]
    public let totalBytesHashed: Int64
    public let totalFilesHashed: Int

    public init(
        v1PiecesData: Data,
        v1InfoHash: Data? = nil,
        v2FileTrees: [String: V2FileTreeEntry] = [:],
        totalBytesHashed: Int64,
        totalFilesHashed: Int
    ) {
        self.v1PiecesData = v1PiecesData
        self.v1InfoHash = v1InfoHash
        self.v2FileTrees = v2FileTrees
        self.totalBytesHashed = totalBytesHashed
        self.totalFilesHashed = totalFilesHashed
    }
}

public enum HasherError: Error, Sendable, Equatable, CustomStringConvertible {
    case fileNotFound(String)
    case unreadableFile(String)
    case sourceModified(String)
    case cancelled
    case hashingFailed(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path): return "file not found during hashing: \(path)"
        case .unreadableFile(let path): return "file unreadable during hashing: \(path)"
        case .sourceModified(let path): return "source file modified during hashing: \(path)"
        case .cancelled: return "hashing operation cancelled"
        case .hashingFailed(let msg): return "hashing failed: \(msg)"
        }
    }
}
