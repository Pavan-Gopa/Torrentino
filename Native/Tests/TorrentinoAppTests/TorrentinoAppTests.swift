// Layer: Unit tests (Torrentino app shell).
// Role: smoke checks for domain/IPC linkage, empty-state contract, TestProfile.
// Must-not: launch network peers or write production Application Support.

import XCTest
import UniformTypeIdentifiers
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

    func testKeychainSave() async {
        _ = await KeychainStore.deleteProxyPassword()
        let saved = await KeychainStore.saveProxyPassword("test_proxy_password_123")
        XCTAssertTrue(saved)
        _ = await KeychainStore.deleteProxyPassword()
    }

    func testKeychainLoad() async {
        _ = await KeychainStore.deleteProxyPassword()
        let password = "test_proxy_password_123"
        let saved = await KeychainStore.saveProxyPassword(password)
        let loaded = await KeychainStore.loadProxyPassword()
        XCTAssertTrue(saved)
        XCTAssertEqual(loaded, password)
        _ = await KeychainStore.deleteProxyPassword()
    }

    func testKeychainDelete() async {
        _ = await KeychainStore.deleteProxyPassword()
        let password = "test_proxy_password_123"
        let saved = await KeychainStore.saveProxyPassword(password)
        let deleted = await KeychainStore.deleteProxyPassword()
        let loaded = await KeychainStore.loadProxyPassword()
        XCTAssertTrue(saved)
        XCTAssertTrue(deleted)
        XCTAssertNil(loaded)
    }

    func testKeychainLoadMissingReturnsNil() async {
        _ = await KeychainStore.deleteProxyPassword()
        let loaded = await KeychainStore.loadProxyPassword()
        XCTAssertNil(loaded)
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

        let invalidPort = EngineSettings(
            downloadDirectory: "~/Downloads",
            maxDownloadBytesPerSec: 0,
            maxUploadBytesPerSec: 0,
            listenPort: 0,
            dhtEnabled: true,
            lsdEnabled: true,
            upnpEnabled: true,
            natPmpEnabled: true,
            encryptionEnabled: true
        )
        XCTAssertEqual(SettingsRules.validate(invalidPort).first?.field, "listenPort")
    }

    func testNotificationCompletion() {
        var tracker = NotificationTransitionTracker()
        let id = TorrentRecordID(rawValue: UUID())
        _ = tracker.processSnapshots([notificationSnapshot(id: id, fraction: 0.5, activity: .downloading)])
        let transitions = tracker.processSnapshots([notificationSnapshot(id: id, fraction: 1, activity: .seeding)])
        XCTAssertTrue(transitions.contains { transition in
            if case .torrentCompleted(let recordID, _) = transition { return recordID == id }
            return false
        })
    }

    func testNotificationAllComplete() {
        var tracker = NotificationTransitionTracker()
        let id = TorrentRecordID(rawValue: UUID())
        _ = tracker.processSnapshots([notificationSnapshot(id: id, fraction: 0.5, activity: .downloading)])
        let finished = tracker.processSnapshots([notificationSnapshot(id: id, fraction: 1, activity: .seeding)])
        XCTAssertTrue(finished.contains(.allComplete))
        XCTAssertFalse(tracker.processSnapshots([notificationSnapshot(id: id, fraction: 1, activity: .seeding)]).contains(.allComplete))
    }

    func testNotificationError() {
        var tracker = NotificationTransitionTracker()
        let id = TorrentRecordID(rawValue: UUID())
        _ = tracker.processSnapshots([notificationSnapshot(id: id, fraction: 0.5, activity: .downloading)])
        let transitions = tracker.processSnapshots([
            notificationSnapshot(id: id, fraction: 0.5, activity: .downloading, health: .recoverableError(.internalError))
        ])
        XCTAssertTrue(transitions.contains { transition in
            if case .error(let recordID, _) = transition { return recordID == id }
            return false
        })
    }

    func testTorrentListProjectionSearchFilterAndSort() {
        let rows = FixtureLibrary.snapshot(count: 100)
        let projected = TorrentListProjection.project(
            Array(rows.reversed()),
            query: "dEmO aRcHiVe 042",
            filter: .all,
            sortOrder: [KeyPathComparator(\TorrentSnapshot.displayName)]
        )
        XCTAssertEqual(projected.map(\.displayName), ["Demo Archive 042 - Backup"])

        let seeding = TorrentListProjection.project(rows, filter: .seeding)
        XCTAssertFalse(seeding.isEmpty)
        XCTAssertTrue(seeding.allSatisfy { $0.activity == .seeding })

        let paused = TorrentListProjection.project(rows, filter: .paused)
        XCTAssertFalse(paused.isEmpty)
        XCTAssertTrue(paused.allSatisfy { $0.desiredState == .paused })
    }

    func testFixtureLibrary100And500Performance() {
        XCTAssertEqual(FixtureLibrary.snapshot(count: 100).count, 100)
        XCTAssertEqual(FixtureLibrary.snapshot(count: 500).count, 500)
        measure {
            _ = FixtureLibrary.snapshot(count: 100)
            _ = FixtureLibrary.snapshot(count: 500)
        }
    }

    func testTorrentListProjection100And500Performance() {
        let rows100 = FixtureLibrary.snapshot(count: 100)
        let rows500 = FixtureLibrary.snapshot(count: 500)
        let sortOrder = [KeyPathComparator(\TorrentSnapshot.displayName)]
        let projected100 = TorrentListProjection.project(rows100, filter: .all, sortOrder: sortOrder)
        let projected500 = TorrentListProjection.project(rows500, query: "Archive", filter: .all, sortOrder: sortOrder)
        XCTAssertEqual(projected100.count, 100)
        XCTAssertEqual(projected500.count, 500)
        XCTAssertEqual(projected500, projected500.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        measure {
            _ = TorrentListProjection.project(rows100, query: "Archive", filter: .all, sortOrder: sortOrder)
            _ = TorrentListProjection.project(rows500, query: "Archive", filter: .all, sortOrder: sortOrder)
        }
    }

    // MARK: - WP13-LIVE-DND-UI-001 / WP13-LIVE-PANE-UX-001

    /// Dropped `.torrent` URLs pass the same gate used by Finder
    /// open-document (extension / exported `com.bittorrent.torrent` UTI).
    func testTorrentDropURLGate() {
        XCTAssertTrue(TorrentDropRouting.isTorrentDropURL(URL(fileURLWithPath: "/tmp/a.torrent")))
        XCTAssertTrue(TorrentDropRouting.isTorrentDropURL(URL(fileURLWithPath: "/tmp/A.TORRENT")))
        XCTAssertFalse(TorrentDropRouting.isTorrentDropURL(URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertFalse(TorrentDropRouting.isTorrentDropURL(URL(fileURLWithPath: "/tmp/a.turn")))
        XCTAssertFalse(TorrentDropRouting.isTorrentDropURL(URL(string: "magnet:?xt=urn:btih:abc")!))
    }

    /// The Info.plist-declared document type must resolve by extension and UTI
    /// so Finder open / window drop both recognize the torrent file type.
    func testTorrentUTTypeMatchesExportedDeclaration() throws {
        let byExtension = try XCTUnwrap(UTType(filenameExtension: "torrent"))
        XCTAssertEqual(byExtension.identifier, "com.bittorrent.torrent")

        let plistURL = Self.locateInfoPlist()
        let plistData = try Data(contentsOf: try XCTUnwrap(plistURL))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let docTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let docType = try XCTUnwrap(docTypes.first)
        XCTAssertTrue((docType["CFBundleTypeExtensions"] as? [String])?.contains("torrent") == true)
        XCTAssertTrue((docType["LSItemContentTypes"] as? [String])?.contains("com.bittorrent.torrent") == true)
    }

    /// Files-pane sizing: tiny file lists size to content, large lists cap.
    func testFilesPaneIdealHeightSizing() {
        let one = FilesPaneSizing.idealHeight(fileCount: 1)
        let two = FilesPaneSizing.idealHeight(fileCount: 2)
        let many = FilesPaneSizing.idealHeight(fileCount: 200)
        XCTAssertGreaterThan(one, FilesPaneSizing.baseHeight)
        XCTAssertEqual(two - one, FilesPaneSizing.rowHeight, accuracy: 0.5)
        XCTAssertEqual(many, FilesPaneSizing.maxHeight)
        XCTAssertLessThanOrEqual(FilesPaneSizing.idealHeight(fileCount: 50), FilesPaneSizing.maxHeight)
        XCTAssertGreaterThanOrEqual(one, FilesPaneSizing.minimumHeight)
    }

    func testFilesPaneVisibilityRequiresVisibleSelectionAndContent() {
        XCTAssertFalse(
            FilesPaneSizing.hasContext(
                selectedTorrentIsVisible: false,
                fileCount: 3,
                filesLoading: false
            )
        )
        XCTAssertFalse(
            FilesPaneSizing.hasContext(
                selectedTorrentIsVisible: true,
                fileCount: 0,
                filesLoading: false
            )
        )
        XCTAssertTrue(
            FilesPaneSizing.hasContext(
                selectedTorrentIsVisible: true,
                fileCount: 0,
                filesLoading: true
            )
        )
        XCTAssertTrue(
            FilesPaneSizing.hasContext(
                selectedTorrentIsVisible: true,
                fileCount: 3,
                filesLoading: false
            )
        )
    }

    func testFilesPaneCollapseHidesContextWithoutDiscardingIt() {
        XCTAssertTrue(
            FilesPaneSizing.isVisible(
                selectedTorrentIsVisible: true,
                fileCount: 3,
                filesLoading: false,
                collapsed: false
            )
        )
        XCTAssertFalse(
            FilesPaneSizing.isVisible(
                selectedTorrentIsVisible: true,
                fileCount: 3,
                filesLoading: false,
                collapsed: true
            )
        )
    }

    private static func locateInfoPlist() -> URL? {
        let fm = FileManager.default
        let thisFile = URL(fileURLWithPath: #filePath)
        var dir = thisFile.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("TorrentinoApp/Info.plist")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private func notificationSnapshot(
        id: TorrentRecordID,
        fraction: Double,
        activity: TorrentActivity,
        health: TorrentHealth = .healthy
    ) -> TorrentSnapshot {
        TorrentSnapshot(
            id: id,
            contentIdentity: nil,
            displayName: "Fixture",
            desiredState: .running,
            activity: activity,
            health: health,
            progress: TransferProgress(fraction: fraction, totalBytes: 100, downloadedBytes: Int64(fraction * 100), uploadedBytes: 0),
            rates: TransferRates(downloadBytesPerSec: 0, uploadBytesPerSec: 0),
            peers: PeerSummary(connected: 0, halfOpen: 0, total: 0),
            saveLocation: PersistedLocation(path: "/tmp"),
            revision: 0
        )
    }
}
