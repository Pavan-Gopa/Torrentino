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

    // MARK: - Shared-sink isolation (WP-13 global log contamination finding)

    /// Installs a disposable TORRENTINO_LOG_DIRECTORY before this suite's
    /// first `RedactedLogFileManager.shared` access. A launcher-provided
    /// disposable override (QA script / gate harness export) wins and is left
    /// untouched; otherwise the suite installs its own so the shared sink can
    /// never resolve to the Human's real log directory.
    override class func setUp() {
        super.setUp()
        guard getenv("TORRENTINO_LOG_DIRECTORY") == nil else { return }
        let disposable = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WP13SharedLogSink_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: disposable, withIntermediateDirectories: true)
        setenv("TORRENTINO_LOG_DIRECTORY", disposable.path, 1)
    }

    override class func tearDown() {
        if let current = getenv("TORRENTINO_LOG_DIRECTORY") {
            let path = String(cString: current)
            if path.contains("WP13SharedLogSink_") {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        unsetenv("TORRENTINO_LOG_DIRECTORY")
        super.tearDown()
    }

    /// Self-verifying isolation proof: a unique marker must round-trip through
    /// the shared sink, a disposable TORRENTINO_LOG_DIRECTORY must be
    /// established, and the marker must never appear in the Human's default
    /// sink file. The test FAILS if the shared sink would touch the user's
    /// log directory.
    private func verifySharedSinkIsolation() async throws {
        let userSinkFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("com.torrentino.app.engine-agent", isDirectory: true)
            .appendingPathComponent("engine_log_current.log")
            ?? URL(fileURLWithPath: "/tmp/torrentino-logs/engine_log_current.log")

        let sentinel = "wp13-shared-sink-sentinel-\(UUID().uuidString)"
        await RedactedLogFileManager.shared.writeLog(
            category: "diagnostics", level: "debug", message: sentinel
        )
        let lines = await RedactedLogFileManager.shared.fetchRecentLogLines(maxCount: 5_000)
        XCTAssertTrue(lines.contains { $0.contains(sentinel) },
                      "shared log sink did not round-trip the isolation sentinel")
        XCTAssertNotNil(getenv("TORRENTINO_LOG_DIRECTORY"),
                        "a disposable TORRENTINO_LOG_DIRECTORY must be established")
        if FileManager.default.fileExists(atPath: userSinkFile.path),
           let userContents = try? String(contentsOf: userSinkFile, encoding: .utf8) {
            XCTAssertFalse(userContents.contains(sentinel),
                           "isolation breach: sentinel leaked into the user log directory")
        }
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
        let applied = await coordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            candidate: customSettings
        )))
        guard case .success(.settingsApply(let applyResult)) = applied else {
            return XCTFail("export setup applySettings failed: \(applied)")
        }
        XCTAssertEqual(applyResult.revision, 2, "a successful apply must publish revision 2")

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

    // MARK: - 4b. Escaped-secret, rollback-overwrite, degraded-phase regressions

    func testRedactorSurvivesEscapedQuotesBackslashesAndNewlinesInJSONSecrets() {
        // Escaped quote inside the secret value (the pre-fix class stopped here).
        let quoted = #"{"proxy":{"password":"prefix\"LEAK_Q","next":"safe"}}"#
        let redactedQuoted = RedactedLogFileManager.redact(quoted)
        XCTAssertFalse(redactedQuoted.contains("LEAK_Q"), "escaped-quote suffix survived: \(redactedQuoted)")
        XCTAssertTrue(redactedQuoted.contains("\"password\":\"<redacted>\""))
        XCTAssertTrue(redactedQuoted.contains("\"next\":\"safe\""), "adjacent fields must survive")

        // Trailing backslash immediately before the closing quote.
        let backslashed = #"{"secret":"trail\\"}"#
        let redactedBackslashed = RedactedLogFileManager.redact(backslashed)
        XCTAssertTrue(redactedBackslashed.contains("\"secret\":\"<redacted>\""))
        XCTAssertFalse(redactedBackslashed.contains("\\"), "backslash secret survived: \(redactedBackslashed)")

        // Newline escape sequence inside the value; output must stay valid JSON.
        let newlineEscape = "{\"passkey\":\"line1\\nline2NL_LEAK\",\"k\":\"v\"}"
        let redactedNewline = RedactedLogFileManager.redact(newlineEscape)
        XCTAssertFalse(redactedNewline.contains("NL_LEAK"), "newline-escape suffix survived: \(redactedNewline)")
        XCTAssertTrue(redactedNewline.contains("\"passkey\":\"<redacted>\""))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(redactedNewline.utf8)),
                        "redacted output must remain valid JSON: \(redactedNewline)")

        // Literal newline character inside the value (plain-text log shape).
        let literalNewline = "{\"token\":\"split\nNL2_LEAK\"}"
        let redactedLiteral = RedactedLogFileManager.redact(literalNewline)
        XCTAssertFalse(redactedLiteral.contains("NL2_LEAK"), "literal-newline suffix survived: \(redactedLiteral)")
        XCTAssertTrue(redactedLiteral.contains("\"token\":\"<redacted>\""))
    }

    /// Behavioral lockstep proof for the mirrored redactor source
    /// (Agent/RedactedLogFileManager.swift). The mirror is intentionally not a
    /// build-target member — the shipped redactor is the one compiled into
    /// PersistenceStore.swift — so this test executes the ruleset the mirror
    /// ACTUALLY declares (same NSRegularExpression machinery, declaration order
    /// preserved) against the same hostile corpus fed to the compiled redactor
    /// and requires byte-identical outputs. A lost, reordered, or retuned
    /// mirror rule diverges here instead of shipping a false lockstep claim.
    func testMirrorRedactorStaysInLockstepWithCompiledRedactor() throws {
        let mirrorURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // …/Native/Tests/TorrentinoEngineAgentTests
            .deletingLastPathComponent() // …/Native/Tests
            .deletingLastPathComponent() // …/Native
            .appendingPathComponent("TorrentinoEngineAgent/Agent/RedactedLogFileManager.swift")
        let mirrorSource = try String(contentsOf: mirrorURL, encoding: .utf8)

        // Decodes a Swift string literal's escapes so the mirror's declared
        // pattern/template text becomes live regex arguments.
        func decodedSwiftLiteral(_ literal: String) -> String? {
            var decoded = ""
            var rest = Substring(literal)
            while let char = rest.popFirst() {
                guard char == "\\" else {
                    decoded.append(char)
                    continue
                }
                guard let escaped = rest.popFirst() else { return nil }
                switch escaped {
                case "\\": decoded.append("\\")
                case "\"": decoded.append("\"")
                case "n": decoded.append("\n")
                case "t": decoded.append("\t")
                case "r": decoded.append("\r")
                case "0": decoded.append("\0")
                default: return nil
                }
            }
            return decoded
        }

        let ruleRegex = try NSRegularExpression(
            pattern: #"try\?\s*NSRegularExpression\(\s*pattern:\s*"((?:[^"\\]|\\.)*)"\s*,\s*options:\s*\[([^\]]*)\]"#
        )
        let templateRegex = try NSRegularExpression(
            pattern: #"withTemplate:\s*"((?:[^"\\]|\\.)*)"#
        )
        let mirrorNSString = mirrorSource as NSString
        var mirrorRules: [(pattern: String, options: NSRegularExpression.Options, template: String)] = []
        for match in ruleRegex.matches(in: mirrorSource, options: [], range: NSRange(location: 0, length: mirrorNSString.length)) {
            let searchRange = NSRange(location: match.range.location, length: mirrorNSString.length - match.range.location)
            guard let templateMatch = templateRegex.firstMatch(in: mirrorSource, options: [], range: searchRange) else {
                XCTFail("mirror redactor rule \(mirrorRules.count + 1) declares no replacement template")
                return
            }
            guard
                let pattern = decodedSwiftLiteral(mirrorNSString.substring(with: match.range(at: 1))),
                let template = decodedSwiftLiteral(mirrorNSString.substring(with: templateMatch.range(at: 1)))
            else {
                XCTFail("mirror redactor uses a string escape this lockstep probe cannot decode")
                return
            }
            var options = NSRegularExpression.Options()
            for rawOption in mirrorNSString.substring(with: match.range(at: 2)).split(separator: ",") {
                switch String(rawOption).trimmingCharacters(in: .whitespaces) {
                case "": continue
                case ".caseInsensitive": options.insert(.caseInsensitive)
                default:
                    XCTFail("unrecognized mirror regex option \(rawOption); extend the lockstep probe decoder")
                    return
                }
            }
            mirrorRules.append((pattern, options, template))
        }

        guard mirrorRules.count == 4 else {
            XCTFail("mirror redactor must declare exactly 4 rules (path, plain-text marker, JSON, auth header); found \(mirrorRules.count)")
            return
        }

        func mirrorRedact(_ text: String) -> String {
            var redacted = text
            for (pattern, options, template) in mirrorRules {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
                let range = NSRange(location: 0, length: redacted.utf16.count)
                redacted = regex.stringByReplacingMatches(in: redacted, options: [], range: range, withTemplate: template)
            }
            return redacted
        }

        // Every vector class the compiled redactor must survive, plus combined
        // lines whose outcome depends on the ruleset ORDER
        // (path → plain-text marker → JSON → auth header).
        let hostileCorpus: [String] = [
            "password=SecretOne token=SecretTwo",
            #"{"proxy":{"password":"prefix\"QUOTE_LEAK","next":"safe"}}"#,
            "/Users/someone/path",
            "Authorization: Bearer bearer_leak",
            "passkey=PK_LEAK /Users/someone/path password=SecretOne token=SecretTwo",
            #"/Users/someone/path password=SecretOne {"token":"a\"b"} Authorization: Bearer bearer_leak"#,
            "/Users/token=hunter2",
        ]
        let forbiddenLeaks = ["SecretOne", "SecretTwo", "QUOTE_LEAK", "/Users/someone", "bearer_leak", "PK_LEAK"]

        for input in hostileCorpus {
            let compiledOutput = RedactedLogFileManager.redact(input)
            let mirrorOutput = mirrorRedact(input)
            XCTAssertEqual(
                Array(compiledOutput.utf8), Array(mirrorOutput.utf8),
                "mirror redactor diverged from the compiled redactor on \(input): compiled=\(compiledOutput) mirror=\(mirrorOutput)"
            )
            // Parity between two equally-broken copies would be vacuous, so
            // the compiled side must also prove every secret is really gone.
            for leak in forbiddenLeaks {
                XCTAssertFalse(
                    compiledOutput.contains(leak),
                    "compiled redactor leaked \(leak) for \(input): \(compiledOutput)"
                )
            }
        }

        let plainMarkers = RedactedLogFileManager.redact(hostileCorpus[0])
        XCTAssertTrue(plainMarkers.contains("password=<redacted>"),
                      "plain-text marker rule regressed in the compiled redactor: \(plainMarkers)")
        XCTAssertTrue(plainMarkers.contains("token=<redacted>"),
                      "plain-text marker rule regressed in the compiled redactor: \(plainMarkers)")
    }

    func testDiagnosticExportRejectsDestinationContainingPreExistingFiles() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let coordinator = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )

        let destinationURL = tempDir.appendingPathComponent("BusyDestination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let keeperURL = destinationURL.appendingPathComponent("user-file.txt")
        let originalBytes = Data("do not delete\n".utf8)
        try originalBytes.write(to: keeperURL)

        let result = await coordinator.processCommandForTest(.exportDiagnostics(
            ExportDiagnosticsRequest(requestID: RequestID(), reason: "busy destination", destinationURL: destinationURL.path)
        ))
        guard case .failure(let fault) = result else {
            return XCTFail("export into a non-empty destination must be rejected")
        }
        XCTAssertEqual(fault.code, .internalError)
        XCTAssertEqual(fault.redactedContext, "diagnostics destination must be nonexistent or an empty directory")

        // The unrelated pre-existing file survives byte-identical; nothing else appeared.
        XCTAssertEqual(try Data(contentsOf: keeperURL), originalBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationURL.path), ["user-file.txt"])
    }

    func testDiagnosticExportMidWriteFailureRollsBackAllWrittenEntries() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let coordinator = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )

        FailpointInjector.disarmAll()
        defer { FailpointInjector.disarmAll() }
        FailpointInjector.arm(.diagnosticsExportMidWrite) { _ in throw MidWriteFault() }

        let destinationURL = tempDir.appendingPathComponent("MidWriteDestination", isDirectory: true)
        let result = await coordinator.processCommandForTest(.exportDiagnostics(
            ExportDiagnosticsRequest(requestID: RequestID(), reason: "mid-write rollback probe", destinationURL: destinationURL.path)
        ))
        guard case .failure(let fault) = result else {
            return XCTFail("mid-write fault must fail the export")
        }
        XCTAssertEqual(fault.code, .internalError)
        XCTAssertEqual(fault.redactedContext, "diagnostics export write failed")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destinationURL.path).count,
            0,
            "rollback must leave zero leftover files in the destination"
        )
    }

    func testDiagnosticExportAllowedWhileDegradedViaRealEnvelopeAndMutationsStayBlocked() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let coordinator = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )
        await coordinator.setSessionPhase(.degraded, reason: "persistenceUnavailable")

        // Durable mutations stay blocked by the degraded gate.
        let blocked = await coordinator.processCommandForTest(.pause(PauseRequest(
            requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: TorrentRecordID(rawValue: UUID())
        )))
        guard case .failure(let blockedFault) = blocked else {
            return XCTFail("durable mutation must stay blocked while degraded")
        }
        // The storage-failure factory deliberately maps the degraded reason to
        // the stable storeError/storage_failure wire shape (never raw text);
        // recordNotFound would prove the gate did not intercept.
        XCTAssertEqual(blockedFault.code, .storeError)
        XCTAssertEqual(blockedFault.redactedContext, "storage_failure")

        // Diagnostics export rides through the REAL IPC envelope while degraded.
        let result = await coordinator.processCommandForTest(.exportDiagnostics(
            ExportDiagnosticsRequest(
                requestID: RequestID(),
                reason: "degraded probe password=DegrSecret /Users/degraded/private",
                destinationURL: nil
            )
        ))
        guard case .success(.diagnosticsExport(let export)) = result else {
            return XCTFail("degraded diagnostics export must succeed: \(result)")
        }
        defer { try? FileManager.default.removeItem(atPath: export.archiveURL) }
        XCTAssertEqual(export.entryCount, 5)

        let bundleURL = URL(fileURLWithPath: export.archiveURL, isDirectory: true)
        for fileName in ["system_info.json", "health_metrics.json", "engine_settings.json", "recent_logs.txt", "persistence_status.json"] {
            let content = try String(contentsOf: bundleURL.appendingPathComponent(fileName), encoding: .utf8)
            XCTAssertFalse(content.contains("DegrSecret"), "degraded export leaked reason secret in \(fileName)")
            XCTAssertFalse(content.contains("/Users/degraded"), "degraded export leaked home path in \(fileName)")
        }
    }

    func testDiagnosticExportSettingsProjectionIsStructuredAndPasswordFree() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let coordinator = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )

        // Hostile secret vectors flow through the shared log sink and must be
        // scrubbed by the compiled redactor before they reach the bundle.
        await RedactedLogFileManager.shared.writeLog(category: "transfer", level: "debug",
                                                     message: #"json probe {"password":"pre\"QUOTE_LEAK b\\BS_LEAK c\nNL_LEAK"}"#)

        let hostilePassword = "q\"LEAK_PW\\tail\nNL_PWLEAK"
        let hostileSettings = EngineSettings(
            downloadDirectory: tempDir.path,
            maxDownloadBytesPerSec: 2048,
            maxUploadBytesPerSec: 1024,
            listenPort: 6889,
            dhtEnabled: false,
            lsdEnabled: false,
            upnpEnabled: false,
            natPmpEnabled: false,
            encryptionEnabled: false,
            proxy: ProxyConfiguration(kind: .socks5, host: "10.0.0.7", port: 1080, username: "svc-account", password: hostilePassword)
        )
        let applied = await coordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(), idempotencyKey: IdempotencyKey(), candidate: hostileSettings
        )))
        guard case .success(.settingsApply) = applied else {
            return XCTFail("hostile-password settings apply failed: \(applied)")
        }

        let result = await coordinator.processCommandForTest(.exportDiagnostics(
            ExportDiagnosticsRequest(requestID: RequestID(), reason: "projection probe", destinationURL: nil)
        ))
        guard case .success(.diagnosticsExport(let export)) = result else {
            return XCTFail("projection probe export must succeed: \(result)")
        }
        defer { try? FileManager.default.removeItem(atPath: export.archiveURL) }
        XCTAssertEqual(export.entryCount, 5)

        let bundleURL = URL(fileURLWithPath: export.archiveURL, isDirectory: true)
        let settingsJSON = try String(contentsOf: bundleURL.appendingPathComponent("engine_settings.json"), encoding: .utf8)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(settingsJSON.utf8)) as? [String: Any],
            "engine_settings.json must parse as JSON: \(settingsJSON)"
        )
        XCTAssertEqual(object["listenPort"] as? Int, 6889)
        let projectedProxy = try XCTUnwrap(object["proxy"] as? [String: Any], "proxy projection missing: \(settingsJSON)")
        XCTAssertEqual(projectedProxy["kind"] as? String, "socks5")
        XCTAssertEqual(projectedProxy["host"] as? String, "10.0.0.7")
        XCTAssertEqual(projectedProxy["username"] as? String, "svc-account")
        XCTAssertFalse(settingsJSON.contains("password"),
                       "the password key must be absent from the projection entirely: \(settingsJSON)")

        for fileName in ["system_info.json", "health_metrics.json", "engine_settings.json", "recent_logs.txt", "persistence_status.json"] {
            let content = try String(contentsOf: bundleURL.appendingPathComponent(fileName), encoding: .utf8)
            for leak in ["QUOTE_LEAK", "BS_LEAK", "NL_LEAK", "LEAK_PW", "NL_PWLEAK"] {
                XCTAssertFalse(content.contains(leak), "\(leak) leaked in \(fileName)")
            }
        }
    }
    // MARK: - 5. End-to-end observability matrix

    func testObservabilityCommandMatrixWritesEveryRequiredClass() async throws {
        // Isolation proof FIRST: the shared sink must be disposable before
        // this matrix relies on it.
        try await verifySharedSinkIsolation()
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
                source: .torrentFileData(torrentData)
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
        let fetchedFiles = await coordinator.processCommandForTest(.fetchFiles(
            FetchFilesRequest(requestID: RequestID(), recordID: recordID, cursor: nil, pageSize: 20, expectedRevision: 0)
        ))
        guard case .success(.files(let filesPage)) = fetchedFiles else {
            return XCTFail("observability matrix fetchFiles failed: \(fetchedFiles)")
        }
        XCTAssertEqual(filesPage.totalCount, 1, "both nested files must collapse to one root directory row")
        XCTAssertEqual(filesPage.items.first?.kind, .directory)
        XCTAssertEqual(filesPage.items.first?.name, "dir")
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

        // Drive one manual reconciliation with a live engine sample (the
        // coordinator was built without a pump interval) so the shipped
        // transition logger observes the admission->downloading activity
        // change on the record.
        await engine.setStatuses([
            TransferTorrentStatus(
                engineID: "stub-1",
                progressFraction: 0.5,
                downloadedBytes: 512,
                uploadedBytes: 0,
                downloadBytesPerSec: 100,
                uploadBytesPerSec: 0,
                peersConnected: 3,
                seedsTotal: 2,
                activity: .downloading,
                health: .healthy,
                etaSeconds: nil
            )
        ])
        await coordinator.pumpOnce()

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
        XCTAssertEqual(trackerLog.severity, "error")
        XCTAssertTrue(trackerLog.message.contains("type=tracker_announce"),
                      "tracker alerts must map to type=tracker_announce: \(trackerLog.message)")

        let storageAlert = EngineAlertDTO(
            kind: "session",
            message: "storage space warning"
        )
        let storageLog = EngineAlertDTO.alertLogMessage(for: storageAlert)
        XCTAssertEqual(storageLog.severity, "warning")
        XCTAssertTrue(storageLog.message.contains("type=storage"),
                      "session alerts must map to type=storage: \(storageLog.message)")

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
            "transfer transition", "bridge alerts drained",
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

/// Thrown by the test-armed `diagnosticsExportMidWrite` failpoint.
private struct MidWriteFault: Error, Sendable {}

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
