// Layer: Unit tests (TorrentinoIPC).
// Role: verify versioned envelopes, command/event schemas, Codable round-trips.
// Must-not: open XPC connections or touch production Application Support.

import XCTest
@testable import TorrentinoIPC

final class TorrentinoIPCTests: TestProfileCase {
    func testCurrentVersionIs1_0() {
        XCTAssertEqual(IPCVersion.current.major, 1)
        XCTAssertEqual(IPCVersion.current.minor, 0)
        XCTAssertEqual(IPCVersion.current.description, "1.0")
    }

    func testVersionOrdering() {
        let v10 = IPCVersion(major: 1, minor: 0)
        let v11 = IPCVersion(major: 1, minor: 1)
        let v20 = IPCVersion(major: 2, minor: 0)
        XCTAssertTrue(v10 < v11)
        XCTAssertTrue(v11 < v20)
        XCTAssertFalse(v20 < v10)
    }

    func testEngineCommandsMatchWP02Surface() {
        let expected: [EngineCommand] = [
            .hello, .health, .increment, .getCounter, .shutdown
        ]
        XCTAssertEqual(EngineCommand.allCases, expected)
    }

    func testEngineEventPlaceholders() {
        XCTAssertEqual(
            Set(EngineEvent.allCases),
            Set([.stateChanged, .progressUpdated])
        )
    }

    func testEnvelopeRoundTripAndCompatibility() throws {
        let envelope = IPCEnvelope(
            version: .current,
            type: EngineCommand.hello.rawValue,
            payload: "ping"
        )
        XCTAssertTrue(envelope.isCompatibleWithCurrent)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IPCEnvelope<String>.self, from: data)
        XCTAssertEqual(decoded, envelope)

        let incompatible = IPCEnvelope(
            version: IPCVersion(major: 99, minor: 0),
            type: EngineCommand.health.rawValue,
            payload: "x"
        )
        XCTAssertFalse(incompatible.isCompatibleWithCurrent)
    }

    func testProfileIsolation() {
        XCTAssertFalse(
            profile.rootURL.path.contains(TestProfile.productionAppSupportMarker)
        )
    }
}
