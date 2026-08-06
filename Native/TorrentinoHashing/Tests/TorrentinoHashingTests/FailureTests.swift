// Layer: Hashing research (WP-12)
// Role: §12.8 failure/fallback tests. Every listed fallback condition must
// either return the CPU-computed result with a nonzero fallback count or a
// defined error; partial Metal output must never be returned.
// Invariants: fallback output is bit-for-bit equal to the pure-CPU output;
// fallbackCount > 0 in every fallback case.

import Foundation
import TorrentinoHashing
import XCTest

final class FailureTests: XCTestCase {
    private func corpus() async throws -> (workspace: TestWorkspace, files: [HashSourceFile]) {
        let workspace = try TestWorkspace(name: "fail")
        let corpus = try TestCorpus.make(root: workspace.root, seed: 11, fileSizes: [500_000, 900_000])
        return (workspace, corpus.files)
    }

    func testNilDeviceFallsBackToCPU() async throws {
        try await withMetalGate {
            let (workspace, files) = try await corpus()
            defer { workspace.remove() }
            let backend = ResearchHashingBackend(injection: MetalInjection(failDeviceCreation: true))
            let result = try await backend.hash(
                scannedFiles: files, pieceSizeBytes: 256 * 1024, format: .hybrid, choice: .metal
            )
            XCTAssertEqual(result.report.actualEngine, .cpu)
            XCTAssertEqual(result.report.fallbackCount, 1)
            let cpu = try await CPUReferenceHasher().hash(
                scannedFiles: files, pieceSizeBytes: 256 * 1024, format: .hybrid
            )
            XCTAssertEqual(result.output, cpu, "fallback output must equal CPU bit-for-bit")
        }
    }

    func testShaderCompileFailureFallsBackToCPU() async throws {
        try await withMetalGate {
            let (workspace, files) = try await corpus()
            defer { workspace.remove() }
            let backend = ResearchHashingBackend(injection: MetalInjection(shaderSourceOverride: "this is not metal"))
            let result = try await backend.hash(
                scannedFiles: files, pieceSizeBytes: 256 * 1024, format: .v2, choice: .metal
            )
            XCTAssertEqual(result.report.actualEngine, .cpu)
            XCTAssertEqual(result.report.fallbackCount, 1)
            let cpu = try await CPUReferenceHasher().hash(
                scannedFiles: files, pieceSizeBytes: 256 * 1024, format: .v2
            )
            XCTAssertEqual(result.output, cpu)
        }
    }

    func testCommandBufferCommitFailureFallsBackToCPU() async throws {
        try await withMetalGate {
            let (workspace, files) = try await corpus()
            defer { workspace.remove() }
            let backend = ResearchHashingBackend(injection: MetalInjection(failCommandBufferCommit: true))
            let result = try await backend.hash(
                scannedFiles: files, pieceSizeBytes: 1024 * 1024, format: .hybrid, choice: .metal
            )
            XCTAssertEqual(result.report.actualEngine, .cpu)
            XCTAssertEqual(result.report.fallbackCount, 1)
            let cpu = try await CPUReferenceHasher().hash(
                scannedFiles: files, pieceSizeBytes: 1024 * 1024, format: .hybrid
            )
            XCTAssertEqual(result.output, cpu)
        }
    }

    func testBufferAllocationFailureFallsBackToCPU() async throws {
        try await withMetalGate {
            let (workspace, files) = try await corpus()
            defer { workspace.remove() }
            let backend = ResearchHashingBackend(injection: MetalInjection(failBufferAllocation: true))
            let result = try await backend.hash(
                scannedFiles: files, pieceSizeBytes: 1024 * 1024, format: .v1, choice: .metal
            )
            XCTAssertEqual(result.report.actualEngine, .cpu)
            XCTAssertEqual(result.report.fallbackCount, 1)
        }
    }

    func testSelfTestFailureFallsBackToCPU() async throws {
        try await withMetalGate {
            let (workspace, files) = try await corpus()
            defer { workspace.remove() }
            // A library that compiles but produces wrong digests must be
            // caught by the validation gate, not returned.
            let brokenSource = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void sha256_blocks(const device uchar* in [[buffer(0)]],
                                      device uchar* out [[buffer(1)]],
                                      constant uint& blockCount [[buffer(2)]],
                                      uint tid [[thread_position_in_grid]]) {
                if (tid >= blockCount) return;
                for (uint i = 0; i < 32u; i++) out[tid*32u+i] = 0xAB;
            }
            kernel void sha1_pieces(const device uchar* in [[buffer(0)]],
                                    device uchar* out [[buffer(1)]],
                                    constant uint& pieceBytes [[buffer(2)]],
                                    constant uint& pieceCount [[buffer(3)]],
                                    const device uint* pieceSizes [[buffer(4)]],
                                    uint tid [[thread_position_in_grid]]) {
                if (tid >= pieceCount) return;
                for (uint i = 0; i < 20u; i++) out[tid*20u+i] = 0xCD;
            }
            """
            let backend = ResearchHashingBackend(injection: MetalInjection(shaderSourceOverride: brokenSource))
            let result = try await backend.hash(
                scannedFiles: files, pieceSizeBytes: 1024 * 1024, format: .hybrid, choice: .metal
            )
            XCTAssertEqual(result.report.actualEngine, .cpu)
            XCTAssertEqual(result.report.fallbackCount, 1)
            let cpu = try await CPUReferenceHasher().hash(
                scannedFiles: files, pieceSizeBytes: 1024 * 1024, format: .hybrid
            )
            XCTAssertEqual(result.output, cpu)
        }
    }

    func testSupportReportWithoutFlagIsUnsupported() async throws {
        TestGate.disable()
        let report = await MetalEnvironment.supportReport()
        XCTAssertFalse(report.isSupported)
        XCTAssertNotNil(report.reason)
        XCTAssertTrue(report.reason!.contains(ExperimentalGate.flagName))
    }

    func testSupportReportWithFlagGreen() async throws {
        await withMetalGate {
            let report = await MetalEnvironment.supportReport()
            XCTAssertTrue(report.isSupported, "expected GPU support on Apple Silicon: \(report.reason ?? "nil")")
            XCTAssertTrue(report.devicePresent)
            XCTAssertTrue(report.libraryCompiles)
            XCTAssertTrue(report.selfTestPassed)
        }
    }
}
