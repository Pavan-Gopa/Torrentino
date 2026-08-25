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
            try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)
            let store = PersistenceStore(dataDirectory: agentRoot)
            _ = try await store.open()
            let agentBridgeCoordinator = EngineCoordinator()
            _ = try await agentBridgeCoordinator.start(configuration: config)
            let agentEngine = BridgeTransferEngine(coordinator: agentBridgeCoordinator)
            let agent = TransferCoordinator(
                engine: agentEngine,
                persistence: store,
                eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
                agentVersion: "swift-bridge-test",
                defaultSaveLocation: PersistedLocation(path: agentRoot.path),
                pumpIntervalNanoseconds: nil
            )
            let agentTorrentData = makeMultiFileSelectionTorrent(name: "agent-ipc-test")
            let agentRecordID = try await Self.commitRecord(
                to: agent,
                source: .torrentFileData(agentTorrentData)
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
            guard let beforeNativeTorrent = beforeNativeInvalid.torrents.first,
                  let infoHashV1 = beforeNativeTorrent.contentIdentity?.infoHashV1 else {
                fatalError("native invalid-limit test requires the added record in the snapshot")
            }
            let nativeEngineID = infoHashV1.map { String(format: "%02x", $0) }.joined()
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

            // A record without metainfo bytes (e.g. magnet restored from store before metainfo download)
            // fails closed at the IPC boundary for structured tracker edits.
            let metainfoLessID = TorrentRecordID(rawValue: UUID())
            try await store.addTorrent(StoredTorrent(
                id: metainfoLessID.rawValue.uuidString,
                infoHashV1: "1111111111111111111111111111111111111111",
                infoHashV2: nil,
                name: "metainfo-less-test",
                state: "running",
                addedAt: Int64(Date().timeIntervalSince1970),
                quarantined: false
            ))
            _ = await agent.restoreFromPersistence()

            let agentTrackers = await agent.processCommand(Self.encode(.editTrackers(EditTrackersRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: metainfoLessID,
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
                recordID: metainfoLessID,
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
                recordID: metainfoLessID,
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

            // --- WP22.D5 / ADR-022: durable file selection reaches libtorrent
            // through the full production chain: IPC command ->
            // TransferCoordinator (engine-first barrier) -> BridgeTransferEngine
            // -> EngineCoordinator.setFilePriorities -> ObjC++ adapter ->
            // EngineBridge prioritize_files + bounded exact read-back.
            let selectionTorrent = makeMultiFileSelectionTorrent()
            let selectionRecordID = try await Self.commitRecord(
                to: agent,
                source: .torrentFileData(selectionTorrent)
            )
            let selectionReply = Self.decode(await agent.processCommand(Self.encode(.setFileSelection(
                SetFileSelectionRequest(
                    requestID: RequestID(),
                    idempotencyKey: IdempotencyKey(),
                    recordID: selectionRecordID,
                    selection: [
                        FileSelectionItem(relativePath: "dir/a.txt", priority: .normal),
                        FileSelectionItem(relativePath: "dir/b.bin", priority: .skip),
                        FileSelectionItem(relativePath: "dir/c.bin", priority: .normal),
                    ],
                    expectedRevision: 0
                )
            ))))
            guard case .success(.ack) = selectionReply.result else {
                fatalError("real file selection must pass the native priority barrier: \(String(describing: selectionReply.result))")
            }

            // An unknown engine id fails closed at the same native boundary.
            do {
                try await agentBridgeCoordinator.setFilePriorities(
                    torrentID: String(repeating: "e", count: 40),
                    priorities: [4, 0, 4]
                )
                fatalError("file priorities for an unknown engine id must throw notFound")
            } catch EngineCoordinatorError.notFound {
                // expected: the vector round-tripped to the engine and was rejected
            }

            // Malformed priority payloads are rejected at the ObjC++ boundary
            // before any engine state can move.
            let malformedPriorities: [(label: String, payload: String)] = [
                ("non-array", #"{"torrent-id":"ignored","priorities":4}"#),
                ("non-integer entry", #"{"torrent-id":"ignored","priorities":[4,"0"]}"#),
                ("out-of-range entry", #"{"torrent-id":"ignored","priorities":[4,300]}"#),
                ("empty vector", #"{"torrent-id":"ignored","priorities":[]}"#),
            ]
            for malformedPriority in malformedPriorities {
                do {
                    _ = try adapter.setFilePrioritiesWithPayloadData(Data(malformedPriority.payload.utf8))
                    fatalError("\(malformedPriority.label) priorities payload must throw invalidArgument")
                } catch let error as NSError {
                    guard error.code == 5 else {
                        fatalError("\(malformedPriority.label) priorities payload returned unexpected error: \(error.code)")
                    }
                }
            }

            // --- WP22.D7 / ADR-022: kebab-case metadata-only add and guarded
            // commit across the real Swift -> ObjC++ -> C++ chain.
            let uploadModeFlag: Int64 = 1 << 1   // torrent_flags::upload_mode
            let pausedFlag: Int64 = 1 << 4       // torrent_flags::paused
            let autoManagedFlag: Int64 = 1 << 5  // torrent_flags::auto_managed
            func latestFlags(for id: String) async throws -> Int64? {
                var flags: Int64?
                for alert in try await coordinator.drainAlerts(maxCount: 200) where alert.torrentID == id {
                    if alert.flags >= 0 { flags = alert.flags }
                }
                return flags
            }

            // The DTO must encode the frozen kebab-case wire key.
            let metaWireJSON = String(decoding: try JSONEncoder().encode(
                AddSpecificationDTO(magnetURI: "magnet:?xt=urn:btih:2222222222222222222222222222222222222222",
                                    savePath: tmp, metadataOnly: true)
            ), as: UTF8.self)
            guard metaWireJSON.contains("\"metadata-only\":true") else {
                fatalError("metadata-only must travel under the frozen kebab-case key: \(metaWireJSON)")
            }

            // A raw magnet with unknown metainfo: added UNPAUSED with the
            // guard set; premature commit fails closed; removal cleans it up.
            let metaAdded = try await coordinator.add(specification: AddSpecificationDTO(
                magnetURI: "magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98&dn=wp22-d7-meta",
                savePath: tmp, metadataOnly: true))
            guard !metaAdded.torrentID.isEmpty else {
                fatalError("metadata-only magnet add must return a torrent id")
            }
            guard let metaPreFlags = try await latestFlags(for: metaAdded.torrentID) else {
                fatalError("alert sample must carry native flags")
            }
            guard metaPreFlags & uploadModeFlag != 0 else {
                fatalError("upload_mode guard must be set before commit")
            }
            guard metaPreFlags & autoManagedFlag == 0, metaPreFlags & pausedFlag == 0 else {
                fatalError("metadata retrieval must run unpaused and not auto-managed")
            }

            do {
                try await coordinator.commitMetadataOnly(
                    torrentID: metaAdded.torrentID, priorities: [4], paused: false)
                fatalError("premature commit without metainfo must fail closed")
            } catch EngineCoordinatorError.invalidArgument {
                // expected: typed failure, guard kept
            }
            guard let metaKeptFlags = try await latestFlags(for: metaAdded.torrentID),
                  metaKeptFlags & uploadModeFlag != 0 else {
                fatalError("a failed commit must keep upload_mode set")
            }
            let metaToken = try await coordinator.prepareRemoval(torrentID: metaAdded.torrentID)
            _ = try await coordinator.commitRemoval(token: metaToken)

            // Multi-file metainfo added metadata-only, then the guarded
            // [4,0,4] paused commit releases the guard last.
            let metaMultiAdded = try await coordinator.add(specification: AddSpecificationDTO(
                torrentFile: makeMultiFileSelectionTorrent(), savePath: tmp, metadataOnly: true))
            guard let multiPreFlags = try await latestFlags(for: metaMultiAdded.torrentID),
                  multiPreFlags & uploadModeFlag != 0 else {
                fatalError("metadata-only .torrent add must carry the upload_mode guard")
            }
            try await coordinator.commitMetadataOnly(
                torrentID: metaMultiAdded.torrentID, priorities: [4, 0, 4], paused: true)
            guard let multiPostFlags = try await latestFlags(for: metaMultiAdded.torrentID) else {
                fatalError("post-commit flag sample missing")
            }
            guard multiPostFlags & uploadModeFlag == 0 else {
                fatalError("guarded commit must clear upload_mode only after the exact read-back")
            }
            guard multiPostFlags & pausedFlag != 0 else {
                fatalError("guarded commit must apply the requested paused state")
            }
            guard !FileManager.default.fileExists(atPath: tmp.appending("/wp22-selection/dir/b.bin")) else {
                fatalError("skipped file must remain unallocated after commit")
            }

            // The successful running branch is a distinct D7 contract: an
            // add-time paused request is ignored while guarded, then paused=false
            // is applied before upload_mode is released.
            let runningFixtureName = "wp22-selection-running"
            let metaRunningAdded = try await coordinator.add(specification: AddSpecificationDTO(
                torrentFile: makeMultiFileSelectionTorrent(name: runningFixtureName),
                savePath: tmp,
                paused: true,
                metadataOnly: true))
            guard let runningPreFlags = try await latestFlags(for: metaRunningAdded.torrentID),
                  runningPreFlags & uploadModeFlag != 0,
                  runningPreFlags & autoManagedFlag == 0,
                  runningPreFlags & pausedFlag == 0 else {
                fatalError("guarded metadata retrieval must override add-time paused and auto-managed state")
            }
            try await coordinator.commitMetadataOnly(
                torrentID: metaRunningAdded.torrentID, priorities: [4, 0, 4], paused: false)
            guard let runningPostFlags = try await latestFlags(for: metaRunningAdded.torrentID),
                  runningPostFlags & uploadModeFlag == 0,
                  runningPostFlags & pausedFlag == 0 else {
                fatalError("guarded commit must apply running state before releasing upload_mode")
            }
            guard !FileManager.default.fileExists(
                atPath: tmp.appending("/\(runningFixtureName)/dir/b.bin")) else {
                fatalError("running commit must not allocate the skipped file")
            }
            let metaRunningToken = try await coordinator.prepareRemoval(
                torrentID: metaRunningAdded.torrentID)
            _ = try await coordinator.commitRemoval(token: metaRunningToken)
            do {
                try await coordinator.commitMetadataOnly(
                    torrentID: metaRunningAdded.torrentID, priorities: [4, 0, 4], paused: false)
                fatalError("removed temporary handle must not remain committable")
            } catch EngineCoordinatorError.notFound {
                // expected: removal drops temporary metadata-only tracking
            }

            // A normal durable handle never passes the temporary-tracking check.
            do {
                try await coordinator.commitMetadataOnly(
                    torrentID: torrentID, priorities: [4], paused: true)
                fatalError("commit on a normal handle must be rejected")
            } catch EngineCoordinatorError.notFound {
                // expected
            }

            // Malformed commit payloads fail closed at the ObjC++ boundary.
            let malformedCommits: [(label: String, payload: String)] = [
                ("non-array", #"{"torrent-id":"ignored","priorities":4,"paused":true}"#),
                ("non-integer entry", #"{"torrent-id":"ignored","priorities":[4,"0"],"paused":true}"#),
                ("out-of-range entry", #"{"torrent-id":"ignored","priorities":[4,300],"paused":true}"#),
                ("empty vector", #"{"torrent-id":"ignored","priorities":[],"paused":true}"#),
            ]
            for malformedCommit in malformedCommits {
                do {
                    _ = try adapter.commitMetadataOnly(withPayloadData: Data(malformedCommit.payload.utf8))
                    fatalError("\(malformedCommit.label) commit payload must throw invalidArgument")
                } catch let error as NSError {
                    guard error.code == 5 else {
                        fatalError("\(malformedCommit.label) commit payload returned unexpected error: \(error.code)")
                    }
                }
            }

            // Removing the promoted torrent keeps the final health invariant
            // intact (one torrent left on this coordinator).
            let metaMultiToken = try await coordinator.prepareRemoval(torrentID: metaMultiAdded.torrentID)
            _ = try await coordinator.commitRemoval(token: metaMultiToken)

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
        try await Self.commitRecord(to: coordinator, source: .magnet(uri))
    }

    /// Inspects and commits any source (.torrent bytes or magnet URI),
    /// returning the durable record id.
    private static func commitRecord(to coordinator: TransferCoordinator, source: AddSource) async throws -> TorrentRecordID {
        let inspectionReply = await coordinator.processCommand(Self.encode(.inspectAddSource(
            InspectAddSourceRequest(requestID: RequestID(), source: source)
        )))
        guard case .success(.addSourceInspection(let inspection)) = Self.decode(inspectionReply).result else {
            throw NSError(domain: "torrentino.bridge.swift-test", code: 1)
        }
        var opID = inspection.operationID
        if inspection.phase == .retrievingMetadata {
            let pollReply = await coordinator.processCommand(Self.encode(.pollAddOperation(
                PollAddOperationRequest(requestID: RequestID(), operationID: inspection.operationID)
            )))
            guard case .success(.pollAddOperation(let pollResult)) = Self.decode(pollReply).result else {
                throw NSError(domain: "torrentino.bridge.swift-test", code: 3)
            }
            opID = pollResult.inspection?.operationID ?? inspection.operationID
        }
        let commitReply = await coordinator.processCommand(Self.encode(.commitAdd(CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: opID
        ))))
        let commitResult = Self.decode(commitReply).result
        guard case .success(.commitAdd(let result)) = commitResult else {
            fatalError("commitAdd failed in commitRecord with \(String(describing: commitResult))")
        }
        return result.recordID
    }

    // ponytail: local fixture writer duplicates the test-target MetainfoBuilder
    // because NegativeCorpus.swift is not part of this harness's compiled
    // sources; upgrade when the harness build list includes it.
    private enum FixtureBencode {
        static func string(_ value: String) -> Data {
            let utf8 = Data(value.utf8)
            return Data("\(utf8.count):".utf8) + utf8
        }

        static func integer(_ value: Int64) -> Data {
            Data("i\(value)e".utf8)
        }

        static func bytes(_ value: Data) -> Data {
            Data("\(value.count):".utf8) + value
        }

        static func list(_ items: [Data]) -> Data {
            Data("l".utf8) + items.reduce(Data(), +) + Data("e".utf8)
        }

        static func dictionary(_ entries: [(String, Data)]) -> Data {
            var data = Data("d".utf8)
            for (key, value) in entries.sorted(by: { $0.0 < $1.0 }) {
                data += string(key)
                data += value
            }
            return data + Data("e".utf8)
        }
    }

    /// Deterministic three-file v1 metainfo (dir/a.txt, dir/b.bin, dir/c.bin)
    /// with syntactically valid placeholder piece hashes; the priority barrier
    /// never downloads payload, so no real hashing is required here.
    private static func makeMultiFileSelectionTorrent(name: String = "wp22-selection") -> Data {
        let files: [(path: String, size: Int64)] = [
            ("dir/a.txt", 100), ("dir/b.bin", 200), ("dir/c.bin", 300),
        ]
        let entries = files.map { file in
            FixtureBencode.dictionary([
                ("length", FixtureBencode.integer(file.size)),
                ("path", FixtureBencode.list(file.path.split(separator: "/").map { FixtureBencode.string(String($0)) })),
            ])
        }
        let info = FixtureBencode.dictionary([
            ("files", FixtureBencode.list(entries)),
            ("name", FixtureBencode.string(name)),
            ("piece length", FixtureBencode.integer(256)),
            ("pieces", FixtureBencode.bytes(Data((0..<60).map { UInt8($0 % 251) }))),
        ])
        return FixtureBencode.dictionary([
            ("announce", FixtureBencode.string("udp://tracker.example:80/announce")),
            ("info", info),
        ])
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
