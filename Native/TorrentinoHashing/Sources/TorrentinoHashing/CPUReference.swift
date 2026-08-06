// Layer: Hashing research (WP-12)
// Role: independent CPU reference implementation of the v1/v2/hybrid piece
// hashing pipeline. This is a faithful port of the production hashing core
// (Native/TorrentinoDomain/CPUHasher.swift — CommonCrypto SHA-1/SHA-256,
// single read epoch, descriptor-anchored identity checks, BEP-47 padding for
// hybrid multi-file alignment, BEP-52 merkle tree with zero-hash padding).
// Why: the TorrentinoHashing package must not depend on the Xcode-only
// TorrentinoDomain framework; the bit-for-bit gate compares GPU output against
// this reference first, and the QA suite re-verifies the produced torrents
// against the pinned libtorrent (independent BEP validator).
// Invariants: identical digest semantics to the production CPUHasher; no
// Metal objects; all digest output byte-for-byte equal to CommonCrypto.

import CommonCrypto
import Darwin
import Foundation

public struct CPUReferenceHasher: Sendable {
    public init() {}

    public func hash(
        scannedFiles: [HashSourceFile],
        pieceSizeBytes: Int64,
        format: ResearchFormat,
        cancelCheck: @Sendable () throws -> Void = {},
        onProgress: @Sendable (Int64, Int64, Int, Int) async -> Void = { _, _, _, _ in }
    ) async throws -> HashingOutput {
        guard !scannedFiles.isEmpty else {
            throw ResearchHasherError.hashingFailed("no files to hash")
        }
        guard isValidPieceSize(pieceSizeBytes) else {
            throw ResearchHasherError.hashingFailed("invalid piece length: \(pieceSizeBytes)")
        }
        if format.isV2Needed {
            guard pieceSizeBytes >= Self.v2BlockSize,
                  pieceSizeBytes % Self.v2BlockSize == 0,
                  isValidPieceSize(pieceSizeBytes) else {
                throw ResearchHasherError.hashingFailed(
                    "v2 requires a piece length that is a multiple of \(Self.v2BlockSize) bytes"
                )
            }
        }

        // Same raw UTF-8 path order as the production creator.
        let orderedFiles = scannedFiles.sorted {
            Data($0.relativePath.utf8).lexicographicallyPrecedes(Data($1.relativePath.utf8))
        }
        let padding = v1PaddingBytes(files: orderedFiles, pieceSizeBytes: pieceSizeBytes, format: format)
        let totalBytes = v1AddressSpaceBytes(files: orderedFiles, padding: padding)

        var v1PiecesData = Data()
        var v2FileTrees: [String: V2FileTreeEntry] = [:]

        var v1Ctx = CC_SHA1_CTX()
        if format.isV1Needed {
            CC_SHA1_Init(&v1Ctx)
        }
        var currentV1PieceBytes: Int64 = 0
        var totalBytesHashed: Int64 = 0
        var totalFilesHashed = 0
        let totalFilesCount = orderedFiles.count

        let readBufferSize = 64 * 1024

        for (fileIndex, fileEntry) in orderedFiles.enumerated() {
            try cancelCheck()
            try Task.checkCancellation()

            let fileDescriptor = open(fileEntry.fullPath, O_RDONLY | O_NOFOLLOW)
            guard fileDescriptor >= 0 else {
                let openError = errno
                if openError == ENOENT {
                    throw ResearchHasherError.fileNotFound(fileEntry.relativePath)
                }
                throw ResearchHasherError.unreadableFile(fileEntry.relativePath)
            }
            var descriptorOpen = true
            func closeDescriptor() throws {
                guard descriptorOpen else { return }
                let result = Darwin.close(fileDescriptor)
                descriptorOpen = false
                guard result == 0 else {
                    throw ResearchHasherError.hashingFailed("close failed for \(fileEntry.relativePath) (errno \(errno))")
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
                var preStat = stat()
                guard fstat(fileDescriptor, &preStat) == 0 else {
                    throw ResearchHasherError.fileNotFound(fileEntry.relativePath)
                }
                guard matchesExpectedIdentity(preStat) else {
                    throw ResearchHasherError.sourceModified(fileEntry.relativePath)
                }

                if fileEntry.sizeBytes == 0 {
                    var postStat = stat()
                    guard fstat(fileDescriptor, &postStat) == 0,
                          matchesExpectedIdentity(postStat) else {
                        throw ResearchHasherError.sourceModified(fileEntry.relativePath)
                    }
                    try closeDescriptor()
                    totalFilesHashed += 1
                    await onProgress(totalBytesHashed, totalBytes, totalFilesHashed, totalFilesCount)
                    continue
                }

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
                        throw ResearchHasherError.sourceModified(fileEntry.relativePath)
                    }
                    let chunk = Data(bytes: rawBuffer, count: readCount)

                    fileBytesRead += Int64(chunk.count)
                    totalBytesHashed += Int64(chunk.count)

                    if format.isV1Needed {
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

                    if format.isV2Needed {
                        v2BlockBuffer.append(chunk)
                        let blockSize = Int(Self.v2BlockSize)
                        while v2BlockStart + blockSize <= v2BlockBuffer.count {
                            let blockData = v2BlockBuffer.subdata(in: v2BlockStart..<(v2BlockStart + blockSize))
                            v2BlockHashes.append(Self.sha256(blockData))
                            v2BlockStart += blockSize
                        }
                        if v2BlockStart > 0 {
                            // Data.removeFirst leaves a non-zero internal
                            // startIndex, breaking 0-based subdata; re-basing
                            // via dropFirst keeps indices 0-based.
                            v2BlockBuffer = Data(v2BlockBuffer.dropFirst(v2BlockStart))
                            v2BlockStart = 0
                        }
                    }

                    await onProgress(totalBytesHashed, totalBytes, totalFilesHashed, totalFilesCount)
                }

                if format.isV2Needed && !v2BlockBuffer.isEmpty {
                    v2BlockHashes.append(Self.sha256(v2BlockBuffer))
                    v2BlockBuffer.removeAll()
                }

                var postStat = stat()
                guard fstat(fileDescriptor, &postStat) == 0,
                      matchesExpectedIdentity(postStat) else {
                    throw ResearchHasherError.sourceModified(fileEntry.relativePath)
                }

                if format.isV2Needed {
                    let treeResult = Self.buildV2MerkleTree(
                        leafHashes: v2BlockHashes,
                        blocksPerPiece: Int(pieceSizeBytes / Self.v2BlockSize)
                    )
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

                if format.isV1Needed, fileIndex < padding.count, padding[fileIndex] > 0 {
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
                        throw ResearchHasherError.hashingFailed("close failed for \(fileEntry.relativePath) (errno \(errno))")
                    }
                }
                throw error
            }
        }

        if format.isV1Needed && currentV1PieceBytes > 0 {
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            CC_SHA1_Final(&digest, &v1Ctx)
            v1PiecesData.append(contentsOf: digest)
        }

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
                throw ResearchHasherError.sourceModified(fileEntry.relativePath)
            }
        }

        return HashingOutput(
            v1PiecesData: v1PiecesData,
            v2FileTrees: v2FileTrees,
            totalBytesHashed: totalBytesHashed,
            totalFilesHashed: Int64(totalFilesHashed)
        )
    }

    // MARK: - v1 stream helpers

    private func finalizeV1Piece(_ pieces: inout Data, _ ctx: inout CC_SHA1_CTX) {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1_Final(&digest, &ctx)
        pieces.append(contentsOf: digest)
        CC_SHA1_Init(&ctx)
    }

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
            // Bound each feed to the current piece remainder: padding length
            // can cross a piece boundary, and an unbounded feed would push
            // currentPieceBytes past pieceSizeBytes (matching the production
            // hasher's boundary semantics: pieces finalize at every boundary).
            let pieceRemainder = pieceSizeBytes - currentPieceBytes
            let toFeed = Int(min(Int64(zeroBuffer.count), min(remaining, pieceRemainder)))
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

    // MARK: - Layout (BEP-3 / BEP-47)

    public static let v2BlockSize: Int64 = 16 * 1024

    private func isValidPieceSize(_ size: Int64) -> Bool {
        size >= 16 * 1024 && size <= 64 * 1024 * 1024
    }

    /// BEP-47: multi-file v1/hybrid alignment padding per file, in file order.
    public func v1PaddingBytes(files: [HashSourceFile], pieceSizeBytes: Int64, format: ResearchFormat) -> [Int64] {
        guard files.count > 1, format.isV1Needed else { return Array(repeating: 0, count: files.count) }
        var padding: [Int64] = []
        var cumulative: Int64 = 0
        for file in files {
            let aligned = (cumulative + pieceSizeBytes - 1) / pieceSizeBytes * pieceSizeBytes
            let pad = aligned - cumulative
            padding.append(pad)
            cumulative += file.sizeBytes + pad
        }
        return padding
    }

    /// Total v1 address space: file bytes plus alignment padding.
    public func v1AddressSpaceBytes(files: [HashSourceFile], padding: [Int64]) -> Int64 {
        var total: Int64 = 0
        for (index, file) in files.enumerated() {
            total += file.sizeBytes
            if index < padding.count {
                total += padding[index]
            }
        }
        return total
    }

    // MARK: - Crypto helpers

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

    // MARK: - v2 Merkle tree (BEP-52)

    private struct MerkleTreeBuildResult {
        let root: Data
        let pieceLayers: Data
    }

    /// Identical algorithm to the production CPUHasher.buildV2MerkleTree.
    public static func buildV2MerkleTree(leafHashes: [Data], blocksPerPiece: Int) -> (root: Data, pieceLayers: Data) {
        let numLeaves = leafHashes.count
        guard numLeaves > 0 else {
            return (Data(repeating: 0, count: 32), Data())
        }

        let zeroHash = Data(repeating: 0, count: 32)
        var targetLeafCount = 1
        while targetLeafCount < numLeaves {
            targetLeafCount *= 2
        }

        var layer = leafHashes
        layer.append(contentsOf: Array(repeating: zeroHash, count: targetLeafCount - numLeaves))

        var pieceLayerHashes: [Data] = []
        var pieceLayerHeight = 0
        var remainingBlocksPerPiece = blocksPerPiece
        while remainingBlocksPerPiece > 1 {
            pieceLayerHeight += 1
            remainingBlocksPerPiece /= 2
        }

        var height = 0
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
                pieceLayerHashes = Array(layer.prefix(realPieceCount))
            }
        }

        let root = layer.first ?? zeroHash
        var concatenatedPieceLayers = Data()
        for hash in pieceLayerHashes {
            concatenatedPieceLayers.append(hash)
        }
        return (root, concatenatedPieceLayers)
    }
}
