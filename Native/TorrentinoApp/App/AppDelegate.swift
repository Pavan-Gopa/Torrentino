// Layer: UI app delegate (AppKit bridge).
// Role: bounded termination deferral for Cmd+Q / quit per LIFECYCLE_CONTRACT.md
// §6: ask the agent to stop, wait at most 5s for the ack, then terminate.
// Must-not: terminate before answering applicationShouldTerminate, wait longer
// than the 5s budget, or run engine IO synchronously on the main thread.
// Invariants: always replies to applicationShouldTerminate; agent shutdown is
// best-effort — UI termination is never held beyond the timeout (ADR-004).

import AppKit
import SwiftUI

enum InboundURL: Equatable {
    case magnet(String)
    case torrent(URL)

    init?(url: URL) {
        if url.scheme?.lowercased() == "magnet" {
            self = .magnet(url.absoluteString)
        } else if url.isFileURL && url.pathExtension.lowercased() == "torrent" {
            self = .torrent(url)
        } else {
            return nil
        }
    }

    var deduplicationKey: String {
        switch self {
        case .magnet(let uri):
            return "magnet:\(uri)"
        case .torrent(let url):
            return "torrent:\(url.absoluteString)"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hard cap for the agent shutdown ack (plan §8.4: <= 5s).
    static let terminationAckTimeout: TimeInterval = 5.0
    /// Matches the SwiftUI `Window("Torrentino", id: "main")` scene title so
    /// activation identifies the real main window and never promotes a
    /// Settings or dialog window to main.
    static let mainWindowTitle = "Torrentino"
    private var statusItem: NSStatusItem?
    private var fallbackMainWindowController: NSWindowController?
    private let creatorServiceRouter = CreatorServiceRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = creatorServiceRouter
        setupStatusItem()
        attachWindowDelegate()
        // Keep registration, the first XPC session, and external URL delivery
        // in one ordered process-lifetime path. A view `.task` can be
        // recreated before BTM has re-anchored the LaunchAgent to this bundle.
        Task { @MainActor in
            await AppContext.shared.prepareForLaunch()
            await AppContext.transfers.start()
            markAppContextReady()
        }
        NotificationManager.shared.requestAuthorization()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let logo = AppLogo.image
            logo.size = NSSize(width: 18, height: 18)
            button.image = logo
            button.toolTip = "Torrentino"
        }

        let menu = NSMenu(title: "Torrentino")

        let openItem = NSMenuItem(
            title: NSLocalizedString("menu.open_torrentino", value: "Open Torrentino", comment: ""),
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: NSLocalizedString("menu.quit_torrentino", value: "Quit Torrentino", comment: ""),
            action: #selector(quitAppFromTray),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    private func attachWindowDelegate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            for window in NSApp.windows where window.canBecomeMain {
                window.delegate = self
            }
        }
    }

    @objc func showMainWindow() {
        ensureMainWindowAndActivate()
    }

    fileprivate func ensureMainWindowAndActivate() {
        // Reveal before deciding: a cold LaunchServices delivery can face a
        // real but never-presented SwiftUI `Window("Torrentino", id: "main")`
        // scene, and macOS reports canBecomeMain only after a window has been
        // on screen once. Unhide/activate up front lets that scene
        // materialize; identity below is the title alone — Settings and
        // dialogs never carry it, and requiring canBecomeMain would ignore
        // the unshown scene and stack a parallel fallback beside it.
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        let window: NSWindow
        if let titledMainWindow = NSApp.windows.first(where: {
            $0.title == Self.mainWindowTitle
        }) {
            window = titledMainWindow
        } else if let fallbackWindow = fallbackMainWindowController?.window {
            window = fallbackWindow
        } else {
            let fallbackWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            fallbackWindow.title = Self.mainWindowTitle
            fallbackWindow.contentViewController = NSHostingController(
                rootView: ContentView()
                    .environmentObject(AppContext.shared)
            )
            fallbackWindow.center()
            fallbackMainWindowController = NSWindowController(window: fallbackWindow)
            window = fallbackWindow
        }

        window.delegate = self
        window.makeKeyAndOrderFront(nil)
    }

    @objc func quitAppFromTray() {
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        showMainWindow()
        // We surfaced a window ourselves; suppress default reopen handling so
        // the scene machinery cannot stack a second main window beside ours.
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Serializes LaunchServices open-document bursts onto the main runloop.
    /// `application(_:openFiles:)` demands a synchronous reply, so accepted
    /// routes are stashed here and drained after the app context is ready.
    private var deferredOpenURLs: [InboundURL] = []
    private var deferredOpenScheduled = false
    private var appContextReady: Bool
    private var recentInboundURLKeys: [String: Date] = [:]
    private static let duplicateWindow: TimeInterval = 2.0
    private static let recentURLWindow: TimeInterval = 10.0

    private let activateMainWindow: @MainActor () -> Void
    private let testDelivery: (@MainActor (InboundURL) -> Void)?

    override init() {
        self.appContextReady = false
        self.activateMainWindow = { CreatorServiceRouter.bringMainWindowForward() }
        self.testDelivery = nil
        super.init()
    }

    init(
        appContextReady: Bool = false,
        activateMainWindow: @escaping @MainActor () -> Void,
        testDelivery: (@MainActor (InboundURL) -> Void)?
    ) {
        self.appContextReady = appContextReady
        self.activateMainWindow = activateMainWindow
        self.testDelivery = testDelivery
        super.init()
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        _ = handleIncomingURLs(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let handled = handleIncomingURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: handled ? .success : .failure)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleIncomingURLs([URL(fileURLWithPath: filename)])
    }

    @discardableResult
    func handleIncomingURLs(_ urls: [URL]) -> Bool {
        let routes = urls.compactMap { InboundURL(url: $0) }
        guard !routes.isEmpty else { return false }

        let acceptedRoutes = routes.filter { acceptIncomingURL($0) }
        guard !acceptedRoutes.isEmpty else { return true }
        deferredOpenURLs.append(contentsOf: acceptedRoutes)
        scheduleIncomingURLDrain()
        return true
    }

    func markAppContextReady() {
        appContextReady = true
        scheduleIncomingURLDrain()
    }

    private func scheduleIncomingURLDrain() {
        guard appContextReady, !deferredOpenScheduled else { return }
        deferredOpenScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredOpenScheduled = false
            guard self.appContextReady, !self.deferredOpenURLs.isEmpty else { return }
            let batch = self.deferredOpenURLs
            self.deferredOpenURLs.removeAll()
            self.activateMainWindow()
            for route in batch {
                self.deliver(route)
            }
        }
    }

    private func acceptIncomingURL(_ route: InboundURL) -> Bool {
        let now = Date()
        let key = route.deduplicationKey
        if let last = recentInboundURLKeys[key],
           now.timeIntervalSince(last) < Self.duplicateWindow {
            return false
        }
        recentInboundURLKeys[key] = now
        recentInboundURLKeys = recentInboundURLKeys.filter {
            now.timeIntervalSince($0.value) < Self.recentURLWindow
        }
        return true
    }

    private func deliver(_ route: InboundURL) {
        if let testDelivery {
            testDelivery(route)
            return
        }
        switch route {
        case .magnet(let uri):
            // WP22.D9: present the Add sheet with a one-shot pending token;
            // the sheet owns inspection, polling and explicit commit.
            AppContext.transfers.presentIncomingMagnet(uri)
        case .torrent(let url):
            AppContext.transfers.presentIncomingTorrent(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let viewModel = AppContext.shared
        viewModel.appendLog("quit requested — asking engine agent for bounded shutdown (5s)")
        Task { @MainActor in
            let acknowledged = await TerminationCoordinator.requestAgentShutdown(
                client: viewModel.client,
                timeout: AppDelegate.terminationAckTimeout)
            viewModel.appendLog(acknowledged
                ? "agent acknowledged shutdown — terminating"
                : "agent did not acknowledge within 5s — terminating anyway")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Routes Finder's "Create with Torrentino" service request into the existing
/// create sheet flow. The pending path is retained by the view model until
/// ContentView has appeared, which also covers a cold launch from Finder.
@MainActor
final class CreatorServiceRouter: NSObject {
    @objc(createTorrent:userData:error:)
    func createTorrent(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: UnsafeMutablePointer<NSString?>
    ) {
        guard
            let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [NSURL],
            let sourceURL = urls.first(where: { $0.isFileURL }),
            let sourcePath = sourceURL.path,
            !sourcePath.isEmpty
        else {
            error.pointee = "Finder did not provide a file URL." as NSString
            return
        }

        AppContext.transfers.pendingCreateSourcePath = sourcePath
        Self.bringMainWindowForward()
    }

    static func bringMainWindowForward() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.ensureMainWindowAndActivate()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.unhide(nil)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

/// Bounded "ask the agent to stop" used by the quit path.
enum TerminationCoordinator {
    static func requestAgentShutdown(client: EngineClient, timeout: TimeInterval) async -> Bool {
        do {
            return try await withTimeout(seconds: timeout) {
                try await client.shutdown()
            }
        } catch {
            return false
        }
    }
}

/// Thrown by withTimeout when the deadline task wins the race.
struct DeadlineExceeded: Error, CustomStringConvertible {
    var description: String { "deadline exceeded" }
}

/// Races an operation against a wall-clock deadline; the loser is cancelled.
/// Used to keep the UI quit path bounded no matter what the agent does.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DeadlineExceeded()
        }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        group.cancelAll()
        return first
    }
}
