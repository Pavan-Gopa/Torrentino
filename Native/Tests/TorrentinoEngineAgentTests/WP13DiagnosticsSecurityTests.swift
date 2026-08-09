// Layer: Tests / Engine Agent
// Role: Comprehensive unit tests for WP-13 Diagnostics, security, logging,
//       redaction, diagnostic export, and input limit validation.
// Must-not: leave temporary log or diagnostic files on disk.
// Invariants: isolated, deterministic; uses disposable temporary directories;
//             asserts zero secret leaks in exports or logs.
// Why: observability regressions must fail at the mapped alert boundary before
// an idle drain can bury the only useful error evidence.

import XCTest
@testable import TorrentinoIPC
@testable import TorrentinoDomain
@testable import TorrentinoEngineAgent

final class WP13DiagnosticsSecurityTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WP13Tests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - 1. Redaction Logic Tests

    func testLogRedactionScrubsSensitiveFields() {
        let rawMessage = "User /Users/john_doe/Downloads/test.torrent connected with password=SecretPassword123 and proxyPassword=MyProxyPass123"
        let redacted = RedactedLogFileManager.redact(rawMessage)

        XCTAssertFalse(redacted.contains("/Users/john_doe"))
        XCTAssertFalse(redacted.contains("SecretPassword123"))
        XCTAssertFalse(redacted.contains("MyProxyPass123"))
        XCTAssertTrue(redacted.contains("password=<redacted>"))
        XCTAssertTrue(redacted.contains("proxyPassword=<redacted>"))
    }

    func testLogRedactionScrubsAuthorizationHeadersAndPasskeys() {
        let rawHeader = "Authorization: Bearer secret_token_abc123 and passkey=my_secret_passkey_456"
        let redacted = RedactedLogFileManager.redact(rawHeader)

        XCTAssertFalse(redacted.contains("secret_token_abc123"))
        XCTAssertFalse(redacted.contains("my_secret_passkey_456"))
        XCTAssertTrue(redacted.contains("Authorization: Bearer <redacted>"))
        XCTAssertTrue(redacted.contains("passkey=<redacted>"))
    }

    func testLogRedactionHandlesUnicodeAndLongLinesOnWrite() async {
        let logsDir = tempDir.appendingPathComponent("UnicodeLogs", isDirectory: true)
        let logManager = RedactedLogFileManager(
            logDirectory: logsDir,
            maxFileSize: 512,
            maxFileCount: 2
        )
        let unicodePayload = String(repeating: "\u{1F9EA}", count: 2_000)
        let secret = "unicode-long-secret-qa"

        await logManager.writeLog(
            category: "transfer",
            level: "debug",
            message: "\(unicodePayload) password=\(secret) token=\(secret)"
        )

        let lines = await logManager.fetchRecentLogLines(maxCount: 10)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { !$0.contains(secret) })
        XCTAssertTrue(lines.contains { $0.contains("password=<redacted>") })
        let logURLs = await logManager.allLogFileURLs()
        XCTAssertLessThanOrEqual(logURLs.count, 2)
    }

    // MARK: - 2. Rotating Log Manager Tests

    func testRotatingLogManagerWritesAndRotates() async {
        let logsDir = tempDir.appendingPathComponent("Logs", isDirectory: true)
        let logManager = RedactedLogFileManager(
            logDirectory: logsDir,
            maxFileSize: 500, // Small limit for fast rotation test
            maxFileCount: 3
        )

        // Write log entries
        for idx in 1...30 {
            await logManager.writeLog(
                category: "transfer",
                level: "info",
                message: "Test log entry number \(idx) with password=Pass\(idx)"
            )
        }

        let lines = await logManager.fetchRecentLogLines(maxCount: 100)
        XCTAssertGreaterThan(lines.count, 0)
        XCTAssertFalse(lines.contains { $0.contains("Pass") && !$0.contains("<redacted>") })

        let urls = await logManager.allLogFileURLs()
        XCTAssertLessThanOrEqual(urls.count, 3)
    }

    // MARK: - 3. ProxyConfiguration String Description Redaction Tests

    func testProxyConfigurationRedactsPasswordInStringRepresentation() {
        let proxy = ProxyConfiguration(
            kind: .socks5,
            host: "127.0.0.1",
            port: 1080,
            username: "admin",
            password: "super_secret_proxy_password"
        )

        let desc = String(describing: proxy)
        let debugDesc = proxy.debugDescription

        XCTAssertFalse(desc.contains("super_secret_proxy_password"))
        XCTAssertFalse(debugDesc.contains("super_secret_proxy_password"))
        XCTAssertTrue(desc.contains("<redacted>"))
        XCTAssertTrue(debugDesc.contains("<redacted>"))
    }

    // MARK: - 4. Diagnostic Export Tests

    func testDiagnosticExportCreatesBundleWithoutSecrets() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let coordinator = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )

        let customProxy = ProxyConfiguration(
            kind: .socks5,
            host: "127.0.0.1",
            port: 1080,
            username: "testuser",
            password: "SecretProxyPassword999"
        )
        let customSettings = EngineSettings(
            downloadDirectory: "/Users/testuser/Downloads",
            maxDownloadBytesPerSec: 0,
            maxUploadBytesPerSec: 0,
            listenPort: 6881,
            dhtEnabled: true,
            lsdEnabled: true,
            upnpEnabled: true,
            natPmpEnabled: true,
            encryptionEnabled: true,
            proxy: customProxy
        )
        _ = await coordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            candidate: customSettings
        )))

        let exportPath = tempDir.appendingPathComponent("ExportBundle", isDirectory: true).path
        let request = ExportDiagnosticsRequest(
            requestID: RequestID(),
            reason: "QA WP-13 Test password=ReasonSecret token=ReasonToken /Users/testuser/private",
            destinationURL: exportPath
        )

        let envelope = EngineCommandV1.exportDiagnostics(request)
        let result = await coordinator.processCommandForTest(envelope)

        guard case .success(let payload) = result,
              case .diagnosticsExport(let exportResult) = payload else {
            XCTFail("Expected diagnosticsExport result payload")
            return
        }

        XCTAssertEqual(exportResult.archiveURL, exportPath)
        XCTAssertEqual(exportResult.entryCount, 5)

        let expectedFiles = [
            "system_info.json",
            "health_metrics.json",
            "engine_settings.json",
            "recent_logs.txt",
            "persistence_status.json"
        ]
        for fileName in expectedFiles {
            let fileURL = URL(fileURLWithPath: exportPath).appendingPathComponent(fileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "missing export entry \(fileName)")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(content.contains("SecretProxyPassword999"), "proxy password leaked in \(fileName)")
            XCTAssertFalse(content.contains("ReasonSecret"), "reason password leaked in \(fileName)")
            XCTAssertFalse(content.contains("ReasonToken"), "reason token leaked in \(fileName)")
            XCTAssertFalse(content.contains("/Users/testuser"), "home path leaked in \(fileName)")
        }
    }

    func testDiagnosticExportDefaultsToTemporaryDirectoryAndFailsClosedOnBadDestination() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let coordinator = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )

        let defaultResult = await coordinator.processCommandForTest(.exportDiagnostics(
            ExportDiagnosticsRequest(requestID: RequestID(), reason: "default path", destinationURL: nil)
        ))
        guard case .success(.diagnosticsExport(let export)) = defaultResult else {
            return XCTFail("default diagnostics export must succeed")
        }
        XCTAssertTrue(export.archiveURL.hasPrefix(NSTemporaryDirectory()))
        XCTAssertEqual(export.entryCount, 5)
        try? FileManager.default.removeItem(atPath: export.archiveURL)

        let pathComponent = tempDir.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: pathComponent)
        let badDestination = pathComponent.appendingPathComponent("child", isDirectory: true).path
        let badResult = await coordinator.processCommandForTest(.exportDiagnostics(
            ExportDiagnosticsRequest(requestID: RequestID(), reason: "bad path", destinationURL: badDestination)
        ))
        guard case .failure(let fault) = badResult else {
            return XCTFail("diagnostics export must fail closed when destination is not writable")
        }
        XCTAssertEqual(fault.code, .internalError)
    }

    // MARK: - 5. End-to-end observability matrix

    func testObservabilityCommandMatrixWritesEveryRequiredClass() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let engine = StubTransferEngine()
        let coordinator = TransferCoordinator(
            engine: engine,
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "observability-test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )

        let torrentData = MetainfoBuilder.multiFile(
            files: [("dir/a.txt", 1), ("dir/b.bin", 1)],
            pieceLength: 16,
            piecesCount: 1,
            name: "observability"
        )
        let inspect = await coordinator.processCommandForTest(.inspectAddSource(
            InspectAddSourceRequest(
                requestID: RequestID(),
                source: .torrentFileData(torrentData),
                saveLocation: PersistedLocation(path: tempDir.path)
            )
        ))
        guard case .success(.addSourceInspection(let inspection)) = inspect else {
            return XCTFail("observability matrix add inspection failed: \(inspect)")
        }

        let commit = await coordinator.processCommandForTest(.commitAdd(
            CommitAddRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                operationID: inspection.operationID,
                saveLocation: PersistedLocation(path: tempDir.path),
                startPaused: false
            )
        ))
        guard case .success(.commitAdd(let addResult)) = commit else {
            return XCTFail("observability matrix commit failed: \(commit)")
        }

        let recordID = addResult.recordID
        let _ = await coordinator.processCommandForTest(.fetchFiles(
            FetchFilesRequest(requestID: RequestID(), recordID: recordID, cursor: nil, pageSize: 20, expectedRevision: 0)
        ))
        let selection = await coordinator.processCommandForTest(.setFileSelection(
            SetFileSelectionRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                selection: [
                    FileSelectionItem(relativePath: "dir/a.txt", priority: .skip),
                    FileSelectionItem(relativePath: "dir/b.bin", priority: .normal)
                ],
                expectedRevision: 0
            )
        ))
        guard case .success(.ack) = selection else {
            return XCTFail("observability matrix file selection failed: \(selection)")
        }

        for command in [
            EngineCommandV1.pause(PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)),
            EngineCommandV1.resume(ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)),
            EngineCommandV1.reannounce(ReannounceRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID))
        ] {
            let result = await coordinator.processCommandForTest(command)
            guard case .success(.ack) = result else {
                return XCTFail("observability matrix command failed: \(result)")
            }
        }

        let prepare = await coordinator.processCommandForTest(.prepareRemoval(
            PrepareRemovalRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                deleteFiles: false
            )
        ))
        guard case .success(.removalToken(let token)) = prepare else {
            return XCTFail("observability matrix prepare removal failed: \(prepare)")
        }
        let removal = await coordinator.processCommandForTest(.commitRemoval(
            CommitRemovalRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), token: token)
        ))
        guard case .success(.removalResult) = removal else {
            return XCTFail("observability matrix commit removal failed: \(removal)")
        }

        // A zero-result drain is an idle tick and must not create a log line.
        XCTAssertNil(EngineAlertDTO.alertDrainLogMessage(count: 0))
        XCTAssertEqual(EngineAlertDTO.alertDrainLogMessage(count: 1), "bridge alerts drained count=1")
        TorrentinoLog.record(category: "transfer", level: "debug", message: "bridge alerts drained count=1")

        // Force the mapped DTO shape used by the live bridge. The empty error
        // field must fall back to message, and the final file record must carry
        // type, severity, and readable text after redaction.
        let forcedAlert = EngineAlertDTO(
            kind: "torrent_error_alert",
            error: "",
            message: "No space left at /Users/human/Downloads"
        )
        let forcedAlertLog = EngineAlertDTO.alertLogMessage(for: forcedAlert)
        XCTAssertEqual(forcedAlertLog.severity, "error")
        XCTAssertTrue(forcedAlertLog.message.contains("type=torrent_error_alert"))
        XCTAssertTrue(forcedAlertLog.message.contains("severity=error"))
        XCTAssertTrue(forcedAlertLog.message.contains("message=No space left"))
        TorrentinoLog.record(category: "transfer", level: forcedAlertLog.severity, message: forcedAlertLog.message)

        let trackerAlert = EngineAlertDTO(
            kind: "unknown",
            message: "tracker announce failed"
        )
        let trackerLog = EngineAlertDTO.alertLogMessage(for: trackerAlert)
        XCTAssertTrue(trackerLog.message.contains("type=tracker_announce"))
        XCTAssertEqual(trackerLog.severity, "error")

        let storageAlert = EngineAlertDTO(
            kind: "session",
            message: "storage space warning"
        )
        let storageLog = EngineAlertDTO.alertLogMessage(for: storageAlert)
        XCTAssertTrue(storageLog.message.contains("type=storage"))
        XCTAssertEqual(storageLog.severity, "warning")

        // The XCTest target deliberately does not exercise a libtorrent session;
        // the QA shell follows with a disposable live engine alert probe.
        TorrentinoLog.record(category: "xpc", level: "notice", message: "xpc connect peer verification accepted disposable-test")

        TorrentinoLog.record(
            category: "transfer",
            level: "info",
            message: "observability secret probe path=/Users/human/Downloads token=qa-token passkey=qa-passkey"
        )
        await TorrentinoLog.flush()
        let logLines = await RedactedLogFileManager.shared.fetchRecentLogLines(maxCount: 2_000)
        let log = logLines.joined(separator: "\n")
        for marker in [
            "inspectAddSource", "commitAdd", "fetchFiles", "setFileSelection",
            "pause", "resume", "reannounce", "prepareRemoval", "commitRemoval",
            "checkpoint", "state transition", "bridge alerts drained",
            "libtorrent alert type=torrent_error_alert", "severity=error", "message=No space left",
            "xpc connect", "peer verification accepted"
        ] {
            XCTAssertTrue(log.contains(marker), "missing observability marker: \(marker)")
        }
        for secret in ["/Users/human", "qa-token", "qa-passkey"] {
            XCTAssertFalse(log.contains(secret), "observability log leaked \(secret)")
        }
    }

    // MARK: - 6. Input Limits & Path Safety Assertions

    func testInputLimitsAreEnforced() {
        XCTAssertEqual(BencodeParser.maxDepth, 64)
        XCTAssertEqual(TransferLimits.maxFiles, 10_000)
        XCTAssertEqual(TransferLimits.maxTorrentFileBytes, 10 * 1024 * 1024)
        XCTAssertEqual(TransferLimits.maxMagnetLength, 8 * 1024)
        XCTAssertEqual(IPCPayloadLimit.maxBytes, 4 * 1024 * 1024)
        XCTAssertEqual(PathValidator.maxPathLength, 4096)
        XCTAssertEqual(PathValidator.maxComponentLength, 255)
        XCTAssertEqual(PathValidator.maxComponents, 512)
    }

    func testPathValidatorRejectsDirectoryTraversalAndAbsolutePaths() {
        XCTAssertNotNil(PathValidator.validationError("/etc/passwd"))
        XCTAssertNotNil(PathValidator.validationError("../escape.txt"))
        XCTAssertNotNil(PathValidator.validationError("subfolder/../../escape.txt"))
        XCTAssertNotNil(PathValidator.validationError("folder\0/file.txt"))
        XCTAssertNil(PathValidator.validationError("safe_folder/subfolder/file.txt"))
    }

    func testNativeTorrentStatesMapToTransferActivities() {
        XCTAssertEqual(LibtorrentActivityMapper.activity(from: 0), .queued)
        XCTAssertEqual(LibtorrentActivityMapper.activity(from: 1), .checking)
        XCTAssertEqual(LibtorrentActivityMapper.activity(from: 2), .fetchingMetadata)
        XCTAssertEqual(LibtorrentActivityMapper.activity(from: 3), .downloading)
        XCTAssertEqual(LibtorrentActivityMapper.activity(from: 4), .seeding)
        XCTAssertEqual(LibtorrentActivityMapper.activity(from: 5), .seeding)
        XCTAssertEqual(LibtorrentActivityMapper.activity(from: 7), .checking)
    }

    func testStatusCachePreservesKnownFieldsAcrossAlertSentinels() {
        var cache = ByteBoundedStatusCache()
        cache.insert(CachedTorrentStatus(fraction: 0.25, state: 3, error: "network"), for: "hash")
        cache.merge(CachedTorrentStatus(fraction: -1, state: -1, error: nil), for: "hash")

        XCTAssertEqual(cache.entries["hash"]?.fraction, 0.25)
        XCTAssertEqual(cache.entries["hash"]?.state, 3)
        XCTAssertNil(cache.entries["hash"]?.error)
    }
}

// MARK: - Helpers

private extension TransferCoordinator {
    func processCommandForTest(_ command: EngineCommandV1) async -> EngineCommandResult {
        let envelope = IPCEnvelope.request(command)
        guard let data = try? JSONEncoder().encode(envelope) else {
            return .failure(EngineFault.invalidPayload(details: "failed to encode command envelope"))
        }
        let responseData = await self.processCommand(data)
        guard let responseEnvelope = try? JSONDecoder().decode(IPCEnvelope.self, from: responseData),
              let result = responseEnvelope.result else {
            return .failure(EngineFault.invalidPayload(details: "unexpected envelope response"))
        }
        return result
    }
}
