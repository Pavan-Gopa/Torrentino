// Layer: Unit tests (Torrentino app shell).
// Role: smoke checks for domain/IPC linkage and isolated TestProfile.
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
    }

    func testTestProfileDoesNotUseProductionPaths() throws {
        let root = profile.rootURL.path
        XCTAssertFalse(root.contains("Application Support/com.torrentino.app"))
        let markerFile = try profile.subdirectory("markers")
            .appendingPathComponent("wp03.txt")
        try "ok".write(to: markerFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path))
    }
}
