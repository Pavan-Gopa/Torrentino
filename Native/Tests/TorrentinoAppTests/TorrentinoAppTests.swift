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
}
