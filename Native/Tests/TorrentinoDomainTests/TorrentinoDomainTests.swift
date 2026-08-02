// Layer: Unit tests (TorrentinoDomain).
// Role: verify domain value types, Sendable DTOs, and error taxonomy.
// Must-not: perform network I/O or touch production Application Support.

import XCTest
@testable import TorrentinoDomain

final class TorrentinoDomainTests: TestProfileCase {
    func testTorrentStateCasesAreStable() {
        let expected: [TorrentState] = [
            .queued, .downloading, .seeding, .paused, .error, .stopped
        ]
        XCTAssertEqual(TorrentState.allCases, expected)
        for state in TorrentState.allCases {
            XCTAssertEqual(TorrentState(rawValue: state.rawValue), state)
        }
    }

    func testTorrentInfoIsImmutableValueType() throws {
        let id = UUID()
        let info = TorrentInfo(
            id: id,
            name: "example.iso",
            size: 1_024,
            progress: 0.5,
            state: .downloading
        )
        XCTAssertEqual(info.id, id)
        XCTAssertEqual(info.name, "example.iso")
        XCTAssertEqual(info.size, 1_024)
        XCTAssertEqual(info.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(info.state, .downloading)

        // Round-trip Codable without I/O side effects.
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(TorrentInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testEngineErrorDescriptions() {
        XCTAssertFalse(EngineError.xpcUnavailable.description.isEmpty)
        XCTAssertFalse(EngineError.agentDenied.description.isEmpty)
        XCTAssertFalse(EngineError.timeout.description.isEmpty)
        XCTAssertFalse(EngineError.internalError.description.isEmpty)
    }

    func testProfileIsIsolatedFromProductionAppSupport() throws {
        let path = profile.rootURL.path
        XCTAssertFalse(
            path.contains(TestProfile.productionAppSupportMarker),
            "TestProfile must not use production path: \(path)"
        )
        let sub = try profile.subdirectory("engine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sub.path))
        XCTAssertTrue(sub.path.hasPrefix(profile.rootURL.path))
    }
}
