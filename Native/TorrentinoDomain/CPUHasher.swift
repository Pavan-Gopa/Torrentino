// Layer: Domain (Hashing)
// Role: Production CPU piece hashing engine for v1, v2, and hybrid torrent
// creation (BEP-3 + BEP-52). Single read epoch per source: each file is read
// once and feeds both the v1 SHA-1 piece stream (with BEP-47 padding for
// hybrid multi-file alignment) and the v2 16 KiB block hashes for the merkle
// tree. Short final blocks are hashed over their REAL bytes (BEP-52 §piece
// layers: the tree is padded with zero hashes, never with zero bytes).
// Must-not: block main actor, follow symlinks, skip source identity checks,
// or retain partial data on cancel.
// Invariants: source identity (inode, size, mtime) checked before read, after
// each file, and once more over the whole manifest after hashing; v2 piece
// layers are emitted only for files larger than the piece length and contain
// only layer hashes covering real bytes.

import Foundation
import CommonCrypto
#if canImport(TorrentinoIPC)
import TorrentinoIPC
#endif
import Darwin

public actor CPUHasher {
    public init() {}

    public func hash(
        scannedFiles: [ScannedFileEntry],
        pieceSizeBytes: Int64,
        format: TorrentFormat,
        cancelCheck: @Sendable () throws -> Void = {},
        onProgress: @Sendable (Int64, Int64, Int, Int) async -> Void
    ) async throws -> HashingResult {
        guard !scannedFiles.isEmpty else {
            throw HasherError.hashingFailed("no files to hash")
        }

        let isV1Needed = format == .v1 || format == .hybrid
        let isV2Needed = format == .v2 || format == .hybrid

        guard SourceScanner.isValidPieceSize(pieceSizeBytes) else {
            throw HasherError.hashingFailed("invalid piece length: \(pieceSizeBytes)")
        }

        // BEP-52: the piece length must be a multiple of the 16 KiB block size.
        if isV2Needed {
            guard pieceSizeBytes >= CreatorLayout.v2BlockSize,
                  pieceSizeBytes % CreatorLayout.v2BlockSize == 0,
                  SourceScanner.isValidPieceSize(pieceSizeBytes) else {
                throw HasherError.hashingFailed(
                    "v2 requires a piece length that is a multiple of \(CreatorLayout.v2BlockSize) bytes"
                )
            }
        }

        // All creator stages use the same raw UTF-8 path order. Swift String
        // ordering is not the bencode byte order for every Unicode spelling;
        // sorting here closes that hybrid v1/v2 ordering mismatch even when a
        // caller bypasses SourceScanner in a test or future backend.
        let orderedFiles = scannedFiles.sorted {
            Data($0.relativePath.utf8).lexicographicallyPrecedes(Data($1.relativePath.utf8))
        }
        let padding = CreatorLayout.v1PaddingBytes(files: orderedFiles, pieceSizeBytes: pieceSizeBytes, format: format)
        let totalBytes = CreatorLayout.v1AddressSpaceBytes(files: orderedFiles, padding: padding)
        guard totalBytes != Int64.max else {
            throw HasherError.hashingFailed("source address space exceeds 64-bit limit")
        }

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
        let totalFilesCount = orderedFiles.count

        let readBufferSize = 64 * 1024 // 64 KiB read buffer

        for (fileIndex, fileEntry) in orderedFiles.enumerated() {
            try cancelCheck()
            try Task.checkCancellation()

            let filePath = fileEntry.fullPath

            // Open without following a symlink and then use fstat on this
            // descriptor for both identity checks. Checking the path before
            // opening and reading it later leaves a replacement window; the
            // descriptor binds the one read epoch to the object we inspected.
            let fileDescriptor = open(filePath, O_RDONLY | O_NOFOLLOW)
            guard fileDescriptor >= 0 else {
                let openError = errno
                if openError == ENOENT {
                    throw HasherError.fileNotFound(fileEntry.relativePath)
                }
                throw HasherError.unreadableFile(fileEntry.relativePath)
            }
            var descriptorOpen = true
            func closeDescriptor() throws {
                guard descriptorOpen else { return }
                let result = Darwin.close(fileDescriptor)
                descriptorOpen = false
                guard result == 0 else {
                    throw HasherError.hashingFailed("close failed for \(fileEntry.relativePath) (errno \(errno))")
                }
            }
            func matchesExpectedIdentity(_ value: stat) -> Bool {
                UInt64(value.st_dev) == fileEntry.deviceID
                    && UInt64(value.st_ino) == fileEntry.fileResourceID
                    && Int64(value.st_size) == fileEntry.sizeBytes
                    && Int64(value.st_mtimespec.tv_sec) == fileEntry.mtimeSeconds
                    && Int64(value.st_mtimespec.tv_nsec) == fileEntry.mtimeNanos
            }

            do {
                // Pre-read validation (§15.4 invariant), on the opened object.
                var preStat = stat()
                guard fstat(fileDescriptor, &preStat) == 0 else {
                    throw HasherError.fileNotFound(fileEntry.relativePath)
                }
                guard matchesExpectedIdentity(preStat) else {
                    throw HasherError.sourceModified(fileEntry.relativePath)
                }

                if fileEntry.sizeBytes == 0 {
                    // Zero-byte files contribute nothing to either address
                    // space (BEP-52: no pieces root, no piece layers) but
                    // still get the full identity check on the same fd.
                    var postStat = stat()
                    guard fstat(fileDescriptor, &postStat) == 0,
                          matchesExpectedIdentity(postStat) else {
                        throw HasherError.sourceModified(fileEntry.relativePath)
                    }
                    try closeDescriptor()
                    totalFilesHashed += 1
                    await onProgress(totalBytesHashed, totalBytes, totalFilesHashed, totalFilesCount)
                    continue
                }

            // v2 16 KiB block hashes for Merkle tree (short final block is
            // hashed over its real bytes — no zero padding of block data).
            var v2BlockHashes: [Data] = []
            var v2BlockStart: Int = 0
            var v2BlockBuffer = Data()

            var fileBytesRead: Int64 = 0

            while fileBytesRead < fileEntry.sizeBytes {
                try cancelCheck()
                try Task.checkCancellation()

                let toRead = Int(min(Int64(readBufferSize), fileEntry.sizeBytes - fileBytesRead))
                var rawBuffer = [UInt8](repeating: 0, count: toRead)
                let readCount = rawBuffer.withUnsafeMutableBytes { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return -1 }
                    return Darwin.read(fileDescriptor, baseAddress, toRead)
                }
                guard readCount > 0 else {
                    throw HasherError.sourceModified(fileEntry.relativePath)
                }
                let chunk = Data(bytes: rawBuffer, count: readCount)

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
                            finalizeV1Piece(&v1PiecesData, &v1Ctx)
                            currentV1PieceBytes = 0
                        }
                    }
                }

                // Process v2 16 KiB blocks for Merkle tree
                if isV2Needed {
                    v2BlockBuffer.append(chunk)
                    let blockSize = Int(CreatorLayout.v2BlockSize)
                    while v2BlockStart + blockSize <= v2BlockBuffer.count {
                        let blockData = v2BlockBuffer.subdata(in: v2BlockStart..<(v2BlockStart + blockSize))
                        v2BlockHashes.append(Self.sha256(blockData))
                        v2BlockStart += blockSize
                    }
                    if v2BlockStart > 0 {
                        // Data.removeFirst leaves a non-zero internal
                        // startIndex, so a later 0-based subdata traps
                        // (EXC_BREAKPOINT in Data._Representation.subscript).
                        // Re-base via dropFirst — same fix as CPUReference.
                        v2BlockBuffer = Data(v2BlockBuffer.dropFirst(v2BlockStart))
                        v2BlockStart = 0
                    }
                }

                await onProgress(totalBytesHashed, totalBytes, totalFilesHashed, totalFilesCount)
            }

            // Short final v2 block: hash the REAL bytes (BEP-52), no padding.
            if isV2Needed && !v2BlockBuffer.isEmpty {
                v2BlockHashes.append(Self.sha256(v2BlockBuffer))
                v2BlockBuffer.removeAll()
            }

            // Post-read validation (§15.4 invariant), still on the opened
            // descriptor, closes the read epoch before any hash is published.
            var postStat = stat()
            guard fstat(fileDescriptor, &postStat) == 0,
                  matchesExpectedIdentity(postStat) else {
                throw HasherError.sourceModified(fileEntry.relativePath)
            }

            // Build v2 Merkle Tree for this file
            if isV2Needed {
                let treeResult = Self.buildV2MerkleTree(
                    leafHashes: v2BlockHashes,
                    blocksPerPiece: Int(pieceSizeBytes / CreatorLayout.v2BlockSize)
                )
                // BEP-52: piece layers exist only when the file spans more
                // than one piece; a single-piece file is fully identified by
                // its root.
                let pieceLayers = fileEntry.sizeBytes > pieceSizeBytes ? treeResult.pieceLayers : Data()
                v2FileTrees[fileEntry.relativePath] = V2FileTreeEntry(
                    piecesRoot: treeResult.root,
                    pieceLayers: pieceLayers,
                    sizeBytes: fileEntry.sizeBytes
                )
            }

            totalFilesHashed += 1
            try closeDescriptor()
            await onProgress(totalBytesHashed, totalBytes, totalFilesHashed, totalFilesCount)

            // Feed the v1 alignment padding for hybrid multi-file torrents.
            if isV1Needed, fileIndex < padding.count, padding[fileIndex] > 0 {
                try feedV1Zeros(
                    padding[fileIndex],
                    pieceSizeBytes: pieceSizeBytes,
                    pieces: &v1PiecesData,
                    ctx: &v1Ctx,
                    currentPieceBytes: &currentV1PieceBytes,
                    totalBytesHashed: &totalBytesHashed,
                    cancelCheck: cancelCheck
                )
                await onProgress(totalBytesHashed, totalBytes, totalFilesHashed, totalFilesCount)
            }
            } catch {
                if descriptorOpen {
                    let closeResult = Darwin.close(fileDescriptor)
                    descriptorOpen = false
                    if closeResult != 0 {
                        throw HasherError.hashingFailed("close failed for \(fileEntry.relativePath) (errno \(errno))")
                    }
                }
                throw error
            }
        }

        // Finalize trailing v1 piece if last piece was partial
        if isV1Needed && currentV1PieceBytes > 0 {
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            CC_SHA1_Final(&digest, &v1Ctx)
            v1PiecesData.append(contentsOf: digest)
        }

        // Whole-manifest post-hash validation (§15.4): a modification of any
        // file (including ones hashed earlier) aborts the creation.
        try cancelCheck()
        for fileEntry in orderedFiles {
            try Task.checkCancellation()
            var manifestStat = stat()
            if lstat(fileEntry.fullPath, &manifestStat) != 0
                || UInt64(manifestStat.st_dev) != fileEntry.deviceID
                || UInt64(manifestStat.st_ino) != fileEntry.fileResourceID
                || Int64(manifestStat.st_size) != fileEntry.sizeBytes
                || Int64(manifestStat.st_mtimespec.tv_sec) != fileEntry.mtimeSeconds
                || Int64(manifestStat.st_mtimespec.tv_nsec) != fileEntry.mtimeNanos {
                throw HasherError.sourceModified(fileEntry.relativePath)
            }
        }

        return HashingResult(
            v1PiecesData: v1PiecesData,
            v2FileTrees: v2FileTrees,
            totalBytesHashed: totalBytesHashed,
            totalFilesHashed: totalFilesHashed
        )
    }

    // MARK: - v1 stream helpers

    private func finalizeV1Piece(_ pieces: inout Data, _ ctx: inout CC_SHA1_CTX) {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1_Final(&digest, &ctx)
        pieces.append(contentsOf: digest)
        CC_SHA1_Init(&ctx)
    }

    /// Feeds `count` zero bytes into the v1 SHA-1 piece stream (hybrid
    /// alignment padding), finalizing pieces at each boundary.
    private func feedV1Zeros(
        _ count: Int64,
        pieceSizeBytes: Int64,
        pieces: inout Data,
        ctx: inout CC_SHA1_CTX,
        currentPieceBytes: inout Int64,
        totalBytesHashed: inout Int64,
        cancelCheck: @Sendable () throws -> Void
    ) throws {
        let zeroBuffer = Data(repeating: 0, count: 64 * 1024)
        var remaining = count
        while remaining > 0 {
            try cancelCheck()
            let toFeed = Int(min(Int64(zeroBuffer.count), remaining))
            let slice = zeroBuffer.subdata(in: 0..<toFeed)
            slice.withUnsafeBytes { ptr in
                if let baseAddress = ptr.baseAddress {
                    CC_SHA1_Update(&ctx, baseAddress, CC_LONG(toFeed))
                }
            }
            remaining -= Int64(toFeed)
            currentPieceBytes += Int64(toFeed)
            if currentPieceBytes == pieceSizeBytes {
                finalizeV1Piece(&pieces, &ctx)
                currentPieceBytes = 0
            }
        }
        totalBytesHashed += count
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

    /// Builds the file's merkle tree from the per-block hashes. `leafHashes`
    /// holds one hash per 16 KiB block (the last one may cover a short block
    /// of real bytes). The tree is padded to the next power of two with zero
    /// hashes; the piece layer is the layer at height log2(blocksPerPiece)
    /// and only its leading hashes (those covering real bytes) are kept.
    private static func buildV2MerkleTree(leafHashes: [Data], blocksPerPiece: Int) -> MerkleTreeBuildResult {
        let numLeaves = leafHashes.count
        guard numLeaves > 0 else {
            return MerkleTreeBuildResult(root: Data(repeating: 0, count: 32), pieceLayers: Data())
        }

        let zeroHash = Data(repeating: 0, count: 32)

        // Next power of 2 for leaf count (padded with zero hashes).
        var targetLeafCount = 1
        while targetLeafCount < numLeaves {
            targetLeafCount *= 2
        }

        var layer = leafHashes
        layer.append(contentsOf: Array(repeating: zeroHash, count: targetLeafCount - numLeaves))

        var pieceLayerHashes: [Data] = []
        // Piece layer height: log2(blocksPerPiece). Piece sizes are powers of
        // two (≥ 16 KiB), so this is exact.
        var pieceLayerHeight = 0
        var remainingBlocksPerPiece = blocksPerPiece
        while remainingBlocksPerPiece > 1 {
            pieceLayerHeight += 1
            remainingBlocksPerPiece /= 2
        }

        var height = 0
        // A piece layer at height 0 (piece length == block size) IS the leaf
        // layer: capture the real leaves before the combine loop rewrites it.
        let realPieceCount = (numLeaves + blocksPerPiece - 1) / blocksPerPiece
        if pieceLayerHeight == 0 {
            pieceLayerHashes = Array(layer.prefix(realPieceCount))
        }
        while layer.count > 1 {
            height += 1
            var nextLayer: [Data] = []
            nextLayer.reserveCapacity(layer.count / 2)
            for i in stride(from: 0, to: layer.count, by: 2) {
                nextLayer.append(combineSHA256(layer[i], layer[i + 1]))
            }
            layer = nextLayer

            if height == pieceLayerHeight {
                // Only hashes covering real bytes belong in the piece layers
                // (BEP-52: layer hashes that cover only beyond-end data are
                // omitted).
                pieceLayerHashes = Array(layer.prefix(realPieceCount))
            }
        }

        let root = layer.first ?? zeroHash
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
