// Layer: Hashing research (WP-12)
// Role: Metal runtime environment for the experimental backend: device
// resolution, runtime library compilation, startup self-test, and the
// §12.8 supported-hook query. All Metal state is confined to one actor so
// non-Sendable MTLDevice/MTLLibrary objects never cross an actor boundary.
// Injection points exist ONLY for the failure tests (shader compile failure,
// command buffer error, nil device); production code paths are unaffected.

import Foundation
import Metal

/// Injectable failure hooks (tests only). All default to "no failure".
public struct MetalInjection: Sendable, Equatable {
    public var failDeviceCreation: Bool
    public var failLibraryCompilation: Bool
    public var failBufferAllocation: Bool
    public var failCommandBufferCommit: Bool
    public var shaderSourceOverride: String?

    public init(
        failDeviceCreation: Bool = false,
        failLibraryCompilation: Bool = false,
        failBufferAllocation: Bool = false,
        failCommandBufferCommit: Bool = false,
        shaderSourceOverride: String? = nil
    ) {
        self.failDeviceCreation = failDeviceCreation
        self.failLibraryCompilation = failLibraryCompilation
        self.failBufferAllocation = failBufferAllocation
        self.failCommandBufferCommit = failCommandBufferCommit
        self.shaderSourceOverride = shaderSourceOverride
    }

    public static let none = MetalInjection()
}

/// Known-answer self-test vector used at startup (bit-for-bit gate §12.7).
public enum SelfTestVectors {
    /// One full 16 KiB block of alternating 0x00/0xFF bytes.
    public static func sha256BlockAlternating() -> Data {
        var block = Data(repeating: 0, count: 16 * 1024)
        for index in stride(from: 1, to: block.count, by: 2) {
            block[index] = 0xFF
        }
        return block
    }
}

/// One held Metal object: device + compiled library. Kept inside the actor.
/// @unchecked Sendable: MTLDevice, MTLLibrary and MTLComputePipelineState are
/// Apple-documented thread-safe for concurrent use and this state is
/// immutable after init, so sharing it across async boundaries is safe.
public final class MetalRuntimeState: @unchecked Sendable {
    public let device: MTLDevice
    public let library: MTLLibrary
    public let sha256Kernel: MTLComputePipelineState
    public let sha1Kernel: MTLComputePipelineState

    public init(device: MTLDevice, library: MTLLibrary, sha256Kernel: MTLComputePipelineState, sha1Kernel: MTLComputePipelineState) {
        self.device = device
        self.library = library
        self.sha256Kernel = sha256Kernel
        self.sha1Kernel = sha1Kernel
    }
}

/// Actor that owns the Metal device and compiled kernels.
public actor MetalEnvironment {
    public private(set) var runtimeState: MetalRuntimeState?
    public private(set) var lastCompileError: String?

    private let injection: MetalInjection

    public init(injection: MetalInjection = .none) {
        self.injection = injection
    }

    /// Compile the experimental kernels. Throws when the device is missing or
    /// the library/pipeline cannot be built (both are §12.8 fallback paths).
    public func ensureRuntime() throws -> MetalRuntimeState {
        if let runtimeState { return runtimeState }

        if injection.failDeviceCreation {
            throw ResearchHasherError.hashingFailed("injected: no MTLDevice")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ResearchHasherError.hashingFailed("no MTLDevice available")
        }
        if injection.failBufferAllocation {
            throw ResearchHasherError.hashingFailed("injected: buffer allocation failure")
        }

        let source = injection.shaderSourceOverride ?? MetalKernels.sha256BlocksSource + "\n" + MetalKernels.sha1PiecesSource
        let options = MTLCompileOptions()
        do {
            let library = try device.makeLibrary(source: source, options: options)
            guard let sha256Function = library.makeFunction(name: "sha256_blocks"),
                  let sha1Function = library.makeFunction(name: "sha1_pieces") else {
                throw ResearchHasherError.hashingFailed("metal kernel functions missing")
            }
            let sha256Kernel = try device.makeComputePipelineState(function: sha256Function)
            let sha1Kernel = try device.makeComputePipelineState(function: sha1Function)
            let state = MetalRuntimeState(device: device, library: library, sha256Kernel: sha256Kernel, sha1Kernel: sha1Kernel)
            runtimeState = state
            lastCompileError = nil
            return state
        } catch {
            lastCompileError = "\(error)"
            throw ResearchHasherError.hashingFailed("metal pipeline creation failed: \(error)")
        }
    }

    /// Startup self-test (§12.8 "failed startup self-test" fallback): hash a
    /// known 16 KiB block on the GPU and require bit-for-bit equality with the
    /// CPU digest. Returns false (never throws) so callers can fall back.
    public func runSelfTest() async -> Bool {
        do {
            let state = try ensureRuntime()
            let block = SelfTestVectors.sha256BlockAlternating()
            let expected = CPUReferenceHasher.sha256(block)
            let digests = try await GPUBlockHasher.hash(
                data: block,
                runtime: state,
                stagingBytes: 4 * 1024 * 1024,
                injection: injection
            )
            guard digests.count == 1, digests[0] == expected else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// §12.8 supported-hook query. Deterministic shape; callers (creator or a
    /// future recheck integration point) use this before requesting Metal.
    public static func supportReport() async -> MetalSupportReport {
        let environment = MetalEnvironment()
        return await environment.report()
    }

    public func report() async -> MetalSupportReport {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = "\(ProcessInfo.processInfo.thermalState.rawValue)"

        guard ExperimentalGate.isMetalExperimentsEnabled else {
            return MetalSupportReport(
                isSupported: false, devicePresent: false, libraryCompiles: false,
                selfTestPassed: false, lowPowerMode: lowPower, thermalState: thermal,
                reason: "experimental flag \(ExperimentalGate.flagName) not set"
            )
        }

        var devicePresent = false
        if !injection.failDeviceCreation {
            devicePresent = MTLCreateSystemDefaultDevice() != nil
        }
        guard devicePresent else {
            return MetalSupportReport(
                isSupported: false, devicePresent: false, libraryCompiles: false,
                selfTestPassed: false, lowPowerMode: lowPower, thermalState: thermal,
                reason: "no MTLDevice"
            )
        }

        var libraryCompiles = false
        var selfTestPassed = false
        var reason: String?
        if lowPower {
            reason = "Low Power Mode active"
        }
        if reason == nil, thermal == "2" || thermal == "3" {
            // §12.8: serious/critical thermal state is a fallback condition.
            reason = "thermal state \(thermal)"
        }
        do {
            _ = try ensureRuntime()
            libraryCompiles = true
            if injection.failLibraryCompilation {
                libraryCompiles = false
                reason = "injected library compile failure"
            }
        } catch {
            reason = error.localizedDescription
        }
        if libraryCompiles, reason == nil {
            selfTestPassed = await runSelfTest()
            if !selfTestPassed {
                reason = "startup self-test failed"
            }
        }

        let isSupported = devicePresent && libraryCompiles && selfTestPassed && !lowPower && reason == nil
        return MetalSupportReport(
            isSupported: isSupported, devicePresent: devicePresent,
            libraryCompiles: libraryCompiles, selfTestPassed: selfTestPassed,
            lowPowerMode: lowPower, thermalState: thermal, reason: reason
        )
    }
}

/// Raw GPU digest compute for one flat buffer (used by the backend and the
/// self-test). Returns one 32-byte digest per 16 KiB block.
public enum GPUBlockHasher {
    public static func hash(
        data: Data,
        runtime: MetalRuntimeState,
        stagingBytes: Int,
        injection: MetalInjection
    ) async throws -> [Data] {
        guard !data.isEmpty else { return [] }
        guard data.count % 16 * 1024 == 0 else {
            throw ResearchHasherError.hashingFailed("GPU block input must be a multiple of 16 KiB")
        }
        if injection.failBufferAllocation {
            throw ResearchHasherError.hashingFailed("injected: buffer allocation failure")
        }

        let blockCount = data.count / (16 * 1024)
        let chunkBlocks = max(1, stagingBytes / (16 * 1024))
        let chunkCount = (blockCount + chunkBlocks - 1) / chunkBlocks
        var digests = [Data](repeating: Data(), count: blockCount)

        for chunkIndex in 0..<chunkCount {
            try Task.checkCancellation()
            let firstBlock = chunkIndex * chunkBlocks
            let blocksInChunk = min(chunkBlocks, blockCount - firstBlock)
            let bytesInChunk = blocksInChunk * (16 * 1024)
            let range = (firstBlock * (16 * 1024))..<(firstBlock * (16 * 1024) + bytesInChunk)

            let start = data.startIndex + range.lowerBound
            let end = data.startIndex + range.upperBound
            let chunk = data.subdata(in: start..<end)

            guard let queue = runtime.device.makeCommandQueue(),
                  let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw ResearchHasherError.hashingFailed("metal command objects unavailable")
            }

            guard let inputBuffer = runtime.device.makeBuffer(length: chunk.count, options: .storageModeShared),
                  let outputBuffer = runtime.device.makeBuffer(length: blocksInChunk * 32, options: .storageModeShared),
                  let countBuffer = runtime.device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared) else {
                throw ResearchHasherError.hashingFailed("metal staging buffers unavailable")
            }

            chunk.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    inputBuffer.contents().copyMemory(from: base, byteCount: chunk.count)
                }
            }
            countBuffer.contents().storeBytes(of: UInt32(blocksInChunk), as: UInt32.self)

            encoder.setComputePipelineState(runtime.sha256Kernel)
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(outputBuffer, offset: 0, index: 1)
            encoder.setBuffer(countBuffer, offset: 0, index: 2)
            let threadsPerGroup = MTLSize(width: min(256, blocksInChunk), height: 1, depth: 1)
            let threadGroups = MTLSize(width: (blocksInChunk + threadsPerGroup.width - 1) / threadsPerGroup.width, height: 1, depth: 1)
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

            let out = outputBuffer.contents()
            let bytes = Data(bytes: out, count: blocksInChunk * 32)
            for index in 0..<blocksInChunk {
                digests[firstBlock + index] = bytes.subdata(in: (index * 32)..<(index * 32 + 32))
            }
        }
        return digests
    }
}
