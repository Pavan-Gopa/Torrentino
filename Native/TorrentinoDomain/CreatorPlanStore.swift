// Layer: Domain
// Role: Two-phase Creator Plan Store & orchestrator for inspectCreateSource
// and commitCreate.
// Must-not: block the main actor, modify source files, leak temporary files on
// failure/cancel, or cross an actor boundary with C++ pointers.
// Invariants: immutable plans bind canonical options, source generation,
// resolved output leaf, and destination identity; every post-acquisition leaf
// operation is descriptor-relative; final bytes pass Domain checks and the
// pinned libtorrent verifier before a token is consumed.

import Foundation
#if canImport(TorrentinoIPC)
import TorrentinoIPC
#endif
import Darwin

public actor CreatorPlanStore {
    /// Root directory mtime is diagnostic only and is deliberately absent from
    /// generation equality: publishing an excluded output leaf may update it.
    private struct SourceFingerprint: Sendable, Equatable {
        struct Entry: Sendable, Equatable {
            let path: String
            let sizeBytes: Int64
            let deviceID: UInt64
            let fileResourceID: UInt64
            let mtimeSeconds: Int64
            let mtimeNanos: Int64
        }

        let isDirectory: Bool
        let rootName: String
        let rootDeviceID: UInt64
        let rootResourceID: UInt64
        let outputPath: String
        let includeHiddenFiles: Bool
        let manualPieceSizeKiB: Int64?
        let entries: [Entry]

        init(_ scan: SourceScanResult, outputPath: String, options: CreateOptions) {
            isDirectory = scan.isDirectory
            rootName = scan.rootName
            rootDeviceID = scan.rootDeviceID
            rootResourceID = scan.rootResourceID
            self.outputPath = outputPath
            includeHiddenFiles = options.includeHiddenFiles
            manualPieceSizeKiB = options.pieceSizeKiB
            entries = scan.files.map {
                Entry(
                    path: $0.relativePath,
                    sizeBytes: $0.sizeBytes,
                    deviceID: $0.deviceID,
                    fileResourceID: $0.fileResourceID,
                    mtimeSeconds: $0.mtimeSeconds,
                    mtimeNanos: $0.mtimeNanos
                )
            }
        }
    }

    private struct DestinationIdentity: Sendable, Equatable {
        let deviceID: UInt64
        let resourceID: UInt64
    }

    private struct OpenDestination: Sendable {
        let fileDescriptor: Int32
        let identity: DestinationIdentity
    }

    private struct ActivePlan {
        let token: CreatorPlanToken
        let sourcePath: String
        let options: CreateOptions
        let resolvedOutputPath: String
        let outputLeaf: String
        let destinationDirectory: String
        let destinationIdentity: DestinationIdentity?
        let scanResult: SourceScanResult
        let fingerprint: SourceFingerprint
    }

    private var activePlans: [CreatorPlanToken: ActivePlan] = [:]
    private var committingTokens: Set<CreatorPlanToken> = []

    public init() {}

    // MARK: - Safe destination helpers

    private static func canonicalAbsolutePath(_ rawPath: String) -> String {
        SourceScanner.canonicalAbsolutePath(rawPath)
    }

    private static func resolvedOutputPath(sourcePath: String, options: CreateOptions) throws -> String {
        let canonicalSource = canonicalAbsolutePath(sourcePath)
        if let requested = options.outputPath, !requested.isEmpty {
            return canonicalAbsolutePath(requested)
        }
        let rootName = (canonicalSource as NSString).lastPathComponent
        guard !rootName.isEmpty else {
            throw EngineFault.invalidPayload(details: "source has no usable output name")
        }
        let parent = (canonicalSource as NSString).deletingLastPathComponent
        return canonicalAbsolutePath((parent as NSString).appendingPathComponent("\(rootName).torrent"))
    }

    private static func outputComponents(outputPath: String) throws -> (directory: String, leaf: String) {
        let canonical = canonicalAbsolutePath(outputPath)
        let leaf = (canonical as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/") else {
            throw EngineFault.invalidPayload(details: "output path must name one regular file leaf")
        }
        let directory = (canonical as NSString).deletingLastPathComponent
        guard !directory.isEmpty else {
            throw EngineFault.invalidPayload(details: "output path has no destination directory")
        }
        return (directory, leaf)
    }

    /// Walks every destination component with O_NOFOLLOW. The returned FD is
    /// the directory used by the transaction; no later leaf operation falls
    /// back to the original path.
    private static func openDestination(_ path: String) throws -> OpenDestination {
        let canonical = canonicalAbsolutePath(path)
        guard canonical.hasPrefix("/") else {
            throw EngineFault.storageFailure(details: "destination path is not absolute")
        }

        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            let errorNumber = errno
            throw EngineFault.storageFailure(
                details: "open destination root failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))"
            )
        }

        let components = canonical.split(separator: "/", omittingEmptySubsequences: true)
        for component in components {
            let next = component.withCString { name in
                openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard next >= 0 else {
                let errorNumber = errno
                _ = Darwin.close(descriptor)
                throw EngineFault.storageFailure(
                    details: "destination component '\(component)' is not safely resolvable (errno \(errorNumber), \(String(cString: strerror(errorNumber))))"
                )
            }
            guard Darwin.close(descriptor) == 0 else {
                let errorNumber = errno
                _ = Darwin.close(next)
                throw EngineFault.storageFailure(
                    details: "close destination walk descriptor failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))"
                )
            }
            descriptor = next
        }

        var statBuffer = stat()
        guard fstat(descriptor, &statBuffer) == 0 else {
            let errorNumber = errno
            _ = Darwin.close(descriptor)
            throw EngineFault.storageFailure(
                details: "stat destination directory failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))"
            )
        }
        guard (statBuffer.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(descriptor)
            throw EngineFault.storageFailure(details: "destination is not a directory")
        }
        return OpenDestination(
            fileDescriptor: descriptor,
            identity: DestinationIdentity(
                deviceID: UInt64(statBuffer.st_dev),
                resourceID: UInt64(statBuffer.st_ino)
            )
        )
    }

    private static func inspectDestinationIdentity(at path: String) throws -> DestinationIdentity {
        let opened = try openDestination(path)
        guard Darwin.close(opened.fileDescriptor) == 0 else {
            let errorNumber = errno
            throw EngineFault.storageFailure(
                details: "close destination inspection descriptor failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))"
            )
        }
        return opened.identity
    }

    private static func ensureLeafAbsent(directoryFD: Int32, leaf: String) throws {
        var existing = stat()
        if fstatat(directoryFD, leaf, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            throw EngineFault.invalidPayload(details: "Output file already exists, overwrite not permitted: \(leaf)")
        }
        let errorNumber = errno
        guard errorNumber == ENOENT else {
            throw EngineFault.storageFailure(
                details: "cannot inspect output leaf '\(leaf)' (errno \(errorNumber), \(String(cString: strerror(errorNumber))))"
            )
        }
    }

    private static func syncDurably(_ descriptor: Int32, label: String) throws {
        // F_FULLFSYNC is the supported macOS durability primitive. There is
        // no silent fsync fallback: if this barrier is unavailable, publication
        // fails closed instead of claiming durable output.
        guard fcntl(descriptor, F_FULLFSYNC, 0) == 0 else {
            let errorNumber = errno
            throw EngineFault.storageFailure(
                details: "\(label) durability barrier failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))"
            )
        }
    }

    private static func readAll(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return -1 }
                return Darwin.read(descriptor, baseAddress, bytes.count)
            }
            if count == 0 { return result }
            guard count > 0 else {
                let errorNumber = errno
                throw EngineFault.storageFailure(
                    details: "read final torrent failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))"
                )
            }
            guard result.count <= TransferLimits.maxTorrentFileBytes - count else {
                throw EngineFault.corruptData(details: "final torrent exceeds the supported size limit")
            }
            result.append(contentsOf: buffer[0..<count])
        }
    }

    // MARK: - Options / inspect

    private static func validateCreateOptions(_ options: CreateOptions) throws {
        var trackerCount = 0
        for tier in options.trackers {
            guard !tier.isEmpty else {
                throw EngineFault.invalidPayload(details: "tracker tiers must not be empty")
            }
            for rawURL in tier {
                guard TrackerURLValidator.isSupported(rawURL) else {
                    throw EngineFault.invalidPayload(details: "invalid tracker URL")
                }
                trackerCount += 1
                guard trackerCount <= TransferLimits.maxTrackers else {
                    throw EngineFault.invalidPayload(details: "too many trackers")
                }
            }
        }
        if options.isPrivate && trackerCount == 0 {
            throw EngineFault.creatorPrivateTrackerMissing()
        }
    }

    public func inspectCreateSource(
        sourcePath: String,
        options: CreateOptions?
    ) throws -> CreateSourceInspection {
        // A new inspection request supersedes the previous one immediately;
        // validation or scanning failure must not leave the old token usable.
        activePlans.removeAll(keepingCapacity: true)
        let effectiveOptions = (options ?? CreateOptions()).canonicalSnapshot
        try Self.validateCreateOptions(effectiveOptions)
        let canonicalSource = Self.canonicalAbsolutePath(sourcePath)
        let resolvedOutput = try Self.resolvedOutputPath(sourcePath: canonicalSource, options: effectiveOptions)
        let destination = try Self.outputComponents(outputPath: resolvedOutput)
        let destinationIdentity: DestinationIdentity?
        do {
            destinationIdentity = try Self.inspectDestinationIdentity(at: destination.directory)
        } catch let fault as EngineFault where fault.code == .volumeUnavailable {
            // Keep the plan so commit can return the typed unavailable-volume
            // result without hashing or creating anything. Existing
            // destinations still bind their descriptor identity here.
            destinationIdentity = nil
        }
        let scanResult = try SourceScanner.scan(
            sourcePath: canonicalSource,
            outputPath: resolvedOutput,
            includeHiddenFiles: effectiveOptions.includeHiddenFiles,
            manualPieceSizeKiB: effectiveOptions.pieceSizeKiB
        )

        let token = CreatorPlanToken(rawValue: UUID().uuidString)
        activePlans[token] = ActivePlan(
            token: token,
            sourcePath: canonicalSource,
            options: effectiveOptions,
            resolvedOutputPath: resolvedOutput,
            outputLeaf: destination.leaf,
            destinationDirectory: destination.directory,
            destinationIdentity: destinationIdentity,
            scanResult: scanResult,
            fingerprint: SourceFingerprint(scanResult, outputPath: resolvedOutput, options: effectiveOptions)
        )

        return CreateSourceInspection(
            token: token,
            summary: CreateSummary(
                fileCount: scanResult.files.count,
                totalBytes: scanResult.totalSizeBytes,
                pieceSizeBytes: scanResult.pieceSizeBytes,
                willSeed: effectiveOptions.seedWhileDownloading,
                skippedSymlinksCount: scanResult.skippedSymlinksCount,
                hardlinkCount: scanResult.hardlinkCount
            ),
            warnings: scanResult.warnings,
            sourceIdentity: nil,
            exclusions: scanResult.exclusions
        )
    }

    // MARK: - Manifest

    public func fetchCreatorManifestPage(
        token: CreatorPlanToken,
        cursor: PageCursor?,
        pageSize: Int
    ) throws -> Page<CreatorManifestEntry> {
        guard let plan = activePlans[token] else {
            throw EngineFault.creatorStalePlan(details: "creator plan token not found or expired")
        }
        let total = plan.scanResult.files.count
        let offset = cursor.flatMap { String(data: $0.token, encoding: .utf8) }.flatMap { Int($0) } ?? 0
        let limit = min(max(pageSize, 1), 1000)
        guard offset < total else {
            return Page(items: [], nextCursor: nil, totalCount: total, revision: 0)
        }
        let end = min(offset + limit, total)
        let entries = plan.scanResult.files[offset..<end].map {
            CreatorManifestEntry(relativePath: $0.relativePath, sizeBytes: $0.sizeBytes, kind: .file)
        }
        let nextCursor = end < total ? PageCursor(token: Data(String(end).utf8)) : nil
        return Page(items: entries, nextCursor: nextCursor, totalCount: total, revision: 0)
    }

    // MARK: - Commit

    /// Former callers without a complete caller assertion are retained only as
    /// a fail-closed source-compatibility stub. No creator side effect is
    /// reachable through this shape.
    public func commitCreate(
        token: CreatorPlanToken,
        idempotencyKey: IdempotencyKey,
        addTorrent: (@Sendable (Data, String, Bool, Bool) async throws -> Void)? = nil,
        onProgress: @Sendable @escaping (Double, OperationProgressDetail) async -> Void,
        cancelCheck: @Sendable @escaping () throws -> Void = { }
    ) async throws -> CreateSummary {
        throw EngineFault.creatorAssertionMissing()
    }

    /// Production commit boundary. The complete asserted options and the
    /// pinned libtorrent verifier are mandatory before any hashing or writing.
    public func commitCreateVerified(
        token: CreatorPlanToken,
        idempotencyKey: IdempotencyKey,
        assertedOptions: CreateOptions,
        independentVerifier: @Sendable @escaping (Data) async throws -> IndependentMetainfoIdentity,
        addTorrent: (@Sendable (Data, String, Bool, Bool) async throws -> Void)? = nil,
        onProgress: @Sendable @escaping (Double, OperationProgressDetail) async -> Void,
        cancelCheck: @Sendable @escaping () throws -> Void = { }
    ) async throws -> CreateSummary {
        try await commitCreateInternal(
            token: token,
            idempotencyKey: idempotencyKey,
            assertedOptions: assertedOptions,
            independentVerifier: independentVerifier,
            addTorrent: addTorrent,
            onProgress: onProgress,
            cancelCheck: cancelCheck
        )
    }

    private func commitCreateInternal(
        token: CreatorPlanToken,
        idempotencyKey: IdempotencyKey,
        assertedOptions: CreateOptions,
        independentVerifier: @Sendable (Data) async throws -> IndependentMetainfoIdentity,
        addTorrent: (@Sendable (Data, String, Bool, Bool) async throws -> Void)?,
        onProgress: @Sendable @escaping (Double, OperationProgressDetail) async -> Void,
        cancelCheck: @Sendable @escaping () throws -> Void
    ) async throws -> CreateSummary {
        guard let plan = activePlans[token] else {
            throw EngineFault.creatorStalePlan(details: "creator plan token not found, expired, or already consumed")
        }
        let options = assertedOptions.canonicalSnapshot
        guard options == plan.options else {
            throw EngineFault.creatorAssertionMismatch()
        }
        guard committingTokens.insert(token).inserted else {
            throw EngineFault.creatorOperationConflict(details: "creator plan is already being committed")
        }
        // A token is one-shot at the agent boundary. Invalidating it on every
        // terminal attempt prevents concurrent retries from co-owning the
        // same plan or publishing a second artifact after a failure.
        defer {
            committingTokens.remove(token)
            activePlans.removeValue(forKey: token)
        }
        try Self.validateCreateOptions(options)

        func cancelledFault() throws {
            do {
                try cancelCheck()
            } catch let err as HasherError where err == .cancelled {
                throw EngineFault.creatorCancelled()
            } catch is CancellationError {
                throw EngineFault.creatorCancelled()
            }
        }

        try cancelledFault()
        await onProgress(0, OperationProgressDetail(
            stage: "Scanning", backend: "cpu", processedBytes: 0,
            totalBytes: plan.scanResult.totalSizeBytes, fileCount: 0,
            totalFileCount: plan.scanResult.files.count, etaSeconds: nil, isCancelled: false
        ))

        let freshScan: SourceScanResult
        do {
            freshScan = try SourceScanner.scan(
                sourcePath: plan.sourcePath,
                outputPath: plan.resolvedOutputPath,
                includeHiddenFiles: options.includeHiddenFiles,
                manualPieceSizeKiB: options.pieceSizeKiB
            )
        } catch let error as SourceScannerError {
            throw EngineFault.storageFailure(details: "source rescan failed: \(error.description)")
        }
        guard SourceFingerprint(freshScan, outputPath: plan.resolvedOutputPath, options: options) == plan.fingerprint else {
            throw EngineFault.storageFailure(details: "source changed since inspection; re-inspect before creating")
        }

        func revalidateSourceGeneration() throws {
            let current: SourceScanResult
            do {
                current = try SourceScanner.scan(
                    sourcePath: plan.sourcePath,
                    outputPath: plan.resolvedOutputPath,
                    includeHiddenFiles: options.includeHiddenFiles,
                    manualPieceSizeKiB: options.pieceSizeKiB
                )
            } catch let error as SourceScannerError {
                throw EngineFault.storageFailure(details: "source rescan failed: \(error.description)")
            }
            guard SourceFingerprint(current, outputPath: plan.resolvedOutputPath, options: options) == plan.fingerprint else {
                throw EngineFault.storageFailure(details: "source changed since inspection; re-inspect before creating")
            }
        }

        var directoryFD: Int32 = -1
        var rollbackFD: Int32 = -1
        var tempFD: Int32 = -1
        var finalFD: Int32 = -1
        var tempName: String?
        var tempFileCreated = false
        var finalFilePlaced = false
        var seedAdmissionCommitted = false

        do {
            let opened = try Self.openDestination(plan.destinationDirectory)
            directoryFD = opened.fileDescriptor
            guard let expectedDestinationIdentity = plan.destinationIdentity else {
                throw EngineFault.volumeUnavailable(details: "creator output directory is unavailable")
            }
            guard opened.identity == expectedDestinationIdentity else {
                throw EngineFault.storageFailure(details: "destination directory identity changed; re-inspect before creating")
            }
            rollbackFD = Darwin.dup(directoryFD)
            guard rollbackFD >= 0 else {
                let errorNumber = errno
                throw EngineFault.storageFailure(details: "duplicate destination rollback descriptor failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))")
            }
            try Self.ensureLeafAbsent(directoryFD: directoryFD, leaf: plan.outputLeaf)
            try cancelledFault()

            // Stage 1: CPU hashing, with identity checks on every source FD.
            await onProgress(0.02, OperationProgressDetail(
                stage: "Hashing", backend: "cpu", processedBytes: 0,
                totalBytes: freshScan.totalSizeBytes, fileCount: 0,
                totalFileCount: freshScan.files.count, etaSeconds: nil, isCancelled: false
            ))
            let hashingStart = Date()
            let hashingResult: HashingResult
            do {
                hashingResult = try await CPUHasher().hash(
                    scannedFiles: freshScan.files,
                    pieceSizeBytes: freshScan.pieceSizeBytes,
                    format: options.format,
                    cancelCheck: cancelCheck,
                    onProgress: { hashedBytes, totalBytes, fileCount, totalFileCount in
                        let fraction = totalBytes > 0 ? Double(hashedBytes) / Double(totalBytes) : 1
                        let elapsed = Date().timeIntervalSince(hashingStart)
                        let eta: Int64?
                        if elapsed > 0.5, hashedBytes > 0 {
                            let rate = Double(hashedBytes) / elapsed
                            eta = rate > 0 ? Int64(Double(totalBytes - hashedBytes) / rate) : nil
                        } else {
                            eta = nil
                        }
                        await onProgress(fraction * 0.85, OperationProgressDetail(
                            stage: "Hashing", backend: "cpu", processedBytes: hashedBytes,
                            totalBytes: totalBytes, fileCount: fileCount,
                            totalFileCount: totalFileCount, etaSeconds: eta, isCancelled: false
                        ))
                    }
                )
            } catch let error as HasherError {
                switch error {
                case .cancelled:
                    throw EngineFault.creatorCancelled()
                case .sourceModified(let path):
                    throw EngineFault.storageFailure(details: "source file modified during hashing: \(path)")
                default:
                    throw EngineFault.storageFailure(details: error.description)
                }
            } catch is CancellationError {
                throw EngineFault.creatorCancelled()
            }
            try cancelledFault()
            try revalidateSourceGeneration()

            // Stage 2: metadata and exact raw-info expectations.
            await onProgress(0.88, OperationProgressDetail(
                stage: "Building Metadata", backend: "cpu",
                processedBytes: freshScan.totalSizeBytes, totalBytes: freshScan.totalSizeBytes,
                fileCount: freshScan.files.count, totalFileCount: freshScan.files.count,
                etaSeconds: nil, isCancelled: false
            ))
            let metainfoBytes = try MetainfoGenerator.buildTorrentFile(
                scanResult: freshScan, options: options, hashingResult: hashingResult
            )
            let expectedIdentity = try MetainfoIdentity.expected(from: metainfoBytes, format: options.format)
            try cancelledFault()

            // Stage 3: all output names are relative to the captured directory.
            await onProgress(0.92, OperationProgressDetail(
                stage: "Writing Torrent", backend: "cpu", processedBytes: 0,
                totalBytes: Int64(metainfoBytes.count), fileCount: 0, totalFileCount: 1,
                etaSeconds: nil, isCancelled: false
            ))
            let generatedTempName = "\(plan.outputLeaf).tmp.\(UUID().uuidString)"
            tempName = generatedTempName
            tempFD = generatedTempName.withCString { name in
                openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            }
            guard tempFD >= 0 else {
                let errorNumber = errno
                throw EngineFault.storageFailure(details: "open relative temp file failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))")
            }
            tempFileCreated = true

            var written = 0
            while written < metainfoBytes.count {
                try cancelledFault()
                let count = metainfoBytes.withUnsafeBytes { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return 0 }
                    return Darwin.write(tempFD, baseAddress.advanced(by: written), metainfoBytes.count - written)
                }
                guard count > 0 else {
                    let errorNumber = errno
                    throw EngineFault.storageFailure(details: "write temp file failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))")
                }
                written += count
            }
            try Self.syncDurably(tempFD, label: "temporary torrent file")
            guard Darwin.close(tempFD) == 0 else {
                let errorNumber = errno
                tempFD = -1
                throw EngineFault.storageFailure(details: "close temp file failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))")
            }
            tempFD = -1
            try cancelledFault()

            // This re-walk detects a path substitution, while publication still
            // uses only the already captured directory FD.
            guard try Self.inspectDestinationIdentity(at: plan.destinationDirectory) == plan.destinationIdentity else {
                throw EngineFault.storageFailure(details: "destination directory identity changed before publication")
            }
            if renameatx_np(directoryFD, generatedTempName, directoryFD, plan.outputLeaf, UInt32(RENAME_EXCL)) != 0 {
                let errorNumber = errno
                if errorNumber == EEXIST {
                    throw EngineFault.invalidPayload(details: "Output file already exists, overwrite not permitted: \(plan.outputLeaf)")
                }
                throw EngineFault.storageFailure(details: "atomic relative rename failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))")
            }
            tempFileCreated = false
            finalFilePlaced = true
            try Self.syncDurably(directoryFD, label: "destination directory after publish")
            try cancelledFault()

            // Stage 4: final read, Domain semantics, raw-span identities, and
            // independent pinned libtorrent identities all use finalFD.
            await onProgress(0.96, OperationProgressDetail(
                stage: "Verification", backend: "cpu", processedBytes: 0,
                totalBytes: Int64(metainfoBytes.count), fileCount: 0, totalFileCount: 1,
                etaSeconds: nil, isCancelled: false
            ))
            finalFD = openat(directoryFD, plan.outputLeaf, O_RDONLY | O_NOFOLLOW)
            guard finalFD >= 0 else {
                let errorNumber = errno
                throw EngineFault.storageFailure(details: "open relative final torrent failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))")
            }
            var finalStat = stat()
            guard fstat(finalFD, &finalStat) == 0, (finalStat.st_mode & S_IFMT) == S_IFREG else {
                throw EngineFault.corruptData(details: "published torrent is not a regular file")
            }
            let writtenData = try Self.readAll(from: finalFD)
            guard Darwin.close(finalFD) == 0 else {
                let errorNumber = errno
                finalFD = -1
                throw EngineFault.storageFailure(details: "close final torrent failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))")
            }
            finalFD = -1

            let parsed = try MetainfoParser.parse(writtenData)
            guard parsed.trackerTiers == options.trackers else {
                // Generated announce-list bytes are an admission assertion,
                // not a best-effort projection of the requested topology.
                throw EngineFault.corruptData(details: "generated tracker topology does not match creator options")
            }
            let independentIdentity: IndependentMetainfoIdentity
            do {
                independentIdentity = try await independentVerifier(writtenData)
            } catch {
                throw EngineFault.corruptData(details: "pinned libtorrent verification failed: \(error)")
            }
            try Self.verifyTorrent(
                parsed, against: freshScan, options: options, hashingResult: hashingResult,
                expectedIdentity: expectedIdentity, independentIdentity: independentIdentity,
                requireIndependentVerification: true
            )
            try cancelledFault()
            try revalidateSourceGeneration()

            // Stage 5: cancellation wins before admission. A successful add
            // callback is the durable seed linearization point; no late cancel
            // check is allowed to convert it into a cancelled result.
            if options.seedWhileDownloading {
                guard let addTorrent else {
                    throw EngineFault.storageFailure(details: "creator seed admission callback is unavailable")
                }
                await onProgress(0.98, OperationProgressDetail(
                    stage: "Seeding", backend: "cpu", processedBytes: Int64(writtenData.count),
                    totalBytes: Int64(writtenData.count), fileCount: freshScan.files.count,
                    totalFileCount: freshScan.files.count, etaSeconds: nil, isCancelled: false
                ))
                try cancelledFault()
                let sourceAbsolute = Self.canonicalAbsolutePath(plan.sourcePath)
                let savePath = (sourceAbsolute as NSString).deletingLastPathComponent
                try await addTorrent(writtenData, savePath, false, options.isPrivate)
                seedAdmissionCommitted = true
            }

            let summary = CreateSummary(
                fileCount: freshScan.files.count,
                totalBytes: freshScan.totalSizeBytes,
                pieceSizeBytes: freshScan.pieceSizeBytes,
                willSeed: options.seedWhileDownloading,
                skippedSymlinksCount: freshScan.skippedSymlinksCount,
                hardlinkCount: freshScan.hardlinkCount
            )
            await onProgress(1, OperationProgressDetail(
                stage: "Completed", backend: "cpu", processedBytes: freshScan.totalSizeBytes,
                totalBytes: freshScan.totalSizeBytes, fileCount: freshScan.files.count,
                totalFileCount: freshScan.files.count, etaSeconds: nil, isCancelled: false
            ))

            guard Darwin.close(directoryFD) == 0 else {
                let errorNumber = errno
                directoryFD = -1
                throw EngineFault.storageFailure(details: "close destination descriptor failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))")
            }
            directoryFD = -1
            guard Darwin.close(rollbackFD) == 0 else {
                let errorNumber = errno
                rollbackFD = -1
                throw EngineFault.storageFailure(details: "close rollback descriptor failed (errno \(errorNumber), \(String(cString: strerror(errorNumber))))")
            }
            rollbackFD = -1

            return summary
        } catch {
            let originalError = error
            var cleanupFailure: String?
            if finalFD >= 0 {
                if Darwin.close(finalFD) != 0 {
                    cleanupFailure = "close final during rollback failed (errno \(errno))"
                }
                finalFD = -1
            }
            if tempFD >= 0 {
                if Darwin.close(tempFD) != 0 {
                    cleanupFailure = cleanupFailure ?? "close temp during rollback failed (errno \(errno))"
                }
                tempFD = -1
            }

            // Rollback is descriptor-relative only. If the primary FD was
            // closed unsuccessfully, use the retained duplicate; never reopen
            // the destination path or unlink by name.
            let cleanupFD = directoryFD >= 0 ? directoryFD : rollbackFD
            if !seedAdmissionCommitted, cleanupFD >= 0 {
                if tempFileCreated, let tempName, unlinkat(cleanupFD, tempName, 0) != 0 && errno != ENOENT {
                    cleanupFailure = cleanupFailure ?? "remove temp during rollback failed (errno \(errno))"
                }
                if finalFilePlaced && unlinkat(cleanupFD, plan.outputLeaf, 0) != 0 && errno != ENOENT {
                    cleanupFailure = cleanupFailure ?? "remove final during rollback failed (errno \(errno))"
                }
                if tempFileCreated || finalFilePlaced {
                    do {
                        try Self.syncDurably(cleanupFD, label: "rollback destination directory")
                    } catch {
                        cleanupFailure = cleanupFailure ?? error.localizedDescription
                    }
                }
            } else if !seedAdmissionCommitted && (tempFileCreated || finalFilePlaced) {
                cleanupFailure = cleanupFailure ?? "no captured directory descriptor remained for rollback"
            }

            if directoryFD >= 0 {
                if Darwin.close(directoryFD) != 0 {
                    cleanupFailure = cleanupFailure ?? "close destination rollback descriptor failed (errno \(errno))"
                }
                directoryFD = -1
            }
            if rollbackFD >= 0 {
                if Darwin.close(rollbackFD) != 0 {
                    cleanupFailure = cleanupFailure ?? "close retained rollback descriptor failed (errno \(errno))"
                }
                rollbackFD = -1
            }
            if let cleanupFailure {
                throw EngineFault.storageFailure(details: "creator rollback failed: \(cleanupFailure); original failure: \(originalError)")
            }
            throw originalError
        }
    }

    // MARK: - Domain verification

    private static func verifyTorrent(
        _ parsed: Metainfo,
        against scan: SourceScanResult,
        options: CreateOptions,
        hashingResult: HashingResult,
        expectedIdentity: MetainfoIdentityExpectation,
        independentIdentity: IndependentMetainfoIdentity,
        requireIndependentVerification: Bool
    ) throws {
        let expectsV1 = options.format == .v1 || options.format == .hybrid
        let expectsV2 = options.format == .v2 || options.format == .hybrid
        guard parsed.fileCount == scan.files.count, parsed.totalSize == scan.totalSizeBytes else {
            throw MetainfoError.invalidField("written manifest size mismatch")
        }
        if expectsV1 {
            guard parsed.metaVersion == (expectsV2 ? 2 : 1),
                  parsed.v1PiecesData == hashingResult.v1PiecesData,
                  parsed.v1PiecesData?.isEmpty == false else {
                throw MetainfoError.invalidPieces
            }
        } else {
            guard parsed.metaVersion == 2, parsed.v1PiecesData == nil else {
                throw MetainfoError.invalidPieces
            }
        }

        let expectedFiles = scan.files.map {
            ($0.relativePath, $0.sizeBytes, hashingResult.v2FileTrees[$0.relativePath]?.piecesRoot)
        }
        let actualFiles = parsed.files.map { ($0.path, $0.sizeBytes, $0.v2PiecesRoot) }
        guard expectedFiles.count == actualFiles.count,
              zip(expectedFiles, actualFiles).allSatisfy({ lhs, rhs in
                  lhs.0 == rhs.0 && lhs.1 == rhs.1 && (!expectsV2 || lhs.2 == rhs.2)
              }) else {
            throw MetainfoError.hybridMismatch("written manifest differs from hashed manifest")
        }

        if expectsV2 {
            guard parsed.infoHashV2 != nil else { throw MetainfoError.invalidField("missing v2 info hash") }
            let expectedLayers = hashingResult.v2FileTrees.reduce(into: [Data: Data]()) { result, entry in
                if !entry.value.pieceLayers.isEmpty {
                    result[entry.value.piecesRoot] = entry.value.pieceLayers
                }
            }
            guard parsed.v2PieceLayers == expectedLayers else {
                throw MetainfoError.invalidPieceLayers("written layers differ from hashed layers")
            }
        } else {
            guard parsed.infoHashV2 == nil, parsed.v2PieceLayers.isEmpty else {
                throw MetainfoError.invalidField("unexpected v2 fields")
            }
        }

        guard parsed.infoDictData == expectedIdentity.infoBytes else {
            throw MetainfoError.invalidField("raw info byte span changed")
        }
        guard parsed.infoHashV1 == expectedIdentity.v1,
              parsed.infoHashV2 == expectedIdentity.v2 else {
            throw MetainfoError.invalidField("Domain info identity mismatch")
        }
        if requireIndependentVerification {
            guard independentIdentity.v1 == expectedIdentity.v1,
                  independentIdentity.v2 == expectedIdentity.v2 else {
                throw MetainfoError.invalidField("pinned libtorrent info identity mismatch")
            }
        }
    }
}
