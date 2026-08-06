// Layer: Hashing research (WP-12)
// Role: research backend entry point. Resolves the requested backend choice
// (ADR-009 shape), runs either the CPU reference or the GPU pump, and
// implements §12.8 fallback: any Metal failure triggers a full recompute on
// CPU and is counted; partial Metal output is never mixed with the trusted
// CPU result.
// Why whole-operation fallback: piece chains and block hashes are independent
// enough to resume at unit granularity, but the research gate (§12.7) only
// requires correctness of the final result and a nonzero fallback count. A
// whole-op retry is the safest unit for the prototype.
// Invariants: automatic/cpu always succeed with CPU (no GPU involvement);
// metal may fall back to CPU but the returned output is always bit-for-bit
// equal to CPUReferenceHasher.

import Foundation

public actor ResearchHashingBackend {
    private let injection: MetalInjection

    // Shared environment for the default (no-failure) case: the shader
    // library is compiled once per process instead of once per run, which is
    // both faster for the stress gate and closer to production reuse.
    private static let sharedEnvironment = MetalEnvironment(injection: .none)

    public init(injection: MetalInjection = .none) {
        self.injection = injection
    }

    /// Minimum input size for `automatic` to consider Metal (§12.7 eligible
    /// workloads are >= 4 GiB).
    public static let automaticMetalThresholdBytes: Int64 = 4 * 1024 * 1024 * 1024

    public func hash(
        scannedFiles: [HashSourceFile],
        pieceSizeBytes: Int64,
        format: ResearchFormat,
        choice: HashingBackendChoice = .automatic,
        cancelCheck: @Sendable () throws -> Void = {},
        onProgress: @Sendable (Int64, Int64, Int, Int) async -> Void = { _, _, _, _ in }
    ) async throws -> BackendHashingResult {
        let totalBytes = scannedFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }

        switch choice {
        case .cpu:
            let output = try await CPUReferenceHasher().hash(
                scannedFiles: scannedFiles,
                pieceSizeBytes: pieceSizeBytes,
                format: format,
                cancelCheck: cancelCheck,
                onProgress: onProgress
            )
            return BackendHashingResult(output: output, report: BackendRunReport(
                requestedChoice: .cpu, actualEngine: .cpu, fallbackCount: 0,
                stagedBytes: 0, gpuWallSeconds: 0, rejectionReason: nil
            ))

        case .automatic:
            // §12.7: Automatic may pick Metal only above the break-even
            // threshold and only when the supported hook is green.
            if totalBytes >= Self.automaticMetalThresholdBytes,
               ExperimentalGate.isMetalExperimentsEnabled {
                do {
        let environment = injection == .none ? Self.sharedEnvironment : MetalEnvironment(injection: injection)
                    let support = await environment.report()
                    if support.isSupported {
                        return try await runMetalOrFallback(
                            scannedFiles: scannedFiles,
                            pieceSizeBytes: pieceSizeBytes,
                            format: format,
                            cancelCheck: cancelCheck,
                            onProgress: onProgress
                        )
                    }
                    let cpuOutput = try await CPUReferenceHasher().hash(
                        scannedFiles: scannedFiles,
                        pieceSizeBytes: pieceSizeBytes,
                        format: format,
                        cancelCheck: cancelCheck,
                        onProgress: onProgress
                    )
                    return BackendHashingResult(output: cpuOutput, report: BackendRunReport(
                        requestedChoice: .automatic, actualEngine: .cpu, fallbackCount: 0,
                        stagedBytes: 0, gpuWallSeconds: 0,
                        rejectionReason: support.reason ?? "below threshold"
                    ))
                } catch {
                    let cpuOutput = try await CPUReferenceHasher().hash(
                        scannedFiles: scannedFiles,
                        pieceSizeBytes: pieceSizeBytes,
                        format: format,
                        cancelCheck: cancelCheck,
                        onProgress: onProgress
                    )
                    return BackendHashingResult(output: cpuOutput, report: BackendRunReport(
                        requestedChoice: .automatic, actualEngine: .cpu, fallbackCount: 0,
                        stagedBytes: 0, gpuWallSeconds: 0, rejectionReason: "\(error)"
                    ))
                }
            }
            let cpuOutput = try await CPUReferenceHasher().hash(
                scannedFiles: scannedFiles,
                pieceSizeBytes: pieceSizeBytes,
                format: format,
                cancelCheck: cancelCheck,
                onProgress: onProgress
            )
            return BackendHashingResult(output: cpuOutput, report: BackendRunReport(
                requestedChoice: .automatic, actualEngine: .cpu, fallbackCount: 0,
                stagedBytes: 0, gpuWallSeconds: 0,
                rejectionReason: totalBytes < Self.automaticMetalThresholdBytes
                    ? "below 4 GiB threshold" : nil
            ))

        case .metal:
            return try await runMetalOrFallback(
                scannedFiles: scannedFiles,
                pieceSizeBytes: pieceSizeBytes,
                format: format,
                cancelCheck: cancelCheck,
                onProgress: onProgress
            )
        }
    }

    private func runMetalOrFallback(
        scannedFiles: [HashSourceFile],
        pieceSizeBytes: Int64,
        format: ResearchFormat,
        cancelCheck: @Sendable () throws -> Void,
        onProgress: @Sendable (Int64, Int64, Int, Int) async -> Void
    ) async throws -> BackendHashingResult {
        // Cancellation must propagate, not fall back: a cancelled run has no
        // result to trust.
        try cancelCheck()
        try Task.checkCancellation()

        let environment = MetalEnvironment(injection: injection)
        do {
            // §12.8 "failed startup self-test": never run GPU without a green
            // self-test, and never run at all without the experimental flag.
            guard ExperimentalGate.isMetalExperimentsEnabled else {
                throw ResearchHasherError.hashingFailed("experimental flag \(ExperimentalGate.flagName) not set")
            }
            let runtime = try await environment.ensureRuntime()
            guard await environment.runSelfTest() else {
                throw ResearchHasherError.hashingFailed("startup self-test failed")
            }
            var pump = MetalHashPump(runtime: runtime, injection: injection)
            let (output, stagedBytes, gpuWallSeconds) = try await pump.hash(
                scannedFiles: scannedFiles,
                pieceSizeBytes: pieceSizeBytes,
                format: format,
                cancelCheck: cancelCheck
            )
            // §12.7: the GPU result must equal the CPU reference. Any
            // mismatch is a fallback condition ("результат validation не
            // совпал"), never a silently-accepted GPU result.
            let referenceOutput = try await CPUReferenceHasher().hash(
                scannedFiles: scannedFiles,
                pieceSizeBytes: pieceSizeBytes,
                format: format,
                cancelCheck: cancelCheck
            )
            guard referenceOutput == output else {
                throw ResearchHasherError.hashingFailed("GPU result validation mismatch")
            }
            return BackendHashingResult(output: output, report: BackendRunReport(
                requestedChoice: .metal, actualEngine: .metal, fallbackCount: 0,
                stagedBytes: stagedBytes, gpuWallSeconds: gpuWallSeconds,
                rejectionReason: nil
            ))
        } catch is CancellationError {
            throw ResearchHasherError.cancelled
        } catch let error as ResearchHasherError {
            if error == .cancelled { throw error }
            // §12.8 fallback: recompute the whole operation on CPU. The GPU
            // partial output is discarded, so partial Metal output can never
            // be mixed with the trusted CPU result.
            let cpuOutput = try await CPUReferenceHasher().hash(
                scannedFiles: scannedFiles,
                pieceSizeBytes: pieceSizeBytes,
                format: format,
                cancelCheck: cancelCheck,
                onProgress: onProgress
            )
            return BackendHashingResult(output: cpuOutput, report: BackendRunReport(
                requestedChoice: .metal, actualEngine: .cpu, fallbackCount: 1,
                stagedBytes: 0, gpuWallSeconds: 0,
                rejectionReason: "\(error)"
            ))
        }
    }
}
