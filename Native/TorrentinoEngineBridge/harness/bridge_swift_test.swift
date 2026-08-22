// Torrentino bridge — Swift-side end-to-end test driver (WP-04).
//
// Role:    proves the EngineCoordinator → EngineBridgeAdapter → EngineBridge
//          path through real Swift, ObjC++ and C++ code: start (peer-id from
//          config), add (magnet), pause/resume/recheck with the torrent id, and
//          the not-found error path for an unknown id. Exit 0 only on success.
// Must not: touch the network (loopback engine, magnet metadata is never
//          fetched — only synchronous handle operations are exercised), fake
//          results, or exit 0 when any assertion fails.
// Invariants: runs as a @main async driver; every coordinator call is awaited;
//          failures throw (or fatalError) instead of being swallowed.

import Foundation
import TorrentinoIPC

@main
struct BridgeSwiftTest {
    static func main() async {
        // Isolated workspace so the engine never touches user data.
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("torrentino-bridge-swift-test")
        try? FileManager.default.removeItem(atPath: tmp)
        try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)

        let coordinator = EngineCoordinator()
        do {
            // --- start: boot report must reflect the CONFIGURED peer-id prefix
            let config = SessionConfigurationDTO(peerIDPrefix: "-TT9001-")
            let boot = try await coordinator.start(configuration: config)
            guard boot.peerID == "-TT9001-" else {
                fatalError("boot peer-id must come from config, got '\(boot.peerID)'")
            }
            guard boot.listenPort > 0 else {
                fatalError("boot report must carry a bound port")
            }

            // --- add a magnet (handle exists immediately; metadata is never
            // fetched — the test only exercises synchronous handle operations)
            let magnet = "magnet:?xt=urn:btih:0a0b0c0d0e0f101112131415161718191a1b1c1d&dn=swift-test"
            let spec = AddSpecificationDTO(magnetURI: magnet, savePath: tmp)
            let added = try await coordinator.add(specification: spec)
            guard !added.torrentID.isEmpty else {
                fatalError("add must return a torrent id")
            }
            let torrentID = added.torrentID

            // --- pause/resume/recheck must reach the ENGINE with the id:
            // with the payload bug these returned notFound (empty torrent-id).
            try await coordinator.pause(torrentID: torrentID)
            try await coordinator.resume(torrentID: torrentID)
            try await coordinator.recheck(torrentID: torrentID)

            // --- per-torrent limits: real Swift -> ObjC++ -> C++ path --------
            try await coordinator.setLimits(
                torrentID: torrentID,
                limits: TorrentinoIPC.TransferLimits(maxDownloadBytesPerSec: 8192, maxUploadBytesPerSec: 4096)
            )

            do {
                try await coordinator.setLimits(
                    torrentID: torrentID,
                    limits: TorrentinoIPC.TransferLimits(ratioLimit: 1.5)
                )
                fatalError("positive ratio goal must throw unsupportedOperation")
            } catch EngineCoordinatorError.unsupportedOperation {
                // Expected: this capability is not exposed by the pinned ABI.
            }

            do {
                try await coordinator.setLimits(
                    torrentID: torrentID,
                    limits: TorrentinoIPC.TransferLimits(seedTimeSeconds: 3600)
                )
                fatalError("positive seed-time goal must throw unsupportedOperation")
            } catch EngineCoordinatorError.unsupportedOperation {
                // Expected: this capability is not exposed by the pinned ABI.
            }

            do {
                try await coordinator.setLimits(
                    torrentID: torrentID,
                    limits: TorrentinoIPC.TransferLimits(maxDownloadBytesPerSec: -1)
                )
                fatalError("negative bandwidth limit must throw invalidArgument")
            } catch EngineCoordinatorError.invalidArgument {
                // Expected: invalid values stay invalid at the native boundary.
            }

            // --- trackers: structured [[String]] topology replacement, explicit
            // empty list and reannounce (ADR-017; scalar edit is reject-only).
            try await coordinator.editTrackers(
                torrentID: torrentID,
                trackerTiers: [["udp://127.0.0.1:1/announce", "https://127.0.0.1/announce"]]
            )
            try await coordinator.editTrackers(torrentID: torrentID, trackerTiers: [])
            try await coordinator.reannounce(torrentID: torrentID)

            do {
                try await coordinator.editTrackers(torrentID: torrentID, trackerTiers: [["not-a-tracker-url"]])
                fatalError("malformed tracker URL must throw malformedPayload")
            } catch EngineCoordinatorError.malformedPayload {
                // Expected: topology validation is fail-closed before the adapter.
            }

            do {
                try await coordinator.editTrackers(torrentID: torrentID, trackers: ["udp://127.0.0.1:1/announce"])
                try await coordinator.editTrackers(torrentID: torrentID, trackers: [])
                fatalError("scalar tracker edit must be rejected")
            } catch EngineCoordinatorError.malformedPayload {
                // Expected: ADR-017 scalar edits — including the empty list —
                // are reject-only; explicit empty replacement is trackerTiers: [].
            }

            // The structured contract is exercised over the adapter's JSON
            // boundary directly: non-array/non-string tiers and the legacy
            // scalar surface must all map to invalidArgument.
            let adapter = TorrentinoEngineBridgeAdapter()
            let nonArrayTiers = Data(#"{"torrent-id":"ignored","tracker-tiers":{}}"#.utf8)
            do {
                _ = try adapter.editTrackers(withPayloadData: nonArrayTiers)
                fatalError("non-array tracker payload must throw invalidArgument")
            } catch let error as NSError {
                guard error.code == 5 else {
                    fatalError("non-array tracker payload returned unexpected error: \(error.code)")
                }
            }
            let malformedTiers = Data(#"{"torrent-id":"ignored","tracker-tiers":[["udp://127.0.0.1:1/announce",7]]}"#.utf8)
            do {
                _ = try adapter.editTrackers(withPayloadData: malformedTiers)
                fatalError("non-string tracker payload element must throw invalidArgument")
            } catch let error as NSError {
                guard error.code == 5 else {
                    fatalError("malformed tracker payload returned unexpected error: \(error.code)")
                }
            }
            let scalarPayload = Data(#"{"torrent-id":"ignored","trackers":["udp://127.0.0.1:1/announce"]}"#.utf8)
            do {
                _ = try adapter.editTrackers(withPayloadData: scalarPayload)
                fatalError("scalar trackers payload must throw invalidArgument")
            } catch let error as NSError {
                guard error.code == 5 else {
                    fatalError("scalar trackers payload returned unexpected error: \(error.code)")
                }
            }

            // --- IPC/agent boundary over the same real bridge ---------------
            // This keeps the unsupported and invalid mappings honest at the
            // command result boundary instead of proving them only in C++.
            let agentRoot = URL(fileURLWithPath: tmp).appendingPathComponent("agent-state", isDirectory: true)
            let store = PersistenceStore(dataDirectory: agentRoot)
            _ = try await store.open()
            let agentBridgeCoordinator = EngineCoordinator()
            let agentEngine = BridgeTransferEngine(coordinator: agentBridgeCoordinator)
            let agent = TransferCoordinator(
                engine: agentEngine,
                persistence: store,
                eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
                agentVersion: "swift-bridge-test",
                defaultSaveLocation: PersistedLocation(path: agentRoot.path),
                pumpIntervalNanoseconds: nil
            )
            let agentRecordID = try await Self.addMagnet(
                to: agent,
                uri: "magnet:?xt=urn:btih:1111111111111111111111111111111111111111"
            )

            let agentBandwidth = await agent.processCommand(Self.encode(.setLimits(SetLimitsRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: agentRecordID,
                limits: TorrentinoIPC.TransferLimits(maxDownloadBytesPerSec: 4096)
            ))))
            guard case .success(.ack) = Self.decode(agentBandwidth).result else {
                fatalError("real bandwidth setLimits must succeed at the IPC boundary")
            }

            let beforeNativeInvalid = try Self.snapshot(from: await agent.processCommand(Self.encode(.fetchSnapshot(
                FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)
            ))))
            guard let beforeNativeTorrent = beforeNativeInvalid.torrents.first else {
                fatalError("native invalid-limit test requires the added record in the snapshot")
            }
            let nativeEngineID = String(repeating: "1", count: 40)
            let appliedBeforeNativeInvalid = try await agentBridgeCoordinator.currentLimits(torrentID: nativeEngineID)
            guard appliedBeforeNativeInvalid.maxDownloadBytesPerSec == 4096,
                  appliedBeforeNativeInvalid.maxUploadBytesPerSec == 0 else {
                fatalError("native engine limits did not reflect the accepted bandwidth request: \(appliedBeforeNativeInvalid)")
            }

            let agentRatio = await agent.processCommand(Self.encode(.setLimits(SetLimitsRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: agentRecordID,
                limits: TorrentinoIPC.TransferLimits(ratioLimit: 1.25)
            ))))
            guard case .failure(let ratioFault) = Self.decode(agentRatio).result,
                  ratioFault.code == .unsupportedOperation else {
                fatalError("real ratio rejection must remain unsupportedOperation at IPC")
            }

            let agentSeed = await agent.processCommand(Self.encode(.setLimits(SetLimitsRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: agentRecordID,
                limits: TorrentinoIPC.TransferLimits(seedTimeSeconds: 3600)
            ))))
            guard case .failure(let seedFault) = Self.decode(agentSeed).result,
                  seedFault.code == .unsupportedOperation else {
                fatalError("real seed-time rejection must remain unsupportedOperation at IPC")
            }

            let agentInvalid = await agent.processCommand(Self.encode(.setLimits(SetLimitsRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: agentRecordID,
                // Swift permits non-negative seed goals; this value is
                // rejected only by the native signed-range check.
                limits: TorrentinoIPC.TransferLimits(seedTimeSeconds: Int64.max)
            ))))
            guard case .failure(let invalidFault) = Self.decode(agentInvalid).result,
                   invalidFault.code == .invalidArgument else {
                fatalError("native invalid limit rejection must remain invalidArgument at IPC")
            }

            let afterNativeInvalid = try Self.snapshot(from: await agent.processCommand(Self.encode(.fetchSnapshot(
                FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)
            ))))
            guard afterNativeInvalid == beforeNativeInvalid,
                  afterNativeInvalid.torrents.first?.revision == beforeNativeTorrent.revision,
                  afterNativeInvalid.torrents.first?.limits == beforeNativeTorrent.limits else {
                fatalError("native invalid limit must not change snapshot or record revision")
            }
            let appliedAfterNativeInvalid = try await agentBridgeCoordinator.currentLimits(torrentID: nativeEngineID)
            guard appliedAfterNativeInvalid == appliedBeforeNativeInvalid else {
                fatalError("native invalid limit must not change engine-applied limits")
            }
            let persistedAfterNativeInvalid = try await store.torrentLimits(
                torrentID: agentRecordID.rawValue.uuidString
            )
            guard persistedAfterNativeInvalid == beforeNativeTorrent.limits else {
                fatalError("native invalid limit must not change persisted limits")
            }

            // The magnet fixture carries no metainfo, so ADR-017 admission
            // fails closed at the IPC boundary: structured edits require a
            // metainfo-backed record, and scalar delta fields are rejected.
            let agentTrackers = await agent.processCommand(Self.encode(.editTrackers(EditTrackersRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: agentRecordID,
                addedURLs: [],
                removedURLs: [],
                trackerTiers: [["udp://127.0.0.1:1/announce"]]
            ))))
            guard case .failure(let metainfoFault) = Self.decode(agentTrackers).result,
                  metainfoFault.code == .invalidPayload else {
                fatalError("structured tracker edit on a metainfo-less record must fail closed: \(String(describing: Self.decode(agentTrackers).result))")
            }
            let agentEmptyTrackers = await agent.processCommand(Self.encode(.editTrackers(EditTrackersRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: agentRecordID,
                addedURLs: [],
                removedURLs: [],
                trackerTiers: []
            ))))
            guard case .failure(let emptyFault) = Self.decode(agentEmptyTrackers).result,
                  emptyFault.code == .invalidPayload else {
                fatalError("empty tracker edit on a metainfo-less record must fail closed: \(String(describing: Self.decode(agentEmptyTrackers).result))")
            }
            let agentMixedTrackers = await agent.processCommand(Self.encode(.editTrackers(EditTrackersRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: agentRecordID,
                addedURLs: ["udp://127.0.0.1:1/announce"],
                removedURLs: [],
                trackerTiers: [["udp://127.0.0.1:1/announce"]]
            ))))
            guard case .failure(let mixedFault) = Self.decode(agentMixedTrackers).result,
                  mixedFault.code == .invalidPayload else {
                fatalError("scalar delta fields must remain rejected at IPC: \(String(describing: Self.decode(agentMixedTrackers).result))")
            }
            let agentReannounce = await agent.processCommand(Self.encode(.reannounce(ReannounceRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: agentRecordID
            ))))
            guard case .success(.ack) = Self.decode(agentReannounce).result else {
                fatalError("real reannounce must succeed at IPC")
            }

            // --- SEC-1 credential delivery (WP13-SEC-HARDEN-001): the full
            // real chain applySettings(proxyPassword) -> TransferCoordinator
            // -> BridgeTransferEngine -> EngineCoordinator.sessionConfiguration
            // (DTO boundary) -> adapter JSON -> EngineBridge make_settings ->
            // live libtorrent session. The authenticated-proxy apply must
            // succeed, the credential must be held in memory afterwards, and
            // the persisted settings row must stay credential-free.
            let boundarySettings = EngineSettings(
                downloadDirectory: agentRoot.path,
                maxDownloadBytesPerSec: 0,
                maxUploadBytesPerSec: 0,
                listenPort: 6889,
                dhtEnabled: false,
                lsdEnabled: false,
                upnpEnabled: false,
                natPmpEnabled: false,
                encryptionEnabled: true,
                proxy: ProxyConfiguration(kind: .http, host: "boundary.proxy", port: 3128, username: "b-user", password: "Boundary_PW_44")
            )
            let boundaryDTO = EngineCoordinator.sessionConfiguration(for: boundarySettings)
            guard boundaryDTO.proxy.username == "b-user",
                  boundaryDTO.proxy.password == "Boundary_PW_44" else {
                fatalError("sessionConfiguration must forward the credential across the DTO boundary")
            }

            let deliveryCandidate = EngineSettings(
                downloadDirectory: agentRoot.path,
                maxDownloadBytesPerSec: 0,
                maxUploadBytesPerSec: 0,
                listenPort: 49_150,
                dhtEnabled: false,
                lsdEnabled: false,
                upnpEnabled: false,
                natPmpEnabled: false,
                encryptionEnabled: true,
                proxy: ProxyConfiguration(kind: .socks5, host: "127.0.0.1", port: 59999, username: "bridge-test-user")
            )
            let deliverySecret = "bridge-delivered-pw-sec1"
            let deliveryReply = Self.decode(await agent.processCommand(Self.encode(.applySettings(ApplySettingsRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                candidate: deliveryCandidate,
                expectedRevision: nil,
                proxyPassword: deliverySecret
            )))))
            guard case .success(.settingsApply) = deliveryReply.result else {
                fatalError("real authenticated-proxy applySettings must succeed through the bridge: \(String(describing: deliveryReply.result))")
            }

            let deliveryFetch = Self.decode(await agent.processCommand(Self.encode(.fetchSettings(
                FetchSettingsRequest(requestID: RequestID())
            ))))
            guard case .success(.settingsFetch(let deliverySettings)) = deliveryFetch.result,
                  deliverySettings.settings.proxy.password == deliverySecret else {
                fatalError("delivered credential must be held in memory after the real apply: \(String(describing: deliveryFetch.result))")
            }
            let deliveryRow = try await store.sessionValue(key: "engine_settings")
            if let row = deliveryRow, String(decoding: row.data, as: UTF8.self).contains(deliverySecret) {
                fatalError("delivered credential reached the persisted settings row")
            }
            await agentBridgeCoordinator.shutdown()
            try await store.close(clean: true)

            // --- negative: an unknown id must surface notFound, proving the
            // id (not a hardcoded empty payload) reaches the engine.
            do {
                try await coordinator.pause(torrentID: String(repeating: "0", count: 64))
                fatalError("pause of an unknown id must throw notFound")
            } catch EngineCoordinatorError.notFound {
                // expected: id round-tripped to the engine and was rejected
            }

            // --- health: engine still running with one torrent
            let health = try await coordinator.health()
            guard health.running, health.activeTorrents == 1 else {
                fatalError("health must report running engine with one torrent")
            }

            await coordinator.shutdown()
            try? FileManager.default.removeItem(atPath: tmp)
            print("bridge swift test: PASS")
        } catch {
            fatalError("bridge swift test: FAIL: \(error)")
        }
    }

    private static func addMagnet(to coordinator: TransferCoordinator, uri: String) async throws -> TorrentRecordID {
        let inspectionReply = await coordinator.processCommand(Self.encode(.inspectAddSource(
            InspectAddSourceRequest(requestID: RequestID(), source: .magnet(uri))
        )))
        guard case .success(.addSourceInspection(let inspection)) = Self.decode(inspectionReply).result else {
            throw NSError(domain: "torrentino.bridge.swift-test", code: 1)
        }
        let commitReply = await coordinator.processCommand(Self.encode(.commitAdd(CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID
        ))))
        guard case .success(.commitAdd(let result)) = Self.decode(commitReply).result else {
            throw NSError(domain: "torrentino.bridge.swift-test", code: 2)
        }
        return result.recordID
    }

    private static func encode(_ command: EngineCommandV1) -> Data {
        do {
            return try JSONEncoder().encode(IPCEnvelope.request(command))
        } catch {
            fatalError("bridge swift test command encoding failed: \(error)")
        }
    }

    private static func decode(_ data: Data) -> IPCEnvelope {
        do {
            return try JSONDecoder().decode(IPCEnvelope.self, from: data)
        } catch {
            fatalError("bridge swift test reply decoding failed: \(error)")
        }
    }

    private static func snapshot(from data: Data) throws -> EngineSnapshot {
        let envelope = decode(data)
        guard case .success(.snapshot(let snapshot)) = envelope.result else {
            throw NSError(domain: "torrentino.bridge.swift-test", code: 3)
        }
        return snapshot
    }
}
