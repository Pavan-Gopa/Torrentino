// Layer: Domain (Hashing)
// Role: Production CPU piece hashing engine for v1, v2, and hybrid torrent creation.
// Must-not: block main actor, follow symlinks, skip source identity checks, or retain partial data on cancel.
// Invariants: single read epoch for hybrid; source identity (inode, size, mtime) checked before and after read.

import Foundation
import CommonCrypto
import TorrentinoIPC

public actor CPUHasher {
    public init() {}

    public func hash(
        scannedFiles: [ScannedFileEntry],
        totalBytes: Int64,
        pieceSizeBytes: Int64,
        format: TorrentFormat,
        onProgress: @Sendable (Int64, Int64, Int, Int) -> Void
    ) async throws -> HashingResult {
        guard !scannedFiles.isEmpty else {
            throw HasherError.hashingFailed("no files to hash")
        }

        let isV1Needed = format == .v1 || format == .hybrid
        let isV2Needed = format == .v2 || format == .hybrid

        var v1PiecesData = Data()
        var v2FileTrees: [String: V2FileTreeEntry] = [:]

        // Ongoing v1 piece SHA-1 context
        var v1Ctx = CC_SHA1_CTX()
        if isV1Needed {
            CC_SHA1_Init(&v1Ctx)
        }
        var currentV1PieceBytes: Int64 = 0

        var totalBytesHashed: Int64 = 0
        var totalFilesHashed = 0
        let totalFilesCount = scannedFiles.count

        let readBufferSize = 64 * 1024 // 64 KiB read buffer

        for fileEntry in scannedFiles {
            try Task.checkCancellation()

            let filePath = fileEntry.fullPath

            // Pre-read validation (§15.4 invariant)
            var preStat = stat()
            if lstat(filePath, &preStat) != 0 {
                throw HasherError.fileNotFound(fileEntry.relativePath)
            }
            guard UInt64(preStat.st_ino) == fileEntry.fileResourceID,
                  Int64(preStat.st_size) == fileEntry.sizeBytes,
                  Int64(preStat.st_mtimespec.tv_sec) == fileEntry.mtimeSeconds,
                  Int64(preStat.st_mtimespec.tv_nsec) == fileEntry.mtimeNanos else {
                throw HasherError.sourceModified(fileEntry.relativePath)
            }

            if fileEntry.sizeBytes == 0 {
                // Zero-byte file handling
                if isV2Needed {
                    let zeroRoot = Data(repeating: 0, count: 32)
                    v2FileTrees[fileEntry.relativePath] = V2FileTreeEntry(
                        piecesRoot: zeroRoot,
                        pieceLayers: Data(),
                        sizeBytes: 0
                    )
                }
                totalFilesHashed += 1
                onProgress(totalBytesHashed, totalBytes, totalFilesHashed, totalFilesCount)
                continue
            }

            guard let handle = FileHandle(forReadingAtPath: filePath) else {
                throw HasherError.unreadableFile(fileEntry.relativePath)
            }

            defer {
                try? handle.close()
            }

            // v2 16 KiB block hashes for Merkle tree
            var v2BlockHashes: [Data] = []
            var currentV2BlockData = Data()
            let v2BlockSize = 16 * 1024 // 16 KiB BEP-52 block size

            var fileBytesRead: Int64 = 0

            while fileBytesRead < fileEntry.sizeBytes {
                try Task.checkCancellation()

                let toRead = Int(min(Int64(readBufferSize), fileEntry.sizeBytes - fileBytesRead))
                guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else {
                    throw HasherError.sourceModified(fileEntry.relativePath)
                }

                fileBytesRead += Int64(chunk.count)
                totalBytesHashed += Int64(chunk.count)

                // Process v1 SHA-1
                if isV1Needed {
                    var chunkOffset = 0
                    while chunkOffset < chunk.count {
                        let bytesNeededForV1Piece = Int(pieceSizeBytes - currentV1PieceBytes)
                        let bytesToFeed = min(bytesNeededForV1Piece, chunk.count - chunkOffset)

                        let subChunk = chunk.subdata(in: chunkOffset..<(chunkOffset + bytesToFeed))
                        subChunk.withUnsafeBytes { ptr in
                            if let baseAddress = ptr.baseAddress {
                                CC_SHA1_Update(&v1Ctx, baseAddress, CC_LONG(bytesToFeed))
                            }
                        }

                        currentV1PieceBytes += Int64(bytesToFeed)
                        chunkOffset += bytesToFeed

                        if currentV1PieceBytes == pieceSizeBytes {
                            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
                            CC_SHA1_Final(&digest, &v1Ctx)
                            v1PiecesData.append(contentsOf: digest)

                            // Reset context for next v1 piece
                            CC_SHA1_Init(&v1Ctx)
                            currentV1PieceBytes = 0
                        }
                    }
                }

                // Process v2 16 KiB blocks for Merkle tree
                if isV2Needed {
                    currentV2BlockData.append(chunk)
                    while currentV2BlockData.count >= v2BlockSize {
                        let blockData = currentV2BlockData.prefix(v2BlockSize)
                        v2BlockHashes.append(Self.sha256(blockData))
                        currentV2BlockData.removeFirst(v2BlockSize)
                    }
                }

                onProgress(totalBytesHashed, totalBytes, totalFilesHashed, totalFilesCount)
            }

            // Finalize remaining v2 block for this file if file end was not aligned to 16 KiB
            if isV2Needed && !currentV2BlockData.isEmpty {
                var paddedBlock = currentV2BlockData
                paddedBlock.append(Data(repeating: 0, count: v2BlockSize - currentV2BlockData.count))
                v2BlockHashes.append(Self.sha256(paddedBlock))
                currentV2BlockData.removeAll()
            }

            // Post-read validation (§15.4 invariant)
            var postStat = stat()
            if lstat(filePath, &postStat) != 0 {
                throw HasherError.sourceModified(fileEntry.relativePath)
            }
            guard UInt64(postStat.st_ino) == fileEntry.fileResourceID,
                  Int64(postStat.st_size) == fileEntry.sizeBytes,
                  Int64(postStat.st_mtimespec.tv_sec) == fileEntry.mtimeSeconds,
                  Int64(postStat.st_mtimespec.tv_nsec) == fileEntry.mtimeNanos else {
                throw HasherError.sourceModified(fileEntry.relativePath)
            }

            // Build v2 Merkle Tree for this file
            if isV2Needed {
                let treeResult = Self.buildV2MerkleTree(
                    leafHashes: v2BlockHashes,
                    pieceSizeBytes: pieceSizeBytes
                )
                v2FileTrees[fileEntry.relativePath] = V2FileTreeEntry(
                    piecesRoot: treeResult.root,
                    pieceLayers: treeResult.pieceLayers,
                    sizeBytes: fileEntry.sizeBytes
                )
            }

            totalFilesHashed += 1
            onProgress(totalBytesHashed, totalBytes, totalFilesHashed, totalFilesCount)
        }

        // Finalize trailing v1 piece if last piece was partial
        if isV1Needed && currentV1PieceBytes > 0 {
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            CC_SHA1_Final(&digest, &v1Ctx)
            v1PiecesData.append(contentsOf: digest)
        }

        return HashingResult(
            v1PiecesData: v1PiecesData,
            v1InfoHash: nil,
            v2FileTrees: v2FileTrees,
            totalBytesHashed: totalBytesHashed,
            totalFilesHashed: totalFilesHashed
        )
    }

    // MARK: - Crypto Helpers

    public static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                CC_SHA256(baseAddress, CC_LONG(data.count), &digest)
            }
        }
        return Data(digest)
    }

    private static func combineSHA256(_ left: Data, _ right: Data) -> Data {
        var combined = Data()
        combined.reserveCapacity(64)
        combined.append(left)
        combined.append(right)
        return sha256(combined)
    }

    // MARK: - v2 Merkle Tree Builder (BEP-52)

    private struct MerkleTreeBuildResult {
        let root: Data
        let pieceLayers: Data
    }

    private static func buildV2MerkleTree(leafHashes: [Data], pieceSizeBytes: Int64) -> MerkleTreeBuildResult {
        guard !leafHashes.isEmpty else {
            return MerkleTreeBuildResult(
                root: Data(repeating: 0, count: 32),
                pieceLayers: Data()
            )
        }

        let numLeaves = leafHashes.count
        let blocksPerPiece = Int(max(1, pieceSizeBytes / (16 * 1024)))

        // Next power of 2 for leaf count
        var targetLeafCount = 1
        while targetLeafCount < numLeaves {
            targetLeafCount *= 2
        }

        let zeroHash = Data(repeating: 0, count: 32)
        var currentLayer = leafHashes
        while currentLayer.count < targetLeafCount {
            currentLayer.append(zeroHash)
        }

        var pieceLayerHashes: [Data] = []
        let isPieceLayer = blocksPerPiece == 1

        if isPieceLayer {
            pieceLayerHashes = Array(leafHashes)
        }

        var currentBlockCount = targetLeafCount

        while currentLayer.count > 1 {
            var nextLayer: [Data] = []
            nextLayer.reserveCapacity(currentLayer.count / 2)

            for i in stride(from: 0, to: currentLayer.count, by: 2) {
                let parent = combineSHA256(currentLayer[i], currentLayer[i + 1])
                nextLayer.append(parent)
            }

            currentLayer = nextLayer
            currentBlockCount /= 2

            // Check if this layer corresponds to pieceSizeBytes layer
            if currentBlockCount == (targetLeafCount / blocksPerPiece) && !isPieceLayer {
                // Collect piece layer hashes for real pieces only
                let realPieceCount = (numLeaves + blocksPerPiece - 1) / blocksPerPiece
                pieceLayerHashes = Array(currentLayer.prefix(realPieceCount))
            }
        }

        let root = currentLayer.first ?? zeroHash
        var concatenatedPieceLayers = Data()
        for hash in pieceLayerHashes {
            concatenatedPieceLayers.append(hash)
        }

        return MerkleTreeBuildResult(
            root: root,
            pieceLayers: concatenatedPieceLayers
        )
    }
}
