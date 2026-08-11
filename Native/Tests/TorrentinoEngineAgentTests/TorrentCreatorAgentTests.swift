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
        let summary = try await store.commitCreateVerified(
            token: inspection.token,
            idempotencyKey: IdempotencyKey(),
            assertedOptions: opts,
            independentVerifier: { data in
                let parsed = try MetainfoParser.parse(data)
                return IndependentMetainfoIdentity(v1: parsed.infoHashV1, v2: parsed.infoHashV2)
            },
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

    // MARK: - §15.5 adversarial test matrix (WP-11 item 11)

    // 15.5-1: empty folder.
    func testEmptyFolderScanFails() {
        let emptyDir = tempDirURL.appendingPathComponent("EmptyFolder")
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SourceScanner.scan(sourcePath: emptyDir.path)) { error in
            guard let err = error as? SourceScannerError, case .emptySource = err else {
                XCTFail("Expected emptySource, got \(error)")
                return
            }
        }
    }

    // 15.5-2: zero-byte files (mixed with real content) round-trip through the
    // real pipeline; the zero-byte v2 leaf carries no pieces root, v1 pieces
    // describe only real bytes.
    func testZeroByteFileHybridRoundTrip() async throws {
        let sourceDir = tempDirURL.appendingPathComponent("ZeroByteSource")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try Data().write(to: sourceDir.appendingPathComponent("empty.dat"))
        try Data(repeating: 0x11, count: 4096).write(to: sourceDir.appendingPathComponent("real.dat"))

        let scanResult = try SourceScanner.scan(sourcePath: sourceDir.path, manualPieceSizeKiB: 16)
        let hashingResult = try await CPUHasher().hash(
            scannedFiles: scanResult.files,
            pieceSizeBytes: scanResult.pieceSizeBytes,
            format: .hybrid,
            onProgress: { _, _, _, _ in }
        )
        let torrentBytes = try MetainfoGenerator.buildTorrentFile(
            scanResult: scanResult,
            options: CreateOptions(outputPath: tempDirURL.appendingPathComponent("zero.torrent").path, format: .hybrid),
            hashingResult: hashingResult
        )
        let parsed = try MetainfoParser.parse(torrentBytes)
        XCTAssertEqual(parsed.fileCount, 2)
        XCTAssertEqual(parsed.totalSize, 4096)
        XCTAssertEqual(parsed.files.first { $0.path == "empty.dat" }?.sizeBytes, 0)
    }

    // 15.5-3: unreadable subtree fails the scan (not a warning).
    func testUnreadableSubtreeFailsScan() throws {
        let sourceDir = tempDirURL.appendingPathComponent("LockedSource")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let lockedSub = sourceDir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: lockedSub, withIntermediateDirectories: true)
        try Data(repeating: 0x22, count: 64).write(to: lockedSub.appendingPathComponent("secret.bin"))
        try Data(repeating: 0x23, count: 64).write(to: sourceDir.appendingPathComponent("open.bin"))

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedSub.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedSub.path)
        }

        XCTAssertThrowsError(try SourceScanner.scan(sourcePath: sourceDir.path)) { error in
            guard let err = error as? SourceScannerError, case .unreadableSubtree = err else {
                XCTFail("Expected unreadableSubtree, got \(error)")
                return
            }
        }
    }

    // 15.5-4: source disappears during hashing.
    func testSourceDisappearsDuringHashingFails() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("GonePayload")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        let file1 = payloadDir.appendingPathComponent("gone.bin")
        try Data(repeating: 0x33, count: 64 * 1024).write(to: file1)

        let scanResult = try SourceScanner.scan(sourcePath: payloadDir.path)
        try FileManager.default.removeItem(at: file1)

        do {
            _ = try await CPUHasher().hash(
                scannedFiles: scanResult.files,
                pieceSizeBytes: scanResult.pieceSizeBytes,
                format: .hybrid,
                onProgress: { _, _, _, _ in }
            )
            XCTFail("Should have thrown sourceModified error")
        } catch let err as HasherError {
            // A deleted source fails closed either way: the pre-read identity
            // check reports fileNotFound, the post-read check sourceModified.
            switch err {
            case .fileNotFound, .sourceModified:
                break
            default:
                XCTFail("Unexpected error: \(err)")
            }
        }
    }

    // 15.5-5: external volume detach is indistinguishable from an output
    // directory that cannot be created — the write must fail closed with a
    // typed storage failure and no artifact.
    func testMissingOutputDirectoryFailsClosed() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("MissingOutPayload")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 512).write(to: payloadDir.appendingPathComponent("f.bin"))

        // A FILE occupies the parent path: createDirectory fails (ENOTDIR),
        // the same fail-closed surface as a detached volume (ENOENT).
        let blocker = tempDirURL.appendingPathComponent("blocker")
        try Data(repeating: 0x00, count: 1).write(to: blocker)

        let store = CreatorPlanStore()
        let opts = CreateOptions(
            outputPath: blocker.appendingPathComponent("out.torrent").path,
            format: .v1
        )
        let inspection = try await store.inspectCreateSource(sourcePath: payloadDir.path, options: opts)

        do {
            _ = try await store.commitCreateVerified(
                token: inspection.token,
                idempotencyKey: IdempotencyKey(),
                assertedOptions: opts,
                independentVerifier: { data in
                    let parsed = try MetainfoParser.parse(data)
                    return IndependentMetainfoIdentity(v1: parsed.infoHashV1, v2: parsed.infoHashV2)
                },
                onProgress: { _, _ in }
            )
            XCTFail("Expected storageFailure for missing output directory")
        } catch let fault as EngineFault {
            guard fault.code == .volumeUnavailable else {
                XCTFail("Expected volumeUnavailable, got \(fault.code)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocker.appendingPathComponent("out.torrent").path))
    }

    // 15.5-6: write failure (read-only output directory, standing in for disk
    // full) fails closed: no temp file remains, no final artifact appears.
    func testReadOnlyOutputDirectoryFailsClosed() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("RoPayload")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 512).write(to: payloadDir.appendingPathComponent("f.bin"))

        let readonlyDir = tempDirURL.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: readonlyDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonlyDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readonlyDir.path)
        }

        let store = CreatorPlanStore()
        let target = readonlyDir.appendingPathComponent("out.torrent")
        let opts = CreateOptions(outputPath: target.path, format: .v1)
        let inspection = try await store.inspectCreateSource(sourcePath: payloadDir.path, options: opts)

        do {
            _ = try await store.commitCreateVerified(
                token: inspection.token,
                idempotencyKey: IdempotencyKey(),
                assertedOptions: opts,
                independentVerifier: { data in
                    let parsed = try MetainfoParser.parse(data)
                    return IndependentMetainfoIdentity(v1: parsed.infoHashV1, v2: parsed.infoHashV2)
                },
                onProgress: { _, _ in }
            )
            XCTFail("Expected storageFailure for read-only output directory")
        } catch let fault as EngineFault {
            guard fault.code == .permissionDenied else {
                XCTFail("Expected permissionDenied, got \(fault.code)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: readonlyDir.path)
        XCTAssertTrue(leftovers.isEmpty, "fail-closed write left artifacts: \(leftovers)")
    }

    // 15.5-7: Unicode normalization collisions are rejected. APFS folds NFC
    // and NFD spellings on disk, so the detector is exercised directly with
    // byte-distinct paths that fold to the same NFC form.
    func testUnicodeNormalizationCollisionRejected() {
        XCTAssertNoThrow(try SourceScanner.detectPathCollisions(["a/b.txt", "c/d.txt"]))
        XCTAssertThrowsError(try SourceScanner.detectPathCollisions(["cafe\u{301}/x.txt", "café/x.txt"])) { error in
            guard let err = error as? SourceScannerError, case .pathCollision = err else {
                XCTFail("Expected pathCollision, got \(error)")
                return
            }
        }
    }

    // 15.5-8: overlong paths are rejected by the validation gate the scanner
    // applies to every entry.
    func testOverlongPathsRejected() {
        let longComponent = String(repeating: "a", count: 256)
        XCTAssertEqual(PathValidator.validationError(longComponent), .componentTooLong(longComponent))
        let longPath = String(repeating: "a", count: 4097)
        XCTAssertEqual(PathValidator.validationError(longPath), .pathTooLong)
    }

    // 15.5-9: file-count bound (TransferLimits.maxFiles) aborts the scan.
    func testFileCountBoundAbortsScan() throws {
        let manyDir = tempDirURL.appendingPathComponent("ManyFiles")
        try FileManager.default.createDirectory(at: manyDir, withIntermediateDirectories: true)
        let limit = TransferLimits.maxFiles
        for i in 0..<(limit + 1) {
            let ok = FileManager.default.createFile(
                atPath: manyDir.appendingPathComponent("f\(i).bin").path,
                contents: Data()
            )
            XCTAssertTrue(ok)
        }
        XCTAssertThrowsError(try SourceScanner.scan(sourcePath: manyDir.path)) { error in
            guard let err = error as? SourceScannerError, case .tooManyFiles = err else {
                XCTFail("Expected tooManyFiles, got \(error)")
                return
            }
        }
    }

    // 15.5-10: tracker passkey URLs survive generate → parse round trip.
    func testTrackerPasskeyRoundTrip() async throws {
        let sourceDir = tempDirURL.appendingPathComponent("PasskeySource")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try Data(repeating: 0x66, count: 1024).write(to: sourceDir.appendingPathComponent("f.bin"))

        let passkeyURL = "https://tracker.example.com/announce.php?passkey=0123456789abcdef0123456789abcdef"
        let scanResult = try SourceScanner.scan(sourcePath: sourceDir.path)
        let hashingResult = try await CPUHasher().hash(
            scannedFiles: scanResult.files,
            pieceSizeBytes: scanResult.pieceSizeBytes,
            format: .v1,
            onProgress: { _, _, _, _ in }
        )
        let torrentBytes = try MetainfoGenerator.buildTorrentFile(
            scanResult: scanResult,
            options: CreateOptions(
                outputPath: tempDirURL.appendingPathComponent("passkey.torrent").path,
                format: .v1,
                trackers: [[passkeyURL]],
                isPrivate: true
            ),
            hashingResult: hashingResult
        )
        let parsed = try MetainfoParser.parse(torrentBytes)
        XCTAssertEqual(parsed.trackers, [passkeyURL])
        XCTAssertTrue(parsed.isPrivate)
    }

    // 15.5-11: invalid manual piece size is rejected (non-power-of-2).
    func testInvalidManualPieceSizeRejected() {
        let probe = tempDirURL.appendingPathComponent("ProbeDir")
        try? FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        try? Data(repeating: 0x00, count: 100).write(to: probe.appendingPathComponent("f.bin"))
        XCTAssertThrowsError(try SourceScanner.scan(sourcePath: probe.path, manualPieceSizeKiB: 3)) { error in
            guard let err = error as? SourceScannerError, case .invalidPieceSize = err else {
                XCTFail("Expected invalidPieceSize, got \(error)")
                return
            }
        }
    }

    // 15.5-12: cancellation before any work starts — the operation settles as
    // .cancelled with no temp file and no final artifact.
    func testCancelBeforeHashingFailsClosed() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("CancelPayload")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try Data(repeating: 0x77, count: 2048).write(to: payloadDir.appendingPathComponent("f.bin"))

        let target = tempDirURL.appendingPathComponent("cancelled.torrent")
        let store = CreatorPlanStore()
        let opts = CreateOptions(outputPath: target.path, format: .hybrid)
        let inspection = try await store.inspectCreateSource(sourcePath: payloadDir.path, options: opts)

        let cancelCheck: @Sendable () throws -> Void = { throw HasherError.cancelled }

        do {
            _ = try await store.commitCreateVerified(
                token: inspection.token,
                idempotencyKey: IdempotencyKey(),
                assertedOptions: opts,
                independentVerifier: { data in
                    let parsed = try MetainfoParser.parse(data)
                    return IndependentMetainfoIdentity(v1: parsed.infoHashV1, v2: parsed.infoHashV2)
                },
                onProgress: { _, _ in },
                cancelCheck: cancelCheck
            )
            XCTFail("Expected operationCancelled")
        } catch let fault as EngineFault {
            guard fault.code == .operationCancelled else {
                XCTFail("Expected operationCancelled, got \(fault.code)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    // 15.5-13: v1 / v2 / hybrid interoperability — all three formats parse
    // independently with the correct layout markers (v1: pieces, no file
    // tree; v2: file tree + meta version 2, no pieces; hybrid: both).
    func testV1V2HybridFormatInterop() async throws {
        let sourceDir = tempDirURL.appendingPathComponent("InteropSource")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try Data(repeating: 0x88, count: 16384).write(to: sourceDir.appendingPathComponent("a.bin"))
        try Data(repeating: 0x89, count: 32768).write(to: sourceDir.appendingPathComponent("b.bin"))

        let scanResult = try SourceScanner.scan(sourcePath: sourceDir.path, manualPieceSizeKiB: 16)

        for format in [TorrentFormat.v1, .v2, .hybrid] {
            let hashingResult = try await CPUHasher().hash(
                scannedFiles: scanResult.files,
                pieceSizeBytes: scanResult.pieceSizeBytes,
                format: format,
                onProgress: { _, _, _, _ in }
            )
            let torrentBytes = try MetainfoGenerator.buildTorrentFile(
                scanResult: scanResult,
                options: CreateOptions(outputPath: tempDirURL.appendingPathComponent("\(format).torrent").path, format: format),
                hashingResult: hashingResult
            )
            let parsed = try MetainfoParser.parse(torrentBytes)
            XCTAssertEqual(parsed.fileCount, 2, "format \(format)")
            XCTAssertEqual(parsed.totalSize, 49152, "format \(format)")
            XCTAssertEqual(parsed.name, "InteropSource", "format \(format)")

            switch format {
            case .v1:
                XCTAssertNotNil(parsed.v1PiecesData)
                XCTAssertNil(parsed.infoHashV2)
            case .v2:
                XCTAssertNil(parsed.v1PiecesData)
                XCTAssertNotNil(parsed.infoHashV2)
                XCTAssertEqual(parsed.metaVersion, 2)
            case .hybrid:
                XCTAssertNotNil(parsed.v1PiecesData)
                XCTAssertNotNil(parsed.infoHashV2)
                XCTAssertEqual(parsed.metaVersion, 2)
            }

            // BEP-52 "piece layers" keys are the raw 32-byte pieces-root
            // hashes (libtorrent's parser requires exactly sha256_hash size).
            let root = try BencodeParser.parse(torrentBytes)
            guard case .dictionary(let top, _) = root else {
                XCTFail("torrent is not a dictionary")
                continue
            }
            if let pieceLayers = top.value(for: "piece layers") {
                guard case .dictionary(let layers, _) = pieceLayers else {
                    XCTFail("piece layers is not a dictionary")
                    continue
                }
                XCTAssertFalse(layers.isEmpty)
                for key in layers.keys {
                    XCTAssertEqual(key.count, 32, "format \(format): piece-layers key must be 32 bytes")
                }
            } else {
                XCTAssertEqual(format, .v1, "only v1 may omit piece layers")
            }
        }
    }

    // Review item 9: single-file start seeding must use the CONTAINING
    // directory as savePath, not the file itself.
    func testSingleFileCommitUsesParentDirectorySavePath() async throws {
        let sourceFile = tempDirURL.appendingPathComponent("single.bin")
        try Data(repeating: 0x99, count: 8192).write(to: sourceFile)

        let target = tempDirURL.appendingPathComponent("single.torrent")
        let store = CreatorPlanStore()
        let opts = CreateOptions(outputPath: target.path, format: .v1, seedWhileDownloading: true)
        let inspection = try await store.inspectCreateSource(sourcePath: sourceFile.path, options: opts)

        let observedSavePath = OSAllocatedUnfairLock(initialState: String?.none)
        _ = try await store.commitCreateVerified(
            token: inspection.token,
            idempotencyKey: IdempotencyKey(),
            assertedOptions: opts,
            independentVerifier: { data in
                let parsed = try MetainfoParser.parse(data)
                return IndependentMetainfoIdentity(v1: parsed.infoHashV1, v2: parsed.infoHashV2)
            },
            addTorrent: { _, savePath, _, _ in
                observedSavePath.withLock { $0 = savePath }
            },
            onProgress: { _, _ in }
        )
        let savePath = observedSavePath.withLock { $0 }
        XCTAssertNotNil(savePath)
        if let savePath {
            XCTAssertEqual(
                URL(fileURLWithPath: savePath).resolvingSymlinksInPath().path,
                tempDirURL.resolvingSymlinksInPath().path
            )
        }
    }

    // MARK: - WP-11 Dedicated Contract & Verification Suite

    func testWP11TrackerTopologyVectorPreservesTiersAndRepeatedURLs() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("TopologyPayload")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 4096).write(to: payloadDir.appendingPathComponent("data.bin"))

        let targetTorrent = tempDirURL.appendingPathComponent("topology.torrent")
        let store = CreatorPlanStore()
        let tiers = [
            ["udp://t-a.example:80/announce", "udp://t-b.example:80/announce"],
            ["udp://t-a.example:80/announce", "udp://t-c.example:80/announce"]
        ]
        let opts = CreateOptions(
            outputPath: targetTorrent.path,
            format: .hybrid,
            trackers: tiers,
            isPrivate: false,
            seedWhileDownloading: false
        )

        let inspection = try await store.inspectCreateSource(sourcePath: payloadDir.path, options: opts)
        XCTAssertEqual(inspection.summary.fileCount, 1)
        let summary = try await store.commitCreateVerified(
            token: inspection.token,
            idempotencyKey: IdempotencyKey(),
            assertedOptions: opts,
            independentVerifier: { data in
                let parsed = try MetainfoParser.parse(data)
                return IndependentMetainfoIdentity(v1: parsed.infoHashV1, v2: parsed.infoHashV2)
            },
            onProgress: { _, _ in }
        )
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetTorrent.path))

        let torrentData = try Data(contentsOf: targetTorrent)
        let parsed = try MetainfoParser.parse(torrentData)
        XCTAssertEqual(parsed.trackerTiers.count, 2)
        XCTAssertEqual(parsed.trackerTiers[0], ["udp://t-a.example:80/announce", "udp://t-b.example:80/announce"])
        XCTAssertEqual(parsed.trackerTiers[1], ["udp://t-a.example:80/announce", "udp://t-c.example:80/announce"])
    }

    func testWP11CreatorAssertedOptionsFailClosed() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("AssertedPayload")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 2048).write(to: payloadDir.appendingPathComponent("file.bin"))

        let targetTorrent = tempDirURL.appendingPathComponent("asserted.torrent")
        let store = CreatorPlanStore()
        let opts = CreateOptions(outputPath: targetTorrent.path, format: .v1, isPrivate: false)

        let inspection = try await store.inspectCreateSource(sourcePath: payloadDir.path, options: opts)

        // 1. Unasserted commitCreate fails closed with creatorAssertionMissing
        do {
            _ = try await store.commitCreate(
                token: inspection.token,
                idempotencyKey: IdempotencyKey(),
                onProgress: { _, _ in }
            )
            XCTFail("Expected creatorAssertionMissing for unasserted commit")
        } catch let fault as EngineFault {
            XCTAssertEqual(fault.localizationKey, "creator.fault.assertion_mismatch")
        }

        // 2. Mismatched options commitVerified fails closed with creatorAssertionMismatch
        let mismatchedOpts = CreateOptions(outputPath: targetTorrent.path, format: .v1, trackers: [["udp://t.example:80/announce"]], isPrivate: true)
        do {
            _ = try await store.commitCreateVerified(
                token: inspection.token,
                idempotencyKey: IdempotencyKey(),
                assertedOptions: mismatchedOpts,
                independentVerifier: { data in
                    let parsed = try MetainfoParser.parse(data)
                    return IndependentMetainfoIdentity(v1: parsed.infoHashV1, v2: parsed.infoHashV2)
                },
                onProgress: { _, _ in }
            )
            XCTFail("Expected creatorAssertionMismatch for mismatched options")
        } catch let fault as EngineFault {
            XCTAssertEqual(fault.localizationKey, "creator.fault.assertion_mismatch")
        }
    }
    func testWP11OutputInsideSourceTreeIsExcluded() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("SourceWithOutput")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 5000).write(to: payloadDir.appendingPathComponent("payload.data"))

        let targetTorrent = payloadDir.appendingPathComponent("output.torrent")
        let store = CreatorPlanStore()
        let opts = CreateOptions(outputPath: targetTorrent.path, format: .v1, seedWhileDownloading: false)

        let inspection = try await store.inspectCreateSource(sourcePath: payloadDir.path, options: opts)
        XCTAssertEqual(inspection.summary.fileCount, 1)
        let summary = try await store.commitCreateVerified(
            token: inspection.token,
            idempotencyKey: IdempotencyKey(),
            assertedOptions: opts,
            independentVerifier: { data in
                let parsed = try MetainfoParser.parse(data)
                return IndependentMetainfoIdentity(v1: parsed.infoHashV1, v2: parsed.infoHashV2)
            },
            onProgress: { _, _ in }
        )
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetTorrent.path))

        let torrentData = try Data(contentsOf: targetTorrent)
        let parsed = try MetainfoParser.parse(torrentData)
        XCTAssertEqual(parsed.fileCount, 1)
        XCTAssertEqual(parsed.files.first?.path, "payload.data")
    }

    func testWP11PrivateTrackerRequiresAtLeastOneURL() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("PrivatePayload")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try Data(repeating: 0x66, count: 1024).write(to: payloadDir.appendingPathComponent("priv.bin"))

        let targetTorrent = tempDirURL.appendingPathComponent("private.torrent")
        let store = CreatorPlanStore()
        let emptyPrivateOpts = CreateOptions(outputPath: targetTorrent.path, format: .v1, trackers: [], isPrivate: true)

        do {
            _ = try await store.inspectCreateSource(sourcePath: payloadDir.path, options: emptyPrivateOpts)
            XCTFail("Expected failure for private torrent with no trackers")
        } catch let fault as EngineFault {
            XCTAssertEqual(fault.localizationKey, "creator.fault.private_tracker_missing")
        }
    }

    func testWP11CPUHasherProgressETAAndCancel() async throws {
        let payloadDir = tempDirURL.appendingPathComponent("HasherProgress")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try Data(repeating: 0x77, count: 65536).write(to: payloadDir.appendingPathComponent("chunk.bin"))

        let scanResult = try SourceScanner.scan(sourcePath: payloadDir.path, manualPieceSizeKiB: 16)
        let observedBytes = OSAllocatedUnfairLock(initialState: [Int64]())

        let hashingResult = try await CPUHasher().hash(
            scannedFiles: scanResult.files,
            pieceSizeBytes: scanResult.pieceSizeBytes,
            format: .hybrid,
            onProgress: { processedBytes, totalBytes, processedFiles, totalFiles in
                observedBytes.withLock { $0.append(processedBytes) }
            }
        )
        XCTAssertEqual(hashingResult.totalBytesHashed, 65536)
        let reported = observedBytes.withLock { $0 }
        XCTAssertFalse(reported.isEmpty)
        XCTAssertEqual(reported.last, 65536)

        // Cancel check during hash
        let cancelCheck: @Sendable () throws -> Void = { throw HasherError.cancelled }
        do {
            _ = try await CPUHasher().hash(
                scannedFiles: scanResult.files,
                pieceSizeBytes: scanResult.pieceSizeBytes,
                format: .hybrid,
                cancelCheck: cancelCheck,
                onProgress: { _, _, _, _ in }
            )
            XCTFail("Expected HasherError.cancelled")
        } catch let error as HasherError {
            guard case .cancelled = error else {
                XCTFail("Expected .cancelled, got \(error)")
                return
            }
        }
    }


}
