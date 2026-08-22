// Layer: Unit tests (WP-18 Finder Services).
// Role: validate the declared Services record and the pasteboard-to-pending-path
// route without starting the engine or touching production storage.

import XCTest
import AppKit
import Foundation

// TorrentinoAppTests is a standalone unit-test bundle. AppDelegate.swift is
// included only to exercise its internal service router, so provide the small
// lifecycle collaborators that the delegate references without booting the app.
@MainActor
final class EngineViewModel {
    let client: EngineClient

    init(client: EngineClient) {
        self.client = client
    }

    func prepareForLaunch() async {}
    func appendLog(_ message: String) {}
}


@MainActor
enum AppContext {
    private static let engineClient = EngineClient()
    static let shared = EngineViewModel(client: engineClient)
    static let transfers = TorrentListViewModel(client: engineClient)
}


enum AppLogo {
    static var image: NSImage { NSImage(size: NSSize(width: 1, height: 1)) }
}

@MainActor
final class WP18FinderServicesTests: XCTestCase {
    func testAppInfoPlistDeclaresFinderCreateService() throws {
        let infoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TorrentinoApp/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: infoURL) as? [String: Any])
        let services = try XCTUnwrap(info["NSServices"] as? [[String: Any]])
        let service = try XCTUnwrap(
            services.first { ($0["NSMessage"] as? String) == "createTorrent" }
        )

        XCTAssertEqual(
            (service["NSMenuItem"] as? [String: String])?["default"],
            "Create with Torrentino"
        )
        XCTAssertEqual(
            service["NSSendFileTypes"] as? [String],
            ["public.folder", "public.item"]
        )
        XCTAssertEqual(
            (service["NSRequiredContext"] as? [String: String])?["NSApplicationIdentifier"],
            "com.apple.finder"
        )
    }

    func testRouterUsesFirstFileURLAndPendingPathIsConsumed() throws {
        _ = NSApplication.shared
        let pasteboard = try XCTUnwrap(NSPasteboard(name: .init("WP18FinderServicesTests")))
        pasteboard.clearContents()
        let firstURL = URL(fileURLWithPath: "/tmp/wp18-first-folder", isDirectory: true)
        let secondURL = URL(fileURLWithPath: "/tmp/wp18-second-file.txt")
        XCTAssertTrue(pasteboard.writeObjects([firstURL as NSURL, secondURL as NSURL]))

        let router = CreatorServiceRouter()
        var error: NSString?
        withUnsafeMutablePointer(to: &error) { errorPointer in
            router.createTorrent(pasteboard, userData: nil, error: errorPointer)
        }

        XCTAssertNil(error)
        XCTAssertEqual(AppContext.transfers.pendingCreateSourcePath, firstURL.path)
        XCTAssertEqual(AppContext.transfers.consumePendingCreateSourcePath(), firstURL.path)
        XCTAssertNil(AppContext.transfers.pendingCreateSourcePath)
    }
}
