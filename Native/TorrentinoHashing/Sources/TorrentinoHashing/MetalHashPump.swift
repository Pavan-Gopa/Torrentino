// Layer: Hashing research (WP-12)
// Role: GPU-executed hashing pump. Streaming file iteration is identical to
// the CPU reference (single read epoch, descriptor-anchored identity checks,
// raw-UTF-8 path order, BEP-47 padding); the difference is that digests are
// computed by Metal dispatch instead of CommonCrypto.
// Why bounded batching: §12.8 forbids mapping whole multi-gigabyte files;
// pieces/blocks are dispatched in capped batches (~256 MiB) so peak RSS stays
// in budget. Cancellation is checked between batches, bounding cancellation
// latency to one batch.
// Invariants: output equals CPUReferenceHasher bit-for-bit; no partial GPU
// result is ever returned — any throw discards the run (caller falls back).

import Foundation

struct MetalHashPump {
    let runtime: MetalRuntimeState
    let injection: MetalInjection
    let batchCapBytes: Int = 256 * 1024 * 1024

    var stagedBytes: Int64 = 0
    var gpuWallSeconds: Double = 0

    mutating func hash(
        scannedFiles: [HashSourceFile],
        pieceSizeBytes: Int64,
        format: ResearchFormat,
        cancelCheck: @Sendable () throws -> Void
    ) async throws -> (HashingOutput, stagedBytes: Int64, gpuWallSeconds: Double) {
        guard !scannedFiles.isEmpty else {
            throw ResearchHasherError.hashingFailed("no files to hash")
        }
        let orderedFiles = scannedFiles.sorted {
            Data($0.relativePath.utf8).lexicographicallyPrecedes(Data($1.relativePath.utf8))
        }
        let padding = CPUReferenceHasher().v1PaddingBytes(files: orderedFiles, pieceSizeBytes: pieceSizeBytes, format: format)

        var v1PiecesData = Data()
        var v2FileTrees: [String: V2FileTreeEntry] = [:]
        var totalBytesHashed: Int64 = 0
        var totalFilesHashed = 0

        // v1: assembled pieces awaiting dispatch (bounded by batchCapBytes).
        var pendingPieces: [GPUPieceInput] = []
        var pendingPiecesBytes = 0
        var currentPieceBytes = Data()
        var currentPieceLength = 0

        var v1Digests: [Data] = []

        // v2: raw 16 KiB blocks accumulate until the batch cap; digests are
        // collected separately so raw data and digests never mix.
        var fileBlockData: [Data] = []
        var fileDigests: [Data] = []
        let blockSize = Int(CPUReferenceHasher.v2BlockSize)

        let readBufferSize = 64 * 1024

        func flushV1Batch() async throws {
            guard !pendingPieces.isEmpty else { return }
            let start = DispatchTime.now()
            let digests = try await GPUPieceHasher.hash(pieces: pendingPieces, runtime: runtime, injection: injection)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            gpuWallSeconds += elapsed
            v1Digests.append(contentsOf: digests)
            pendingPieces.removeAll(keepingCapacity: true)
            pendingPiecesBytes = 0
        }

        /// Hash all pending raw blocks of the current file; digests append to
        /// `fileDigests` in order. Caller clears `fileBlockData` afterwards.
        func flushV2Blocks() async throws {
            guard !fileBlockData.isEmpty else { return }
            var flat = Data()
            flat.reserveCapacity(fileBlockData.count * blockSize)
            for block in fileBlockData { flat.append(block) }
            let start = DispatchTime.now()
            let digests = try await GPUBlockHasher.hash(data: flat, runtime: runtime, stagingBytes: batchCapBytes, injection: injection)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            gpuWallSeconds += elapsed
            stagedBytes += Int64(flat.count)
            fileDigests.append(contentsOf: digests)
        }

        func appendV1Bytes(_ bytes: Data) async throws {
            var offset = 0
            while offset < bytes.count {
                let needed = Int(pieceSizeBytes) - currentPieceLength
                let take = min(needed, bytes.count - offset)
                currentPieceBytes.append(bytes.subdata(in: offset..<(offset + take)))
                currentPieceLength += take
                offset += take
                if currentPieceLength == Int(pieceSizeBytes) {
                    let piece = GPUPieceInput(bytes: currentPieceBytes, pieceBytes: Int(pieceSizeBytes))
                    pendingPieces.append(piece)
                    pendingPiecesBytes += Int(pieceSizeBytes)
                    currentPieceBytes = Data()
                    currentPieceLength = 0
                    if pendingPiecesBytes >= batchCapBytes {
                        try await flushV1Batch()
                    }
                }
            }
        }

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
                    continue
                }

                var v2BlockBuffer = Data()
                var v2BlockStart = 0
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
                        try await appendV1Bytes(chunk)
                    }

                    if format.isV2Needed {
                        v2BlockBuffer.append(chunk)
                        while v2BlockStart + blockSize <= v2BlockBuffer.count {
                            fileBlockData.append(v2BlockBuffer.subdata(in: v2BlockStart..<(v2BlockStart + blockSize)))
                            v2BlockStart += blockSize
                        }
                        if v2BlockStart > 0 {
                            // Re-base via dropFirst: removeFirst leaves a
                            // non-zero internal startIndex that breaks the
                            // 0-based subdata above.
                            v2BlockBuffer = Data(v2BlockBuffer.dropFirst(v2BlockStart))
                            v2BlockStart = 0
                        }
                        if fileBlockData.count * blockSize >= batchCapBytes {
                            try await flushV2Blocks()
                            fileBlockData.removeAll(keepingCapacity: true)
                        }
                    }
                }

                var postStat = stat()
                guard fstat(fileDescriptor, &postStat) == 0,
                      matchesExpectedIdentity(postStat) else {
                    throw ResearchHasherError.sourceModified(fileEntry.relativePath)
                }

                if format.isV2Needed {
                    // Complete the file: hash the full 16 KiB blocks, then the
                    // short final block (cannot be a 16 KiB GPU chunk — hash
                    // it with the reference, same bytes and digest), then
                    // build the merkle tree (CPU-side: negligible cost, same
                    // code as the reference).
                    try await flushV2Blocks()
                    fileBlockData.removeAll(keepingCapacity: true)
                    if !v2BlockBuffer.isEmpty {
                        fileDigests.append(CPUReferenceHasher.sha256(v2BlockBuffer))
                        v2BlockBuffer.removeAll()
                    }
                    let tree = CPUReferenceHasher.buildV2MerkleTree(
                        leafHashes: fileDigests,
                        blocksPerPiece: Int(pieceSizeBytes / CPUReferenceHasher.v2BlockSize)
                    )
                    let pieceLayers = fileEntry.sizeBytes > pieceSizeBytes ? tree.pieceLayers : Data()
                    v2FileTrees[fileEntry.relativePath] = V2FileTreeEntry(
                        piecesRoot: tree.root,
                        pieceLayers: pieceLayers,
                        sizeBytes: fileEntry.sizeBytes
                    )
                    fileDigests.removeAll(keepingCapacity: true)
                }

                totalFilesHashed += 1
                try closeDescriptor()

                if format.isV1Needed, fileIndex < padding.count, padding[fileIndex] > 0 {
                    let zeroChunk = Data(repeating: 0, count: Int(padding[fileIndex]))
                    try await appendV1Bytes(zeroChunk)
                    totalBytesHashed += Int64(zeroChunk.count)
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

        // Flush the trailing short piece and remaining pending pieces.
        if format.isV1Needed {
            if currentPieceLength > 0 {
                let piece = GPUPieceInput(bytes: currentPieceBytes, pieceBytes: Int(pieceSizeBytes))
                pendingPieces.append(piece)
                pendingPiecesBytes += Int(pieceSizeBytes)
                currentPieceBytes = Data()
                currentPieceLength = 0
            }
            try await flushV1Batch()
            for digest in v1Digests {
                v1PiecesData.append(digest)
            }
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

        let output = HashingOutput(
            v1PiecesData: v1PiecesData,
            v2FileTrees: v2FileTrees,
            totalBytesHashed: totalBytesHashed,
            totalFilesHashed: Int64(totalFilesHashed)
        )
        return (output, stagedBytes, gpuWallSeconds)
    }
}
