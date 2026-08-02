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
}
