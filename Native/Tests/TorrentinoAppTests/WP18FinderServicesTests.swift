// Layer: Unit tests (WP-18 Finder Services).
// Role: validate the declared Services record and the pasteboard-to-pending-path
// route without starting the engine or touching production storage.

import XCTest
import AppKit
import Foundation
import SwiftUI
import Combine
// TorrentinoAppTests is a standalone unit-test bundle. AppDelegate.swift is
// included only to exercise its internal service router, so provide the small
// lifecycle collaborators that the delegate references without booting the app.
@MainActor
final class EngineViewModel: ObservableObject {
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

/// The delegate's fallback main window hosts the production `ContentView`;
/// this standalone bundle compiles only the delegate and its collaborators,
/// so provide a stand-in view that keeps `.environmentObject(AppContext.shared)`
/// type-correct without booting any UI.
struct ContentView: View {
    var body: some View { EmptyView() }
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

    func testInboundURLClassifiesMagnetAndTorrentRoutes() throws {
        let magnet = try XCTUnwrap(URL(string: "magnet:?xt=urn:btih:abc"))
        let torrent = URL(fileURLWithPath: "/tmp/wp22-example.torrent")

        XCTAssertEqual(InboundURL(url: magnet), .magnet(magnet.absoluteString))
        XCTAssertEqual(InboundURL(url: torrent), .torrent(torrent))
        XCTAssertNil(InboundURL(url: URL(string: "https://example.com/file")!))
    }

    func testProductionInitializerQueuesColdInboundURLWithoutStartingAppContext() throws {
        let magnet = try XCTUnwrap(URL(string: "magnet:?xt=urn:btih:wp22-production"))
        let delegate = AppDelegate()

        XCTAssertTrue(delegate.handleIncomingURLs([magnet]))
    }

    func testInboundURLQueuesColdLaunchAndDeduplicatesWarmDelivery() async throws {
        let magnet = try XCTUnwrap(URL(string: "magnet:?xt=urn:btih:wp22"))
        var delivered: [InboundURL] = []
        var activations = 0
        let delegate = AppDelegate(
            activateMainWindow: { activations += 1 },
            testDelivery: { delivered.append($0) }
        )

        XCTAssertTrue(delegate.handleIncomingURLs([magnet]))
        XCTAssertTrue(delegate.handleIncomingURLs([magnet]))
        await waitForMainQueue()
        XCTAssertTrue(delivered.isEmpty)

        delegate.markAppContextReady()
        await waitForMainQueue()
        XCTAssertEqual(delivered, [.magnet(magnet.absoluteString)])
        XCTAssertEqual(activations, 1)

        XCTAssertTrue(delegate.handleIncomingURLs([magnet]))
        await waitForMainQueue()
        XCTAssertEqual(delivered, [.magnet(magnet.absoluteString)])
        XCTAssertEqual(activations, 1)
    }

    func testInboundURLPreservesTorrentFileDelivery() async throws {
        let torrent = URL(fileURLWithPath: "/tmp/wp22-preserved.torrent")
        var delivered: [InboundURL] = []
        let delegate = AppDelegate(
            appContextReady: true,
            activateMainWindow: {},
            testDelivery: { delivered.append($0) }
        )

        XCTAssertTrue(delegate.handleIncomingURLs([torrent]))
        await waitForMainQueue()
        XCTAssertEqual(delivered, [.torrent(torrent)])
    }

    /// Cold LaunchServices: the SwiftUI `Window("Torrentino", id: "main")`
    /// scene can exist while never having been presented, and macOS reports
    /// canBecomeMain only after a window has been on screen once. Activation
    /// must adopt that unshown scene window by title in place — observable
    /// through the delegate wiring AppDelegate installs on it — and never
    /// build a parallel fallback beside it. Key/frontmost status is granted
    /// by WindowServer focus and stays undetermined in a test runner, so it
    /// is left to live smoke.
    func testActivationAdoptsUnshownColdSceneWindowWithoutCreatingFallback() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = delegate
        defer { NSApp.delegate = originalDelegate }

        // Stand-in for the never-presented SwiftUI scene window: carries the
        // product main title but is never ordered front.
        let sceneWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        sceneWindow.title = AppDelegate.mainWindowTitle
        defer {
            // Tear down this stand-in and any fallback the run created so
            // later tests start from a clean window list.
            for window in NSApp.windows where window.title == AppDelegate.mainWindowTitle {
                window.delegate = nil
                window.close()
            }
        }

        XCTAssertFalse(sceneWindow.canBecomeMain, "cold precondition: window was never presented")

        CreatorServiceRouter.bringMainWindowForward()

        XCTAssertTrue(sceneWindow.isVisible, "activation adopts the unshown scene window")
        XCTAssertTrue(
            sceneWindow.delegate === delegate,
            "activation adopts the existing main window instead of replacing it"
        )
        let stacked = NSApp.windows.filter {
            $0 !== sceneWindow && $0.title == AppDelegate.mainWindowTitle
        }
        XCTAssertTrue(
            stacked.isEmpty,
            "activation with an existing main window must not create a fallback"
        )
    }

    /// The cold LaunchServices path may find no SwiftUI `Window` scene at all;
    /// repeated activation requests (URL drain, status item, Dock reopen) must
    /// surface exactly one retained fallback main window, never a second one.
    func testFallbackMainWindowActivationRetainsSingleWindow() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = delegate
        defer { NSApp.delegate = originalDelegate }
        defer {
            // Tear down every retained fallback this run created so later
            // tests start from a clean window list.
            for window in NSApp.windows where window.title == AppDelegate.mainWindowTitle {
                window.delegate = nil
                window.close()
            }
        }

        CreatorServiceRouter.bringMainWindowForward()
        CreatorServiceRouter.bringMainWindowForward()

        let mainWindows = NSApp.windows.filter { $0.title == AppDelegate.mainWindowTitle }
        XCTAssertEqual(mainWindows.count, 1, "repeated activation must not stack main windows")
        XCTAssertEqual(mainWindows.first?.contentViewController?.isViewLoaded, true)
        XCTAssertTrue(mainWindows.first?.isVisible ?? false)
    }

    func testUnsupportedSchemeIsRejectedWithoutQueueingOrActivating() async throws {
        let web = try XCTUnwrap(URL(string: "https://example.com/file"))
        var delivered: [InboundURL] = []
        var activations = 0
        let delegate = AppDelegate(
            activateMainWindow: { activations += 1 },
            testDelivery: { delivered.append($0) }
        )

        XCTAssertFalse(delegate.handleIncomingURLs([web]))
        delegate.markAppContextReady()
        await waitForMainQueue()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(activations, 0)
    }

    func testColdBurstDeliversEachRouteOnceWithSingleActivation() async throws {
        let magnet = try XCTUnwrap(URL(string: "magnet:?xt=urn:btih:wp22-burst"))
        let torrent = URL(fileURLWithPath: "/tmp/wp22-burst.torrent")
        var delivered: [InboundURL] = []
        var activations = 0
        let delegate = AppDelegate(
            activateMainWindow: { activations += 1 },
            testDelivery: { delivered.append($0) }
        )

        XCTAssertTrue(delegate.handleIncomingURLs([magnet, torrent]))
        await waitForMainQueue()
        XCTAssertTrue(delivered.isEmpty, "delivery waits for appContextReady")

        delegate.markAppContextReady()
        await waitForMainQueue()
        XCTAssertEqual(
            delivered,
            [.magnet(magnet.absoluteString), .torrent(torrent)],
            "one ready drain delivers the whole queued burst exactly once"
        )
        XCTAssertEqual(activations, 1, "a burst activates the main window once")
    }

    /// WP22.D9: the real LaunchServices drain presents a delivered magnet as
    /// exactly one pending Add-sheet token; no engine commit happens on this
    /// path and the token is consumed exactly once.
    func testDeliveredMagnetRoutePresentsSinglePendingToken() async throws {
        let magnet = try XCTUnwrap(URL(string: "magnet:?xt=urn:btih:wp22-d9-route"))
        let delegate = AppDelegate(
            appContextReady: true,
            activateMainWindow: {},
            testDelivery: nil
        )

        XCTAssertTrue(delegate.handleIncomingURLs([magnet]))
        await waitForMainQueue()

        XCTAssertEqual(AppContext.transfers.pendingAddMagnetURI, magnet.absoluteString)
        XCTAssertTrue(AppContext.transfers.showAddSheet, "browser delivery opens the existing Add sheet")
        XCTAssertNil(AppContext.transfers.magnetInspection, "delivery never starts engine work by itself")
        XCTAssertEqual(AppContext.transfers.consumePendingMagnetURI(), magnet.absoluteString)
        XCTAssertNil(AppContext.transfers.consumePendingMagnetURI(), "the token is consumed exactly once")

        AppContext.transfers.showAddSheet = false
    }

    func testCompiledAppLogoRetainsSourceAlphaAndNonTemplateRendering() throws {
        let productsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let appBundle = try XCTUnwrap(
            Bundle(url: productsURL.appendingPathComponent("Torrentino.app"))
        )
        XCTAssertEqual(appBundle.infoDictionary?["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertEqual(appBundle.infoDictionary?["CFBundleIconFile"] as? String, "AppIcon")

        let compiledLogo = try XCTUnwrap(
            appBundle.image(forResource: NSImage.Name("AppLogo"))
        )
        XCTAssertFalse(compiledLogo.isTemplate)

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "TorrentinoApp/Resources/Assets.xcassets/AppLogo.imageset/AppLogo.png"
            )
        let contentsURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Contents.json")
        let contentsData = try Data(contentsOf: contentsURL)
        let contentsJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: contentsData) as? [String: Any]
        )
        let properties = try XCTUnwrap(contentsJSON["properties"] as? [String: Any])
        XCTAssertEqual(properties["template-rendering-intent"] as? String, "original")
        let sourceLogo = try XCTUnwrap(NSImage(contentsOf: sourceURL))
        let sourceCGImage = try XCTUnwrap(
            sourceLogo.cgImage(forProposedRect: nil, context: nil, hints: nil)
        )
        var compiledRect = NSRect(
            x: 0,
            y: 0,
            width: sourceCGImage.width,
            height: sourceCGImage.height
        )
        let compiledCGImage = try XCTUnwrap(
            compiledLogo.cgImage(
                forProposedRect: &compiledRect,
                context: nil,
                hints: nil
            )
        )

        let sourceAlpha = try alphaProfile(of: sourceCGImage)
        let compiledAlpha = try alphaProfile(of: compiledCGImage)
        XCTAssertEqual(compiledAlpha, sourceAlpha)
        XCTAssertEqual(compiledAlpha.minimum, 0)
        XCTAssertEqual(compiledAlpha.maximum, 255)
        XCTAssertTrue(compiledAlpha.corners.allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(compiledAlpha.partialCount, 0)
    }

    private struct AlphaProfile: Equatable {
        let minimum: UInt8
        let maximum: UInt8
        let transparentCount: Int
        let partialCount: Int
        let opaqueCount: Int
        let corners: [UInt8]
    }

    private func alphaProfile(of image: CGImage) throws -> AlphaProfile {
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let didDraw = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.setBlendMode(.copy)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard didDraw else {
            throw NSError(
                domain: "WP18FinderServicesTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create RGBA8 alpha census"]
            )
        }

        var minimum = UInt8.max
        var maximum = UInt8.min
        var transparentCount = 0
        var partialCount = 0
        var opaqueCount = 0
        for pixel in 0..<(image.width * image.height) {
            let alpha = pixels[pixel * 4 + 3]
            minimum = min(minimum, alpha)
            maximum = max(maximum, alpha)
            switch alpha {
            case 0:
                transparentCount += 1
            case 255:
                opaqueCount += 1
            default:
                partialCount += 1
            }
        }

        let cornerOffsets = [
            3,
            (image.width - 1) * 4 + 3,
            (image.height - 1) * bytesPerRow + 3,
            (image.height - 1) * bytesPerRow + (image.width - 1) * 4 + 3,
        ]
        return AlphaProfile(
            minimum: minimum,
            maximum: maximum,
            transparentCount: transparentCount,
            partialCount: partialCount,
            opaqueCount: opaqueCount,
            corners: cornerOffsets.map { pixels[$0] }
        )
    }

    private func waitForMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
