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
        // SEC-3 line integrity: the balanced rule must not consume the
        // following line; the per-line fallback redacts and re-closes only
        // the truncated first line, so the post-break chunk stays byte-intact
        // (documented residual: it is no longer attributable once matching
        // stops at the line boundary).
        let literalNewline = "{\"token\":\"split\nNL2_LEAK\"}"
        let redactedLiteral = RedactedLogFileManager.redact(literalNewline)
        XCTAssertEqual(
            redactedLiteral,
            "{\"token\":\"<redacted>\"\nNL2_LEAK\"}",
            "first line redacts, following line survives byte-for-byte: \(redactedLiteral)"
        )
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
                case ".anchorsMatchLines": options.insert(.anchorsMatchLines)
                default:
                    XCTFail("unrecognized mirror regex option \(rawOption); extend the lockstep probe decoder")
                    return
                }
            }
            mirrorRules.append((pattern, options, template))
        }

        guard mirrorRules.count == 7 else {
            XCTFail("mirror redactor must declare exactly 7 rules (path, plain-text marker, yaml colon, tracker announce URL, JSON, unterminated-JSON fallback, auth header); found \(mirrorRules.count)")
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
        // (path → plain marker → yaml colon → tracker URL → JSON →
        // unterminated-JSON fallback → auth header).
        let hostileCorpus: [String] = [
            "password=SecretOne token=SecretTwo",
            #"{"proxy":{"password":"prefix\"QUOTE_LEAK","next":"safe"}}"#,
            "/Users/someone/path",
            "Authorization: Bearer bearer_leak",
            "passkey=PK_LEAK /Users/someone/path password=SecretOne token=SecretTwo",
            #"/Users/someone/path password=SecretOne {"token":"a\"b"} Authorization: Bearer bearer_leak"#,
            "/Users/token=hunter2",
            // SEC-3: tracker credential styles.
            "http://t.example/announce?key=TRACK_KEY_LEAK&uid=77",
            "https://tracker.example.net/TRACKPATH12345/announce",
            "proxy password: YAML_COLON_LEAK",
            "http://t.example/A1B2C3D4E5F6G7/announce?uid=7&key=K2 tracker https://x.example/HYBRIDPASS12/announce?key=HYB_Q_LEAK",
            // SEC-4: unterminated JSON value (no later quote on the line).
            "{\"password\":\"UNBAL_LEAK tail",
            // SEC-3 line integrity: balanced-JSON value split by a literal
            // newline must redact per line and preserve the following one.
            "{\"password\":\"BALNL_LEAK\nKEEP_LINE_TWO\":\"safe\"}",
            // SEC-4 backslash coverage: escape pairs and a terminal trailing
            // backslash inside an unterminated value.
            #"{"password":"esc \" ESC_UNTERM_LEAK tail"#,
            #"{"token":"TRAILBS_LEAK\"#,
            // SEC-3 announce policy (REVIEW-002): intentionally broad —
            // every opaque ≥9-char segment shape before /announce(.php)? is
            // redacted by design, digits and leading character irrelevant.
            "https://tracker.example.net/_SECRET12345/announce",
            "https://tracker.example.net/-SECRET12345/announce",
            "https://tracker.example.net/tracker-path2/announce https://y.example/_nodigit_key/announce.php",
            "https://z.example/-DashLedKey9/announce plain https://w.example/AbCdEfGhIj/announce",
        ]
        let forbiddenLeaks = [
            "SecretOne", "SecretTwo", "QUOTE_LEAK", "/Users/someone", "bearer_leak", "PK_LEAK",
            "TRACK_KEY_LEAK", "uid=77", "TRACKPATH12345", "YAML_COLON_LEAK",
            "A1B2C3D4E5F6G7", "HYBRIDPASS12", "HYB_Q_LEAK", "UNBAL_LEAK",
            "BALNL_LEAK", "ESC_UNTERM_LEAK", "TRAILBS_LEAK", "_SECRET12345", "-SECRET12345",
            "tracker-path2", "_nodigit_key", "-DashLedKey9", "AbCdEfGhIj",
        ]

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

        // Word-boundary safety (SEC-3): credential-adjacent ordinary words
        // must NOT trigger redaction, and announce URLs without an opaque
        // first segment must survive structurally intact. A long ordinary
        // first segment before /announce is redacted BY DESIGN (see
        // testAnnouncePolicyRedactsEveryOpaqueSegmentShapeByDesign) — it is
        // not a false-positive candidate anymore.
        let falsePositives: [(input: String, mustSurvive: String)] = [
            ("keyboard=QWERTY_OK monkey=brown guid=xyz", "keyboard=QWERTY_OK"),
            ("guuid=not-a-credential tokenish=keepme", "tokenish=keepme"),
            ("http://t.example/announce?info_hash=abc", "http://t.example/announce?info_hash=abc"),
        ]
        for (input, survivor) in falsePositives {
            let compiledOutput = RedactedLogFileManager.redact(input)
            let mirrorOutput = mirrorRedact(input)
            XCTAssertEqual(Array(compiledOutput.utf8), Array(mirrorOutput.utf8),
                           "mirror diverged on false-positive vector \(input)")
            XCTAssertTrue(compiledOutput.contains(survivor),
                          "redactor false positive destroyed \(survivor) in \(input): \(compiledOutput)")
        }
    }

    // MARK: - WP-13 SEC hardening (SEC-1..SEC-5)

    /// Compiled-redactor behavioral coverage for the SEC-3/SEC-4 credential
    /// classes (tracker query params, path-embedded passkeys, yaml-ish colon
    /// values, unterminated JSON values), including newline safety and
    /// word-boundary false-positive guards. The adversarial shell probe lives
    /// in scripts/qa/test_security_redactor_negative.sh; this keeps the same
    /// contract enforced inside XCTest.
    func testRedactorScrubsTrackerCredentialStylesAndUnterminatedJSONValues() {
        // Tracker credential styles must be scrubbed…
        let trackerKey = RedactedLogFileManager.redact("http://t.example/announce?key=DEADBEEF_KEY&uid=7")
        XCTAssertFalse(trackerKey.contains("DEADBEEF_KEY"))
        XCTAssertTrue(trackerKey.contains("key=<redacted>"))
        XCTAssertTrue(trackerKey.contains("uid=<redacted>"), trackerKey)

        let pathCredential = RedactedLogFileManager.redact("https://tracker.example.net/PATHKEY123456/announce")
        XCTAssertEqual(pathCredential, "https://tracker.example.net/<redacted>/announce")

        let yamlColon = RedactedLogFileManager.redact("proxy password: COLON_LEAK")
        XCTAssertFalse(yamlColon.contains("COLON_LEAK"))
        XCTAssertTrue(yamlColon.contains("password: <redacted>"), yamlColon)

        // …while ordinary words and announce URLs stay intact…
        let untouched = RedactedLogFileManager.redact("keyboard=QWERTY_OK monkey=brown guid=xyz http://t.example/announce?info_hash=abc")
        XCTAssertTrue(untouched.contains("keyboard=QWERTY_OK"), untouched)
        XCTAssertTrue(untouched.contains("monkey=brown"), untouched)
        XCTAssertTrue(untouched.contains("guid=xyz"), untouched)
        XCTAssertTrue(untouched.contains("info_hash=abc"), untouched)

        // …and an unterminated JSON value redacts to end of line (SEC-4).
        let unbalanced = RedactedLogFileManager.redact("{\"password\":\"unterminated UNBAL_LEAK tail")
        XCTAssertFalse(unbalanced.contains("UNBAL_LEAK"), unbalanced)
        XCTAssertEqual(unbalanced, "{\"password\":\"<redacted>\"", "fallback must re-close the string value")

        // Newline-safety property holds for the fallback rule too: only the
        // truncated line is consumed; following lines survive byte-intact.
        let multiline = "{\n\"secret\":\"UNBAL2_LEAK tail\nstill-no-quotes-here"
        let redactedMultiline = RedactedLogFileManager.redact(multiline)
        XCTAssertFalse(redactedMultiline.contains("UNBAL2_LEAK"), redactedMultiline)
        XCTAssertTrue(redactedMultiline.hasSuffix("\nstill-no-quotes-here"), redactedMultiline.debugDescription)
    }

    /// SEC-3 line-integrity + SEC-4 backslash on the compiled redactor. A
    /// credential value split by a literal newline must never consume the
    /// following line (byte-for-byte preservation), while backslash-bearing
    /// unterminated values (escape pairs, terminal trailing backslash) must
    /// still redact to end of line with the string re-closed. The mirror
    /// implementation is held to the same vectors by
    /// testMirrorRedactorStaysInLockstepWithCompiledRedactor; the announce
    /// policy vectors live in
    /// testAnnouncePolicyRedactsEveryOpaqueSegmentShapeByDesign.
    func testRedactorPreservesLineIntegrityAndCoversBackslashBearingUnterminatedValues() {
        // Balanced-JSON-shaped value containing a literal newline: the
        // balanced rule cannot match across the break; the per-line fallback
        // redacts only the truncated first line.
        let multiline = "{\"password\":\"BALNL_LEAK\nKEEP_LINE_TWO\":\"safe\"}"
        let redactedMultiline = RedactedLogFileManager.redact(multiline)
        XCTAssertFalse(redactedMultiline.contains("BALNL_LEAK"), redactedMultiline)
        XCTAssertEqual(
            redactedMultiline,
            "{\"password\":\"<redacted>\"\nKEEP_LINE_TWO\":\"safe\"}",
            "following-line bytes must survive byte-for-byte"
        )

        // Unterminated value with an escaped quote inside: escape pairs are
        // consumed to end of line and the string is re-closed (SEC-4).
        let escapedUnterminated = RedactedLogFileManager.redact(#"{"password":"esc \" ESC_UNTERM_LEAK tail"#)
        XCTAssertFalse(escapedUnterminated.contains("ESC_UNTERM_LEAK"), escapedUnterminated)
        XCTAssertEqual(escapedUnterminated, #"{"password":"<redacted>""#)

        // Unterminated value ending in a lone trailing backslash.
        let trailingBackslash = RedactedLogFileManager.redact(#"{"token":"TRAILBS_LEAK\"#)
        XCTAssertFalse(trailingBackslash.contains("TRAILBS_LEAK"), trailingBackslash)
        XCTAssertEqual(trailingBackslash, #"{"token":"<redacted>""#)

        // Separator hardening: a colon separator must not bridge a newline.
        let foldedYaml = RedactedLogFileManager.redact("password:\nPLAIN_NEXT_LINE")
        XCTAssertEqual(foldedYaml, "password:\nPLAIN_NEXT_LINE", "separator must stay on one line")

    }

    /// SEC-3 announce policy (WP13-SEC-HARDEN-001 REVIEW-002): INTENTIONALLY
    /// BROAD. ANY opaque [A-Za-z0-9_-]{9,} first segment before
    /// /announce(.php)? is treated as a private-tracker passkey and redacted
    /// BY DESIGN — digits and the leading character are irrelevant, because
    /// numeric, underscore-led, dash-led, and plain-alphanumeric passkeys all
    /// occur in the wild. Deliberate diagnostic-fidelity tradeoff: the HOST
    /// and the announce suffix always survive, so tracker connectivity stays
    /// diagnosable while no credential-shaped token reaches logs. The former
    /// digit-heuristic survivor framing is gone; these are covered vectors.
    func testAnnouncePolicyRedactsEveryOpaqueSegmentShapeByDesign() {
        let redactedByDesign: [(input: String, expected: String)] = [
            // Numeric-bearing alphanumeric segment (former heuristic match).
            ("https://tracker.example.net/tracker-path2/announce",
             "https://tracker.example.net/<redacted>/announce"),
            // Underscore-led segment WITHOUT any digit.
            ("https://tracker.example.net/_passkey_nodigit/announce",
             "https://tracker.example.net/<redacted>/announce"),
            // Dash-led segment WITHOUT any digit.
            ("https://tracker.example.net/-PASSKEY-LED/announce",
             "https://tracker.example.net/<redacted>/announce"),
            // Plain lowercase alphanumeric segment WITHOUT any digit.
            ("https://tracker.example.net/AbCdEfGhIj/announce",
             "https://tracker.example.net/<redacted>/announce"),
            // The former "false positive survivor" corpus vector: now a
            // designed redaction under the intentionally broad policy.
            ("http://t.example/tracker-path/announce",
             "http://t.example/<redacted>/announce"),
            // announce.php suffix variant.
            ("https://t.example/0123456789/announce.php",
             "https://t.example/<redacted>/announce.php"),
        ]
        for (input, expected) in redactedByDesign {
            XCTAssertEqual(
                RedactedLogFileManager.redact(input),
                expected,
                "opaque announce first segment must be redacted by design: \(input)"
            )
        }

        // Survivors: no opaque ≥9-char first segment — host, short segments,
        // and query material stay structurally intact.
        let survivors = [
            "http://t.example/announce?info_hash=abc",
            "http://t.example/a/announce",
            "https://t.example/announce.php",
        ]
        for input in survivors {
            XCTAssertEqual(
                RedactedLogFileManager.redact(input),
                input,
                "non-opaque announce URL must survive untouched: \(input)"
            )
        }
    }

    /// SEC-1(a): with an authenticated proxy configured, the persisted
    /// `engine_settings` row (decoded through the existing store seam AND
    /// scanned raw on disk across the forensic trio) contains no credential
    /// material — only the presence marker.
    func testPersistedSettingsRowContainsNoCredentialMaterialAtRest() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let secret = "RestSecretProxyPW_7f31"
        let candidate = EngineSettings(
            downloadDirectory: tempDir.path,
            maxDownloadBytesPerSec: 1024,
            maxUploadBytesPerSec: 2048,
            listenPort: 49_100,
            dhtEnabled: true,
            lsdEnabled: false,
            upnpEnabled: true,
            natPmpEnabled: false,
            encryptionEnabled: true,
            proxy: ProxyConfiguration(
                kind: .socks5,
                host: "127.0.0.1",
                port: 10_805,
                username: "sec-user",
                password: secret
            )
        )
        try await store.persistSettings(candidate, revision: 3)

        let persistedBytes = try await store.sessionValue(key: "engine_settings")
        let rowText = String(decoding: persistedBytes?.data ?? Data(), as: UTF8.self)
        XCTAssertFalse(rowText.contains(secret), "credential material found in engine_settings row: \(rowText)")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(persistedBytes?.data)) as? [String: Any])
        XCTAssertEqual(row["hasProxyPassword"] as? Bool, true, "presence marker must record the withheld credential")
        XCTAssertEqual(row["version"] as? Int, 1)
        let projectedProxy = try XCTUnwrap(
            ((row["settings"] as? [String: Any])?["proxy"]) as? [String: Any]
        )
        XCTAssertFalse(projectedProxy.keys.contains("password"), "projection must have no representation for the credential")
        XCTAssertEqual(projectedProxy["username"] as? String, "sec-user")

        // Raw at-rest scan: main database plus WAL/-shm sidecars.
        let databaseURL = store.databaseURL
        let walURL = await store.walURL
        let shmURL = await store.shmURL
        for url in [databaseURL, walURL, shmURL] where FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).range(of: secret) != nil,
                           "credential bytes found at rest in \(url.lastPathComponent)")
        }

        // Loading reconstructs without the secret: present-but-withheld.
        let loaded = try await store.loadSettings()
        XCTAssertEqual(loaded?.revision, 3)
        XCTAssertEqual(loaded?.settings.proxy.kind, .socks5)
        XCTAssertEqual(loaded?.settings.proxy.host, "127.0.0.1")
        XCTAssertEqual(loaded?.settings.proxy.port, 10_805)
        XCTAssertEqual(loaded?.settings.proxy.username, "sec-user")
        XCTAssertEqual(loaded?.settings.proxy.password, "")
    }

    /// SEC-1(b): boot restore reconstructs the configuration without the
    /// credential, and an applySettings round trip restores full proxy
    /// function while keeping the durable row credential-free.
    func testBootRestoreStripsSecretThenApplyRoundTripRestoresProxyFunction() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let secret = "RoundTripProxyPW_99aa"
        let candidate = EngineSettings(
            downloadDirectory: tempDir.path,
            maxDownloadBytesPerSec: 4096,
            maxUploadBytesPerSec: 8192,
            listenPort: 49_101,
            dhtEnabled: false,
            lsdEnabled: true,
            upnpEnabled: false,
            natPmpEnabled: true,
            encryptionEnabled: false,
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.internal",
                port: 3128,
                username: "rt-user",
                password: secret
            )
        )
        try await store.persistSettings(candidate, revision: 7)

        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let engine = StubTransferEngine()
        let coordinator = TransferCoordinator(
            engine: engine,
            persistence: store,
            eventBus: bus,
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )
        await coordinator.restoreFromPersistence()

        let fetchedReply = await coordinator.processCommandForTest(.fetchSettings(FetchSettingsRequest(requestID: RequestID())))
        guard case .success(.settingsFetch(let fetched)) = fetchedReply else {
            return XCTFail("settings fetch after restore failed: \(fetchedReply)")
        }
        XCTAssertEqual(fetched.revision, 7)
        XCTAssertEqual(fetched.settings.proxy.kind, .http)
        XCTAssertEqual(fetched.settings.proxy.host, "proxy.internal")
        XCTAssertEqual(fetched.settings.proxy.port, 3128)
        XCTAssertEqual(fetched.settings.proxy.username, "rt-user")
        XCTAssertEqual(fetched.settings.proxy.password, "", "boot restore must not retain the credential value")

        let applied = await coordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            candidate: candidate,
            expectedRevision: fetched.revision
        )))
        guard case .success(.settingsApply(let applyResult)) = applied else {
            return XCTFail("apply round trip failed: \(applied)")
        }
        XCTAssertEqual(applyResult.revision, 8)

        let applications = await engine.settingsApplications()
        XCTAssertEqual(applications.last, candidate, "the live engine must receive the full configuration")

        let repersisted = try await store.loadSettings()
        XCTAssertEqual(repersisted?.revision, 8)
        XCTAssertEqual(repersisted?.settings.proxy.password, "")
        XCTAssertEqual(repersisted?.settings.proxy.host, "proxy.internal")

        let persistedBytes = try await store.sessionValue(key: "engine_settings")
        XCTAssertFalse(String(decoding: persistedBytes?.data ?? Data(), as: UTF8.self).contains(secret),
                       "round trip re-persisted credential material")
    }

    /// SEC-1 credential delivery (WP13-SEC-HARDEN-001): an applySettings
    /// carrying proxyPassword reaches the LIVE engine configuration and the
    /// in-memory active settings, while every durable byte — the persisted
    /// engine_settings row and the forensic trio (db + wal + shm) — stays
    /// credential-free.
    func testApplySettingsDeliversProxyPasswordToLiveEngineMemoryOnly() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let secret = "DeliverSecret_PW_5c1"
        let engine = StubTransferEngine()
        let coordinator = TransferCoordinator(
            engine: engine,
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )
        let candidate = EngineSettings(
            downloadDirectory: tempDir.path,
            maxDownloadBytesPerSec: 1024,
            maxUploadBytesPerSec: 512,
            listenPort: 49_102,
            dhtEnabled: true,
            lsdEnabled: true,
            upnpEnabled: false,
            natPmpEnabled: false,
            encryptionEnabled: true,
            proxy: ProxyConfiguration(kind: .socks5, host: "proxy.delivery", port: 10_806, username: "del-user")
        )
        XCTAssertNil(candidate.proxy.password)

        let applied = await coordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            candidate: candidate,
            expectedRevision: nil,
            proxyPassword: secret
        )))
        guard case .success(.settingsApply(let result)) = applied else {
            return XCTFail("credential delivery apply failed: \(applied)")
        }
        XCTAssertEqual(result.revision, 2)

        let applications = await engine.settingsApplications()
        XCTAssertEqual(applications.last?.proxy.host, "proxy.delivery")
        XCTAssertEqual(applications.last?.proxy.username, "del-user")
        XCTAssertEqual(applications.last?.proxy.password, secret,
                       "the live engine session must receive the delivered credential")

        let fetchedReply = await coordinator.processCommandForTest(.fetchSettings(FetchSettingsRequest(requestID: RequestID())))
        guard case .success(.settingsFetch(let fetched)) = fetchedReply else {
            return XCTFail("settings fetch after delivery failed: \(fetchedReply)")
        }
        XCTAssertEqual(fetched.settings.proxy.password, secret,
                       "activeSettings holds the delivered credential in memory only")

        // No durable byte carries the secret: the row is the credential-free
        // projection with the DELIVERED-configuration presence marker (F1
        // marker invariant, REVIEW-002) and a raw scan of the forensic trio
        // stays clean.
        let rowPayload = try await store.sessionValue(key: "engine_settings")
        let rowText = String(decoding: rowPayload?.data ?? Data(), as: UTF8.self)
        XCTAssertFalse(rowText.contains(secret), "persisted row absorbed the delivered credential: \(rowText)")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(rowPayload?.data)) as? [String: Any])
        XCTAssertEqual(row["hasProxyPassword"] as? Bool, true,
                       "a delivered credential must persist marker=true with zero secret bytes")
        let projectedProxy = try XCTUnwrap(((row["settings"] as? [String: Any])?["proxy"]) as? [String: Any])
        XCTAssertFalse(projectedProxy.keys.contains("password"),
                       "projection must have no representation for the credential")
        for url in [store.databaseURL, await store.walURL, await store.shmURL]
        where FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(secret),
                           "delivered credential bytes found at rest in \(url.lastPathComponent)")
        }

        // The redactor corpus covers the new wire field name too.
        let redactedJSON = RedactedLogFileManager.redact("{"+"\"proxyPassword\":\"\(secret)\"}")
        XCTAssertFalse(redactedJSON.contains(secret), "redactor leaked the delivered credential shape: \(redactedJSON)")
    }

    /// SEC-1 compatibility: applySettings WITHOUT the optional credential
    /// keeps today's exact behavior — the engine receives the candidate
    /// verbatim and no password appears anywhere.
    func testApplySettingsWithoutProxyPasswordKeepsCandidateCredentialFree() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let engine = StubTransferEngine()
        let coordinator = TransferCoordinator(
            engine: engine,
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )
        let candidate = EngineSettings(
            downloadDirectory: tempDir.path,
            maxDownloadBytesPerSec: 256,
            maxUploadBytesPerSec: 128,
            listenPort: 49_103,
            dhtEnabled: false,
            lsdEnabled: true,
            upnpEnabled: true,
            natPmpEnabled: true,
            encryptionEnabled: true,
            proxy: ProxyConfiguration(kind: .http, host: "anon.proxy", port: 3128)
        )

        let applied = await coordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            candidate: candidate,
            expectedRevision: nil
        )))
        guard case .success(.settingsApply) = applied else {
            return XCTFail("credential-free apply failed: \(applied)")
        }

        let applications = await engine.settingsApplications()
        XCTAssertEqual(applications.last, candidate,
                       "an apply without the credential must hand the engine the untouched candidate")
        XCTAssertNil(applications.last?.proxy.password)

        let persisted = try await store.loadSettings()
        XCTAssertEqual(persisted?.settings, candidate)

        // F1 marker invariant: an apply that delivered NO credential must
        // persist marker=false — the live configuration is genuinely
        // unauthenticated.
        let rowPayload = try await store.sessionValue(key: "engine_settings")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(rowPayload?.data)) as? [String: Any])
        XCTAssertEqual(row["hasProxyPassword"] as? Bool, false,
                       "an apply without a delivered credential must persist marker=false")
    }

    /// SEC-1 boot transient (WP13-SEC-HARDEN-001): a marker-only disk restore
    /// boots the authenticated proxy WITHOUT its credential (the withheld
    /// empty value) until the first UI-driven apply re-supplies it; later
    /// boots then carry the delivered memory-only credential.
    func testBootRestoredAuthenticatedProxyBootsUnauthenticatedUntilFirstApply() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let secret = "BootTransient_PW_77e"
        func configuredCandidate(password: String?) -> EngineSettings {
            EngineSettings(
                downloadDirectory: tempDir.path,
                maxDownloadBytesPerSec: 2048,
                maxUploadBytesPerSec: 1024,
                listenPort: 49_104,
                dhtEnabled: true,
                lsdEnabled: false,
                upnpEnabled: true,
                natPmpEnabled: false,
                encryptionEnabled: true,
                proxy: ProxyConfiguration(kind: .http, host: "proxy.boot", port: 3128, username: "boot-user", password: password)
            )
        }
        try await store.persistSettings(configuredCandidate(password: secret), revision: 4)

        let engine = StubTransferEngine()
        let coordinator = TransferCoordinator(
            engine: engine,
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )
        await coordinator.restoreFromPersistence()

        let bootRestart = await coordinator.processCommandForTest(.restartEngineSafely(
            RestartEngineSafelyRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey())
        ))
        guard case .success(.ack) = bootRestart else {
            return XCTFail("boot restart failed: \(bootRestart)")
        }
        var configurations = await engine.recordedConfigurations()
        var booted = try XCTUnwrap(configurations.last, "restart must hand the engine a configuration")
        XCTAssertEqual(booted?.proxy.username, "boot-user")
        XCTAssertEqual(booted?.proxy.password, "",
                       "boot from marker-only rows must run the authenticated proxy unauthenticated until the first apply")

        let applied = await coordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            candidate: configuredCandidate(password: nil),
            expectedRevision: 4,
            proxyPassword: secret
        )))
        guard case .success(.settingsApply) = applied else {
            return XCTFail("post-boot credential delivery failed: \(applied)")
        }
        let applications = await engine.settingsApplications()
        XCTAssertEqual(applications.last?.proxy.password, secret)

        let postApplyRestart = await coordinator.processCommandForTest(.restartEngineSafely(
            RestartEngineSafelyRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey())
        ))
        guard case .success(.ack) = postApplyRestart else {
            return XCTFail("post-apply restart failed: \(postApplyRestart)")
        }
        configurations = await engine.recordedConfigurations()
        booted = try XCTUnwrap(configurations.last)
        XCTAssertEqual(booted?.proxy.password, secret,
                       "after the delivery the memory-only credential must survive restarts")
    }

    /// F1 sentinel distinction (WP13-SEC-HARDEN-001 REVIEW-002): a
    /// marker=true restore takes the WITHHELD path — "" until the first
    /// apply re-supplies it, notice-worthy, then authenticated live state —
    /// while a marker=false restore is genuinely unauthenticated (nil,
    /// silent). The predicate behind the boot notice is asserted directly so
    /// the two sentinel shapes can never collapse into one notice path again.
    func testBootRestoreMarkerStatesDistinguishWithheldFromGenuinelyUnauthenticated() async throws {
        let secret = "Sentinel_PW_41f"
        func configuredCandidate(
            host: String,
            password: String?
        ) -> EngineSettings {
            EngineSettings(
                downloadDirectory: tempDir.path,
                maxDownloadBytesPerSec: 1024,
                maxUploadBytesPerSec: 512,
                listenPort: 49_105,
                dhtEnabled: true,
                lsdEnabled: false,
                upnpEnabled: true,
                natPmpEnabled: false,
                encryptionEnabled: true,
                proxy: ProxyConfiguration(kind: .http, host: host, port: 3128, username: "sentinel-user", password: password)
            )
        }

        // marker=true row: persisted by an apply that DELIVERED a credential.
        let withheldDir = tempDir.appendingPathComponent("marker-true", isDirectory: true)
        try FileManager.default.createDirectory(at: withheldDir, withIntermediateDirectories: true)
        let withheldStore = PersistenceStore(dataDirectory: withheldDir)
        _ = try await withheldStore.open()
        try await withheldStore.persistSettings(configuredCandidate(host: "withheld.proxy", password: secret), revision: 5)

        let withheldEngine = StubTransferEngine()
        let withheldCoordinator = TransferCoordinator(
            engine: withheldEngine,
            persistence: withheldStore,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: withheldDir.path)
        )
        await withheldCoordinator.restoreFromPersistence()

        let withheldFetch = await withheldCoordinator.processCommandForTest(
            .fetchSettings(FetchSettingsRequest(requestID: RequestID()))
        )
        guard case .success(.settingsFetch(let withheld)) = withheldFetch else {
            return XCTFail("marker-true fetch failed: \(withheldFetch)")
        }
        XCTAssertEqual(withheld.settings.proxy.password, "",
                       "a marker-true boot must withhold the credential as empty, not nil")
        XCTAssertTrue(
            TransferCoordinator.shouldNoteUnauthenticatedProxyWindow(withheld.settings.proxy),
            "the withheld sentinel must take the unauthenticated-window notice path"
        )

        let firstApply = await withheldCoordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            candidate: configuredCandidate(host: "withheld.proxy", password: nil),
            expectedRevision: 5,
            proxyPassword: secret
        )))
        guard case .success(.settingsApply) = firstApply else {
            return XCTFail("re-supply apply failed: \(firstApply)")
        }
        let postApplyApplications = await withheldEngine.settingsApplications()
        XCTAssertEqual(postApplyApplications.last?.proxy.password, secret,
                       "the first post-boot apply must deliver the credential to the live engine")
        let postApplyFetch = await withheldCoordinator.processCommandForTest(
            .fetchSettings(FetchSettingsRequest(requestID: RequestID()))
        )
        guard case .success(.settingsFetch(let authenticated)) = postApplyFetch else {
            return XCTFail("post-apply fetch failed: \(postApplyFetch)")
        }
        XCTAssertEqual(authenticated.settings.proxy.password, secret)
        XCTAssertFalse(
            TransferCoordinator.shouldNoteUnauthenticatedProxyWindow(authenticated.settings.proxy),
            "an authenticated live configuration must never take the notice path"
        )

        // marker=false row: no credential was ever configured.
        let silentDir = tempDir.appendingPathComponent("marker-false", isDirectory: true)
        try FileManager.default.createDirectory(at: silentDir, withIntermediateDirectories: true)
        let silentStore = PersistenceStore(dataDirectory: silentDir)
        _ = try await silentStore.open()
        try await silentStore.persistSettings(configuredCandidate(host: "silent.proxy", password: nil), revision: 2)

        let silentCoordinator = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: silentStore,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: silentDir.path)
        )
        await silentCoordinator.restoreFromPersistence()

        let silentFetch = await silentCoordinator.processCommandForTest(
            .fetchSettings(FetchSettingsRequest(requestID: RequestID()))
        )
        guard case .success(.settingsFetch(let silent)) = silentFetch else {
            return XCTFail("marker-false fetch failed: \(silentFetch)")
        }
        XCTAssertNil(silent.settings.proxy.password,
                     "a marker-false boot restores nil — genuinely unauthenticated")
        XCTAssertFalse(
            TransferCoordinator.shouldNoteUnauthenticatedProxyWindow(silent.settings.proxy),
            "the nil sentinel boots silently; only the withheld empty value notices"
        )
    }

    /// F1-ROLLBACK-SENTINEL (WP13-SEC-HARDEN-001 REVIEW-003): a failed
    /// apply on top of a marker=true boot must roll the durable row back to
    /// the EXACT pre-apply at-rest semantics — marker=true with zero secret
    /// bytes across db/-wal/-shm — so the next boot restores the withheld ""
    /// sentinel instead of a silent nil while the Keychain secret survives.
    func testFailedApplyRollbackRestoresWithheldMarkerTrueAndZeroSecretBytes() async throws {
        let secret = "RollbackSentinel_PW_9d2"
        func configuredCandidate(host: String, password: String?) -> EngineSettings {
            EngineSettings(
                downloadDirectory: tempDir.path,
                maxDownloadBytesPerSec: 1024,
                maxUploadBytesPerSec: 512,
                listenPort: 49_106,
                dhtEnabled: true,
                lsdEnabled: false,
                upnpEnabled: true,
                natPmpEnabled: false,
                encryptionEnabled: true,
                proxy: ProxyConfiguration(kind: .http, host: host, port: 3128, username: "rollback-user", password: password)
            )
        }

        let withheldDir = tempDir.appendingPathComponent("rollback-marker-true", isDirectory: true)
        try FileManager.default.createDirectory(at: withheldDir, withIntermediateDirectories: true)
        let store = PersistenceStore(dataDirectory: withheldDir)
        _ = try await store.open()
        // Seed the marker=true row exactly the way a delivered apply leaves it.
        try await store.persistSettings(configuredCandidate(host: "withheld.proxy", password: secret), revision: 5)

        let engine = StubTransferEngine()
        let coordinator = TransferCoordinator(
            engine: engine,
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: withheldDir.path)
        )
        await coordinator.restoreFromPersistence()

        await engine.failNextSettingsApplication()
        let failed = await coordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            candidate: configuredCandidate(host: "withheld.proxy", password: nil),
            expectedRevision: 5
        )))
        guard case .failure(let fault) = failed else {
            return XCTFail("forced apply failure did not fail: \(failed)")
        }
        XCTAssertEqual(fault.code, .engineBusy, "the stub failure must surface as the typed busy fault")

        let applications = await engine.settingsApplications()
        XCTAssertEqual(applications.count, 1,
                       "only the live-engine rollback may land: the failed delivery throws before recording")
        XCTAssertEqual(applications.last?.proxy.password, "",
                       "rollback must hand the engine back the withheld empty credential shape")

        let rowPayload = try await store.sessionValue(key: "engine_settings")
        let rowText = String(decoding: rowPayload?.data ?? Data(), as: UTF8.self)
        XCTAssertFalse(rowText.contains(secret), "rollback row absorbed the credential: \(rowText)")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(rowPayload?.data)) as? [String: Any])
        XCTAssertEqual(row["hasProxyPassword"] as? Bool, true,
                       "failed-apply rollback must restore the pre-apply withheld marker=true")
        for url in [store.databaseURL, await store.walURL, await store.shmURL]
        where FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(secret),
                           "credential bytes found at rest in \(url.lastPathComponent)")
        }
        let restored = try await store.loadSettings()
        XCTAssertEqual(restored?.revision, 5, "rollback must restore the pre-apply revision")
        XCTAssertEqual(restored?.settings.proxy.password, "",
                       "next boot must see the withheld empty sentinel again, not nil")
    }

    /// F1-ROLLBACK-SENTINEL counterpart: the genuinely-unauthenticated boot
    /// (marker=false) must survive a failed apply unchanged — no phantom
    /// presence marker may appear on rollback.
    func testFailedApplyRollbackKeepsGenuinelyUnauthenticatedMarkerFalse() async throws {
        func configuredCandidate(host: String, password: String?) -> EngineSettings {
            EngineSettings(
                downloadDirectory: tempDir.path,
                maxDownloadBytesPerSec: 1024,
                maxUploadBytesPerSec: 512,
                listenPort: 49_107,
                dhtEnabled: true,
                lsdEnabled: false,
                upnpEnabled: true,
                natPmpEnabled: false,
                encryptionEnabled: true,
                proxy: ProxyConfiguration(kind: .http, host: host, port: 3128, username: "silent-user", password: password)
            )
        }

        let silentDir = tempDir.appendingPathComponent("rollback-marker-false", isDirectory: true)
        try FileManager.default.createDirectory(at: silentDir, withIntermediateDirectories: true)
        let store = PersistenceStore(dataDirectory: silentDir)
        _ = try await store.open()
        try await store.persistSettings(configuredCandidate(host: "silent.proxy", password: nil), revision: 2)

        let engine = StubTransferEngine()
        let coordinator = TransferCoordinator(
            engine: engine,
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: silentDir.path)
        )
        await coordinator.restoreFromPersistence()

        await engine.failNextSettingsApplication()
        let failed = await coordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            candidate: configuredCandidate(host: "silent.proxy", password: nil),
            expectedRevision: 2
        )))
        guard case .failure(let fault) = failed else {
            return XCTFail("forced apply failure did not fail: \(failed)")
        }
        XCTAssertEqual(fault.code, .engineBusy)

        let rowPayload = try await store.sessionValue(key: "engine_settings")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(rowPayload?.data)) as? [String: Any])
        XCTAssertEqual(row["hasProxyPassword"] as? Bool, false,
                       "rollback must keep the genuinely-unauthenticated marker=false")
        let restored = try await store.loadSettings()
        XCTAssertEqual(restored?.revision, 2)
        XCTAssertNil(restored?.settings.proxy.password,
                     "a marker-false boot stays nil after rollback — no withheld sentinel invented")
    }

    /// SEC-1 plumbing: the internal SessionProxyDTO carries the credential
    /// across the PIMPL JSON boundary under the exact "password" key the
    /// ObjC++ adapter decodes, omits the key when no credential is held, and
    /// tolerates envelopes written before the field existed.
    func testSessionProxyDTOPlumbsPasswordAcrossBridgeJSONBoundary() throws {
        let withCredential = SessionConfigurationDTO(proxy: SessionProxyDTO(
            kind: "socks5", host: "proxy.bridge", port: 1080, username: "svc", password: "BridgePW_31"
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(withCredential)) as? [String: Any]
        )
        let proxyObject = try XCTUnwrap(object["proxy"] as? [String: Any])
        XCTAssertEqual(proxyObject["password"] as? String, "BridgePW_31")

        // Old bridge-facing envelope (pre-field encoder output = key absent)
        // decodes with nil while every other proxy field survives.
        var legacyObject = object
        var legacyProxy = proxyObject
        legacyProxy.removeValue(forKey: "password")
        legacyObject["proxy"] = legacyProxy
        let legacyDTO = try JSONDecoder().decode(
            SessionConfigurationDTO.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertNil(legacyDTO.proxy.password)
        XCTAssertEqual(legacyDTO.proxy.username, "svc")
        XCTAssertEqual(legacyDTO.proxy.host, "proxy.bridge")

        // A nil credential encodes key-absent, so the segment handed to
        // adapter.applyEngine(withConfigurationData:) stays old-shape.
        let credentialFree = SessionConfigurationDTO(proxy: SessionProxyDTO(
            kind: "http", host: "proxy.bridge", port: 1080, username: "svc"
        ))
        let freeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(credentialFree)) as? [String: Any]
        )
        let freeProxy = try XCTUnwrap(freeObject["proxy"] as? [String: Any])
        XCTAssertFalse(freeProxy.keys.contains("password"))
    }

    /// SEC-1(c)/SEC-1-LEGACY: legacy rows that DID carry credential material
    /// are sanitized on load — typed legacy shape, tolerant dictionary, AND
    /// missing-revision rows — and the very load that sanitizes them rewrites
    /// the persisted row so a RAW scan of the forensic trio (main db + -wal +
    /// -shm) finds zero credential bytes afterwards, with the sanitized
    /// envelope in place.
    func testLegacyPersistedSettingsWithCredentialAreSanitizedAndScrubbedAtRestOnLoad() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()

        // Shared scrub proof: the active row decodes as the sanitized
        // envelope (presence marker preserved, no credential value), and no
        // file of the forensic trio contains the secret's bytes anymore.
        func assertRowScrubbedAtRest(secret: String, username: String) async throws {
            let payload = try await store.sessionValue(key: "engine_settings")
            let row = try XCTUnwrap(payload)
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: row.data) as? [String: Any])
            XCTAssertEqual(record["version"] as? Int, 1)
            XCTAssertEqual(record["hasProxyPassword"] as? Bool, true, "presence marker must survive the scrub")
            let projectedProxy = try XCTUnwrap(((record["settings"] as? [String: Any])?["proxy"]) as? [String: Any])
            XCTAssertFalse(projectedProxy.keys.contains("password"), "projection must have no representation for the credential")
            XCTAssertEqual(projectedProxy["username"] as? String, username)
            let walURL = await store.walURL
            let shmURL = await store.shmURL
            for url in [store.databaseURL, walURL, shmURL]
            where FileManager.default.fileExists(atPath: url.path) {
                let bytes = try Data(contentsOf: url)
                XCTAssertFalse(
                    String(decoding: bytes, as: UTF8.self).contains(secret),
                    "credential bytes found at rest in \(url.lastPathComponent)"
                )
            }
        }

        // Shape 1: pre-projection rows were verbatim EngineSettings JSON.
        let legacyTyped = EngineSettings(
            downloadDirectory: "/Users/legacy/Downloads",
            maxDownloadBytesPerSec: 512,
            maxUploadBytesPerSec: 256,
            listenPort: 49_102,
            dhtEnabled: true,
            lsdEnabled: true,
            upnpEnabled: true,
            natPmpEnabled: true,
            encryptionEnabled: true,
            proxy: ProxyConfiguration(
                kind: .socks5,
                host: "legacy.proxy",
                port: 1080,
                username: "old-user",
                password: "LegacyLeak_PW1"
            )
        )
        try await store.setSessionValue(key: "engine_settings", data: try JSONEncoder().encode(legacyTyped))
        try await store.setSessionValue(key: "engine_settings_revision", data: Data("12".utf8))
        let sanitized = try await store.loadSettings()
        XCTAssertEqual(sanitized?.revision, 12)
        XCTAssertEqual(sanitized?.settings.downloadDirectory, "/Users/legacy/Downloads")
        XCTAssertEqual(sanitized?.settings.listenPort, 49_102)
        XCTAssertEqual(sanitized?.settings.proxy.kind, .socks5)
        XCTAssertEqual(sanitized?.settings.proxy.host, "legacy.proxy")
        XCTAssertEqual(sanitized?.settings.proxy.username, "old-user")
        XCTAssertEqual(sanitized?.settings.proxy.password, "", "legacy credential must be withheld, not retained")
        try await assertRowScrubbedAtRest(secret: "LegacyLeak_PW1", username: "old-user")

        // Shape 2: damaged scalar forces the tolerant dictionary fallback;
        // its proxy reconstruction must strip the credential too.
        let tolerantShape: [String: Any] = [
            "downloadDirectory": "/Users/legacy/Downloads",
            "listenPort": "not-a-number",
            "dhtEnabled": true,
            "proxy": [
                "kind": "http",
                "host": "tolerant.proxy",
                "port": 8080,
                "username": "tolerant-user",
                "password": "TolerantLeak_PW2",
            ],
        ]
        let tolerantData = try JSONSerialization.data(withJSONObject: tolerantShape)
        try await store.setSessionValue(key: "engine_settings", data: tolerantData)
        try await store.setSessionValue(key: "engine_settings_revision", data: Data("13".utf8))
        let tolerantLoaded = try await store.loadSettings()
        XCTAssertEqual(tolerantLoaded?.revision, 13)
        XCTAssertEqual(tolerantLoaded?.settings.downloadDirectory, "/Users/legacy/Downloads")
        XCTAssertEqual(tolerantLoaded?.settings.proxy.kind, .http)
        XCTAssertEqual(tolerantLoaded?.settings.proxy.host, "tolerant.proxy")
        XCTAssertEqual(tolerantLoaded?.settings.proxy.port, 8080)
        XCTAssertEqual(tolerantLoaded?.settings.proxy.password, "", "tolerant decode must not retain the credential")
        try await assertRowScrubbedAtRest(secret: "TolerantLeak_PW2", username: "tolerant-user")

        // Shape 3: settings row WITHOUT its revision companion. The load
        // keeps the historical nil restore result but must still scrub the
        // credential bytes at rest (SEC-1-LEGACY).
        try await store.setSessionValue(key: "engine_settings", data: try JSONEncoder().encode(legacyTyped))
        try await store.removeSessionValue(key: "engine_settings_revision")
        let missingRevision = try await store.loadSettings()
        XCTAssertNil(missingRevision, "missing-revision row keeps the historical nil restore result")
        try await assertRowScrubbedAtRest(secret: "LegacyLeak_PW1", username: "old-user")
    }

    /// SEC-5: the payload size gate runs before any typed decoding. An
    /// oversized-but-parseable request envelope is rejected with the
    /// correlated requestID; an oversized undecodable blob is rejected with no
    /// correlation. Neither pays a full envelope/command decode.
    func testProcessCommandEnforcesSizeLimitBeforeDecoding() async throws {
        let store = PersistenceStore(dataDirectory: tempDir)
        _ = try await store.open()
        let coordinator = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: tempDir.path)
        )

        // Oversized yet structurally parseable envelope: correlate the ID.
        let requestID = RequestID()
        let envelopeData = try JSONEncoder().encode(IPCEnvelope.request(
            .fetchSettings(FetchSettingsRequest(requestID: requestID))
        ))
        var padded = String(decoding: envelopeData, as: UTF8.self)
        // Pad INSIDE the TOP-LEVEL object (before its closing brace; the
        // encoded envelope always ends with the root "}"). JSONDecoder ignores
        // unknown keys, so this stays a valid envelope while exceeding the
        // size gate.
        padded.insert(contentsOf: ",\"padding\":\"\(String(repeating: "A", count: IPCPayloadLimit.maxBytes))\"", at: padded.index(before: padded.endIndex))
        let paddedData = Data(padded.utf8)
        XCTAssertGreaterThan(paddedData.count, IPCPayloadLimit.maxBytes)

        let correlatedReply = await coordinator.processCommand(paddedData)
        let correlatedEnvelope = try JSONDecoder().decode(IPCEnvelope.self, from: correlatedReply)
        guard case .failure(let oversizedFault) = correlatedEnvelope.result else {
            return XCTFail("expected oversized failure result")
        }
        XCTAssertEqual(oversizedFault.code, .oversizedPayload)
        XCTAssertEqual(correlatedEnvelope.requestID, requestID, "oversized reply must keep requestID correlation when parseable")

        // Oversized garbage: rejected with the typed fault and no meaningful
        // correlation. Baseline wire behavior stands — result envelopes always
        // carry some requestID (a fresh one when none can be recovered) and no
        // command is decoded or dispatched.
        let garbage = Data(repeating: 0x7B, count: IPCPayloadLimit.maxBytes + 1)
        let garbageReply = await coordinator.processCommand(garbage)
        let garbageEnvelope = try JSONDecoder().decode(IPCEnvelope.self, from: garbageReply)
        guard case .failure(let garbageFault) = garbageEnvelope.result else {
            return XCTFail("expected oversized failure for garbage payload")
        }
        XCTAssertEqual(garbageFault.code, .oversizedPayload)
        XCTAssertNotEqual(garbageEnvelope.requestID?.rawValue, requestID.rawValue)
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
        // The delivered wire credential (SEC-1) is a second hostile vector:
        // the export projection must exclude it exactly like the in-candidate
        // one.
        let deliveredPassword = "DELIVERED_PW_LEAK_9f2"
        let applied = await coordinator.processCommandForTest(.applySettings(ApplySettingsRequest(
            requestID: RequestID(), idempotencyKey: IdempotencyKey(), candidate: hostileSettings,
            proxyPassword: deliveredPassword
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
            for leak in ["QUOTE_LEAK", "BS_LEAK", "NL_LEAK", "LEAK_PW", "NL_PWLEAK", "DELIVERED_PW_LEAK_9f2"] {
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
