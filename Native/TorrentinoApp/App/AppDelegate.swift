// Layer: UI app delegate (AppKit bridge).
// Role: bounded termination deferral for Cmd+Q / quit per LIFECYCLE_CONTRACT.md
// §6: ask the agent to stop, wait at most 5s for the ack, then terminate.
// Must-not: terminate before answering applicationShouldTerminate, wait longer
// than the 5s budget, or run engine IO synchronously on the main thread.
// Invariants: always replies to applicationShouldTerminate; agent shutdown is
// best-effort — UI termination is never held beyond the timeout (ADR-004).

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hard cap for the agent shutdown ack (plan §8.4: <= 5s).
    static let terminationAckTimeout: TimeInterval = 5.0
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        attachWindowDelegate()
        // Keep registration and the first XPC session in one ordered,
        // process-lifetime path. A view `.task` can be recreated before BTM
        // has re-anchored the LaunchAgent to this app bundle.
        Task { @MainActor in
            await AppContext.shared.prepareForLaunch()
            await AppContext.transfers.start()
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
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.unhide(nil)
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc func quitAppFromTray() {
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Serializes Finder open-document bursts onto the main runloop.
    /// `application(_:openFiles:)` demands a synchronous reply, so the URL
    /// list is stashed here and drained once from a DispatchQueue.main hop;
    /// this avoids re-entrant `@Published`/AppKit churn when LaunchServices
    /// delivers rapid double-clicks, and makes WPL drop inherit the fix.
    private var deferredOpenURLs: [URL] = []
    private var deferredOpenScheduled = false

    func application(_ sender: NSApplication, open urls: [URL]) {
        _ = handleIncomingTorrentURLs(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let handled = handleIncomingTorrentURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: handled ? .success : .failure)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard isTorrentURL(url) else { return false }
        _ = handleIncomingTorrentURLs([url])
        return true
    }

    @discardableResult
    private func handleIncomingTorrentURLs(_ urls: [URL]) -> Bool {
        let torrentURLs = urls.filter { isTorrentURL($0) }
        guard !torrentURLs.isEmpty else { return false }
        deferredOpenURLs.append(contentsOf: torrentURLs)
        guard !deferredOpenScheduled else { return true }
        deferredOpenScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let batch = self.deferredOpenURLs
            self.deferredOpenURLs.removeAll()
            self.deferredOpenScheduled = false
            self.showMainWindow()
            for url in batch {
                AppContext.transfers.presentIncomingTorrent(url)
            }
        }
        return true
    }

    private func isTorrentURL(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "torrent"
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
