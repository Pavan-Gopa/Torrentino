// Layer: Hashing research (WP-12)
// Role: randomized bit-for-bit correctness gate. GPU output must equal the
// CPU reference on randomized multi-file corpora across formats and piece
// sizes (§12.7: 100% v1/v2/hybrid match with CPU reference, >= 100
// randomized cases).
// Invariants: every case compares the full HashingOutput (v1 pieces + v2
// trees) byte-for-byte; fallback count must be zero on the Metal engine.

import Foundation
import TorrentinoHashing
import XCTest

final class CorrectnessTests: XCTestCase {
    private func assertBackendsEqual(
        seed: UInt64,
        fileSizes: [Int],
        pieceSizeBytes: Int64,
        format: ResearchFormat
    ) async throws {
        let workspace = try TestWorkspace(name: "corr-\(seed)")
        defer { workspace.remove() }
        let corpus = try TestCorpus.make(root: workspace.root, seed: seed, fileSizes: fileSizes)

        let cpu = try await CPUReferenceHasher().hash(
            scannedFiles: corpus.files,
            pieceSizeBytes: pieceSizeBytes,
            format: format
        )
        let backend = ResearchHashingBackend()
        let metal = try await backend.hash(
            scannedFiles: corpus.files,
            pieceSizeBytes: pieceSizeBytes,
            format: format,
            choice: .metal
        )
        XCTAssertEqual(metal.report.actualEngine, .metal, "GPU engine not used (seed \(seed))")
        XCTAssertEqual(metal.output, cpu, "bit-for-bit mismatch (seed \(seed), piece \(pieceSizeBytes), format \(format.rawValue))")
        XCTAssertEqual(metal.report.fallbackCount, 0, "unexpected fallback (seed \(seed))")
    }

    func testRandomizedCases() async throws {
        try await withMetalGate {
            // Deterministic set: 120 randomized corpora covering edge shapes:
            // empty files, tiny files, cross-piece files, exact multiples,
            // many small files.
            var executed = 0
            for seed in 1...40 {
                for format in [ResearchFormat.v1, .v2, .hybrid] {
                    let pieceKiB = [256, 1024, 4096][Int(seed % 3)]
                    let sizes: [Int]
                    switch seed % 5 {
                    case 0: sizes = [0]
                    case 1: sizes = [0, 0, 1, 2]
                    case 2: sizes = [pieceKiB * 1024, pieceKiB * 1024 + 1]
                    case 3: sizes = [pieceKiB * 1024 * 5, 1, pieceKiB * 1024]
                    default: sizes = Array(repeating: pieceKiB * 1024 / 7 + seed * 13, count: 8)
                    }
                    try await assertBackendsEqual(
                        seed: UInt64(seed),
                        fileSizes: sizes,
                        pieceSizeBytes: Int64(pieceKiB * 1024),
                        format: format
                    )
                    executed += 1
                }
            }
            XCTAssertGreaterThanOrEqual(executed, 120, "randomized case count below gate minimum")
        }
    }

    func testLargePieceAnd16MiB() async throws {
        try await withMetalGate {
            let workspace = try TestWorkspace(name: "corr-16m")
            defer { workspace.remove() }
            // 16 MiB pieces over a 100 MiB file (multi-piece tree) and a
            // 16 MiB exact file (single-piece tree, piece-layer boundary).
            let corpus = try TestCorpus.make(
                root: workspace.root,
                seed: 777,
                fileSizes: [100 * 1024 * 1024, 16 * 1024 * 1024, 32 * 1024 * 1024 + 5]
            )
            for format in [ResearchFormat.v1, .v2, .hybrid] {
                let cpu = try await CPUReferenceHasher().hash(
                    scannedFiles: corpus.files, pieceSizeBytes: 16 * 1024 * 1024, format: format
                )
                let metal = try await ResearchHashingBackend().hash(
                    scannedFiles: corpus.files, pieceSizeBytes: 16 * 1024 * 1024, format: format, choice: .metal
                )
                XCTAssertEqual(metal.output, cpu, "16 MiB piece mismatch (\(format.rawValue))")
                XCTAssertEqual(metal.report.fallbackCount, 0)
            }
        }
    }

    func testHundredRandomizedTwoFileStreams() async throws {
        try await withMetalGate {
            // 100 randomized single/hybrid runs with random sizes.
            var generator = DeterministicBytes(seed: 99_001)
            for caseIndex in 0..<100 {
                let workspace = try TestWorkspace(name: "corr-rand-\(caseIndex)")
                defer { workspace.remove() }
                let a = Int(generator.next() % 4_000_000)
                let b = Int(generator.next() % 4_000_000)
                let pieceKiB = [256, 1024, 4096][Int(generator.next() % 3)]
                let format: ResearchFormat = [.v1, .v2, .hybrid][Int(generator.next() % 3)]
                let corpus = try TestCorpus.make(
                    root: workspace.root, seed: UInt64(caseIndex), fileSizes: [a, b]
                )
                let cpu = try await CPUReferenceHasher().hash(
                    scannedFiles: corpus.files, pieceSizeBytes: Int64(pieceKiB * 1024), format: format
                )
                let metal = try await ResearchHashingBackend().hash(
                    scannedFiles: corpus.files, pieceSizeBytes: Int64(pieceKiB * 1024), format: format, choice: .metal
                )
                XCTAssertEqual(metal.output, cpu, "random case \(caseIndex) mismatch")
                XCTAssertEqual(metal.report.fallbackCount, 0)
            }
        }
    }

    func testAutomaticBelowThresholdStaysCPU() async throws {
        // §12.7: below 4 GiB, automatic must pick CPU even with the flag on.
        try await withMetalGate {
            let workspace = try TestWorkspace(name: "corr-auto")
            defer { workspace.remove() }
            let corpus = try TestCorpus.make(root: workspace.root, seed: 5, fileSizes: [1_000_000])
            let result = try await ResearchHashingBackend().hash(
                scannedFiles: corpus.files,
                pieceSizeBytes: 256 * 1024,
                format: .v2,
                choice: .automatic
            )
            XCTAssertEqual(result.report.actualEngine, .cpu)
            XCTAssertEqual(result.report.rejectionReason, "below 4 GiB threshold")
        }
    }
}
