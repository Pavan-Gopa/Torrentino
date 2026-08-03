// Layer: WP-07 transfer smoke tests.
// Role: covers the plan gate for the transfer vertical slice — bencode +
// metainfo + magnet + path parsing (positive and negative corpora), preflight
// gates, HTTP source fetch via an in-process URLProtocol stub (no real
// network), and the TransferCoordinator end-to-end flow over a stub engine +
// real persistence: inspect → commitAdd, duplicate detection, idempotent
// replay, startPaused, pause/resume, restart restore, paginated files with
// directory drill-down, setFileSelection, and delta publication.
// Must-not: touch production App Support (TestProfile only), use the real
// engine, or hit EXTERNAL network. Redirect-limit coverage runs against an
// in-test 127.0.0.1 loopback python server — URLProtocol stubs cannot
// reproduce 3xx redirects (URLSession completes each hop with an empty
// buffer before the redirect machinery runs).

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

    // MARK: - Bencode boundedness (ADR-010: depth + size + strict integers)

    func testBencodeDepthBoundary() throws {
        // 64 nested containers parse; the 66th level is rejected with the
        // typed .depthExceeded error (maxDepth = 64).
        let atDepth = Data((String(repeating: "l", count: 64) + String(repeating: "e", count: 64)).utf8)
        XCTAssertNoThrow(try BencodeParser.parse(atDepth))
        let tooDeep = Data((String(repeating: "l", count: 66) + String(repeating: "e", count: 66)).utf8)
        XCTAssertThrowsError(try BencodeParser.parse(tooDeep)) { error in
            XCTAssertEqual(error as? BencodeError, .depthExceeded)
        }
    }

    func testBencodeInputSizeBound() {
        // Hard ceiling: maxInputBytes (16 MiB). One byte over must be rejected
        // BEFORE any token is parsed.
        let over = Data(repeating: 0x61, count: BencodeParser.maxInputBytes + 1)
        XCTAssertThrowsError(try BencodeParser.parse(over)) { error in
            XCTAssertEqual(error as? BencodeError, .sizeExceeded(BencodeParser.maxInputBytes + 1))
        }
        // A payload that exceeds the limit by its declared length is rejected
        // as truncated (bounded allocation: the length is never trusted).
        let hugeLength = Data("\(BencodeParser.maxInputBytes + 1):a".utf8)
        XCTAssertThrowsError(try BencodeParser.parse(hugeLength))
    }

    func testBencodeStrictIntegerFormsTyped() {
        let cases: [(String, BencodeError)] = [
            ("i01e", .malformedInteger("<leading-zero>")),
            ("i-0e", .malformedInteger("-0")),
            ("ie", .malformedInteger("")),
            ("i1-2e", .malformedInteger("<non-digit>")),
            ("i9223372036854775808e", .malformedInteger("<overflow>")),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try BencodeParser.parse(Data(text.utf8))) { error in
                XCTAssertEqual(error as? BencodeError, expected, "expected \(expected) for \(text)")
            }
        }
    }

    // MARK: - Metainfo limits (file count, trackers, path length, SHA-1)

    func testMetainfoSHA1KnownVector() throws {
        // Independent BEP-3 check: SHA-1 of the exact bencoded info dict of a
        // deterministic fixture must equal the externally computed digest
        // (verified with `shasum -a 1` on the identical bytes).
        let data = MetainfoBuilder.singleFile(name: "fixture.bin", size: 1024, pieceLength: 256, piecesCount: 1, trackers: ["udp://tracker.example:80/announce"])
        let metainfo = try MetainfoParser.parse(data)
        XCTAssertEqual(metainfo.infoHashHex, "dcc9ecbdd3c8f7dc2554a3bc9fd0003778dbae0c")
        XCTAssertEqual(metainfo.infoHashV1.count, 20)
        // The info-dict byte range must be re-hashable to the same digest.
        XCTAssertEqual(try MetainfoParser.parse(data).infoDictData, metainfo.infoDictData)
    }

    func testMetainfoFileCountLimitExactBoundary() throws {
        let atLimit = MetainfoBuilder.multiFile(files: (0..<TransferLimits.maxFiles).map { ("f\($0).bin", 1) }, pieceLength: 16, piecesCount: 1)
        XCTAssertEqual(try MetainfoParser.parse(atLimit).fileCount, TransferLimits.maxFiles)

        let overLimit = MetainfoBuilder.multiFile(files: (0...TransferLimits.maxFiles).map { ("f\($0).bin", 1) }, pieceLength: 16, piecesCount: 1)
        XCTAssertThrowsError(try MetainfoParser.parse(overLimit)) { error in
            XCTAssertEqual(error as? MetainfoError, .tooManyFiles(TransferLimits.maxFiles + 1))
        }
    }

    func testMetainfoTrackerLimitCappedAt512() throws {
        let trackers = (0..<600).map { "udp://t\($0).example/announce" }
        let info: [String: Data] = [
            "name": BencodeBuilder.encode(string: "cap.bin"),
            "length": BencodeBuilder.encode(integer: 1024),
            "piece length": BencodeBuilder.encode(integer: 256),
            "pieces": BencodeBuilder.encode(bytes: BencodeBuilder.pieceHashes(count: 20)),
        ]
        let top: [String: Data] = [
            "announce": BencodeBuilder.encode(string: trackers[0]),
            "announce-list": BencodeBuilder.encode(list: [
                BencodeBuilder.encode(list: trackers.map { BencodeBuilder.encode(string: $0) })
            ]),
            "info": BencodeBuilder.encode(dictionary: info),
        ]
        let metainfo = try MetainfoParser.parse(BencodeBuilder.encode(dictionary: top))
        XCTAssertEqual(metainfo.trackers.count, TransferLimits.maxTrackers)
        XCTAssertEqual(metainfo.trackers.first, "udp://t0.example/announce")
    }

    func testMetainfoPathLengthBoundaries() {
        // Component: exactly 255 accepted, 256 rejected.
        XCTAssertNil(PathValidator.validationError(String(repeating: "x", count: 255)))
        XCTAssertEqual(PathValidator.validationError(String(repeating: "x", count: 256)), .componentTooLong(String(repeating: "x", count: 256)))
        // Whole path: exactly 4096 accepted, 4097 rejected.
        let exact4096 = Array(repeating: String(repeating: "a", count: 255), count: 16).joined(separator: "/")
        XCTAssertEqual(exact4096.count, 16 * 255 + 15)
        XCTAssertNil(PathValidator.validationError(exact4096))
        let over4096 = Array(repeating: String(repeating: "a", count: 255), count: 17).joined(separator: "/")
        XCTAssertEqual(PathValidator.validationError(over4096), .pathTooLong)
        // Component count: 513 components rejected even when total is short.
        let manyComponents = Array(repeating: "a", count: 513).joined(separator: "/")
        XCTAssertEqual(PathValidator.validationError(manyComponents), .pathTooLong)
    }

    func testMetainfoPiecesSanityTyped() {
        XCTAssertThrowsError(try MetainfoParser.parse(MetainfoBuilder.singleFile(piecesCount: 0))) { error in
            XCTAssertEqual(error as? MetainfoError, .invalidPieces)
        }
        XCTAssertThrowsError(try MetainfoParser.parse(MetainfoBuilder.withRawPieces(Data(repeating: 0xAA, count: 30)))) { error in
            XCTAssertEqual(error as? MetainfoError, .invalidPieces)
        }
    }

    // MARK: - Magnet (base32, v2 handling, dedupe, length boundary)

    func testMagnetBase32HashDecodesToKnownBytes() throws {
        // RFC 4648 base32 (no padding) of the same 20 bytes as the hex form.
        let link = try MagnetParser.parse("magnet:?xt=urn:btih:aerukz4jvpg66ajdivtytk6n54asgrlh")
        XCTAssertEqual(link.infoHashHex, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(link.infoHashV1.count, 20)
    }

    func testMagnetRejectsShortHashTyped() {
        let shortHex = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef0123456"
        XCTAssertEqual(shortHex.count, 39 + "magnet:?xt=urn:btih:".count)
        XCTAssertThrowsError(try MagnetParser.parse(shortHex)) { error in
            XCTAssertEqual(error as? MagnetError, .invalidHash("0123456789abcdef0123456789abcdef0123456"))
        }
    }

    func testMagnetBTMHOnlyRejectedHybridUsesBTIH() throws {
        // v2-only hash: the v1 slice has no identity → reject (missingHash).
        let v2Only = "magnet:?xt=urn:btmh:1220\(String(repeating: "0", count: 120))"
        XCTAssertThrowsError(try MagnetParser.parse(v2Only)) { error in
            XCTAssertEqual(error as? MagnetError, .missingHash)
        }
        // Hybrid: btmh is ignored, btih still yields the v1 identity.
        let hybrid = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&xt=urn:btmh:1220\(String(repeating: "0", count: 120))"
        let link = try MagnetParser.parse(hybrid)
        XCTAssertEqual(link.infoHashV1.count, 20)
        XCTAssertEqual(link.infoHashHex, "0123456789abcdef0123456789abcdef01234567")
    }

    func testMagnetTrackerDedupeAndSchemeWhitelist() throws {
        let deduped = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
            + "&tr=udp%3A%2F%2Fa.example%2Fannounce&tr=udp%3A%2F%2Fa.example%2Fannounce"
            + "&tr=udp%3A%2F%2Fb.example%2Fannounce"
        let link = try MagnetParser.parse(deduped)
        XCTAssertEqual(link.trackers, ["udp://a.example/announce", "udp://b.example/announce"])

        let ftpTracker = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=ftp%3A%2F%2Fb.example%2Fannounce"
        XCTAssertThrowsError(try MagnetParser.parse(ftpTracker)) { error in
            XCTAssertEqual(error as? MagnetError, .invalidTrackerURL("ftp://b.example/announce"))
        }
    }

    func testMagnetLengthBoundaryExact() throws {
        let base = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn="
        let padded = base + String(repeating: "x", count: TransferLimits.maxMagnetLength - base.count)
        XCTAssertEqual(padded.count, TransferLimits.maxMagnetLength)
        XCTAssertNoThrow(try MagnetParser.parse(padded))
        XCTAssertThrowsError(try MagnetParser.parse(padded + "x")) { error in
            XCTAssertEqual(error as? MagnetError, .tooLong)
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

    func testHTTPSourceFetchHTTPSchemeAllowed() async throws {
        // http (not only https) is in the frozen scheme allowlist.
        let torrent = MetainfoBuilder.singleFile()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.install(response: torrent, contentType: "application/x-bittorrent", status: 200)
        let fetcher = HTTPSourceFetcher(configuration: configuration)
        let data = try await fetcher.fetch(urlString: "http://example.test/a.torrent")
        XCTAssertEqual(data, torrent)
    }

    func testHTTPSourceFetchRejectsUnsupportedScheme() async {
        let fetcher = HTTPSourceFetcher()
        for scheme in ["ftp://example.test/a.torrent", "file:///tmp/a.torrent", "gopher://example.test/a"] {
            do {
                _ = try await fetcher.fetch(urlString: scheme)
                XCTFail("expected scheme rejection for \(scheme)")
            } catch let error as HTTPSourceError {
                guard case .unsupportedScheme = error else {
                    return XCTFail("expected unsupportedScheme, got \(error)")
                }
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testHTTPSourceFetchRejectsMoreThanFiveRedirects() async throws {
        // Redirects cannot be exercised through URLProtocol stubs (URLSession
        // completes each 3xx hop's task with an empty buffer, which the fetch
        // surfaces as .emptyResponse before the redirect machinery runs), so
        // the frozen limit is verified over a 127.0.0.1 loopback server.
        let server = try startRedirectServer()
        defer { server.process.terminate() }
        let fetcher = HTTPSourceFetcher()
        do {
            _ = try await fetcher.fetch(urlString: "http://127.0.0.1:\(server.port)/redir/6")
            XCTFail("expected too-many-redirects rejection")
        } catch let error as HTTPSourceError {
            XCTAssertEqual(error, .tooManyRedirects)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHTTPSourceFetchAllowsExactlyFiveRedirects() async throws {
        let server = try startRedirectServer()
        defer { server.process.terminate() }
        let fetcher = HTTPSourceFetcher()
        let data = try await fetcher.fetch(urlString: "http://127.0.0.1:\(server.port)/redir/5")
        XCTAssertFalse(data.isEmpty, "5 redirects then a 200 must succeed")
    }

    func testHTTPSourceFetchRejectsRedirectToUnsupportedScheme() async throws {
        let server = try startRedirectServer()
        defer { server.process.terminate() }
        let fetcher = HTTPSourceFetcher()
        do {
            _ = try await fetcher.fetch(urlString: "http://127.0.0.1:\(server.port)/ftp")
            XCTFail("expected redirect-to-unsupported-scheme rejection")
        } catch let error as HTTPSourceError {
            guard case .redirectToUnsupportedScheme = error else {
                return XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHTTPSourceFetchMissingContentTypeAllowed() async throws {
        // Absent Content-Type is allowed by the frozen allowlist (only a
        // PRESENT disallowed type is rejected).
        let torrent = MetainfoBuilder.singleFile()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.install(response: torrent, contentType: nil, status: 200)
        let fetcher = HTTPSourceFetcher(configuration: configuration)
        let data = try await fetcher.fetch(urlString: "https://example.test/a.torrent")
        XCTAssertEqual(data, torrent)
    }

    func testHTTPSourceFetchDeadlineEnforced() async {
        // A source that never responds must abort at the deadline. The
        // injected session carries a short request timeout; the fetch maps
        // URLError.timedOut to the typed .deadlineExceeded.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangURLProtocol.self]
        configuration.timeoutIntervalForRequest = 0.2
        configuration.timeoutIntervalForResource = 0.2
        let fetcher = HTTPSourceFetcher(configuration: configuration)
        do {
            _ = try await fetcher.fetch(urlString: "https://example.test/slow.torrent")
            XCTFail("expected deadline enforcement")
        } catch let error as HTTPSourceError {
            XCTAssertEqual(error, .deadlineExceeded)
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

    // MARK: - Duplicate detection across sources

    func testDuplicateMagnetSameHashReturnsExistingRecord() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let hash = "0123456789abcdef0123456789abcdef01234567"

        let first = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(hash)&dn=First")
        let second = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(hash)&dn=Second&tr=udp%3A%2F%2Ft.example%2Fannounce")
        XCTAssertEqual(second, first, "same content hash must map to the same record regardless of dn/tr")

        let other = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "f", count: 40))")
        XCTAssertNotEqual(other, first)
    }

    // MARK: - Start paused vs immediately

    func testCommitAddImmediateStartRuns() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)

        let explicit = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))", startPaused: false)
        let implicit = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))", startPaused: nil)
        let paused = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "c", count: 40))", startPaused: true)

        let snap = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))))
        let byID = Dictionary(uniqueKeysWithValues: snap.torrents.map { ($0.id, $0) })
        XCTAssertEqual(byID[explicit]?.desiredState, .running)
        XCTAssertEqual(byID[implicit]?.desiredState, .running)
        XCTAssertEqual(byID[paused]?.desiredState, .paused)
    }

    // MARK: - File selection round-trip (skip/normal)

    func testFileSelectionPrioritiesRoundTrip() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)

        let torrent = MetainfoBuilder.multiFile(
            files: [("dir/skip.bin", 10), ("dir/norm.bin", 20), ("dir/high.bin", 30)],
            pieceLength: 16, piecesCount: 1, name: "sel"
        )
        let inspection = try await inspect(coordinator, source: .torrentFileData(torrent))
        let commit = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: inspection.operationID)
        ))))
        guard case .commitAdd(let addResult) = commit else { return XCTFail() }

        let selectionResult = try resultPayload(from: await coordinator.processCommand(encode(.setFileSelection(
            SetFileSelectionRequest(
                requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: addResult.recordID,
                selection: [
                    FileSelectionItem(relativePath: "dir/skip.bin", priority: .skip),
                    FileSelectionItem(relativePath: "dir/norm.bin", priority: .normal),
                    FileSelectionItem(relativePath: "dir/high.bin", priority: .normal),
                ],
                expectedRevision: 0
            )
        ))))
        XCTAssertEqual(selectionResult, .ack)

        let dir = try await filesPage(coordinator, recordID: addResult.recordID, cursor: FileCursor(directoryStack: ["dir"]))
        let selection = Dictionary(uniqueKeysWithValues: dir.items.map { ($0.relativePath, $0.selection) })
        XCTAssertEqual(selection["dir/skip.bin"], .skip)
        XCTAssertEqual(selection["dir/norm.bin"], .normal)
        XCTAssertEqual(selection["dir/high.bin"], .normal)
    }

    func testFileSelectionRejectsUnknownPath() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let inspection = try await inspect(coordinator, source: .torrentFileData(
            MetainfoBuilder.multiFile(files: [("dir/a.txt", 10)], pieceLength: 16, piecesCount: 1)
        ))
        let commit = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: inspection.operationID)
        ))))
        guard case .commitAdd(let addResult) = commit else { return XCTFail() }

        let reply = await coordinator.processCommand(encode(.setFileSelection(
            SetFileSelectionRequest(
                requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: addResult.recordID,
                selection: [FileSelectionItem(relativePath: "dir/not-a-file.bin", priority: .skip)],
                expectedRevision: 0
            )
        )))
        guard case .failure(let fault) = decode(IPCEnvelope.self, from: reply).result else {
            return XCTFail("expected fault for unknown selection path")
        }
        XCTAssertEqual(fault.code, .invalidPayload)
    }

    // MARK: - Per-torrent limits and seed goals

    func testTransferLimitsRoundTrip() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let recordID = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))")
        let limits = TorrentinoIPC.TransferLimits(
            maxDownloadBytesPerSec: 2_000,
            maxUploadBytesPerSec: 1_000,
            ratioLimit: 2.5,
            seedTimeSeconds: 3_600
        )
        let result = try resultPayload(from: await coordinator.processCommand(encode(.setLimits(
            SetLimitsRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID, limits: limits)
        ))))
        XCTAssertEqual(result, SuccessPayload.ack)

        let snap = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(
            FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)
        ))))
        XCTAssertEqual(snap.torrents.first?.limits, limits)
    }

    func testUnsupportedEngineOperationRemainsTypedOnWire() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _, _) = try await makeCoordinator(engine: engine, bus: bus)
        let recordID = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "9", count: 40))")
        await engine.setUnsupportedTorrentMutation(true)

        let reply = await coordinator.processCommand(encode(.setLimits(SetLimitsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: recordID,
            limits: TorrentinoIPC.TransferLimits(maxDownloadBytesPerSec: 1024)
        ))))
        guard case .failure(let fault) = decode(IPCEnvelope.self, from: reply).result else {
            return XCTFail("expected typed unsupportedOperation fault")
        }
        XCTAssertEqual(fault.code, EngineErrorCode.unsupportedOperation)
    }

    func testTransferLimitsNegativeBecomeUnlimited() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let recordID = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))")
        _ = try resultPayload(from: await coordinator.processCommand(encode(.setLimits(
            SetLimitsRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                limits: TorrentinoIPC.TransferLimits(
                    maxDownloadBytesPerSec: -1,
                    maxUploadBytesPerSec: nil,
                    ratioLimit: -2,
                    seedTimeSeconds: -10
                )
            )
        ))))

        let snap = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(
            FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)
        ))))
        let normalized = try XCTUnwrap(snap.torrents.first?.limits)
        XCTAssertEqual(normalized.maxDownloadBytesPerSec, 0)
        XCTAssertNil(normalized.maxUploadBytesPerSec)
        XCTAssertEqual(normalized.ratioLimit, 0)
        XCTAssertEqual(normalized.seedTimeSeconds, 0)
    }

    func testSeedGoalsRoundTrip() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let recordID = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "c", count: 40))")
        let goals = TorrentinoIPC.TransferLimits(ratioLimit: 1.25, seedTimeSeconds: 7_200)
        _ = try resultPayload(from: await coordinator.processCommand(encode(.setLimits(
            SetLimitsRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID, limits: goals)
        ))))
        let snap = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(
            FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)
        ))))
        XCTAssertEqual(snap.torrents.first?.limits.ratioLimit, 1.25)
        XCTAssertEqual(snap.torrents.first?.limits.seedTimeSeconds, 7_200)
    }

    // MARK: - Tracker command axes

    func testFetchTrackers() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let recordID = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "d", count: 40))")
        let reply = await coordinator.processCommand(encode(.fetchTrackers(FetchTrackersRequest(
            requestID: RequestID(), recordID: recordID, cursor: nil, pageSize: 50, expectedRevision: 0
        ))))
        guard case .trackers(let page) = try resultPayload(from: reply) else { return XCTFail("expected tracker page") }
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.totalCount, 0)

        let missing = await coordinator.processCommand(encode(.fetchTrackers(FetchTrackersRequest(
            requestID: RequestID(), recordID: TorrentRecordID(rawValue: UUID()), cursor: nil, pageSize: 50, expectedRevision: 0
        ))))
        guard case .failure(let fault) = decode(IPCEnvelope.self, from: missing).result else {
            return XCTFail("missing tracker record must fail")
        }
        XCTAssertEqual(fault.code, .recordNotFound)
    }

    func testEditTrackers() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let recordID = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "e", count: 40))")
        let firstEdit = try resultPayload(from: await coordinator.processCommand(encode(.editTrackers(
            EditTrackersRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                addedURLs: ["udp://one.example/announce", "https://two.example/announce"],
                removedURLs: []
            )
        ))))
        XCTAssertEqual(firstEdit, SuccessPayload.ack)

        let reply = await coordinator.processCommand(encode(.fetchTrackers(FetchTrackersRequest(
            requestID: RequestID(), recordID: recordID, cursor: nil, pageSize: 50, expectedRevision: 1
        ))))
        guard case .trackers(let page) = try resultPayload(from: reply) else { return XCTFail("expected tracker page") }
        XCTAssertEqual(page.items.map(\.url), ["udp://one.example/announce", "https://two.example/announce"])

        let secondEdit = try resultPayload(from: await coordinator.processCommand(encode(.editTrackers(
            EditTrackersRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                addedURLs: [],
                removedURLs: ["udp://one.example/announce"]
            )
        ))))
        XCTAssertEqual(secondEdit, SuccessPayload.ack)
    }

    func testReannounce() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let recordID = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "f", count: 40))")
        let request = ReannounceRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)
        let firstReannounce = try resultPayload(from: await coordinator.processCommand(encode(.reannounce(request))))
        XCTAssertEqual(firstReannounce, SuccessPayload.ack)

        let repeated = await coordinator.processCommand(encode(.reannounce(
            ReannounceRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)
        )))
        guard case .failure(let fault) = decode(IPCEnvelope.self, from: repeated).result else {
            return XCTFail("reannounce must be rate limited")
        }
        XCTAssertEqual(fault.code, .rateLimited)

        let missing = await coordinator.processCommand(encode(.reannounce(
            ReannounceRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: TorrentRecordID(rawValue: UUID()))
        )))
        guard case .failure(let missingFault) = decode(IPCEnvelope.self, from: missing).result else {
            return XCTFail("missing reannounce record must fail")
        }
        XCTAssertEqual(missingFault.code, .recordNotFound)
    }

    // MARK: - Aggregated stats

    func testAggregateStatsAccumulate() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _, engineRef) = try await makeCoordinator(engine: engine, bus: bus)

        let sizes = [1024, 2048, 4096]
        var ids: [TorrentRecordID] = []
        for (index, size) in sizes.enumerated() {
            let inspection = try await inspect(coordinator, source: .torrentFileData(
                MetainfoBuilder.singleFile(name: "agg-\(index).bin", size: Int64(size), pieceLength: 256, piecesCount: 1)
            ))
            let commit = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
                CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: inspection.operationID)
            ))))
            guard case .commitAdd(let addResult) = commit else { return XCTFail() }
            ids.append(addResult.recordID)
        }

        await engineRef.setStatuses([
            TransferTorrentStatus(engineID: "stub-1", progressFraction: 0.5, downloadedBytes: 512, uploadedBytes: 40,
                                  downloadBytesPerSec: 100, uploadBytesPerSec: 5, peersConnected: 3, seedsTotal: 2,
                                  activity: .downloading, health: .healthy, etaSeconds: nil),
            TransferTorrentStatus(engineID: "stub-2", progressFraction: 1.0, downloadedBytes: 2048, uploadedBytes: 200,
                                  downloadBytesPerSec: 0, uploadBytesPerSec: 10, peersConnected: 0, seedsTotal: 1,
                                  activity: .seeding, health: .healthy, etaSeconds: nil),
            TransferTorrentStatus(engineID: "stub-3", progressFraction: 0, downloadedBytes: 0, uploadedBytes: 0,
                                  downloadBytesPerSec: 0, uploadBytesPerSec: 0, peersConnected: 0, seedsTotal: 0,
                                  activity: .idle, health: .healthy, etaSeconds: nil),
        ])
        await coordinator.pumpOnce()

        let stats = await coordinator.aggregateStats()
        XCTAssertEqual(stats.totalCount, 3)
        XCTAssertEqual(stats.activeCount, 2, "downloading + seeding count, paused does not")
        XCTAssertEqual(stats.downloadBytesPerSec, 100)
        XCTAssertEqual(stats.uploadBytesPerSec, 15)
        XCTAssertEqual(stats.totalSizeBytes, 1024 + 2048 + 4096)

        // Live status reached the snapshot through the pump.
        let snap = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))))
        let byID = Dictionary(uniqueKeysWithValues: snap.torrents.map { ($0.id, $0) })
        XCTAssertEqual(byID[ids[0]]?.activity, .downloading)
        XCTAssertEqual(byID[ids[0]]?.rates.downloadBytesPerSec, 100)
        XCTAssertEqual(byID[ids[1]]?.activity, .seeding)
        XCTAssertEqual(byID[ids[2]]?.activity, .idle)
    }

    // MARK: - Error isolation (one torrent's engine failure never blocks others)

    func testEngineAddFailureIsolatesRecord() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _, engineRef) = try await makeCoordinator(engine: engine, bus: bus)

        let hashA = String(repeating: "a", count: 40)
        let hashB = String(repeating: "b", count: 40)
        let hashC = String(repeating: "c", count: 40)

        let idA = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(hashA)")
        await engineRef.failAdds(containing: hashB)
        let idB = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(hashB)")
        let idC = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(hashC)")

        var snap = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))))
        var byID = Dictionary(uniqueKeysWithValues: snap.torrents.map { ($0.id, $0) })
        XCTAssertEqual(byID[idA]?.health, .healthy)
        XCTAssertEqual(byID[idB]?.health, .recoverableError(.engineBusy), "failed add degrades only record B")
        XCTAssertEqual(byID[idC]?.health, .healthy)

        // Other commands keep working while B is degraded.
        _ = try resultPayload(from: await coordinator.processCommand(encode(.pause(
            PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: idA)
        ))))
        _ = try resultPayload(from: await coordinator.processCommand(encode(.resume(
            ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: idC)
        ))))

        // Engine recovers: the next pump re-adds B and heals the record.
        await engineRef.failAdds(containing: nil)
        await coordinator.pumpOnce()
        snap = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))))
        byID = Dictionary(uniqueKeysWithValues: snap.torrents.map { ($0.id, $0) })
        XCTAssertEqual(byID[idB]?.health, .healthy, "pump must re-add and heal the isolated record")
        XCTAssertEqual(byID[idA]?.health, .healthy)
    }

    func testEngineStatusErrorDegradesOnlyThatRecord() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _, engineRef) = try await makeCoordinator(engine: engine, bus: bus)

        let idA = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))")
        let idB = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))")

        await engineRef.setStatuses([
            TransferTorrentStatus(engineID: "stub-1", progressFraction: 0.5, downloadedBytes: 0, uploadedBytes: 0,
                                  downloadBytesPerSec: 10, uploadBytesPerSec: 0, peersConnected: 2, seedsTotal: 1,
                                  activity: .downloading, health: .healthy, etaSeconds: nil),
            TransferTorrentStatus(engineID: "stub-2", progressFraction: 0, downloadedBytes: 0, uploadedBytes: 0,
                                  downloadBytesPerSec: 0, uploadBytesPerSec: 0, peersConnected: 0, seedsTotal: 0,
                                  activity: .idle, health: .recoverableError(.internalError), etaSeconds: nil),
        ])
        await coordinator.pumpOnce()

        let snap = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))))
        let byID = Dictionary(uniqueKeysWithValues: snap.torrents.map { ($0.id, $0) })
        XCTAssertEqual(byID[idA]?.health, .healthy)
        XCTAssertEqual(byID[idB]?.health, .recoverableError(.internalError))
        XCTAssertEqual(byID[idA]?.rates.downloadBytesPerSec, 10, "healthy record keeps live rates")
    }

    // MARK: - Event delta continuity + urgent flush

    func testDeltaContinuityTwoAddsSingleBatch() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 50)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let deliveries = DeliveryCollector()
        await bus.register(deliveries.sink())

        let first = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))")
        let second = try await addMagnet(coordinator, uri: "magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))")

        // Both deltas coalesce into ONE batch with contiguous revisions.
        let events = await deliveries.events(timeoutNanoseconds: 2_000_000_000)
        let deltas = events.compactMap { event -> TorrentDelta? in
            if case .torrentDelta(let payload) = event { return payload.delta }
            return nil
        }
        XCTAssertEqual(deltas.count, 2, "two adds → two contiguous delta events")
        XCTAssertEqual(deltas[0].engineRevision + 1, deltas[1].engineRevision, "delta revisions must be contiguous")
        XCTAssertEqual(deltas[0].added.map(\.id), [first])
        XCTAssertEqual(deltas[1].added.map(\.id), [second])
    }

    func testSnapshotRequiredFlushesImmediately() async throws {
        // 5 s coalescing window; the urgent snapshotRequired must bypass it.
        let bus = TransferEventBus(flushIntervalMilliseconds: 5000)
        let deliveries = DeliveryCollector()
        await bus.register(deliveries.sink())
        await bus.publish([.snapshotRequired(SnapshotRequiredEvent(reason: .droppedDelta, afterRevision: 7))], urgent: true)
        let events = await deliveries.events(timeoutNanoseconds: 2_000_000_000)
        XCTAssertTrue(events.contains { event in
            if case .snapshotRequired(let payload) = event {
                return payload.reason == .droppedDelta && payload.afterRevision == 7
            }
            return false
        }, "urgent snapshotRequired must be delivered before the 5 s window")
    }

    func testEventBusCoalescesBurstIntoOneDelivery() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 50)
        let deliveries = DeliveryCollector()
        await bus.register(deliveries.sink())
        for revision in 1...3 {
            await bus.publish([.torrentDelta(TorrentDeltaEvent(delta: TorrentDelta(added: [], updated: [], removed: [], engineRevision: UInt64(revision))))])
        }
        let events = await deliveries.events(timeoutNanoseconds: 2_000_000_000)
        XCTAssertEqual(events.count, 3, "a burst must coalesce into a single delivery")
    }

    // MARK: - Concurrency stress (shared coordinator state)

    func testConcurrentMixedCommandsAllResolve() async throws {
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, _) = try await makeCoordinator(bus: bus)
        let inspection = try await inspect(coordinator, source: .magnet("magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))"))
        let commit = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: inspection.operationID)
        ))))
        guard case .commitAdd(let addResult) = commit else { return XCTFail() }

        let snapshotRequest = encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))
        let filesRequest = encode(.fetchFiles(FetchFilesRequest(requestID: RequestID(), recordID: addResult.recordID, cursor: nil, pageSize: 10, expectedRevision: 0)))
        let pauseRequest = encode(.pause(PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: addResult.recordID)))

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await coordinator.processCommand(snapshotRequest).isEmpty == false
                }
                group.addTask {
                    await coordinator.processCommand(filesRequest).isEmpty == false
                }
            }
            group.addTask {
                await coordinator.processCommand(pauseRequest).isEmpty == false
            }
            for await resolved in group {
                XCTAssertTrue(resolved, "every concurrent command must resolve to a reply")
            }
        }
        let snap = try snapshot(from: await coordinator.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))))
        XCTAssertEqual(snap.torrents.count, 1)
        XCTAssertEqual(snap.torrents.first?.desiredState, .paused)
    }

    // MARK: - 100-row fixture (restart restore renders all rows)

    func testHundredRowFixtureRestoresAndRenders() async throws {
        let (_, store) = try await makeCoordinator(bus: TransferEventBus(flushIntervalMilliseconds: 0))
        for index in 0..<100 {
            let id = UUID().uuidString
            let metainfo = MetainfoBuilder.singleFile(name: "row-\(index).bin", size: Int64(1024 + index), pieceLength: 256, piecesCount: 1)
            try await store.addTorrent(StoredTorrent(
                id: id,
                infoHashV1: String(format: "%040x", index),
                infoHashV2: nil,
                name: "row-\(index)",
                state: index % 3 == 0 ? "paused" : "running",
                addedAt: Int64(index),
                quarantined: false
            ))
            _ = try await store.storeMetainfo(torrentID: id, data: metainfo)
        }

        // Simulated restart: a fresh coordinator rebuilds from persistence.
        let restarted = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        await restarted.restoreFromPersistence()
        let snap = try snapshot(from: await restarted.processCommand(encode(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)))))
        XCTAssertEqual(snap.torrents.count, 100, "all 100 rows must restore")
        XCTAssertEqual(snap.torrents.first?.displayName, "row-0")
        XCTAssertEqual(snap.torrents.first?.progress.totalBytes, 1024, "metainfo-derived size survives restore")
        let paused = snap.torrents.filter { $0.desiredState == .paused }.count
        XCTAssertEqual(paused, 34)
        let stats = await restarted.aggregateStats()
        XCTAssertEqual(stats.totalCount, 100)
    }

    // MARK: - Helpers

    private func makeCoordinator(engine: StubTransferEngine, bus: TransferEventBus) async throws -> (TransferCoordinator, PersistenceStore, StubTransferEngine) {
        let store = PersistenceStore(dataDirectory: profile.rootURL)
        _ = try await store.open()
        let coordinator = TransferCoordinator(
            engine: engine,
            persistence: store,
            eventBus: bus,
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        return (coordinator, store, engine)
    }

    private func addMagnet(_ coordinator: TransferCoordinator, uri: String, startPaused: Bool? = nil) async throws -> TorrentRecordID {
        let inspection = try await inspect(coordinator, source: .magnet(uri))
        let commit = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), operationID: inspection.operationID, startPaused: startPaused)
        ))))
        guard case .commitAdd(let addResult) = commit else {
            throw NSError(domain: "test", code: 6, userInfo: [NSLocalizedDescriptionKey: "unexpected \(commit)"])
        }
        return addResult.recordID
    }

    /// Launches a 127.0.0.1 loopback HTTP server (python3, ephemeral port)
    /// that serves redirect chains and scheme-reject routes. No external
    /// network is involved. The server is killed by the caller via `defer`.
    private func startRedirectServer() throws -> (port: Int, process: Process) {
        let dir = try profile.subdirectory("redirect-server")
        let scriptURL = dir.appendingPathComponent("server.py")
        let portFile = dir.appendingPathComponent("port.txt")
        let script = """
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class H(BaseHTTPRequestHandler):
            def do_GET(self):
                p = self.path.strip('/').split('/')
                route = p[0]
                if route == 'redir':
                    n = int(p[1])
                    if n > 0:
                        self.send_response(302)
                        self.send_header('Location', '/redir/' + str(n - 1))
                        self.send_header('Content-Length', '0')
                        self.end_headers()
                    else:
                        body = b'd4:infod4:name8:redir.bin6:lengthi1024e12:piece lengthi256e6:pieces20:' + bytes(range(20)) + b'ee'
                        self.send_response(200)
                        self.send_header('Content-Type', 'application/x-bittorrent')
                        self.send_header('Content-Length', str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                elif route == 'ftp':
                    self.send_response(302)
                    self.send_header('Location', 'ftp://127.0.0.1/x')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                else:
                    self.send_response(404)
                    self.end_headers()
            def log_message(self, *args):
                pass
        srv = HTTPServer(('127.0.0.1', 0), H)
        with open('\(portFile.path)', 'w') as f:
            f.write(str(srv.server_address[1]))
        srv.serve_forever()
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]
        try process.run()
        for _ in 0..<100 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8),
               let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (port, process)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.terminate()
        throw NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "redirect server did not start"])
    }

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
    private var settingsHistory: [EngineSettings] = []
    private var appliedLimits: [String: TorrentinoIPC.TransferLimits] = [:]
    private var appliedTrackers: [String: [String]] = [:]
    private var reannouncedIDs: [String] = []
    private var failSettingsApply = false
    private var failTorrentMutation = false
    private var unsupportedTorrentMutation = false
    /// When non-nil, add() throws for every magnet whose URI contains the
    /// marker (per-record engine fault injection).
    private var failAddMarker: String?

    var isStarted: Bool { started }

    func start(configuration: EngineSettings?) async throws {
        started = true
    }

    func apply(settings: EngineSettings) async throws {
        if failSettingsApply { throw EngineStubError.settingsApplyFailed }
        settingsHistory.append(settings)
        started = true
    }

    func setLimits(torrentID: String, limits: TorrentinoIPC.TransferLimits) async throws {
        if unsupportedTorrentMutation {
            throw EngineFault.unsupportedOperation(operation: "stub setLimits")
        }
        if failTorrentMutation { throw EngineStubError.torrentMutationFailed }
        appliedLimits[torrentID] = limits
    }

    func editTrackers(torrentID: String, trackers: [String]) async throws {
        if unsupportedTorrentMutation {
            throw EngineFault.unsupportedOperation(operation: "stub editTrackers")
        }
        if failTorrentMutation { throw EngineStubError.torrentMutationFailed }
        appliedTrackers[torrentID] = trackers
    }

    func reannounce(torrentID: String) async throws {
        if unsupportedTorrentMutation {
            throw EngineFault.unsupportedOperation(operation: "stub reannounce")
        }
        if failTorrentMutation { throw EngineStubError.torrentMutationFailed }
        reannouncedIDs.append(torrentID)
    }

    func setSettingsApplyFailure(_ value: Bool) {
        failSettingsApply = value
    }

    func setUnsupportedTorrentMutation(_ value: Bool) {
        unsupportedTorrentMutation = value
    }

    func settingsApplications() -> [EngineSettings] {
        settingsHistory
    }

    func limits(for torrentID: String) -> TorrentinoIPC.TransferLimits? {
        appliedLimits[torrentID]
    }

    func trackers(for torrentID: String) -> [String]? {
        appliedTrackers[torrentID]
    }

    func reannounceCount(for torrentID: String) -> Int {
        reannouncedIDs.filter { $0 == torrentID }.count
    }

    func failAdds(containing marker: String?) {
        failAddMarker = marker
    }

    func setStatuses(_ statuses: [TransferTorrentStatus]) {
        for status in statuses {
            self.statuses[status.engineID] = status
        }
    }

    func add(specification: AddSpecificationDTO) async throws -> AddResultDTO {
        if let marker = failAddMarker, specification.magnetURI?.contains(marker) == true {
            throw EngineStubError.addFailed
        }
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

private enum EngineStubError: Error {
    case addFailed
    case settingsApplyFailed
    case torrentMutationFailed
}

// MARK: - URLProtocol stub

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseData: Data = Data()
    nonisolated(unsafe) private static var contentType: String? = "application/octet-stream"
    nonisolated(unsafe) private static var status: Int = 200

    static func install(response: Data, contentType: String?, status: Int) {
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
        let headers = contentType.map { ["Content-Type": $0] }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status >= 200 && status < 300 {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Hang stub (never responds → deadline enforcement)

private final class HangURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Intentionally never deliver a response.
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
