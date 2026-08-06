// Layer: Tests (Domain)
// Role: Unit tests for Torrent Creator domain components (SourceScanner, BencodeEncoder, MetainfoGenerator).
// Must-not: mutate system files or rely on network.
// Invariants: test isolation; deterministic assertions; temporary directory cleanup.

import XCTest
import TorrentinoDomain
import TorrentinoIPC

final class TorrentCreatorDomainTests: XCTestCase {
    private var tempDirURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TorrentinoCreatorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirURL, FileManager.default.fileExists(atPath: tempDirURL.path) {
            try? FileManager.default.removeItem(at: tempDirURL)
        }
        try super.tearDownWithError()
    }

    func testSourceScannerExclusionsAndSymlinks() throws {
        let sourceDir = tempDirURL.appendingPathComponent("SourcePayload")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        // Create standard files
        let file1 = sourceDir.appendingPathComponent("file1.txt")
        try "Hello World".write(to: file1, atomically: true, encoding: .utf8)

        let subDir = sourceDir.appendingPathComponent("SubFolder")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let file2 = subDir.appendingPathComponent("file2.bin")
        try Data(repeating: 0x42, count: 2048).write(to: file2)

        // Create default excluded files
        let dsStore = sourceDir.appendingPathComponent(".DS_Store")
        try "ds".write(to: dsStore, atomically: true, encoding: .utf8)

        let appleDouble = sourceDir.appendingPathComponent("._file1.txt")
        try "resource".write(to: appleDouble, atomically: true, encoding: .utf8)

        // Create symlink
        let symlink = sourceDir.appendingPathComponent("symlink.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file1)

        // Perform scan
        let result = try SourceScanner.scan(sourcePath: sourceDir.path)

        XCTAssertTrue(result.isDirectory)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(result.skippedSymlinksCount, 1)
        XCTAssertTrue(result.exclusions.contains(".DS_Store"))
        XCTAssertEqual(result.files.map(\.relativePath), ["SubFolder/file2.bin", "file1.txt"])
    }

    func testSourceScannerOutputInsideSourceTreeExcluded() throws {
        let sourceDir = tempDirURL.appendingPathComponent("SourceTree")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let file1 = sourceDir.appendingPathComponent("data.bin")
        try Data(repeating: 0x01, count: 500).write(to: file1)

        let outputInside = sourceDir.appendingPathComponent("result.torrent")
        try "dummy torrent".write(to: outputInside, atomically: true, encoding: .utf8)

        let result = try SourceScanner.scan(sourcePath: sourceDir.path, outputPath: outputInside.path)

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.relativePath, "data.bin")
    }

    func testAutomaticPieceSizeCalculation() {
        // The algorithm targets ~1000 pieces and rounds UP to the next power of 2.
        // Edge: tiny source → min piece size.
        XCTAssertEqual(SourceScanner.calculateAutomaticPieceSize(totalSizeBytes: 100), 16 * 1024)
        // 50 MiB / 1000 ≈ 51 KiB → next power of 2 = 64 KiB.
        XCTAssertEqual(SourceScanner.calculateAutomaticPieceSize(totalSizeBytes: 50 * 1024 * 1024), 64 * 1024)
        // 2 GiB / 1000 ≈ 2.1 MiB → next power of 2 = 4 MiB.
        XCTAssertEqual(SourceScanner.calculateAutomaticPieceSize(totalSizeBytes: 2 * 1024 * 1024 * 1024), 4 * 1024 * 1024)
    }

    func testBencodeEncoderAndMetainfoParserRoundTrip() async throws {
        // Round trip through the real pipeline: scan → hash (CPUHasher) →
        // generate (MetainfoGenerator) → parse (MetainfoParser). Fabricated
        // hashes are deliberately NOT accepted here: the hybrid cross-check
        // and the v2 pieces-root validation reject torrents whose file tree
        // has no real merkle roots.
        let sourceDir = tempDirURL.appendingPathComponent("TestRoot")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 100).write(to: sourceDir.appendingPathComponent("a.txt"))
        try Data(repeating: 0x02, count: 200).write(to: sourceDir.appendingPathComponent("b.txt"))

        let scanResult = try SourceScanner.scan(sourcePath: sourceDir.path, manualPieceSizeKiB: 16)

        let hashingResult = try await CPUHasher().hash(
            scannedFiles: scanResult.files,
            pieceSizeBytes: scanResult.pieceSizeBytes,
            format: .hybrid,
            onProgress: { _, _, _, _ in }
        )

        let options = CreateOptions(
            outputPath: tempDirURL.appendingPathComponent("test.torrent").path,
            format: .hybrid,
            trackers: [["https://tracker.example.com/announce"]],
            isPrivate: true,
            comment: "Test torrent",
            source: "TorrentinoTest"
        )

        let torrentBytes = try MetainfoGenerator.buildTorrentFile(
            scanResult: scanResult,
            options: options,
            hashingResult: hashingResult
        )

        // Verify independent parse
        let parsed = try MetainfoParser.parse(torrentBytes)
        XCTAssertEqual(parsed.name, "TestRoot")
        XCTAssertEqual(parsed.pieceLength, 16 * 1024)
        XCTAssertEqual(parsed.fileCount, 2)
        XCTAssertEqual(parsed.totalSize, 300)
        XCTAssertTrue(parsed.isPrivate)
        XCTAssertEqual(parsed.trackers, ["https://tracker.example.com/announce"])
    }
}
