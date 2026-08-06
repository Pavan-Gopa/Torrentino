// Layer: Hashing research (WP-12)
// Role: known-answer tests. Hardcoded digests were computed independently
// (CommonCrypto + published FIPS vectors); the GPU kernels must reproduce
// them bit-for-bit (§12.7 first gate bullet).
// Invariants: no corpus beyond constants; deterministic.

import CommonCrypto
import Foundation
import TorrentinoHashing
import XCTest

final class KnownAnswerTests: XCTestCase {
    // FIPS 180-2 / published vectors.
    func testCPUSHA256PublishedVectors() {
        XCTAssertEqual(CPUReferenceHasher.sha256(Data()).hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(CPUReferenceHasher.sha256(Data("abc".utf8)).hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(CPUReferenceHasher.sha256(Data(repeating: 0x61, count: 1_000_000)).hex,
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testCPUSHA1PublishedVectors() async throws {
        let workspace = try TestWorkspace(name: "ka-sha1")
        defer { workspace.remove() }
        let corpus = try TestCorpus.make(
            root: workspace.root,
            seed: 1,
            fileSizes: [0, 3, 1_000_000]
        )
        let pieceSize = 256 * 1024
        let hasher = CPUReferenceHasher()
        let output = try await hasher.hash(
            scannedFiles: corpus.files,
            pieceSizeBytes: Int64(pieceSize),
            format: .v1
        )
        // Stream = file bytes interleaved with BEP-47 alignment padding
        // (multi-file v1), then CC_SHA1 per 256 KiB piece.
        let ordered = corpus.files.sorted {
            Data($0.relativePath.utf8).lexicographicallyPrecedes(Data($1.relativePath.utf8))
        }
        let padding = hasher.v1PaddingBytes(files: ordered, pieceSizeBytes: Int64(pieceSize), format: .v1)
        var stream = Data()
        for (index, file) in ordered.enumerated() {
            stream.append(contentsOf: try Data(contentsOf: URL(fileURLWithPath: file.fullPath)))
            if index < padding.count {
                stream.append(contentsOf: Data(repeating: 0, count: Int(padding[index])))
            }
        }
        var expected = Data()
        var offset = 0
        while offset < stream.count {
            let take = min(pieceSize, stream.count - offset)
            let chunk = stream.subdata(in: offset..<(offset + take))
            var digest = [UInt8](repeating: 0, count: 20)
            chunk.withUnsafeBytes { ptr in
                if let b = ptr.baseAddress { CC_SHA1(b, CC_LONG(chunk.count), &digest) }
            }
            expected.append(contentsOf: digest)
            offset += take
        }
        XCTAssertEqual(output.v1PiecesData, expected)
    }

    // GPU SHA-256 block kernel against independently computed digests.
    func testGPUSHA256BlockKnownAnswers() async throws {
        try await withMetalGate {
            let workspace = try TestWorkspace(name: "ka-sha256")
            defer { workspace.remove() }
            let environment = MetalEnvironment()
            let runtime = try await environment.ensureRuntime()

            let zeroBlock = Data(repeating: 0, count: 16 * 1024)
            let altBytes = [UInt8](repeating: 0xFF, count: 16 * 1024)
            var alt = [UInt8](repeating: 0, count: 16 * 1024)
            for i in stride(from: 1, to: 16 * 1024, by: 2) { alt[i] = altBytes[i] }
            let altBlock = Data(alt)

            for (data, expected) in [
                (zeroBlock, "4fe7b59af6de3b665b67788cc2f99892ab827efae3a467342b3bb4e3bc8e5bfe"),
                (altBlock, "3d558540e8c59a9e6915aaa700c8d714c8927167920bf0bcf84c4ece2589f368"),
            ] {
                let digests = try await GPUBlockHasher.hash(
                    data: data, runtime: runtime, stagingBytes: 4 * 1024 * 1024, injection: .none
                )
                XCTAssertEqual(digests.count, 1)
                XCTAssertEqual(digests[0].hex, expected, "GPU SHA-256 block mismatch")
            }
        }
    }

    // GPU SHA-1 piece kernel: single-piece dispatches covering exact-block,
    // two-pad-block and short-final cases.
    func testGPUSHA1PieceKnownAnswers() async throws {
        try await withMetalGate {
            let workspace = try TestWorkspace(name: "ka-sha1-gpu")
            defer { workspace.remove() }
            let environment = MetalEnvironment()
            let runtime = try await environment.ensureRuntime()

            let cases: [(count: Int, expected: String)] = [
                (57, "f08f24908d682555111be7ff6f004e78283d989a"),   // rem=57: two pad blocks
                (63, "03f09f5b158a7a8cdad920bddc29b81c18a551f5"),   // rem=63: two pad blocks
                (64, "0098ba824b5c16427bd7a1122a5a442a25ec644d"),   // exact block: pad-only block
                (65, "11655326c708d70319be2610e8a57d9a5b959d3b"),
                (0, "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
                (256 * 1024, "69f990968cdf7ac2bba8be0e24ecfc8c23a8b5e8"),
                (1024 * 1024, "454027d64e3b855735552d42230eea1cbd645fa0"),
            ]
            for testCase in cases {
                let pieceBytes = 1024 * 1024
                let data = Data(repeating: 0x61, count: testCase.count)
                let digests = try await GPUPieceHasher.hash(
                    pieces: [GPUPieceInput(bytes: data, pieceBytes: pieceBytes)],
                    runtime: runtime,
                    injection: .none
                )
                XCTAssertEqual(digests.count, 1)
                XCTAssertEqual(digests[0].hex, testCase.expected, "GPU SHA-1 piece mismatch for count=\(testCase.count)")
            }
        }
    }

    // Hybrid multi-file with BEP-47 padding must equal the CPU reference.
    func testGPUHybridPaddingMatchesCPU() async throws {
        try await withMetalGate {
            let workspace = try TestWorkspace(name: "ka-hybrid")
            defer { workspace.remove() }
            let corpus = try TestCorpus.make(
                root: workspace.root,
                seed: 42,
                fileSizes: [300_000, 700_000, 2_000_000, 1]
            )
            let backend = ResearchHashingBackend()
            for pieceKiB in [256, 1024, 4096] {
                let cpu = try await CPUReferenceHasher().hash(
                    scannedFiles: corpus.files,
                    pieceSizeBytes: Int64(pieceKiB * 1024),
                    format: .hybrid
                )
                let metal = try await backend.hash(
                    scannedFiles: corpus.files,
                    pieceSizeBytes: Int64(pieceKiB * 1024),
                    format: .hybrid,
                    choice: .metal
                )
                XCTAssertEqual(metal.report.actualEngine, .metal)
                XCTAssertEqual(metal.output, cpu, "hybrid mismatch at \(pieceKiB) KiB")
                XCTAssertEqual(metal.report.fallbackCount, 0)
            }
        }
    }
}

extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
