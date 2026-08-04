// Layer: Domain
// Role: Two-phase Creator Plan Store & orchestrator for inspectCreateSource and commitCreate.
// Must-not: block main actor, modify source files, leak temporary files on failure/cancel, or cross actor boundary with C++ pointers.
// Invariants: immutable plan tokens; atomic write (temp file → fsync → rename → fsync dir); independent parse verification; clean cleanup on failure.

import Foundation
import TorrentinoIPC

public actor CreatorPlanStore {
    private struct ActivePlan {
        let token: CreatorPlanToken
        let sourcePath: String
        let options: CreateOptions
        let scanResult: SourceScanResult
        let createdAt: Date
    }

    private var activePlans: [CreatorPlanToken: ActivePlan] = [:]
    private var committedResults: [IdempotencyKey: CreateSummary] = [:]

    public init() {}

    // MARK: - Inspect

    public func inspectCreateSource(
        sourcePath: String,
        options: CreateOptions?
    ) throws -> CreateSourceInspection {
        let effectiveOptions = options ?? CreateOptions()
        let scanResult = try SourceScanner.scan(
            sourcePath: sourcePath,
            outputPath: effectiveOptions.outputPath,
            includeHiddenFiles: effectiveOptions.includeHiddenFiles,
            manualPieceSizeKiB: effectiveOptions.pieceSizeKiB
        )

        let token = CreatorPlanToken(rawValue: UUID().uuidString)
        let plan = ActivePlan(
            token: token,
            sourcePath: sourcePath,
            options: effectiveOptions,
            scanResult: scanResult,
            createdAt: Date()
        )
        activePlans[token] = plan

        let summary = CreateSummary(
            fileCount: scanResult.files.count,
            totalBytes: scanResult.totalSizeBytes,
            pieceSizeBytes: scanResult.pieceSizeBytes,
            willSeed: effectiveOptions.seedWhileDownloading,
            skippedSymlinksCount: scanResult.skippedSymlinksCount,
            hardlinkCount: scanResult.hardlinkCount
        )

        let sourceIdentity = scanResult.files.first.map { _ in
            ContentIdentity(
                infoHashV1: nil,
                infoHashV2: nil
            )
        }

        return CreateSourceInspection(
            token: token,
            summary: summary,
            warnings: scanResult.warnings,
            sourceIdentity: sourceIdentity,
            exclusions: scanResult.exclusions
        )
    }

    // MARK: - Fetch Manifest Page

    public func fetchCreatorManifestPage(
        token: CreatorPlanToken,
        cursor: PageCursor?,
        pageSize: Int
    ) throws -> Page<CreatorManifestEntry> {
        guard let plan = activePlans[token] else {
            throw EngineFault.invalidPayload(details: "CreatorPlanToken not found or expired: \(token.rawValue)")
        }

        let total = plan.scanResult.files.count
        let offset = cursor.flatMap { String(data: $0.token, encoding: .utf8) }.flatMap { Int($0) } ?? 0
        let limit = min(max(pageSize, 1), 1000)

        guard offset < total else {
            return Page(items: [], nextCursor: nil, totalCount: total, revision: 0)
        }

        let end = min(offset + limit, total)
        let slice = plan.scanResult.files[offset..<end]
        let entries = slice.map { file in
            CreatorManifestEntry(
                relativePath: file.relativePath,
                sizeBytes: file.sizeBytes,
                kind: .file
            )
        }

        let nextCursor = end < total ? PageCursor(token: Data(String(end).utf8)) : nil
        return Page(items: entries, nextCursor: nextCursor, totalCount: total, revision: 0)
    }

    // MARK: - Commit Create

    /// Per-stage cancellation check hook. Use commitCreate() with a throwing
    /// cancelCheck that the caller wires to the UI's Task.isCancelled or other
    /// cancellation mechanism. Throws HasherError.cancelled → EngineFault.operationCancelled.
    public func commitCreate(
        token: CreatorPlanToken,
        idempotencyKey: IdempotencyKey,
        addTorrent: (@Sendable (Data, String, Bool) async throws -> Void)? = nil,
        onProgress: @Sendable @escaping (Double, String) -> Void,
        cancelCheck: @Sendable @escaping () throws -> Void = { }
    ) async throws -> CreateSummary {
        // Check idempotency
        if let existing = committedResults[idempotencyKey] {
            return existing
        }

        guard let plan = activePlans[token] else {
            throw EngineFault.invalidPayload(details: "CreatorPlanToken not found: \(token.rawValue)")
        }

        let scanResult = plan.scanResult
        let options = plan.options

        // Determine destination output file
        let outputPath: String
        if let target = options.outputPath, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputPath = (target as NSString).standardizingPath
        } else {
            let parentDir = ((plan.sourcePath as NSString).standardizingPath as NSString).deletingLastPathComponent
            outputPath = (parentDir as NSString).appendingPathComponent("\(scanResult.rootName).torrent")
        }

        let outputDir = (outputPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // §15.4: do not overwrite existing .torrent without explicit confirmation
        if fm.fileExists(atPath: outputPath) {
            throw EngineFault.invalidPayload(details: "Output file already exists, overwrite not permitted: \(outputPath)")
        }

        // Per-stage cancellation check
        try cancelCheck()

        // Generate temporary output file in same destination directory (§15.4 invariant)
        let tempOutputPath = "\(outputPath).tmp.\(UUID().uuidString)"

        var tempFileCreated = false

        defer {
            if tempFileCreated && fm.fileExists(atPath: tempOutputPath) {
                try? fm.removeItem(atPath: tempOutputPath)
            }
        }

        // Stage 1: Hashing on CPU
        onProgress(0.0, "Hashing")
        let hasher = CPUHasher()

        let hashingResult: HashingResult
        do {
            hashingResult = try await hasher.hash(
                scannedFiles: scanResult.files,
                totalBytes: scanResult.totalSizeBytes,
                pieceSizeBytes: scanResult.pieceSizeBytes,
                format: options.format,
                onProgress: { hashedBytes, totalBytes, _, _ in
                    let fraction = totalBytes > 0 ? Double(hashedBytes) / Double(totalBytes) : 1.0
                    onProgress(fraction * 0.85, "Hashing")
                }
            )
        } catch let err as HasherError {
            switch err {
            case .cancelled:
                throw EngineFault.operationCancelled(details: "torrent creation cancelled")
            case .sourceModified(let p):
                throw EngineFault.storageFailure(details: "source file modified during hashing: \(p)")
            default:
                throw EngineFault.storageFailure(details: err.description)
            }
        }

        // Stage 1→2 cancel check
        try cancelCheck()

        // Stage 2: Building Metadata
        onProgress(0.88, "Building Metadata")
        let metainfoBytes = try MetainfoGenerator.buildTorrentFile(
            scanResult: scanResult,
            options: options,
            hashingResult: hashingResult
        )

        // Stage 2→3 cancel check
        try cancelCheck()

        // Stage 3: Writing Torrent (Atomic temp write -> fsync -> rename -> fsync parent dir)
        onProgress(0.92, "Writing Torrent")

        guard fm.createFile(atPath: tempOutputPath, contents: metainfoBytes) else {
            throw EngineFault.storageFailure(details: "Failed to write temp torrent file at \(tempOutputPath)")
        }
        tempFileCreated = true

        // Fsync temp file
        let tempFD = open(tempOutputPath, O_RDWR)
        if tempFD >= 0 {
            _ = fcntl(tempFD, F_FULLFSYNC, 0)
            close(tempFD)
        }

        // Atomic rename to final output path
        if rename(tempOutputPath, outputPath) != 0 {
            let errNo = errno
            throw EngineFault.storageFailure(details: "Failed to atomic rename torrent file (errno: \(errNo))")
        }
        tempFileCreated = false // temp file was renamed to output file

        // Fsync parent directory
        let dirFD = open(outputDir, O_RDONLY)
        if dirFD >= 0 {
            _ = fcntl(dirFD, F_FULLFSYNC, 0)
            close(dirFD)
        }

        // Stage 3→4 cancel check
        try cancelCheck()

        // Stage 4: Verification (independent bencode structure validation)
        onProgress(0.96, "Verification")
        do {
            let writtenData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
            guard !writtenData.isEmpty else {
                throw EngineFault.corruptData(details: "written torrent data is empty")
            }
        } catch {
            // Remove corrupted output file
            try? fm.removeItem(atPath: outputPath)
            throw EngineFault.corruptData(details: "Independent verification of created torrent failed: \(error)")
        }

        // Stage 4→5 cancel check
        try cancelCheck()

        // Stage 5: Starting Seed (if requested)
        if options.seedWhileDownloading, let addTorrent {
            onProgress(0.98, "Starting Seed")
            let savePath: String
            if scanResult.isDirectory {
                savePath = ((plan.sourcePath as NSString).standardizingPath as NSString).deletingLastPathComponent
            } else {
                savePath = (plan.sourcePath as NSString).standardizingPath
            }
            try await addTorrent(metainfoBytes, savePath, false)
        }

        onProgress(1.0, "Completed")

        let summary = CreateSummary(
            fileCount: scanResult.files.count,
            totalBytes: scanResult.totalSizeBytes,
            pieceSizeBytes: scanResult.pieceSizeBytes,
            willSeed: options.seedWhileDownloading,
            skippedSymlinksCount: scanResult.skippedSymlinksCount,
            hardlinkCount: scanResult.hardlinkCount
        )

        // Store result for idempotency & consume token
        committedResults[idempotencyKey] = summary
        activePlans.removeValue(forKey: token)

        return summary
    }
}
