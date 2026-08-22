// Layer: Unit tests (WP-21 removal actions).
// Role: verify durable removal request wiring and destructive confirmation routing.
// Must-not: start the engine, touch storage, or send network traffic.

import Foundation
import XCTest
import TorrentinoIPC

private actor RemovalCommandSpy {
    private(set) var commands: [EngineCommandV1] = []
    private var recordIDsByToken: [String: TorrentRecordID] = [:]

    func send(_ command: EngineCommandV1) -> SuccessPayload {
        commands.append(command)
        switch command {
        case .prepareRemoval(let request):
            let token = RemovalToken(rawValue: "wp21-token-\(commands.count)")
            recordIDsByToken[token.rawValue] = request.recordID
            return .removalToken(token)
        case .commitRemoval(let request):
            guard let recordID = recordIDsByToken[request.token.rawValue] else {
                fatalError("commitRemoval token was not prepared")
            }
            return .removalResult(RemovalBatchResult(
                recordID: recordID,
                token: request.token,
                outcome: .completed,
                trashedItems: 1,
                skippedSharedItems: 0,
                failedItems: []
            ))
        default:
            fatalError("unexpected command in removal flow: \(command)")
        }
    }
}

@MainActor
final class WP21RemovalTests: XCTestCase {
    func testRemovalFlowWiresDeleteFilesAndRecordIDs() async throws {
        let keepFilesID = TorrentRecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
        let deleteFilesID = TorrentRecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!)
        let spy = RemovalCommandSpy()

        _ = try await TorrentRemovalFlow.run(
            recordID: keepFilesID,
            deleteFiles: false,
            send: { command in await spy.send(command) }
        )
        _ = try await TorrentRemovalFlow.run(
            recordID: deleteFilesID,
            deleteFiles: true,
            send: { command in await spy.send(command) }
        )

        let commands = await spy.commands
        let prepares = commands.compactMap { command -> PrepareRemovalRequest? in
            guard case .prepareRemoval(let request) = command else { return nil }
            return request
        }
        XCTAssertEqual(prepares.map(\.recordID), [keepFilesID, deleteFilesID])
        XCTAssertEqual(prepares.map(\.deleteFiles), [false, true])
        XCTAssertEqual(commands.count, 4, "each removal must prepare and commit exactly once")
    }

    func testConfirmationConfirmConsumesIDsOnceAndClearsRouter() {
        var router = TorrentRemovalConfirmationRouter()
        let targetIDs: Set<TorrentRecordID> = [
            TorrentRecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000024")!),
            TorrentRecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000025")!)
        ]

        router.request(for: targetIDs)
        XCTAssertEqual(router.confirm(), targetIDs)
        XCTAssertFalse(router.isPresented)
        XCTAssertTrue(router.pendingIDs.isEmpty)
        XCTAssertTrue(router.confirm().isEmpty, "a confirmation snapshot must route at most once")
    }

    func testConfirmationSnapshotSurvivesTeardownBeforeAction() throws {
        var router = TorrentRemovalConfirmationRouter()
        let targetIDs: Set<TorrentRecordID> = [
            TorrentRecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000026")!)
        ]

        router.request(for: targetIDs)
        let snapshot = try XCTUnwrap(router.confirmationSnapshot)
        router.dismiss()
        XCTAssertFalse(router.isPresented)
        XCTAssertTrue(router.pendingIDs.isEmpty)

        XCTAssertEqual(router.confirm(snapshot), targetIDs)
        XCTAssertTrue(router.pendingIDs.isEmpty)
        XCTAssertTrue(router.confirm(snapshot).isEmpty, "the captured request must not dispatch twice")
    }

    func testDestructiveConfirmationCancelClearsTargetsWithoutRouting() throws {
        var router = TorrentRemovalConfirmationRouter()
        let targetID = TorrentRecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!)

        router.request(for: [targetID])
        let snapshot = try XCTUnwrap(router.confirmationSnapshot)
        XCTAssertTrue(router.isPresented)
        XCTAssertEqual(router.pendingIDs, [targetID])

        router.cancel()
        XCTAssertFalse(router.isPresented)
        XCTAssertTrue(router.pendingIDs.isEmpty)

        XCTAssertTrue(router.confirm().isEmpty, "cancel must leave no IDs to route")
        XCTAssertTrue(router.confirm(snapshot).isEmpty, "a canceled snapshot must not route")

        router.request(for: [targetID])
        router.dismiss()
        XCTAssertTrue(router.confirm().isEmpty, "dismissal must also clear stale IDs")
    }
}
