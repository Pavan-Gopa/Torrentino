// Layer: Unit tests (Torrentino app shell).
// Role: smoke checks for domain/IPC linkage, empty-state contract, TestProfile.
// Must-not: launch network peers or write production Application Support.

import XCTest
import TorrentinoDomain
import TorrentinoIPC

final class TorrentinoAppTests: TestProfileCase {
    func testDomainAndIPCAreLinked() {
        let state = TorrentState.stopped
        XCTAssertEqual(state.rawValue, "stopped")

        let command = EngineCommand.hello
        XCTAssertEqual(command.rawValue, "hello")

        let error = EngineError.xpcUnavailable
        XCTAssertEqual(error, .xpcUnavailable)

        let version = IPCVersion.current
        XCTAssertEqual(version.major, 1)
        XCTAssertEqual(version.minor, 0)

        let event = EngineEvent.stateChanged
        XCTAssertEqual(event.rawValue, "stateChanged")
    }

    func testEmptyStateLocalizationKeysExistInCatalog() throws {
        // App empty state uses String Catalog keys (see ContentView).
        // Catalog is validated as source-tree JSON (bundle may not embed .xcstrings).
        let catalogURL = try XCTUnwrap(
            Self.locateLocalizableCatalog(),
            "Localizable.xcstrings must be findable from test host (SRCROOT/PROJECT_DIR/#filePath)"
        )
        let data = try Data(contentsOf: catalogURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try XCTUnwrap(json?["strings"] as? [String: Any])
        for key in ["empty.no_torrents", "empty.subtitle"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing catalog key \(key)")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertNotNil(locs["en"], "\(key) missing en")
            XCTAssertNotNil(locs["ru"], "\(key) missing ru")
        }
    }

    func testTestProfileDoesNotUseProductionPaths() throws {
        let root = profile.rootURL.path
        XCTAssertFalse(root.contains("Application Support/com.torrentino.app"))
        let markerFile = try profile.subdirectory("markers")
            .appendingPathComponent("wp03.txt")
        try "ok".write(to: markerFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path))
    }

    // MARK: - PeerValidation (plan §23, WP-05)

    func testPeerValidationNonexistentPathRejected() {
        let missing = profile.rootURL.appendingPathComponent("no-such-agent-binary")
        guard case .failure(let error) = PeerValidation.validateAgentBinary(at: missing) else {
            return XCTFail("expected failure for nonexistent binary")
        }
        guard case .agentBinaryNotFound(let path) = error else {
            return XCTFail("expected agentBinaryNotFound, got \(error)")
        }
        XCTAssertEqual(path, missing.path)
    }

    func testPeerValidationUnsignedDummyFileRejected() throws {
        let dir = try profile.subdirectory("peer-validation")
        let dummy = dir.appendingPathComponent("dummy-agent-binary")
        try Data("not-a-mach-o-not-signed".utf8).write(to: dummy)
        let result = PeerValidation.validateAgentBinary(at: dummy)
        switch result {
        case .failure(let error):
            // An unsigned/dummy file must be rejected; the exact case depends
            // on the OS code-signing result for non-signed data files.
            guard case .unsignedPeer = error else {
                guard case .codeSigningUnavailable = error else {
                    return XCTFail("expected unsignedPeer or codeSigningUnavailable, got \(error)")
                }
                return
            }
        case .success:
            XCTFail("unsigned dummy binary must be rejected")
        }
    }

    func testPeerValidationWrongTeamIdentifierRejected() throws {
        // A real Mach-O re-signed ad-hoc (no Developer ID cert, no team OU)
        // must pass basic validity but FAIL the frozen requirement match and
        // be reported as .wrongTeamIdentifier.
        let dir = try profile.subdirectory("peer-validation")
        let wrongTeamBinary = dir.appendingPathComponent("ad-hoc-signed-agent")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: wrongTeamBinary)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "-s", "-", wrongTeamBinary.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "codesign ad-hoc must succeed")

        let result = PeerValidation.validateAgentBinary(at: wrongTeamBinary)
        guard case .failure(let error) = result else {
            return XCTFail("ad-hoc signed binary must be rejected")
        }
        guard case .wrongTeamIdentifier = error else {
            return XCTFail("expected wrongTeamIdentifier, got \(error)")
        }
    }

    func testPeerValidationRequirementExpressionFrozen() {
        let requirement = PeerValidation.expectedAgentRequirement
        XCTAssertTrue(
            requirement.contains(#"identifier "com.torrentino.app.engine-agent""#),
            "frozen requirement must pin the exact agent signing identifier"
        )
        XCTAssertTrue(
            requirement.contains(#"certificate leaf[subject.OU] = "438UQRF7JV""#),
            "frozen requirement must pin the Developer ID team (subject.OU)"
        )
        // The frozen expression must still compile: this is the exact guard
        // that would return .requirementInvalid on regression.
        XCTAssertNotNil(PeerValidation.makeRequirement(requirement))
    }

    func testPeerValidationInvalidRequirementExpressionRejected() {
        // Garbage expressions fail to compile; validateAgentBinary maps this
        // to .requirementInvalid (see makeRequirement guard).
        XCTAssertNil(PeerValidation.makeRequirement("identifier garbage((("))
        XCTAssertNil(PeerValidation.makeRequirement(""))
        XCTAssertNil(PeerValidation.makeRequirement("anchor apple garbage &&("))
    }

    func testPeerValidationEnforcementGate() {
        // Developer-ID (Release) builds enforce the checks; Debug builds are
        // unsigned by design and skip them (WP-02 QA runs against Debug).
#if DEBUG
        XCTAssertFalse(PeerValidation.isEnforcementActive)
#else
        XCTAssertTrue(PeerValidation.isEnforcementActive)
#endif
    }

    /// Resolve Localizable.xcstrings from the source tree.
    private static func locateLocalizableCatalog() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        for envKey in ["SRCROOT", "PROJECT_DIR", "SOURCE_ROOT"] {
            if let root = ProcessInfo.processInfo.environment[envKey], !root.isEmpty {
                candidates.append(
                    URL(fileURLWithPath: root)
                        .appendingPathComponent("TorrentinoApp/Resources/Localizable.xcstrings")
                )
                candidates.append(
                    URL(fileURLWithPath: root)
                        .appendingPathComponent("Native/TorrentinoApp/Resources/Localizable.xcstrings")
                )
            }
        }

        // Walk up from this source file: .../Native/Tests/TorrentinoAppTests/ → Native/
        let thisFile = URL(fileURLWithPath: #filePath)
        var dir = thisFile.deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(
                dir.appendingPathComponent("TorrentinoApp/Resources/Localizable.xcstrings")
            )
            candidates.append(
                dir.appendingPathComponent("Native/TorrentinoApp/Resources/Localizable.xcstrings")
            )
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("TorrentinoApp/Resources/Localizable.xcstrings"))
        candidates.append(cwd.appendingPathComponent("Native/TorrentinoApp/Resources/Localizable.xcstrings"))

        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - WP-08 Smoke Tests

    func testKeychainStoreOperations() {
        let password = "test_proxy_password_123"
        XCTAssertTrue(KeychainStore.saveProxyPassword(password))
        XCTAssertEqual(KeychainStore.loadProxyPassword(), password)
        XCTAssertTrue(KeychainStore.deleteProxyPassword())
        XCTAssertNil(KeychainStore.loadProxyPassword())
    }

    func testSettingsTransactionValidation() {
        let invalidCandidate = EngineSettings(
            downloadDirectory: "~/Downloads",
            maxDownloadBytesPerSec: -100,
            maxUploadBytesPerSec: 0,
            listenPort: 6881,
            dhtEnabled: true,
            lsdEnabled: true,
            upnpEnabled: true,
            natPmpEnabled: true,
            encryptionEnabled: true
        )
        let errors = SettingsRules.validate(invalidCandidate)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.field, "maxDownloadBytesPerSec")
    }
}
