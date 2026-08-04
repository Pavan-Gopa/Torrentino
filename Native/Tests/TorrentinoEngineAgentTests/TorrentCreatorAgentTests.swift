// Layer: Tests (EngineAgent)
// Role: Integration & concurrency tests for Creator flow (CPUHasher, CreatorPlanStore, atomic write, edge cases).
// Must-not: leave orphaned temporary files or block indefinitely.
// Invariants: temp files cleaned up; source modification detected; independent parse verification green.

import XCTest
import os
import TorrentinoDomain
import TorrentinoIPC
@testable import TorrentinoEngineAgent

final class TorrentCreatorAgentTests: XCTestCase {
    private var tempDirURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TorrentinoAgentCreatorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirURL, FileManager.default.fileExists(atPath: tempDirURL.path) {
            try? FileManager.default.removeItem(at: tempDirURL)
        }
        try super.tearDownWithError()
    }

    func testCPUHasherV1AndV2SingleReadEpoch() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        let file1 = payloadDir.appendingPathComponent("sample.txt")
        let data1 = Data(repeating: 0x55, count: 32768) // 32 KiB
        try data1.write(to: file1)

        let scanResult = try SourceScanner.scan(sourcePath: payloadDir.path, manualPieceSizeKiB: 16)
        let hasher = CPUHasher()

        let progressReported = OSAllocatedUnfairLock(initialState: false)
        let hashingResult = try await hasher.hash(
            scannedFiles: scanResult.files,
            totalBytes: scanResult.totalSizeBytes,
            pieceSizeBytes: scanResult.pieceSizeBytes,
            format: .hybrid,
            onProgress: { _, _, _, _ in
                progressReported.withLock { $0 = true }
            }
        )

        XCTAssertTrue(progressReported.withLock { $0 })
        XCTAssertEqual(hashingResult.totalBytesHashed, 32768)
        XCTAssertEqual(hashingResult.v1PiecesData.count, 40) // 32 KiB / 16 KiB = 2 pieces -> 40 bytes SHA-1
        XCTAssertEqual(hashingResult.v2FileTrees.count, 1)
        XCTAssertNotNil(hashingResult.v2FileTrees["sample.txt"])
    }

    func testCreatorPlanStoreTwoPhaseFlowAndAtomicWrite() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("SourceFiles")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        let file1 = payloadDir.appendingPathComponent("document.pdf")
        try Data(repeating: 0x12, count: 10000).write(to: file1)

        let targetTorrent = tempDirURL.appendingPathComponent("output.torrent")

        let store = CreatorPlanStore()
        let opts = CreateOptions(
            outputPath: targetTorrent.path,
            format: .hybrid,
            seedWhileDownloading: false
        )

        // Phase 1: Inspect
        let inspection = try await store.inspectCreateSource(sourcePath: payloadDir.path, options: opts)
        XCTAssertEqual(inspection.summary.fileCount, 1)
        XCTAssertEqual(inspection.summary.totalBytes, 10000)

        // Paginated manifest check
        let page = try await store.fetchCreatorManifestPage(token: inspection.token, cursor: nil, pageSize: 10)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.relativePath, "document.pdf")

        // Phase 2: Commit
        let summary = try await store.commitCreate(
            token: inspection.token,
            idempotencyKey: IdempotencyKey(),
            onProgress: { _, _ in }
        )

        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetTorrent.path))

        // Independent parse verification
        let torrentData = try Data(contentsOf: targetTorrent)
        let parsed = try MetainfoParser.parse(torrentData)
        XCTAssertEqual(parsed.name, "SourceFiles")
        XCTAssertEqual(parsed.fileCount, 1)
        XCTAssertEqual(parsed.totalSize, 10000)
    }

    func testSourceModifiedDuringHashingFails() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("ModPayload")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        let file1 = payloadDir.appendingPathComponent("mod.txt")
        try "Original Content".write(to: file1, atomically: true, encoding: .utf8)

        let scanResult = try SourceScanner.scan(sourcePath: payloadDir.path)

        // Modify file after scan
        try "Modified Content After Scan!".write(to: file1, atomically: true, encoding: .utf8)

        let hasher = CPUHasher()
        do {
            _ = try await hasher.hash(
                scannedFiles: scanResult.files,
                totalBytes: scanResult.totalSizeBytes,
                pieceSizeBytes: scanResult.pieceSizeBytes,
                format: .hybrid,
                onProgress: { _, _, _, _ in }
            )
            XCTFail("Should have thrown sourceModified error")
        } catch let err as HasherError {
            if case .sourceModified = err {
                // Expected
            } else {
                XCTFail("Unexpected error: \(err)")
            }
        }
    }
}
