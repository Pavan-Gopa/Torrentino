// Layer: Hashing research (WP-12)
// Role: stress gate (§12.7: >= 1000 stress iterations without mismatch).
// Small fast corpora keep the suite green in CI; the QA script adds a larger
// on-disk stress pass.

import Foundation
import TorrentinoHashing
import XCTest

final class StressTests: XCTestCase {
    func testThousandIterationsNoMismatch() async throws {
        try await withMetalGate {
            var generator = DeterministicBytes(seed: 0x5EED_0001)
            var mismatches = 0
            var executed = 0
            var fallbacks = 0
            for iteration in 0..<1000 {
                let workspace = try TestWorkspace(name: "stress-\(iteration % 20)")
                defer { workspace.remove() }
                let sizes = [Int(generator.next() % 200_000), Int(generator.next() % 300_000)]
                let pieceKiB = [256, 1024][Int(generator.next() % 2)]
                let format: ResearchFormat = [.v1, .v2, .hybrid][Int(generator.next() % 3)]
                let corpus = try TestCorpus.make(
                    root: workspace.root, seed: UInt64(iteration), fileSizes: sizes
                )
                let cpu = try await CPUReferenceHasher().hash(
                    scannedFiles: corpus.files, pieceSizeBytes: Int64(pieceKiB * 1024), format: format
                )
                let metal = try await ResearchHashingBackend().hash(
                    scannedFiles: corpus.files, pieceSizeBytes: Int64(pieceKiB * 1024), format: format, choice: .metal
                )
                if metal.output != cpu {
                    mismatches += 1
                }
                fallbacks += metal.report.fallbackCount
                executed += 1
            }
            XCTAssertEqual(executed, 1000)
            XCTAssertEqual(mismatches, 0, "stress mismatches: \(mismatches)")
            XCTAssertEqual(fallbacks, 0, "stress fallbacks: \(fallbacks)")
        }
    }
}
