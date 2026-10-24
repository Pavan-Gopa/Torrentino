// Layer: test (WP-27 status-item downloads).
// Role: pins the WP-27 rules on the pure model, and the controller's menu shape,
// press routing, and dot colours.
// Must-not: depend on engine state, a real download, or a Human download.

import AppKit
import Combine
import XCTest
import TorrentinoIPC

@MainActor
final class WP27MenuBarDownloadsTests: XCTestCase {
    /// One status item shared by every test: each controller repaints it when built.
    private static let sharedStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var statusItem: NSStatusItem { Self.sharedStatusItem }
    /// Controllers subscribe to a publisher, so they must stay alive for the test.
    private var controllers: [MenuBarDownloadsController] = []

    // MARK: Model: rows

    func testActiveRowsEqualTheDownloadsFilterForEveryActivityAndDesiredState() {
        for activity in TorrentActivity.allCases {
            for desired in DesiredTorrentState.allCases {
                let id = TorrentRecordID(rawValue: UUID())
                let snapshot = torrent(id, desired: desired, activity: activity, fraction: activity == .seeding ? 1 : 0.5)
                var model = MenuBarDownloads()
                model.apply([snapshot])
                XCTAssertEqual(
                    model.menuWillOpen().contains(id),
                    TorrentListFilter.downloading.matches(snapshot),
                    "\(activity) / \(desired)"
                )
            }
        }
    }

    func testEveryDownloadingRowShowsWithoutACapAndPausedRowsJoinIn() {
        let running = (0..<20).map { _ in TorrentRecordID(rawValue: UUID()) }
        let paused = (0..<5).map { _ in TorrentRecordID(rawValue: UUID()) }
        var model = MenuBarDownloads()
        model.apply(running.map { torrent($0) } + paused.map { torrent($0) })
        model.apply(running.map { torrent($0) } + paused.map { torrent($0, desired: .paused, activity: .idle) })
        XCTAssertEqual(model.menuWillOpen().count, 25)
    }

    func testPauseNeverSeenActiveStaysHiddenAcrossRepeatedEmissions() {
        let id = TorrentRecordID(rawValue: UUID())
        var model = MenuBarDownloads()
        for _ in 0..<3 {
            model.apply([torrent(id, desired: .paused, activity: .idle)])
        }
        XCTAssertEqual(model.menuWillOpen(), [])
    }

    func testPreLaunchPauseAppearsOnlyAfterPlayMakesItActive() {
        let id = TorrentRecordID(rawValue: UUID())
        var model = MenuBarDownloads()
        model.apply([torrent(id, desired: .paused, activity: .idle)])
        XCTAssertEqual(model.menuWillOpen(), [])
        model.menuDidClose()

        model.apply([torrent(id)])
        XCTAssertEqual(model.menuWillOpen(), [id], "Play in the main window brings the download back")
        XCTAssertEqual(model.row(for: id)?.kind, .active)
        XCTAssertEqual(model.badge, .downloading)
    }

    func testThisRunPauseSurvivesCloseAndEmptyEngineAndPlayReturnsTheSameRow() {
        let id = TorrentRecordID(rawValue: UUID())
        var model = MenuBarDownloads()
        model.apply([torrent(id)])
        model.apply([torrent(id, desired: .paused, activity: .idle)])
        XCTAssertEqual(model.menuWillOpen(), [id])
        XCTAssertEqual(model.row(for: id)?.kind, .paused)
        model.menuDidClose()

        model.apply([])
        XCTAssertEqual(model.menuWillOpen(), [id], "an empty emission keeps this run's pause")
        XCTAssertEqual(model.row(for: id)?.kind, .paused)
        model.menuDidClose()

        model.apply([torrent(id, desired: .paused, activity: .idle)])
        XCTAssertEqual(model.menuWillOpen(), [id])
        model.menuDidClose()

        model.apply([torrent(id)])
        XCTAssertEqual(model.menuWillOpen(), [id])
        XCTAssertEqual(model.row(for: id)?.kind, .active)
    }

    func testRetainedPauseLeavesWhenALaterNonEmptySnapshotOmitsItAndDoesNotReturn() {
        let id = TorrentRecordID(rawValue: UUID())
        let other = TorrentRecordID(rawValue: UUID())
        var model = MenuBarDownloads()
        model.apply([torrent(id)])
        model.apply([torrent(id, desired: .paused, activity: .idle)])
        model.apply([])
        model.apply([])
        XCTAssertEqual(model.menuWillOpen(), [id], "repeated empty emissions keep the pause")
        model.menuDidClose()

        model.apply([torrent(other)])
        XCTAssertEqual(model.menuWillOpen(), [other])
        model.menuDidClose()

        model.apply([torrent(id, desired: .paused, activity: .idle), torrent(other)])
        XCTAssertEqual(model.menuWillOpen(), [other], "the omission dropped its seen-active membership")
    }

    func testFinishedRowShowsOnceAndAFinishedIdDoesNotReturnWhenPausedLater() {
        let id = TorrentRecordID(rawValue: UUID())
        var model = MenuBarDownloads()
        model.apply([torrent(id)])
        model.apply([torrent(id, activity: .seeding, fraction: 1)])
        XCTAssertEqual(model.menuWillOpen(), [id])
        model.menuDidClose()

        model.apply([torrent(id, desired: .paused, activity: .seeding, fraction: 1)])
        XCTAssertEqual(model.menuWillOpen(), [])
    }

    // MARK: Model: dot

    func testWatchedCompletionRaisesGreenOnceAndOnlyOpeningClearsIt() {
        let id = TorrentRecordID(rawValue: UUID())
        var model = MenuBarDownloads()
        model.apply([torrent(id)])
        XCTAssertEqual(model.badge, .downloading)
        model.apply([torrent(id, activity: .seeding, fraction: 1)])
        XCTAssertEqual(model.badge, .finished)
        model.apply([])
        XCTAssertEqual(model.badge, .finished, "an empty engine keeps green")
        XCTAssertEqual(model.menuWillOpen(), [id])
        XCTAssertEqual(model.badge, .clear)
    }

    func testFirstSeenCompleteAndCheckingToSeedingRaiseNoGreen() {
        let seeded = TorrentRecordID(rawValue: UUID())
        let checked = TorrentRecordID(rawValue: UUID())
        var model = MenuBarDownloads()
        model.apply([torrent(seeded, activity: .seeding, fraction: 1)])
        model.apply([torrent(seeded, activity: .seeding, fraction: 1), torrent(checked, activity: .checking, fraction: 0)])
        model.apply([torrent(seeded, activity: .seeding, fraction: 1), torrent(checked, activity: .seeding, fraction: 1)])
        XCTAssertEqual(model.badge, .clear)
    }

    func testCompletionWhileTheMenuIsOpenLeavesNoGreenAndShowsItsRowOnce() {
        let id = TorrentRecordID(rawValue: UUID())
        var model = MenuBarDownloads()
        model.apply([torrent(id)])
        XCTAssertEqual(model.menuWillOpen(), [id])
        model.apply([torrent(id, activity: .seeding, fraction: 1)])
        XCTAssertEqual(model.badge, .clear)
        XCTAssertEqual(model.row(for: id)?.kind, .finished)
        model.menuDidClose()
        XCTAssertEqual(model.badge, .clear)
        XCTAssertEqual(model.menuWillOpen(), [])
    }

    func testOrangeNeedsARunningActiveRowAndGreenWinsOverIt() {
        let running = TorrentRecordID(rawValue: UUID())
        let finishing = TorrentRecordID(rawValue: UUID())
        var model = MenuBarDownloads()
        model.apply([torrent(running), torrent(finishing)])
        XCTAssertEqual(model.badge, .downloading)
        model.apply([torrent(running), torrent(finishing, activity: .seeding, fraction: 1)])
        XCTAssertEqual(model.badge, .finished)
        _ = model.menuWillOpen()
        model.menuDidClose()
        XCTAssertEqual(model.badge, .downloading)
    }

    func testPausedOnlyRowsGiveNoDot() {
        let id = TorrentRecordID(rawValue: UUID())
        var model = MenuBarDownloads()
        model.apply([torrent(id)])
        model.apply([torrent(id, desired: .paused, activity: .idle)])
        XCTAssertEqual(model.badge, .clear)
    }

    // MARK: Model: captions

    func testCaptionsFloorTheFractionClampNaNAndNameThePausedText() {
        let ids = (0..<5).map { _ in TorrentRecordID(rawValue: UUID()) }
        var model = MenuBarDownloads()
        model.apply(ids.map { torrent($0, fraction: 0.5) })
        model.apply([
            torrent(ids[0], fraction: 0.295),
            torrent(ids[1], fraction: .nan),
            torrent(ids[2], fraction: -0.5),
            torrent(ids[3], desired: .paused, activity: .idle, fraction: 0.5, downloadedBytes: 0),
            torrent(ids[4], desired: .paused, activity: .idle, fraction: 0.5, downloadedBytes: 50),
        ])
        XCTAssertEqual(model.row(for: ids[0])?.caption, .percent(29))
        XCTAssertEqual(model.row(for: ids[1])?.caption, .percent(0))
        XCTAssertEqual(model.row(for: ids[1])?.fraction, 0)
        XCTAssertEqual(model.row(for: ids[2])?.caption, .percent(0))
        XCTAssertEqual(model.row(for: ids[3])?.caption, .paused)
        XCTAssertEqual(model.row(for: ids[4])?.caption, .pausedPercent(50))
    }

    func testRowsWithoutAnHonestPercentShowStatusInstead() {
        let id = TorrentRecordID(rawValue: UUID())
        for activity: TorrentActivity in [.fetchingMetadata, .queued, .checking] {
            var model = MenuBarDownloads()
            model.apply([torrent(id, activity: activity, fraction: 0.25)])
            XCTAssertEqual(model.row(for: id)?.caption, .status, "\(activity)")
        }

        var model = MenuBarDownloads()
        model.apply([torrent(id, fraction: 0.25, totalBytes: 0)])
        XCTAssertEqual(model.row(for: id)?.caption, .status, "unknown total cannot show a percent")
    }

    // MARK: Controller

    func testZeroRowsKeepTheExistingThreeItemsAndRowsAddOneEachPlusADivider() {
        let menu = makeMenu()
        let subject = PassthroughSubject<[TorrentSnapshot], Never>()
        let controller = makeController(menu: menu, torrents: subject)
        controller.menuWillOpen(menu)
        XCTAssertEqual(menu.items.count, 3)
        controller.menuDidClose(menu)

        subject.send((0..<2).map { torrent(TorrentRecordID(rawValue: UUID()), name: "Row \($0)") })
        controller.menuWillOpen(menu)
        XCTAssertEqual(menu.items.count, 3 + 2 + 1)
        controller.menuDidClose(menu)
        XCTAssertEqual(menu.items.count, 3)
    }

    func testEveryDownloadHasItsOwnVisibleRowWithoutAnOverflowItem() throws {
        let menu = makeMenu()
        let existingItems = menu.items
        let subject = PassthroughSubject<[TorrentSnapshot], Never>()
        let controller = makeController(menu: menu, torrents: subject)
        let names = (0..<20).map { String(format: "Download %02d", $0) }
        subject.send(names.map { torrent(TorrentRecordID(rawValue: UUID()), name: $0) })
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        XCTAssertEqual(menu.items.count, names.count + 1 + existingItems.count)
        let visibleNames = try menu.items.prefix(names.count).map { item in
            let view = try XCTUnwrap(item.view, "every download gets a row, not an overflow item")
            return try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first).stringValue
        }
        XCTAssertEqual(visibleNames, names)
        XCTAssertTrue(try XCTUnwrap(menu.items.dropFirst(names.count).first).isSeparatorItem)
        for (actual, expected) in zip(menu.items.suffix(existingItems.count), existingItems) {
            XCTAssertTrue(actual === expected, "existing menu actions stay below the downloads")
        }
    }

    func testRowsAreFrozenWhileOpenAndAVanishedRowStaysInPlace() throws {
        let menu = makeMenu()
        let subject = PassthroughSubject<[TorrentSnapshot], Never>()
        let controller = makeController(menu: menu, torrents: subject)
        let first = TorrentRecordID(rawValue: UUID())
        let second = TorrentRecordID(rawValue: UUID())
        subject.send([torrent(first)])
        controller.menuWillOpen(menu)
        let firstView = menu.items.first?.view

        subject.send([torrent(first), torrent(second)])
        XCTAssertEqual(menu.items.count, 3 + 1 + 1, "a new download waits for the next open")

        subject.send([])
        XCTAssertEqual(menu.items.count, 3 + 1 + 1)
        XCTAssertTrue(menu.items.first?.view === firstView, "the same row view stays in place")
        XCTAssertFalse(try XCTUnwrap(button(in: try XCTUnwrap(firstView))).isEnabled,
                       "a vanished download stays visible but cannot be paused")
        controller.menuDidClose(menu)
    }

    func testPressRoutesEachStateToItsInjectedClosureAndUpdatesInPlace() {
        let menu = makeMenu()
        let subject = PassthroughSubject<[TorrentSnapshot], Never>()
        var paused: [Set<TorrentRecordID>] = []
        var resumed: [Set<TorrentRecordID>] = []
        let controller = makeController(
            menu: menu,
            torrents: subject,
            pause: { paused.append($0) },
            resume: { resumed.append($0) }
        )
        let id = TorrentRecordID(rawValue: UUID())
        subject.send([torrent(id)])
        controller.menuWillOpen(menu)
        let view = menu.items.first?.view

        controller.press(id)
        XCTAssertEqual(paused, [[id]])

        subject.send([torrent(id, desired: .paused, activity: .idle)])
        XCTAssertTrue(menu.items.first?.view === view)
        XCTAssertEqual(menu.items.count, 3 + 1 + 1)

        controller.press(id)
        XCTAssertEqual(resumed, [[id]])
        controller.menuDidClose(menu)
    }

    func testFinishedRowRevealsItsCapturedSnapshot() {
        let menu = makeMenu()
        let subject = PassthroughSubject<[TorrentSnapshot], Never>()
        var revealed: [TorrentRecordID] = []
        let controller = makeController(menu: menu, torrents: subject, reveal: { revealed.append($0.id) })
        let id = TorrentRecordID(rawValue: UUID())
        subject.send([torrent(id)])
        subject.send([torrent(id, activity: .seeding, fraction: 1)])
        controller.menuWillOpen(menu)
        controller.press(id)
        XCTAssertEqual(revealed, [id])
        controller.menuDidClose(menu)
    }

    func testFinishedRowBodyClickRevealsTheCapturedSnapshotThroughTheViewAndTheButtonStillDoes() throws {
        let menu = makeMenu()
        let subject = PassthroughSubject<[TorrentSnapshot], Never>()
        var revealed: [TorrentRecordID] = []
        let controller = makeController(menu: menu, torrents: subject, reveal: { revealed.append($0.id) })
        let id = TorrentRecordID(rawValue: UUID())
        subject.send([torrent(id)])
        subject.send([torrent(id, activity: .seeding, fraction: 1)])
        controller.menuWillOpen(menu)
        let view = try XCTUnwrap(menu.items.first?.view)

        click(view, at: Self.bodyPoint)
        XCTAssertEqual(revealed, [id], "a click on the row body reveals")

        let button = try XCTUnwrap(button(in: view))
        let center = NSPoint(x: button.frame.midX, y: button.frame.midY)
        XCTAssertTrue(view.hitTest(center) === button, "the folder button keeps its own clicks")
        button.performClick(nil)
        XCTAssertEqual(revealed, [id, id])
        controller.menuDidClose(menu)
    }

    func testActiveAndPausedRowBodyClicksDoNothing() throws {
        let menu = makeMenu()
        let subject = PassthroughSubject<[TorrentSnapshot], Never>()
        var calls = 0
        let controller = makeController(
            menu: menu,
            torrents: subject,
            pause: { _ in calls += 1 },
            resume: { _ in calls += 1 },
            reveal: { _ in calls += 1 }
        )
        let active = TorrentRecordID(rawValue: UUID())
        let paused = TorrentRecordID(rawValue: UUID())
        subject.send([torrent(active, name: "A"), torrent(paused, name: "B")])
        subject.send([torrent(active, name: "A"), torrent(paused, name: "B", desired: .paused, activity: .idle)])
        controller.menuWillOpen(menu)
        XCTAssertEqual(menu.items.count, 3 + 2 + 1)
        for item in menu.items.prefix(2) {
            click(try XCTUnwrap(item.view), at: Self.bodyPoint)
        }
        XCTAssertEqual(calls, 0)
        controller.menuDidClose(menu)
    }

    func testPausedRowStaysEnabledThroughAnEmptyEmissionAndShowsOnTheNextOpen() throws {
        let menu = makeMenu()
        let subject = PassthroughSubject<[TorrentSnapshot], Never>()
        var resumed: [Set<TorrentRecordID>] = []
        let controller = makeController(menu: menu, torrents: subject, resume: { resumed.append($0) })
        let id = TorrentRecordID(rawValue: UUID())
        subject.send([torrent(id)])
        subject.send([torrent(id, desired: .paused, activity: .idle)])
        controller.menuWillOpen(menu)
        let openButton = try XCTUnwrap(button(in: try XCTUnwrap(menu.items.first?.view)))

        subject.send([])
        XCTAssertTrue(openButton.isEnabled, "an open paused row stays enabled")
        controller.menuDidClose(menu)

        controller.menuWillOpen(menu)
        XCTAssertEqual(menu.items.count, 3 + 1 + 1, "the next open still shows the paused row")
        let reopened = try XCTUnwrap(button(in: try XCTUnwrap(menu.items.first?.view)))
        XCTAssertTrue(reopened.isEnabled)
        reopened.performClick(nil)
        XCTAssertEqual(resumed, [[id]])
        controller.menuDidClose(menu)
    }

    func testClosingTheMenuReleasesItsRowViews() {
        let menu = makeMenu()
        let subject = PassthroughSubject<[TorrentSnapshot], Never>()
        let controller = makeController(menu: menu, torrents: subject)
        subject.send([torrent(TorrentRecordID(rawValue: UUID()))])
        weak var weakView: NSView?
        autoreleasepool {
            controller.menuWillOpen(menu)
            weakView = menu.items.first?.view
            XCTAssertNotNil(weakView)
            controller.menuDidClose(menu)
        }
        XCTAssertNil(weakView, "a closed menu keeps no row view alive")
    }

    func testDotIsOrangeWhileDownloadingGreenWhenFinishedAndNeverATemplate() {
        let menu = makeMenu()
        let subject = PassthroughSubject<[TorrentSnapshot], Never>()
        _ = makeController(menu: menu, torrents: subject)
        let id = TorrentRecordID(rawValue: UUID())

        subject.send([torrent(id)])
        let downloading = statusItem.button?.image
        XCTAssertEqual(downloading?.isTemplate, false)
        XCTAssertEqual(downloading?.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(containsPixel(downloading) { color in
            color.redComponent > 0.8 && color.greenComponent > 0.3 && color.greenComponent < 0.8 && color.blueComponent < 0.3
        }, "orange dot")

        subject.send([torrent(id, activity: .seeding, fraction: 1)])
        XCTAssertTrue(containsPixel(statusItem.button?.image) { color in
            color.greenComponent > 0.6 && color.redComponent < 0.5
        }, "green dot")
    }

    // MARK: Helpers

    /// Left of the trailing button, over the name and bar.
    private static let bodyPoint = NSPoint(x: 100, y: 30)

    /// Delivers a left click the way AppKit does: to the view that hit-testing picks.
    private func click(_ view: NSView, at point: NSPoint) {
        view.layoutSubtreeIfNeeded()
        let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
        if let event {
            view.hitTest(point)?.mouseUp(with: event)
        }
    }

    private func button(in view: NSView) -> NSButton? {
        view.layoutSubtreeIfNeeded()
        for subview in view.subviews {
            if let button = subview as? NSButton { return button }
        }
        return nil
    }

    private func torrent(
        _ id: TorrentRecordID,
        name: String = "Fixture",
        desired: DesiredTorrentState = .running,
        activity: TorrentActivity = .downloading,
        fraction: Double = 0.5,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64 = 100
    ) -> TorrentSnapshot {
        let safeFraction = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        return TorrentSnapshot(
            id: id,
            contentIdentity: nil,
            displayName: name,
            desiredState: desired,
            activity: activity,
            health: .healthy,
            progress: TransferProgress(
                fraction: fraction,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes ?? Int64(safeFraction * 100),
                uploadedBytes: 0
            ),
            rates: TransferRates(downloadBytesPerSec: 0, uploadBytesPerSec: 0),
            peers: PeerSummary(connected: 0, halfOpen: 0, total: 0),
            saveLocation: PersistedLocation(path: "/tmp/wp27-fixture"),
            revision: 0
        )
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Torrentino")
        menu.addItem(NSMenuItem(title: "Open Torrentino", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Torrentino", action: nil, keyEquivalent: "q"))
        return menu
    }

    private func makeController(
        menu: NSMenu,
        torrents: PassthroughSubject<[TorrentSnapshot], Never>,
        pause: @escaping (Set<TorrentRecordID>) -> Void = { _ in },
        resume: @escaping (Set<TorrentRecordID>) -> Void = { _ in },
        reveal: @escaping (TorrentSnapshot) -> Void = { _ in }
    ) -> MenuBarDownloadsController {
        let base = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.gray.setFill()
            rect.fill()
            return true
        }
        let controller = MenuBarDownloadsController(
            statusItem: statusItem,
            menu: menu,
            baseImage: base,
            torrents: torrents,
            pause: pause,
            resume: resume,
            reveal: reveal
        )
        controllers.append(controller)
        return controller
    }

    private func containsPixel(_ image: NSImage?, where predicate: (NSColor) -> Bool) -> Bool {
        guard let data = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: data) else { return false }
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), predicate(color) {
                    return true
                }
            }
        }
        return false
    }
}
