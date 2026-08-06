// Layer: Hashing research (WP-12)
// Role: GPU piece-level SHA-1 compute for v1/hybrid torrents. Piece buffers
// are assembled on the CPU side by the streaming pump (identical layout to
// the CPU reference, including BEP-47 inter-file padding), then one GPU
// thread hashes each piece serially. Only piece-level parallelism exists for
// SHA-1 because the compression function is a dependency chain; this is the
// honest structural limit the benchmark measures.
// Invariants: digests byte-for-byte equal to CommonCrypto SHA-1.

import Darwin
import Foundation
import Metal

/// One assembled v1 piece (real bytes only; the final piece may be short).
public struct GPUPieceInput: Sendable {
    public let bytes: Data
    public let pieceBytes: Int

    public init(bytes: Data, pieceBytes: Int) {
        self.bytes = bytes
        self.pieceBytes = pieceBytes
    }
}

public enum GPUPieceHasher {
    /// Hash all pieces in one dispatch. `pieces` are laid out contiguously in
    /// the staging buffer with stride `pieceBytes` (zero-extended tail for the
    /// short final piece). Returns one 20-byte digest per piece.
    public static func hash(
        pieces: [GPUPieceInput],
        runtime: MetalRuntimeState,
        injection: MetalInjection
    ) async throws -> [Data] {
        guard !pieces.isEmpty else { return [] }
        if injection.failBufferAllocation {
            throw ResearchHasherError.hashingFailed("injected: buffer allocation failure")
        }

        let pieceBytes = pieces[0].pieceBytes
        guard pieces.allSatisfy({ $0.pieceBytes == pieceBytes }) else {
            throw ResearchHasherError.hashingFailed("mixed piece sizes in one dispatch")
        }
        // Bounded dispatch: never stage the whole multi-GiB corpus at once
        // (§12.8: no full-file mapping). 256 MiB ring cap.
        let maxStagedBytes = 256 * 1024 * 1024
        let maxPiecesPerBatch = max(1, maxStagedBytes / pieceBytes)
        var digests: [Data] = []
        digests.reserveCapacity(pieces.count)

        var startIndex = 0
        while startIndex < pieces.count {
            try Task.checkCancellation()
            let endIndex = min(startIndex + maxPiecesPerBatch, pieces.count)
            let batch = Array(pieces[startIndex..<endIndex])

            let totalInputBytes = batch.count * pieceBytes
            guard let inputBuffer = runtime.device.makeBuffer(length: totalInputBytes, options: .storageModeShared),
                  let outputBuffer = runtime.device.makeBuffer(length: batch.count * 20, options: .storageModeShared),
                  let pieceBytesBuffer = runtime.device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
                  let pieceCountBuffer = runtime.device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
                  let sizesBuffer = runtime.device.makeBuffer(length: batch.count * MemoryLayout<UInt32>.size, options: .storageModeShared) else {
                throw ResearchHasherError.hashingFailed("metal staging buffers unavailable")
            }

            try Task.checkCancellation()
            let base = inputBuffer.contents()
            for (index, piece) in batch.enumerated() {
                guard piece.bytes.count <= pieceBytes else {
                    throw ResearchHasherError.hashingFailed("piece longer than stride")
                }
                let dest = base + (index * pieceBytes)
                piece.bytes.withUnsafeBytes { raw in
                    if let rawBase = raw.baseAddress {
                        dest.copyMemory(from: rawBase, byteCount: piece.bytes.count)
                    }
                }
                // Zero-fill the stride remainder so no stale bytes are hashed.
                if piece.bytes.count < pieceBytes {
                    memset(dest.advanced(by: piece.bytes.count), 0, pieceBytes - piece.bytes.count)
                }
                sizesBuffer.contents().storeBytes(of: UInt32(piece.bytes.count), toByteOffset: index * MemoryLayout<UInt32>.size, as: UInt32.self)
            }
            pieceBytesBuffer.contents().storeBytes(of: UInt32(pieceBytes), as: UInt32.self)
            pieceCountBuffer.contents().storeBytes(of: UInt32(batch.count), as: UInt32.self)

            guard let queue = runtime.device.makeCommandQueue(),
                  let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw ResearchHasherError.hashingFailed("metal command objects unavailable")
            }
            encoder.setComputePipelineState(runtime.sha1Kernel)
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(outputBuffer, offset: 0, index: 1)
            encoder.setBuffer(pieceBytesBuffer, offset: 0, index: 2)
            encoder.setBuffer(pieceCountBuffer, offset: 0, index: 3)
            encoder.setBuffer(sizesBuffer, offset: 0, index: 4)
            let threadsPerGroup = MTLSize(width: min(256, batch.count), height: 1, depth: 1)
            let threadGroups = MTLSize(width: (batch.count + threadsPerGroup.width - 1) / threadsPerGroup.width, height: 1, depth: 1)
            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()

            if injection.failCommandBufferCommit {
                throw ResearchHasherError.hashingFailed("injected: command buffer commit failure")
            }
            commandBuffer.commit()
            await commandBuffer.completed()
            if commandBuffer.status == .error {
                throw ResearchHasherError.hashingFailed("command buffer error: \(commandBuffer.error.map(String.init(describing:)) ?? "unknown")")
            }

            let bytes = Data(bytes: outputBuffer.contents(), count: batch.count * 20)
            for index in 0..<batch.count {
                digests.append(bytes.subdata(in: (index * 20)..<(index * 20 + 20)))
            }
            startIndex = endIndex
        }
        return digests
    }
}
