// Layer: WP-07 transfer smoke tests.
// Role: covers the plan gate for the transfer vertical slice — bencode +
// metainfo + magnet + path parsing (positive and negative corpora), preflight
// gates, HTTP source fetch via an in-process URLProtocol stub (no real
// network), and the TransferCoordinator end-to-end flow over a stub engine +
// real persistence: inspect → commitAdd, duplicate detection, idempotent
// replay, startPaused, pause/resume, restart restore, paginated files with
// directory drill-down, setFileSelection, and delta publication.
// Must-not: touch production App Support (TestProfile only), use the real
// engine, or hit the network.

import Foundation
import XCTest
import TorrentinoIPC
import TorrentinoDomain

final class TransferSmokeTests: TestProfileCase {

    // MARK: - Bencode

    func testBencodePositiveInputsParse() throws {
        let positives: [(String, Data)] = [
            ("integer", Data("i42e".utf8)),
            ("negative integer", Data("i-42e".utf8)),
            ("string", Data("4:spam".utf8)),
            ("empty string", Data("0:".utf8)),
            ("list", Data("l4:spami42ee".utf8)),
            ("empty list", Data("le".utf8)),
            ("dict", Data("d3:foo3:bare".utf8)),
            ("empty dict", Data("de".utf8)),
            ("nested dict", Data("d4:infod4:name5:helloee".utf8)),
        ]
        for (label, data) in positives {
            XCTAssertNoThrow(try BencodeParser.parse(data), "expected parse success: \(label)")
        }
    }

    func testBencodeNegativeCorpusRejects() {
        for fixture in NegativeCorpus.bencodeNegatives {
            XCTAssertThrowsError(try BencodeParser.parse(fixture.data), "expected failure for \(fixture.label)")
        }
    }

    // MARK: - Metainfo

    func testMetainfoSingleFileParse() throws {
        let data = MetainfoBuilder.singleFile(name: "fixture.bin", size: 1024, pieceLength: 256, piecesCount: 1, trackers: ["udp://tracker.example:80/announce"])
        let metainfo = try Preflight.validateTorrentData(data)
        XCTAssertEqual(metainfo.name, "fixture.bin")
        XCTAssertEqual(metainfo.totalSize, 1024)
        XCTAssertEqual(metainfo.files.count, 1)
        XCTAssertEqual(metainfo.trackers, ["udp://tracker.example:80/announce"])
        XCTAssertTrue(metainfo.isSingleFile)
        XCTAssertEqual(metainfo.infoHashV1.count, 20)
        // The info-dict digest must be stable: parse twice, same hash.
        let again = try MetainfoParser.parse(data)
        XCTAssertEqual(metainfo.infoHashV1, again.infoHashV1)
    }

    func testMetainfoMultiFileParse() throws {
        let data = MetainfoBuilder.multiFile(files: [("dir/a.txt", 100), ("dir/nested/b.bin", 200)], pieceLength: 256, piecesCount: 1, name: "root")
        let metainfo = try Preflight.validateTorrentData(data)
        XCTAssertEqual(metainfo.name, "root")
        XCTAssertEqual(metainfo.totalSize, 300)
        XCTAssertEqual(metainfo.files.map(\.path), ["dir/a.txt", "dir/nested/b.bin"])
        XCTAssertFalse(metainfo.isSingleFile)
    }

    func testMetainfoNegativeCorpusRejects() {
        for fixture in NegativeCorpus.metainfoNegatives {
            XCTAssertThrowsError(try Preflight.validateTorrentData(fixture.data), "expected failure for \(fixture.label)")
        }
    }

    func testMetainfoRejectsBadInfoDictionary() {
        XCTAssertThrowsError(try MetainfoParser.parse(Data("d8:announce10:tracker.xi1ee".utf8)))
    }

    func testPreflightRejectsOversizeAndZeroTotal() {
        let oversize = Data(repeating: 0x41, count: TransferLimits.maxTorrentFileBytes + 1)
        XCTAssertThrowsError(try Preflight.validateTorrentFileSize(oversize))

        let zeroSize = MetainfoBuilder.withRawPieces(Data(repeating: 0x00, count: 20), name: "empty.bin", size: 0)
        XCTAssertThrowsError(try Preflight.validateTorrentData(zeroSize))
    }

    // MARK: - Magnet

    func testMagnetParseValid() throws {
        let link = try MagnetParser.parse("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Sample&tr=udp%3A%2F%2Ft.example%2Fannounce")
        XCTAssertEqual(link.infoHashV1.count, 20)
        XCTAssertEqual(link.displayName, "Sample")
        XCTAssertEqual(link.trackers, ["udp://t.example/announce"])
    }

    func testMagnetRejectsMissingHash() {
        XCTAssertThrowsError(try MagnetParser.parse("magnet:?dn=Sample"))
    }

    func testMagnetRejectsOversizeURI() {
        let oversized = String(repeating: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567", count: 150)
        XCTAssertThrowsError(try MagnetParser.parse(oversized)) { error in
            XCTAssertEqual(error as? MagnetError, .tooLong)
        }
    }

    func testMagnetNegativeCorpusRejects() {
        for uri in NegativeCorpus.magnetNegatives {
            XCTAssertThrowsError(try MagnetParser.parse(uri), "expected failure for \(uri.prefix(40))")
        }
    }

    // MARK: - Path validation

    func testPathValidatorPositives() {
        for path in NegativeCorpus.pathPositives {
            XCTAssertNil(PathValidator.validationError(path), "expected valid: \(path)")
        }
    }

    func testPathValidatorNegatives() {
        for path in NegativeCorpus.pathNegatives {
            XCTAssertNotNil(PathValidator.validationError(path), "expected invalid: \(path)")
        }
    }

    // MARK: - HTTP source fetch (in-process stub, no network)

    func testHTTPSourceFetchSuccess() async throws {
        let torrent = MetainfoBuilder.singleFile()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.install(response: torrent, contentType: "application/x-bittorrent", status: 200)

        let fetcher = HTTPSourceFetcher(configuration: configuration)
        let data = try await fetcher.fetch(urlString: "https://example.test/a.torrent")
        XCTAssertEqual(data, torrent)
    }

    func testHTTPSourceFetchRejectsWrongContentType() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.install(response: Data("html".utf8), contentType: "text/html", status: 200)

        let fetcher = HTTPSourceFetcher(configuration: configuration)
        do {
            _ = try await fetcher.fetch(urlString: "https://example.test/a.torrent")
            XCTFail("expected content-type rejection")
        } catch let error as HTTPSourceError {
            guard case .unacceptableContentType = error else {
                return XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHTTPSourceFetchRejectsNonSuccess() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.install(response: Data("nope".utf8), contentType: "application/octet-stream", status: 404)

        let fetcher = HTTPSourceFetcher(configuration: configuration)
        do {
            _ = try await fetcher.fetch(urlString: "https://example.test/missing.torrent")
            XCTFail("expected 404 rejection")
        } catch let error as HTTPSourceError {
            guard case .nonSuccessStatus = error else {
                return XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHTTPSourceFetchRejectsOversizeBody() async {
        let big = Data(repeating: 0x42, count: HTTPSourceFetcher.maxBodyBytes + 1)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.install(response: big, contentType: "application/x-bittorrent", status: 200)

        let fetcher = HTTPSourceFetcher(configuration: configuration)
        do {
            _ = try await fetcher.fetch(urlString: "https://example.test/big.torrent")
            XCTFail("expected oversized rejection")
        } catch let error as HTTPSourceError {
            guard case .responseTooLarge = error else {
                return XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHTTPSourceFetchRejectsInvalidURL() async {
        let fetcher = HTTPSourceFetcher()
        do {
            _ = try await fetcher.fetch(urlString: "not a url")
            XCTFail("expected invalid URL rejection")
        } catch let error as HTTPSourceError {
            XCTAssertEqual(error, .invalidURL("not a url"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Coordinator end-to-end (stub engine + real persistence)

    private func makeCoordinator(bus: TransferEventBus) async throws -> (TransferCoordinator, PersistenceStore) {
        let store = PersistenceStore(dataDirectory: profile.rootURL)
        _ = try await store.open()
        let coordinator = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: bus,
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        return (coordinator, store)
    }

    func testCommitAddFlowPublishesDelta() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store) = try await makeCoordinator(bus: bus)
        let deliveries = DeliveryCollector()
        await bus.register(deliveries.sink())

        let torrent = MetainfoBuilder.singleFile(name: "flow.bin", size: 2048, pieceLength: 256, piecesCount: 1)
        let inspection = try await inspect(coordinator, source: .torrentFileData(torrent))
        let commit = CommitAddRequest(
            requestID: RequestID(), idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID, desiredName: "Flow", startPaused: true
        )
        let reply = await coordinator.processCommand(encode(.commitAdd(commit)))
        let result = try resultPayload(from: reply)
        guard case .commitAdd(let addResult) = result else {
            return XCTFail("expected commitAdd result, got \(result)")
        }

        let snapshotReply = await coordinator.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil))))
        let snap = try snapshot(from: snapshotReply)
        XCTAssertEqual(snap.torrents.count, 1)
        XCTAssertEqual(snap.torrents.first?.displayName, "Flow")
        XCTAssertEqual(snap.torrents.first?.desiredState, .paused)
        XCTAssertEqual(snap.torrents.first?.id, addResult.recordID)

        // A delta for the add must have been delivered.
        let deltaEvents = await deliveries.events(timeoutNanoseconds: 500_000_000)
        XCTAssertTrue(deltaEvents.contains { event in
            if case .torrentDelta(let payload) = event {
                return payload.delta.added.contains { $0.id == addResult.recordID }
            }
            return false
        }, "expected torrentDelta with the added record")

        // Restart: a fresh coordinator over the same store rebuilds the record.
        let second = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        await second.restoreFromPersistence()
        let snap2 = try snapshot(from: await second.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))))
        XCTAssertEqual(snap2.torrents.count, 1)
        XCTAssertEqual(snap2.torrents.first?.desiredState, .paused)
        XCTAssertEqual(snap2.torrents.first?.displayName, "Flow")
    }

    func testDuplicateAddReturnsExistingRecord() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)

        let torrent = MetainfoBuilder.singleFile(name: "dup.bin", size: 2048, pieceLength: 256, piecesCount: 1)
        let inspection = try await inspect(coordinator, source: .torrentFileData(torrent))
        let first = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: inspection.operationID)
        ))))
        guard case .commitAdd(let firstResult) = first else { return XCTFail() }

        let inspection2 = try await inspect(coordinator, source: .torrentFileData(torrent))
        let second = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: inspection2.operationID)
        ))))
        guard case .commitAdd(let secondResult) = second else { return XCTFail() }
        XCTAssertEqual(secondResult.recordID, firstResult.recordID)
    }

    func testCommitAddIdempotentReplay() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)

        let inspection = try await inspect(coordinator, source: .magnet("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"))
        let key = IdempotencyKey()
        let request = CommitAddRequest(requestID: RequestID(), idempotencyKey: key, operationID: inspection.operationID)
        let first = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(request))))
        guard case .commitAdd(let firstResult) = first else { return XCTFail() }

        // Replaying the same idempotency key must return the same record.
        let replayed = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(request))))
        guard case .commitAdd(let replayedResult) = replayed else { return XCTFail() }
        XCTAssertEqual(replayedResult.recordID, firstResult.recordID)
    }

    func testCommitAddWithoutInspectFails() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let reply = await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: AddOperationID())
        )))
        guard case .failure(let fault) = decode(IPCEnvelope.self, from: reply).result else {
            return XCTFail("expected fault")
        }
        XCTAssertEqual(fault.code, .operationNotFound)
    }

    func testPauseResumeUpdatesRecord() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)

        let inspection = try await inspect(coordinator, source: .magnet("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"))
        let commit = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: inspection.operationID)
        ))))
        guard case .commitAdd(let addResult) = commit else { return XCTFail() }

        let paused = try resultPayload(from: await coordinator.processCommand(encode(.pause(
            PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: addResult.recordID)
        ))))
        XCTAssertEqual(paused, .ack)
        let snapshot1 = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))))
        XCTAssertEqual(snapshot1.torrents.first?.desiredState, .paused)

        _ = try resultPayload(from: await coordinator.processCommand(encode(.resume(
            ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: addResult.recordID)
        ))))
        let snapshot2 = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))))
        XCTAssertEqual(snapshot2.torrents.first?.desiredState, .running)
    }

    func testFilesPageWithDirectoryDrillDown() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)

        let torrent = MetainfoBuilder.multiFile(
            files: [("root/a.txt", 100), ("root/sub/b.bin", 200), ("root/sub/c.bin", 300), ("root/sub/deep/d.bin", 400)],
            pieceLength: 256, piecesCount: 1, name: "root"
        )
        let inspection = try await inspect(coordinator, source: .torrentFileData(torrent))
        let commit = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: inspection.operationID)
        ))))
        guard case .commitAdd(let addResult) = commit else { return XCTFail() }

        // Root page: one entry — the "root" directory (all files live below it).
        let root = try await filesPage(coordinator, recordID: addResult.recordID, cursor: nil)
        XCTAssertEqual(root.items.count, 1)
        XCTAssertEqual(root.items.filter { $0.kind == .directory }.count, 1)
        XCTAssertEqual(root.items.filter { $0.kind == .file }.count, 0)
        let rootDir = root.items.first { $0.kind == .directory }
        XCTAssertEqual(rootDir?.relativePath, "root")

        // Enter "root": one directory "sub" + one file "a.txt".
        let sub = try await filesPage(coordinator, recordID: addResult.recordID, cursor: FileCursor(directoryStack: ["root"]))
        XCTAssertEqual(sub.items.count, 2)
        XCTAssertEqual(sub.items.filter { $0.kind == .directory }.first?.relativePath, "root/sub")

        // Enter "root/sub": two files + one directory.
        let deep = try await filesPage(coordinator, recordID: addResult.recordID, cursor: FileCursor(directoryStack: ["root", "sub"]))
        XCTAssertEqual(deep.items.count, 3)
        XCTAssertEqual(deep.items.filter { $0.kind == .file }.map(\.relativePath).sorted(),
                       ["root/sub/b.bin", "root/sub/c.bin"])
        XCTAssertEqual(deep.items.filter { $0.kind == .directory }.first?.relativePath, "root/sub/deep")

        // Pagination within a directory using the opaque cursor.
        let page = try await filesPage(coordinator, recordID: addResult.recordID, cursor: FileCursor(directoryStack: ["root", "sub"]), pageSize: 2)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertNotNil(page.nextCursor)
        let page2 = try await filesPage(coordinator, recordID: addResult.recordID, cursor: FileCursor(directoryStack: ["root", "sub"], token: page.nextCursor), pageSize: 2)
        XCTAssertEqual(page2.items.count, 1)
        XCTAssertNil(page2.nextCursor)
    }

    func testSetFileSelectionInvalidatesInspection() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let deliveries = DeliveryCollector()
        await bus.register(deliveries.sink())

        let torrent = MetainfoBuilder.multiFile(files: [("dir/a.txt", 100)], pieceLength: 256, piecesCount: 1, name: "sel")
        let inspection = try await inspect(coordinator, source: .torrentFileData(torrent))
        let commit = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: inspection.operationID)
        ))))
        guard case .commitAdd(let addResult) = commit else { return XCTFail() }

        let result = try resultPayload(from: await coordinator.processCommand(encode(.setFileSelection(
            SetFileSelectionRequest(
                requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: addResult.recordID,
                selection: [FileSelectionItem(relativePath: "dir/a.txt", priority: .skip)],
                expectedRevision: 0
            )
        ))))
        XCTAssertEqual(result, .ack)

        let events = await deliveries.events(timeoutNanoseconds: 500_000_000)
        XCTAssertTrue(events.contains { event in
            if case .inspectionInvalidated(let payload) = event {
                return payload.recordID == addResult.recordID && payload.scope == .files
            }
            return false
        }, "expected inspectionInvalidated(files)")

        let root = try await filesPage(coordinator, recordID: addResult.recordID, cursor: nil)
        XCTAssertEqual(root.items.first { $0.kind == .directory }?.relativePath, "dir")

        // The file lives inside the "dir" directory; its selection is .skip.
        let dir = try await filesPage(coordinator, recordID: addResult.recordID, cursor: FileCursor(directoryStack: ["dir"]))
        XCTAssertEqual(dir.items.first { $0.kind == .file }?.selection, .skip)
    }

    // MARK: - Helpers

    private func inspect(_ coordinator: TransferCoordinator, source: AddSource) async throws -> AddSourceInspection {
        let reply = await coordinator.processCommand(encode(.inspectAddSource(
            InspectAddSourceRequest(requestID: RequestID(), source: source)
        )))
        let payload = try resultPayload(from: reply)
        guard case .addSourceInspection(let inspection) = payload else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected \(payload)"])
        }
        return inspection
    }

    private func snapshot(from reply: Data) throws -> EngineSnapshot {
        let payload = try resultPayload(from: reply)
        guard case .snapshot(let snapshot) = payload else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected \(payload)"])
        }
        return snapshot
    }

    private func filesPage(_ coordinator: TransferCoordinator, recordID: TorrentRecordID, cursor: FileCursor?, pageSize: Int = 200) async throws -> Page<FileEntry> {
        let reply = await coordinator.processCommand(encode(.fetchFiles(
            FetchFilesRequest(requestID: RequestID(), recordID: recordID, cursor: cursor, pageSize: pageSize, expectedRevision: 0)
        )))
        let payload = try resultPayload(from: reply)
        guard case .files(let page) = payload else {
            throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "unexpected \(payload)"])
        }
        return page
    }

    private func resultPayload(from reply: Data) throws -> SuccessPayload {
        let envelope = decode(IPCEnvelope.self, from: reply)
        guard let result = envelope.result else {
            throw NSError(domain: "test", code: 4, userInfo: [NSLocalizedDescriptionKey: "no result in \(envelope)"])
        }
        switch result {
        case .success(let payload):
            return payload
        case .failure(let fault):
            throw NSError(domain: "test", code: 5, userInfo: [NSLocalizedDescriptionKey: "fault \(fault.code.rawValue) \(fault.redactedContext ?? "")"])
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            fatalError("decode failed: \(error)")
        }
    }

    private func encode(_ command: EngineCommandV1) -> Data {
        (try? JSONEncoder().encode(IPCEnvelope.request(command))) ?? Data()
    }
}

// MARK: - Stub engine

private actor StubTransferEngine: TransferEngine {
    private var started = false
    private var nextID = 0
    private var statuses: [String: TransferTorrentStatus] = [:]

    var isStarted: Bool { started }

    func start() async throws {
        started = true
    }

    func add(specification: AddSpecificationDTO) async throws -> AddResultDTO {
        nextID += 1
        return AddResultDTO(torrentID: "stub-\(nextID)", infoHash: "stub", name: "stub", totalSize: -1)
    }

    func pause(torrentID: String) async throws {}
    func resume(torrentID: String) async throws {}
    func recheck(torrentID: String) async throws {}
    func remove(torrentID: String) async throws {}

    func statusUpdate() async throws -> [TransferTorrentStatus] {
        Array(statuses.values)
    }

    func aggregateHealth() async throws -> TransferAggregateStats {
        .zero
    }
}

// MARK: - URLProtocol stub

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseData: Data = Data()
    nonisolated(unsafe) private static var contentType: String = "application/octet-stream"
    nonisolated(unsafe) private static var status: Int = 200

    static func install(response: Data, contentType: String, status: Int) {
        lock.lock()
        responseData = response
        self.contentType = contentType
        self.status = status
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let data = Self.responseData
        let contentType = Self.contentType
        let status = Self.status
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status >= 200 && status < 300 {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Delivery collector

private actor DeliveryCollector {
    private var collected: [EngineEventV1] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func sink() -> TransferEventBus.Sink {
        TransferEventBus.Sink(id: UUID()) { [weak self] events in
            guard let self else { return }
            await self.record(events)
        }
    }

    private func record(_ events: [EngineEventV1]) {
        collected.append(contentsOf: events)
        waiting?.resume()
        waiting = nil
    }

    func events(timeoutNanoseconds: UInt64) async -> [EngineEventV1] {
        guard collected.isEmpty else { return collected }
        await withCheckedContinuation { continuation in
            waiting = continuation
        }
        return collected
    }
}
