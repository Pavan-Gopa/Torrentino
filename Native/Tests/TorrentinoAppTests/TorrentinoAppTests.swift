// Layer: Unit tests (Torrentino app shell).
// Role: smoke checks for domain/IPC linkage, empty-state contract, TestProfile.
// Must-not: launch network peers or write production Application Support.

import XCTest
import AppKit
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
        for key in [
            "empty.no_torrents",
            "empty.subtitle",
            "torrents.col.eta",
            "torrents.row.downloaded_of_total",
            "torrents.row.eta_unavailable",
            "creator.public_trackers_toggle",
            "creator.public_trackers_disclosure",
            "creator.effective_trackers",
            "creator.tracker_origin_manual",
            "creator.tracker_origin_recommended",
            "creator.no_effective_trackers",
            "creator.public_trackers_private_disabled",
            "creator.public_trackers_capacity_exceeded",
            "creator.public_trackers_invalid_catalog",
        ] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing catalog key \(key)")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in ["en", "ru"] {
                let localization = try XCTUnwrap(
                    locs[language] as? [String: Any],
                    "\(key) missing \(language)"
                )
                let stringUnit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(stringUnit["value"] as? String)
                XCTAssertFalse(value.isEmpty, "\(key) has empty \(language) value")
            }
        }
    }

    func testCreatorTrackerCatalogIsStaticNonEmptyAndBounded() throws {
        try CreatorTrackerSharingPolicy.validateRecommendedCatalog()

        let catalog = CreatorTrackerSharingPolicy.recommendedPublicTrackerTiers
        XCTAssertEqual(
            catalog,
            [
                ["udp://tracker.opentrackr.org:1337/announce"],
                ["udp://open.stealth.si:80/announce"],
                ["udp://tracker.torrent.eu.org:451"],
            ],
            "ADR-021 catalog must remain the three release-reviewed tiers in order"
        )
        XCTAssertFalse(catalog.isEmpty)
        XCTAssertTrue(catalog.allSatisfy { !$0.isEmpty })

        let urls = catalog.flatMap { $0 }
        XCTAssertFalse(urls.isEmpty)
        XCTAssertLessThanOrEqual(urls.count, TransferLimits.maxTrackers)
        for url in urls {
            XCTAssertTrue(TrackerURLValidator.isSupported(url), "unsupported catalog URL: \(url)")
            let components = try XCTUnwrap(URLComponents(string: url))
            XCTAssertNil(components.user, "catalog URL must not contain credentials")
            XCTAssertNil(components.password, "catalog URL must not contain credentials")
            XCTAssertNil(components.query, "catalog URL must not contain a passkey or query")
            XCTAssertFalse(url.contains("@"), "catalog URL must not contain embedded credentials")
            if let host = components.host?.lowercased() {
                XCTAssertFalse(host == "localhost" || host.hasSuffix(".local"))
                XCTAssertFalse(host == "127.0.0.1" || host == "0.0.0.0" || host == "::1")
            } else {
                XCTFail("catalog URL must contain a host: \(url)")
            }
        }
    }

    func testCreatorTrackerPolicyMatrixPreservesExactManualTopology() throws {
        let manual = [
            [
                "udp://manual-a.example:80/announce",
                "udp://manual-a.example:80/announce",
            ],
            ["https://manual-b.example/announce"],
        ]
        let recommended = CreatorTrackerSharingPolicy.recommendedPublicTrackerTiers

        let freshPublicDefault = try CreatorTrackerSharingPolicy.effectiveTopology(
            manualTiers: [],
            isPrivate: false,
            includeRecommendedPublicTrackers: true
        )
        XCTAssertEqual(freshPublicDefault.trackerTiers, recommended)
        XCTAssertTrue(freshPublicDefault.origins.allSatisfy { $0 == .recommendedPublic })

        let publicDefault = try CreatorTrackerSharingPolicy.effectiveTopology(
            manualTiers: manual,
            isPrivate: false,
            includeRecommendedPublicTrackers: true
        )
        XCTAssertEqual(publicDefault.trackerTiers, manual + recommended)
        XCTAssertEqual(
            publicDefault.origins,
            Array(repeating: .manual, count: manual.count)
                + Array(repeating: .recommendedPublic, count: recommended.count)
        )

        let publicOptOut = try CreatorTrackerSharingPolicy.effectiveTopology(
            manualTiers: manual,
            isPrivate: false,
            includeRecommendedPublicTrackers: false
        )
        XCTAssertEqual(publicOptOut.trackerTiers, manual)
        XCTAssertEqual(publicOptOut.origins, [.manual, .manual])

        let privateWithPreference = try CreatorTrackerSharingPolicy.effectiveTopology(
            manualTiers: manual,
            isPrivate: true,
            includeRecommendedPublicTrackers: true
        )
        let privateWithoutPreference = try CreatorTrackerSharingPolicy.effectiveTopology(
            manualTiers: manual,
            isPrivate: true,
            includeRecommendedPublicTrackers: false
        )
        XCTAssertEqual(privateWithPreference.trackerTiers, manual)
        XCTAssertEqual(privateWithoutPreference.trackerTiers, manual)
        XCTAssertEqual(privateWithPreference, privateWithoutPreference)

        let privateEmpty = try CreatorTrackerSharingPolicy.effectiveTopology(
            manualTiers: [],
            isPrivate: true,
            includeRecommendedPublicTrackers: true
        )
        XCTAssertEqual(privateEmpty.trackerTiers, [])
        XCTAssertTrue(privateEmpty.origins.isEmpty)
    }

    func testCreatorTrackerPolicyFailsExplicitlyAtCapacity() throws {
        let max = TransferLimits.maxTrackers
        let manualAtLimit = [[String]](repeating: ["udp://manual.example:80/announce"], count: max)

        let manualOnly = try CreatorTrackerSharingPolicy.effectiveTopology(
            manualTiers: manualAtLimit,
            isPrivate: false,
            includeRecommendedPublicTrackers: false
        )
        XCTAssertEqual(manualOnly.trackerTiers, manualAtLimit)

        XCTAssertThrowsError(
            try CreatorTrackerSharingPolicy.effectiveTopology(
                manualTiers: manualAtLimit,
                isPrivate: false,
                includeRecommendedPublicTrackers: true
            )
        ) { error in
            guard case let CreatorTrackerSharingPolicy.CompositionError.capacityExceeded(actual, maximum) = error else {
                return XCTFail("expected explicit capacity failure, got \(error)")
            }
            XCTAssertEqual(actual, max + CreatorTrackerSharingPolicy.recommendedPublicTrackerTiers.flatMap { $0 }.count)
            XCTAssertEqual(maximum, max)
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

    // MARK: - SEC-1 Credential Delivery (WP13-SEC-HARDEN-001)

    /// The single delivery rule every UI apply path must use: a
    /// non-anonymous proxy kind with a held password ships it on
    /// ApplySettingsRequest.proxyPassword; anything else delivers nil.
    func testProxyPasswordDeliveryRule() {
        XCTAssertEqual(
            ApplySettingsRequest.proxyPasswordForDelivery(kind: .socks5, entered: "kc_secret_1"),
            "kc_secret_1"
        )
        XCTAssertEqual(
            ApplySettingsRequest.proxyPasswordForDelivery(kind: .http, entered: "kc_secret_2"),
            "kc_secret_2"
        )
        XCTAssertNil(
            ApplySettingsRequest.proxyPasswordForDelivery(kind: .none, entered: "kc_secret_3"),
            "an anonymously authenticating proxy kind must not ship a credential"
        )
        XCTAssertNil(
            ApplySettingsRequest.proxyPasswordForDelivery(kind: .socks5, entered: ""),
            "no held credential means nothing is delivered"
        )
        XCTAssertNil(ApplySettingsRequest.proxyPasswordForDelivery(kind: .none, entered: ""))
    }

    /// Spying send closure recorder: captures every command the seam sends.
    private actor RequestSpy {
        private(set) var commands: [EngineCommandV1] = []
        func record(_ command: EngineCommandV1) { commands.append(command) }
    }

    private static func makeFormInput(
        kind: ProxyConfiguration.Kind,
        password: String
    ) -> SettingsApplyFlow.FormInput {
        SettingsApplyFlow.FormInput(
            downloadDir: "~/Downloads",
            maxDownKB: "0",
            maxUpKB: "0",
            listenPort: "6881",
            dhtEnabled: true,
            lsdEnabled: true,
            upnpEnabled: true,
            natPmpEnabled: true,
            encryptionEnabled: true,
            proxyKind: kind,
            proxyHost: "proxy.local",
            proxyPort: "1080",
            proxyUsername: "app-user",
            proxyPassword: password
        )
    }

    /// TEST-HONESTY-UI-CHAIN (WP13-SEC-HARDEN-001 REVIEW-002): this drives
    /// the SAME application-level functions the REAL SettingsView.applySettings
    /// delegates to — no mirrored request building. A REAL KeychainStore seeds
    /// the form state and a spying send closure captures the actual outgoing
    /// ApplySettingsRequest. Mutation honesty: removing the Keychain
    /// attachment anywhere on that path (e.g. passing nil instead of
    /// proxyPasswordForDelivery(kind:entered:)) makes `outgoing.proxyPassword`
    /// nil while the Keychain holds a credential — every captured-request
    /// assertion below fails. Two-leg composition: this leg proves the UI→IPC
    /// chain; the captured request SHAPE (optional delivery field present,
    /// candidate.proxy password-free) is what the live bridge harness leg
    /// (`scripts/test_bridge_swift.sh` through libtorrent 2.1.1) exercises
    /// across the engine boundary.
    func testApplyFlowDeliversKeychainPasswordThroughCapturedRequest() async throws {
        _ = await KeychainStore.deleteProxyPassword()
        let keychainPassword = "keychain_delivered_pw_41"
        let saved = await KeychainStore.saveProxyPassword(keychainPassword)
        XCTAssertTrue(saved)
        defer { Task { _ = await KeychainStore.deleteProxyPassword() } }

        // loadCurrentSettings() seeds the form state from the REAL Keychain…
        let loadedFormPassword = await KeychainStore.loadProxyPassword()
        let formPassword = try XCTUnwrap(loadedFormPassword)
        XCTAssertEqual(formPassword, keychainPassword)

        // …and applySettings moves that value through the shared seam only.
        let request = try XCTUnwrap(
            SettingsApplyFlow.makeRequest(
                from: Self.makeFormInput(kind: .socks5, password: formPassword),
                expectedRevision: 8
            ).get()
        )
        XCTAssertNil(request.candidate.proxy.password,
                     "the durable candidate must stay credential-free")

        let spy = RequestSpy()
        let outcome = await SettingsApplyFlow.apply(request) { command in
            await spy.record(command)
            return .settingsApply(SettingsApplyResult(revision: 9))
        }
        guard case .applied(let revision, let credentialsSaved) = outcome else {
            return XCTFail("seam apply failed: \(outcome)")
        }
        XCTAssertEqual(revision, 9)
        XCTAssertTrue(credentialsSaved, "post-acceptance Keychain commit must succeed")

        let captured = await spy.commands
        XCTAssertEqual(captured.count, 1)
        guard case .applySettings(let outgoing) = captured[0] else {
            return XCTFail("unexpected captured command: \(captured[0])")
        }
        // THE chain proof: the actual outgoing request carries the Keychain
        // credential via the single delivery rule.
        XCTAssertEqual(outgoing.proxyPassword, keychainPassword)
        XCTAssertEqual(
            outgoing.proxyPassword,
            ApplySettingsRequest.proxyPasswordForDelivery(kind: .socks5, entered: formPassword)
        )
        XCTAssertNil(outgoing.candidate.proxy.password)
        let encoded = try JSONEncoder().encode(outgoing)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["proxyPassword"] as? String, keychainPassword)
        let candidateObject = try XCTUnwrap(object["candidate"] as? [String: Any])
        let proxyObject = try XCTUnwrap(candidateObject["proxy"] as? [String: Any])
        XCTAssertFalse(proxyObject.keys.contains("password"),
                       "the wire candidate must carry no credential representation")

        // The real Keychain still holds the committed credential afterwards.
        let committedPassword = await KeychainStore.loadProxyPassword()
        XCTAssertEqual(committedPassword, keychainPassword)
    }

    /// Failure path of the same seam: a rejected apply must preserve the
    /// prior Keychain state exactly — no commit, no delete.
    func testApplyFlowFailurePreservesPriorKeychainState() async throws {
        _ = await KeychainStore.deleteProxyPassword()
        let priorPassword = "prior_state_pw_77"
        let saved = await KeychainStore.saveProxyPassword(priorPassword)
        XCTAssertTrue(saved)
        defer { Task { _ = await KeychainStore.deleteProxyPassword() } }

        let loadedFormPassword = await KeychainStore.loadProxyPassword()
        let formPassword = try XCTUnwrap(loadedFormPassword)
        let request = try XCTUnwrap(
            SettingsApplyFlow.makeRequest(
                from: Self.makeFormInput(kind: .http, password: formPassword),
                expectedRevision: 3
            ).get()
        )

        struct SendRejected: Error {}
        let spy = RequestSpy()
        let outcome = await SettingsApplyFlow.apply(request) { command in
            await spy.record(command)
            throw SendRejected()
        }
        guard case .failed = outcome else {
            return XCTFail("expected failure outcome, got \(outcome)")
        }
        let captured = await spy.commands
        XCTAssertEqual(captured.count, 1, "the rejected attempt must be the only traffic")
        let preservedPassword = await KeychainStore.loadProxyPassword()
        XCTAssertEqual(preservedPassword, priorPassword,
                       "a failed apply must not touch the prior Keychain state")
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

    func testTorrentListRowProjectionFormatsDownloadedAmountWithByteCountFormatter() {
        let row = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(
                totalBytes: 500_000_000,
                downloadedBytes: 150_000_000,
                downloadBytesPerSec: 1_000_000
            )
        )
        let downloaded = ByteCountFormatter.string(fromByteCount: 150_000_000, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: 500_000_000, countStyle: .file)

        XCTAssertTrue(row.downloadedAmountText.contains(downloaded))
        XCTAssertTrue(row.downloadedAmountText.contains(total))
        XCTAssertEqual(row.downloadedBytes, 150_000_000)
        XCTAssertEqual(row.effectiveTotalBytes, 500_000_000)
    }

    func testTorrentListRowProjectionComputesActiveDownloadETA() {
        let row = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot()
        )

        XCTAssertEqual(row.etaSeconds, 4)
        XCTAssertNotEqual(
            row.etaText,
            String(localized: "torrents.row.eta_unavailable", defaultValue: "—")
        )
    }

    func testTorrentListRowProjectionHidesETAWhenStalledPausedOrComplete() {
        let unavailable = String(localized: "torrents.row.eta_unavailable", defaultValue: "—")
        let stalled = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(downloadBytesPerSec: 0)
        )
        let paused = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(desiredState: .paused)
        )
        let idle = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(activity: .idle)
        )
        let complete = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(downloadedBytes: 500)
        )

        for row in [stalled, paused, idle, complete] {
            XCTAssertNil(row.etaSeconds)
            XCTAssertEqual(row.etaText, unavailable)
        }
    }

    func testTorrentListRowProjectionClampsDownloadedBytesForETA() {
        let row = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(downloadedBytes: 600)
        )

        XCTAssertEqual(row.downloadedBytes, 500)
        XCTAssertNil(row.etaSeconds)
        XCTAssertEqual(
            row.etaText,
            String(localized: "torrents.row.eta_unavailable", defaultValue: "—")
        )
    }

    func testTorrentListRowProjectionRejectsUnreasonableETADurations() {
        let maximum = TorrentListRowProjection.maximumDisplayHorizonSeconds
        let unavailable = String(localized: "torrents.row.eta_unavailable", defaultValue: "—")
        let boundary = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(
                totalBytes: maximum,
                downloadedBytes: 0,
                downloadBytesPerSec: 1
            )
        )
        let beyondBoundary = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(
                totalBytes: maximum + 1,
                downloadedBytes: 0,
                downloadBytesPerSec: 1
            )
        )
        let unreasonable = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(
                totalBytes: Int64.max,
                downloadedBytes: 0,
                downloadBytesPerSec: 1
            )
        )

        XCTAssertEqual(boundary.etaSeconds, maximum)
        XCTAssertNotEqual(
            boundary.etaText,
            unavailable
        )
        XCTAssertNil(beyondBoundary.etaSeconds)
        XCTAssertEqual(beyondBoundary.etaText, unavailable)
        XCTAssertNil(unreasonable.etaSeconds)
        XCTAssertEqual(unreasonable.etaText, unavailable)
    }

    func testTorrentListRowProjectionGatesETAOnAuthoritativeHealthAndActivity() {
        let unavailable = String(localized: "torrents.row.eta_unavailable", defaultValue: "—")
        let waitingForSpace = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(health: .waitingForSpace)
        )
        let waitingForNetwork = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(health: .waitingForNetwork)
        )
        let zeroRate = TorrentListRowProjection(
            torrent: authoritativeTorrentSnapshot(downloadBytesPerSec: 0)
        )

        for row in [waitingForSpace, waitingForNetwork, zeroRate] {
            XCTAssertNil(row.etaSeconds)
            XCTAssertEqual(row.etaText, unavailable)
        }
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

    /// The live pane uses a constant first-run baseline and never derives its
    /// size from the selected torrent's file count.
    func testFilesPaneUsesFixedGlobalBaseline() {
        let firstLaunch = FilesPaneSizing.fixedHeight(
            persistedValue: 0,
            availableHeight: 800
        )
        XCTAssertEqual(firstLaunch, FilesPaneSizing.defaultHeight)
        XCTAssertEqual(
            FilesPaneSizing.fixedHeight(persistedValue: 310, availableHeight: 800),
            310
        )
        XCTAssertEqual(
            FilesPaneSizing.windowMaximumHeight(availableHeight: 800),
            800 - FilesPaneSizing.tableMinimumHeight
        )
        XCTAssertEqual(
            FilesPaneSizing.clampedHeight(10_000, availableHeight: 800),
            FilesPaneSizing.windowMaximumHeight(availableHeight: 800)
        )
        XCTAssertGreaterThanOrEqual(firstLaunch, FilesPaneSizing.minimumHeight)
    }

    func testFilesPaneRestoresGlobalBaselineWithinWindowBounds() {
        XCTAssertNil(FilesPaneSizing.restoredHeight(0, availableHeight: 800))
        XCTAssertNil(FilesPaneSizing.restoredHeight(.nan, availableHeight: 800))
        XCTAssertEqual(FilesPaneSizing.restoredHeight(180, availableHeight: 800), 180)
        XCTAssertEqual(
            FilesPaneSizing.restoredHeight(10_000, availableHeight: 800),
            FilesPaneSizing.windowMaximumHeight(availableHeight: 800)
        )
    }

    func testFilesPaneSelectionSwitchKeepsGlobalBaseline() {
        let selectedTorrentA = FilesPaneSizing.fixedHeight(
            persistedValue: 260,
            availableHeight: 800
        )
        let loadingTorrentB = FilesPaneSizing.fixedHeight(
            persistedValue: 260,
            availableHeight: 800
        )
        let selectedTorrentB = FilesPaneSizing.fixedHeight(
            persistedValue: 260,
            availableHeight: 800
        )

        XCTAssertEqual(selectedTorrentA, 260)
        XCTAssertEqual(loadingTorrentB, selectedTorrentA)
        XCTAssertEqual(selectedTorrentB, selectedTorrentA)
    }

    func testFilesPaneRemovalKeepsGlobalBaseline() {
        let beforeRemoval = FilesPaneSizing.fixedHeight(
            persistedValue: 500,
            availableHeight: 800
        )
        let afterSelectionEmpties = FilesPaneSizing.fixedHeight(
            persistedValue: 500,
            availableHeight: 800
        )

        XCTAssertEqual(afterSelectionEmpties, beforeRemoval)
        XCTAssertEqual(
            FilesPaneSizing.fixedHeight(persistedValue: 500, availableHeight: 800),
            beforeRemoval
        )
    }

    func testFilesPaneWindowResizeOnlyClampsLiveHeight() {
        let baseline = FilesPaneSizing.fixedHeight(
            persistedValue: 500,
            availableHeight: 800
        )
        let clampedForSmallWindow = FilesPaneSizing.fixedHeight(
            persistedValue: 500,
            availableHeight: 500
        )

        XCTAssertEqual(baseline, 500)
        XCTAssertEqual(
            clampedForSmallWindow,
            FilesPaneSizing.windowMaximumHeight(availableHeight: 500)
        )
        XCTAssertEqual(
            FilesPaneSizing.restoredHeight(Double(baseline), availableHeight: 800),
            baseline
        )
    }

    func testProductionAddInspectionOlderFailureAfterNewerSuccessIsIgnored() {
        var inspectionState = LatestInspectionState<AddTorrentPreview>()
        var presentation = AddTorrentInspectionPresentation()
        presentation.inspecting = true
        let olderGeneration = inspectionState.begin()
        let latestGeneration = inspectionState.begin()
        let latestPreview = addPreview(
            named: "latest",
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        XCTAssertTrue(
            AddTorrentInspectionResultApplication.apply(
                .success(latestPreview),
                for: latestGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )
        XCTAssertEqual(presentation.preview, latestPreview)
        XCTAssertNil(presentation.errorMessage)
        XCTAssertFalse(presentation.inspecting)
        XCTAssertTrue(presentation.canCommit)
        let acceptedPresentation = presentation

        XCTAssertFalse(
            AddTorrentInspectionResultApplication.apply(
                .failure(String(localized: "torrents.add.inspection_failed")),
                for: olderGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )
        XCTAssertEqual(presentation, acceptedPresentation)
        XCTAssertEqual(inspectionState.result, .success(latestPreview))
    }

    func testProductionAddInspectionStaleFailureLeavesCurrentConnectionNote() {
        var inspectionState = LatestInspectionState<AddTorrentPreview>()
        var presentation = AddTorrentInspectionPresentation()
        presentation.inspecting = true
        let olderGeneration = inspectionState.begin()
        let latestGeneration = inspectionState.begin()
        let latestPreview = addPreview(
            named: "latest",
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        )
        var connectionNote: String? = "current connection state"

        XCTAssertTrue(
            AddTorrentInspectionResultApplication.apply(
                .success(latestPreview),
                for: latestGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )
        let staleFailure = String(localized: "torrents.add.inspection_failed")
        let staleOutcome = AddTorrentInspectionResultApplication.failure(
            staleFailure,
            preserving: &connectionNote
        )
        XCTAssertFalse(
            AddTorrentInspectionResultApplication.apply(
                staleOutcome,
                for: olderGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )

        XCTAssertEqual(connectionNote, "current connection state")
        XCTAssertEqual(presentation.preview, latestPreview)
        XCTAssertNil(presentation.errorMessage)
        XCTAssertFalse(presentation.inspecting)
        XCTAssertTrue(presentation.canCommit)
    }

    func testProductionAddInspectionOlderSuccessAfterNewerFailureIsIgnored() {
        var inspectionState = LatestInspectionState<AddTorrentPreview>()
        var presentation = AddTorrentInspectionPresentation()
        presentation.inspecting = true
        let olderGeneration = inspectionState.begin()
        let latestGeneration = inspectionState.begin()
        let latestFailure = String(localized: "error.permission_denied")
        let olderPreview = addPreview(
            named: "older",
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )

        XCTAssertTrue(
            AddTorrentInspectionResultApplication.apply(
                .failure(latestFailure),
                for: latestGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )
        XCTAssertNil(presentation.preview)
        XCTAssertEqual(presentation.errorMessage, latestFailure)
        XCTAssertFalse(presentation.inspecting)
        XCTAssertFalse(presentation.canCommit)

        XCTAssertFalse(
            AddTorrentInspectionResultApplication.apply(
                .success(olderPreview),
                for: olderGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )
        XCTAssertNil(presentation.preview)
        XCTAssertEqual(presentation.errorMessage, latestFailure)
        XCTAssertFalse(presentation.inspecting)
        XCTAssertFalse(presentation.canCommit)
        XCTAssertEqual(inspectionState.result, .failure(latestFailure))
    }

    func testProductionAddInspectionKeepsExactLatestFailureAcrossInterleaving() {
        var inspectionState = LatestInspectionState<AddTorrentPreview>()
        var presentation = AddTorrentInspectionPresentation()
        presentation.inspecting = true
        let olderGeneration = inspectionState.begin()
        let latestGeneration = inspectionState.begin()
        let latestFailure = String(localized: "error.volume_unavailable")
        let olderPreview = addPreview(
            named: "older",
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        )
        let staleFailure = String(localized: "torrents.add.inspection_failed")

        XCTAssertFalse(
            AddTorrentInspectionResultApplication.apply(
                .success(olderPreview),
                for: olderGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )
        XCTAssertTrue(
            AddTorrentInspectionResultApplication.apply(
                .failure(latestFailure),
                for: latestGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )
        XCTAssertFalse(
            AddTorrentInspectionResultApplication.apply(
                .failure(staleFailure),
                for: olderGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )

        XCTAssertEqual(presentation.errorMessage, latestFailure)
        XCTAssertNotEqual(presentation.errorMessage, staleFailure)
        XCTAssertNil(presentation.preview)
        XCTAssertFalse(presentation.inspecting)
        XCTAssertFalse(presentation.canCommit)
        XCTAssertEqual(inspectionState.result, .failure(latestFailure))
    }

    func testProductionAddInspectionSeamRequiresCurrentGenerationAcceptance() {
        var inspectionState = LatestInspectionState<AddTorrentPreview>()
        var presentation = AddTorrentInspectionPresentation()
        presentation.inspecting = true
        let olderGeneration = inspectionState.begin()
        let latestGeneration = inspectionState.begin()
        let staleFailure = String(localized: "torrents.add.inspection_failed")
        let latestPreview = addPreview(
            named: "latest",
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        )

        XCTAssertFalse(
            AddTorrentInspectionResultApplication.apply(
                .failure(staleFailure),
                for: olderGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )
        XCTAssertNil(inspectionState.result)
        XCTAssertNil(presentation.preview)
        XCTAssertNil(presentation.errorMessage)
        XCTAssertTrue(presentation.inspecting)
        XCTAssertFalse(presentation.canCommit)

        XCTAssertTrue(
            AddTorrentInspectionResultApplication.apply(
                .success(latestPreview),
                for: latestGeneration,
                to: &inspectionState,
                presentation: &presentation
            )
        )
        XCTAssertEqual(presentation.preview, latestPreview)
        XCTAssertTrue(presentation.canCommit)
    }

    // MARK: - ControlledNSSplitView bridge ownership

    @MainActor
    func testControlledNSSplitViewUserDragInvokesPersistenceCallback() {
        let (splitView, coordinator) = makeControlledSplitView()
        var persistedHeights: [CGFloat] = []
        coordinator.onUserResize = { persistedHeights.append($0) }
        splitView.delegate = coordinator

        let initialHeight = splitView.arrangedSubviews[1].frame.height
        let draggedHeight = splitView.clampedBottomHeight(360)
        splitView.withUserDividerTracking {
            splitView.setPosition(splitView.position(forBottomHeight: draggedHeight), ofDividerAt: 0)
            // AppKit normally posts this notification during a real drag. The
            // direct coordinator call keeps the bridge test deterministic when
            // an unattached view does not post it automatically.
            if persistedHeights.isEmpty {
                coordinator.splitViewDidResizeSubviews(
                    Notification(name: Notification.Name("ControlledNSSplitView.didResize"), object: splitView)
                )
            }
        }

        XCTAssertEqual(persistedHeights.count, 1)
        XCTAssertNotEqual(splitView.arrangedSubviews[1].frame.height, initialHeight)
        XCTAssertEqual(persistedHeights[0], splitView.arrangedSubviews[1].frame.height, accuracy: 1)
    }

    @MainActor
    func testControlledNSSplitViewProgrammaticUpdatesNeverPersistOrMoveDivider() {
        let (splitView, coordinator) = makeControlledSplitView()
        var persistedHeights: [CGFloat] = []
        coordinator.onUserResize = { persistedHeights.append($0) }
        splitView.delegate = coordinator
        let persistedBaseline = 500.0

        let initialPosition = splitView.position(forBottomHeight: splitView.arrangedSubviews[1].frame.height)
        splitView.updateFixedHeight(
            persistedBaseline,
            minimumTopHeight: FilesPaneSizing.tableMinimumHeight,
            minimumBottomHeight: FilesPaneSizing.minimumHeight,
            maximumBottomHeight: FilesPaneSizing.windowMaximumHeight(availableHeight: 800)
        )
        coordinator.splitViewDidResizeSubviews(
            Notification(name: Notification.Name("programmatic"), object: splitView)
        )
        XCTAssertTrue(persistedHeights.isEmpty)

        splitView.setFrameSize(NSSize(width: 600, height: 500))
        splitView.updateFixedHeight(
            persistedBaseline,
            minimumTopHeight: FilesPaneSizing.tableMinimumHeight,
            minimumBottomHeight: FilesPaneSizing.minimumHeight,
            maximumBottomHeight: FilesPaneSizing.windowMaximumHeight(availableHeight: 500)
        )
        XCTAssertEqual(persistedBaseline, 500)
        XCTAssertLessThanOrEqual(
            splitView.arrangedSubviews[1].frame.height,
            FilesPaneSizing.windowMaximumHeight(availableHeight: 500) + 1
        )
        XCTAssertNotEqual(
            splitView.position(forBottomHeight: splitView.arrangedSubviews[1].frame.height),
            initialPosition
        )

        let clampedPosition = splitView.position(forBottomHeight: splitView.arrangedSubviews[1].frame.height)
        for state in ["selection", "loading", "empty", "removal"] {
            splitView.updateFixedHeight(
                persistedBaseline,
                minimumTopHeight: FilesPaneSizing.tableMinimumHeight,
                minimumBottomHeight: FilesPaneSizing.minimumHeight,
                maximumBottomHeight: FilesPaneSizing.windowMaximumHeight(availableHeight: 500)
            )
            coordinator.splitViewDidResizeSubviews(
                Notification(name: Notification.Name(state), object: splitView)
            )
            XCTAssertEqual(
                splitView.position(forBottomHeight: splitView.arrangedSubviews[1].frame.height),
                clampedPosition,
                accuracy: 1,
                state
            )
        }

        for _ in 0..<20 {
            splitView.updateFixedHeight(
                persistedBaseline,
                minimumTopHeight: FilesPaneSizing.tableMinimumHeight,
                minimumBottomHeight: FilesPaneSizing.minimumHeight,
                maximumBottomHeight: FilesPaneSizing.windowMaximumHeight(availableHeight: 500)
            )
            coordinator.splitViewDidResizeSubviews(
                Notification(name: Notification.Name("update-cycle"), object: splitView)
            )
        }
        XCTAssertTrue(persistedHeights.isEmpty)
        XCTAssertEqual(
            splitView.position(forBottomHeight: splitView.arrangedSubviews[1].frame.height),
            clampedPosition,
            accuracy: 1
        )
    }

    @MainActor
    func testControlledNSSplitViewCoordinatorLifetimeHasNoRetainCycle() {
        let splitView = ControlledNSSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        weak var weakCoordinator: ControlledNSSplitViewCoordinator?

        do {
            let coordinator = ControlledNSSplitViewCoordinator()
            coordinator.onUserResize = { _ in }
            splitView.delegate = coordinator
            weakCoordinator = coordinator
        }

        XCTAssertNil(weakCoordinator)
        XCTAssertNil(splitView.delegate)
    }

    @MainActor
    private func makeControlledSplitView() -> (
        ControlledNSSplitView,
        ControlledNSSplitViewCoordinator
    ) {
        let splitView = ControlledNSSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        splitView.isVertical = false
        splitView.addArrangedSubview(NSView(frame: .zero))
        splitView.addArrangedSubview(NSView(frame: .zero))
        splitView.layoutSubtreeIfNeeded()
        splitView.updateFixedHeight(
            260,
            minimumTopHeight: FilesPaneSizing.tableMinimumHeight,
            minimumBottomHeight: FilesPaneSizing.minimumHeight,
            maximumBottomHeight: FilesPaneSizing.windowMaximumHeight(availableHeight: 800)
        )
        return (splitView, ControlledNSSplitViewCoordinator())
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

    private func authoritativeTorrentSnapshot(
        desiredState: DesiredTorrentState = .running,
        activity: TorrentActivity = .downloading,
        health: TorrentHealth = .healthy,
        totalBytes: Int64 = 500,
        downloadedBytes: Int64 = 150,
        downloadBytesPerSec: Int64 = 100
    ) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentRecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!),
            contentIdentity: nil,
            displayName: "Authoritative fixture",
            desiredState: desiredState,
            activity: activity,
            health: health,
            progress: TransferProgress(
                fraction: 0.5,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes,
                uploadedBytes: 0
            ),
            rates: TransferRates(
                downloadBytesPerSec: downloadBytesPerSec,
                uploadBytesPerSec: 0
            ),
            peers: PeerSummary(connected: 1, halfOpen: 0, total: 1),
            saveLocation: PersistedLocation(path: profile.rootURL.path),
            revision: 1
        )
    }

    private func addPreview(named name: String, operationID: UUID) -> AddTorrentPreview {
        AddTorrentPreview(
            inspection: AddSourceInspection(
                operationID: AddOperationID(rawValue: operationID),
                contentIdentity: nil,
                displayName: name,
                sizeBytes: 100,
                warnings: []
            ),
            files: [
                FileEntry(
                    relativePath: "\(name).bin",
                    name: "\(name).bin",
                    sizeBytes: 100,
                    kind: .file,
                    selection: .normal
                )
            ]
        )
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
