// Layer: Production UI shared helpers.
// Role: pure projection/routing/inspection/split-view types shared by the
// transfer UI and its tests. Contains no demo data and no client/persistence
// dependencies.

import Foundation
import AppKit
import TorrentinoIPC

/// Stable filter vocabulary shared by the table projection and its
/// performance tests. It contains no UI state or engine mutation.
enum TorrentListFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case downloading
    case seeding
    case paused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "torrents.filter.all")
        case .downloading: return String(localized: "torrents.filter.downloading")
        case .seeding: return String(localized: "torrents.filter.seeding")
        case .paused: return String(localized: "torrents.filter.paused")
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .seeding: return "arrow.up.circle"
        case .paused: return "pause.circle"
        }
    }

    func matches(_ torrent: TorrentSnapshot) -> Bool {
        switch self {
        case .all: return true
        case .downloading:
            return torrent.desiredState != .paused
                && [.downloading, .fetchingMetadata, .checking, .queued].contains(torrent.activity)
        case .seeding: return torrent.activity == .seeding
        case .paused: return torrent.desiredState == .paused
        }
    }
}

/// The production table projection path is kept pure so 100-500 row behavior
/// can be measured without constructing a second fake view or touching XPC.
enum TorrentListProjection {
    static func project(
        _ torrents: [TorrentSnapshot],
        query: String = "",
        filter: TorrentListFilter = .all,
        sortOrder: [KeyPathComparator<TorrentSnapshot>] = [KeyPathComparator(\.displayName)]
    ) -> [TorrentSnapshot] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = torrents.filter { torrent in
            filter.matches(torrent)
                && (normalizedQuery.isEmpty || torrent.displayName.localizedCaseInsensitiveContains(normalizedQuery))
        }
        result.sort(using: sortOrder)
        return result
    }
}

/// Presentation-only values used by each transfer table row. The snapshot's
/// `totalBytes` is the agent's effective total after file selection.
struct TorrentListRowProjection: Equatable {
    let downloadedBytes: Int64
    let downloadBytesPerSec: Int64
    let effectiveTotalBytes: Int64
    let downloadedAmountText: String
    let etaSeconds: Int64?
    let etaText: String

    init(torrent: TorrentSnapshot) {
        self.init(
            downloadedBytes: torrent.progress.downloadedBytes,
            effectiveTotalBytes: torrent.progress.totalBytes,
            downloadBytesPerSec: torrent.rates.downloadBytesPerSec,
            desiredState: torrent.desiredState,
            activity: torrent.activity,
            health: torrent.health
        )
    }

    init(
        downloadedBytes: Int64,
        effectiveTotalBytes: Int64,
        downloadBytesPerSec: Int64,
        desiredState: DesiredTorrentState,
        activity: TorrentActivity,
        health: TorrentHealth
    ) {
        self.effectiveTotalBytes = max(0, effectiveTotalBytes)
        self.downloadedBytes = min(max(0, downloadedBytes), self.effectiveTotalBytes)
        self.downloadBytesPerSec = max(0, downloadBytesPerSec)
        self.downloadedAmountText = Self.downloadedAmount(
            downloadedBytes: self.downloadedBytes,
            effectiveTotalBytes: self.effectiveTotalBytes
        )
        self.etaSeconds = Self.etaSeconds(
            downloadedBytes: self.downloadedBytes,
            effectiveTotalBytes: self.effectiveTotalBytes,
            downloadBytesPerSec: self.downloadBytesPerSec,
            desiredState: desiredState,
            activity: activity,
            health: health
        )
        self.etaText = Self.etaText(seconds: self.etaSeconds)
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    static func downloadedAmount(downloadedBytes: Int64, effectiveTotalBytes: Int64) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "torrents.row.downloaded_of_total",
                defaultValue: "%@ of %@"
            ),
            byteCount(downloadedBytes),
            byteCount(effectiveTotalBytes)
        )
    }

    /// Returns a rounded-up duration so a partially completed second is not
    /// displayed as an already elapsed second.
    static func etaSeconds(
        downloadedBytes: Int64,
        effectiveTotalBytes: Int64,
        downloadBytesPerSec: Int64,
        desiredState: DesiredTorrentState,
        activity: TorrentActivity,
        health: TorrentHealth
    ) -> Int64? {
        guard desiredState == .running,
              activity == .downloading,
              health == .healthy,
              downloadBytesPerSec > 0 else { return nil }

        let total = max(0, effectiveTotalBytes)
        let downloaded = min(max(0, downloadedBytes), total)
        guard total > 0, total > downloaded else { return nil }

        let remaining = total - downloaded
        let wholeSeconds = remaining / downloadBytesPerSec
        let roundingIncrement: Int64 = remaining % downloadBytesPerSec == 0 ? 0 : 1
        let (roundedSeconds, overflow) = wholeSeconds.addingReportingOverflow(roundingIncrement)
        guard !overflow, roundedSeconds <= maximumDisplayHorizonSeconds else { return nil }
        return roundedSeconds
    }

    static func etaText(seconds: Int64?) -> String {
        guard let seconds,
              seconds >= 0,
              seconds <= maximumDisplayHorizonSeconds else {
            return unavailableETAText
        }

        let interval = TimeInterval(seconds)
        guard interval.isFinite else { return unavailableETAText }
        guard let formatted = etaFormatter.string(from: interval),
              !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unavailableETAText
        }

        // DateComponentsFormatter can return the same zero string for an
        // unrepresentable large interval. Never show that as a positive ETA.
        if seconds > 0, formatted == etaFormatter.string(from: 0) {
            return unavailableETAText
        }
        return formatted
    }

    /// A one-year horizon keeps ETA presentation useful and prevents unsafe
    /// Int64-to-TimeInterval values from reaching DateComponentsFormatter.
    static let maximumDisplayHorizonSeconds: Int64 = 365 * 24 * 60 * 60

    private static let etaFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    private static let unavailableETAText = String(
        localized: "torrents.row.eta_unavailable",
        defaultValue: "—"
    )
}

import UniformTypeIdentifiers

/// `.torrent` gate shared by the window drop handler and Finder
/// open-document: file URL, extension/UTI match against the app-declared
/// `com.bittorrent.torrent` type (Info.plist exports it with the `torrent`
/// filename extension).
enum TorrentDropRouting {
    static func isTorrentDropURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if url.pathExtension.lowercased() == "torrent" { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.identifier == "com.bittorrent.torrent"
    }
}

/// Shared files-pane geometry. The persisted value is the one global user
/// baseline; the live split view only clamps that value to the window bounds.
enum FilesPaneSizing {
    /// Header plus one row leaves a usable placeholder even before files load.
    static let baseHeight: CGFloat = 40
    static let rowHeight: CGFloat = 28
    static let minimumHeight: CGFloat = baseHeight + rowHeight
    /// Keep a visible strip of the torrent table inside the window bounds.
    static let tableMinimumHeight: CGFloat = 180
    /// Content never sizes the live divider. This is only the first-launch
    /// baseline before the user has dragged the divider once.
    static let defaultHeight: CGFloat = 240
    static let persistenceKey = "torrentino.filesPane.height"

    /// The only permanent upper bound: keep the table's minimum visible strip
    /// inside the current detail window.
    static func windowMaximumHeight(availableHeight: CGFloat) -> CGFloat {
        guard availableHeight.isFinite else { return minimumHeight }
        return max(minimumHeight, availableHeight - tableMinimumHeight)
    }

    static func clampedHeight(_ height: CGFloat, availableHeight: CGFloat) -> CGFloat {
        min(
            max(height, minimumHeight),
            windowMaximumHeight(availableHeight: availableHeight)
        )
    }

    static func restoredHeight(_ value: Double, availableHeight: CGFloat) -> CGFloat? {
        guard value.isFinite, value > 0 else { return nil }
        return clampedHeight(CGFloat(value), availableHeight: availableHeight)
    }

    /// Resolves the fixed live height from the one persisted baseline. The
    /// fallback is deliberately constant: file counts, selection, and loading
    /// state have no path into divider sizing.
    static func fixedHeight(persistedValue: Double, availableHeight: CGFloat) -> CGFloat {
        let baseline = restoredHeight(persistedValue, availableHeight: availableHeight)
            ?? defaultHeight
        return clampedHeight(baseline, availableHeight: availableHeight)
    }
}

/// Generation-gated result state for asynchronous UI inspections. A result
/// from an older source is ignored even if its transport completes last.
struct LatestInspectionState<Value: Equatable>: Equatable {
    enum Result: Equatable {
        case success(Value)
        case failure(String)
    }

    private(set) var generation: UInt64 = 0
    private(set) var result: Result?

    mutating func begin() -> UInt64 {
        generation &+= 1
        result = nil
        return generation
    }

    @discardableResult
    mutating func resolve(_ result: Result, for generation: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        self.result = result
        return true
    }
}

/// Agent inspection plus the local file rows needed to render the pre-commit
/// selection tree. The operation ID remains agent-owned and is never rebuilt.
struct AddTorrentPreview: Sendable, Equatable {
    let inspection: AddSourceInspection
    let files: [FileEntry]
}

struct AddTorrentInspectionPresentation: Equatable {
    var preview: AddTorrentPreview?
    var selectedPaths: Set<String> = []
    var errorMessage: String?
    var inspecting = false

    var canCommit: Bool {
        !inspecting && preview != nil
    }
}

enum AddTorrentInspectionResultApplication {
    /// Inspection owns the sheet error. Shared connection status belongs to
    /// the connection/lifecycle paths and is intentionally left untouched.
    static func failure(
        _ message: String,
        preserving connectionNote: inout String?
    ) -> LatestInspectionState<AddTorrentPreview>.Result {
        .failure(message)
    }

    @discardableResult
    static func apply(
        _ outcome: LatestInspectionState<AddTorrentPreview>.Result,
        for generation: UInt64,
        to inspectionState: inout LatestInspectionState<AddTorrentPreview>,
        presentation: inout AddTorrentInspectionPresentation
    ) -> Bool {
        guard inspectionState.resolve(outcome, for: generation) else { return false }

        switch outcome {
        case .success(let preview):
            presentation.preview = preview
            presentation.selectedPaths = Set(preview.files.map(\.relativePath))
            presentation.errorMessage = nil
            presentation.inspecting = false
        case .failure(let failureMessage):
            presentation.preview = nil
            presentation.selectedPaths.removeAll()
            presentation.errorMessage = failureMessage
            presentation.inspecting = false
        }
        return true
    }
}

/// AppKit owns divider tracking. SwiftUI updates only replace hosted content
/// and reapply the fixed baseline through this same bridge.
@MainActor
final class ControlledNSSplitViewCoordinator: NSObject, NSSplitViewDelegate {
    var onUserResize: ((CGFloat) -> Void)?

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0, let splitView = splitView as? ControlledNSSplitView else {
            return proposedPosition
        }
        return splitView.position(forBottomHeight: splitView.clampedBottomHeight(
            splitView.bottomHeight(forPosition: proposedPosition)
        ))
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Programmatic layout and window resize can emit the same notification;
        // only an active user drag may cross the persistence boundary.
        guard let splitView = notification.object as? ControlledNSSplitView,
              splitView.isTrackingUserDivider,
              !splitView.isApplyingFixedHeight,
              let bottomView = splitView.arrangedSubviews.dropFirst().first else { return }
        onUserResize?(bottomView.frame.height)
    }
}

@MainActor
final class ControlledNSSplitView: NSSplitView {
    var minimumTopHeight: CGFloat = FilesPaneSizing.tableMinimumHeight
    var minimumBottomHeight: CGFloat = FilesPaneSizing.minimumHeight
    var maximumBottomHeight: CGFloat = .greatestFiniteMagnitude
    private(set) var isTrackingUserDivider = false
    private(set) var isApplyingFixedHeight = false

    func updateFixedHeight(
        _ requestedHeight: CGFloat,
        minimumTopHeight: CGFloat,
        minimumBottomHeight: CGFloat,
        maximumBottomHeight: CGFloat
    ) {
        self.minimumTopHeight = minimumTopHeight
        self.minimumBottomHeight = minimumBottomHeight
        self.maximumBottomHeight = maximumBottomHeight
        guard bounds.height.isFinite, bounds.height > dividerThickness else { return }

        layoutSubtreeIfNeeded()
        let height = clampedBottomHeight(requestedHeight)
        isApplyingFixedHeight = true
        setPosition(position(forBottomHeight: height), ofDividerAt: 0)
        isApplyingFixedHeight = false
    }

    func clampedBottomHeight(_ requestedHeight: CGFloat) -> CGFloat {
        let availableHeight = max(0, bounds.height - dividerThickness)
        let windowMaximum = min(
            maximumBottomHeight,
            max(minimumBottomHeight, availableHeight - minimumTopHeight)
        )
        return min(max(requestedHeight, minimumBottomHeight), windowMaximum)
    }

    func bottomHeight(forPosition position: CGFloat) -> CGFloat {
        if isFlipped {
            return bounds.height - position - dividerThickness
        }
        return position
    }

    func position(forBottomHeight height: CGFloat) -> CGFloat {
        if isFlipped {
            return bounds.height - height - dividerThickness
        }
        return height
    }

    /// Test seam for the same tracking flag used by the real AppKit mouse path.
    /// The coordinator callback remains the only persistence boundary.
    func withUserDividerTracking(_ body: () -> Void) {
        let wasTracking = isTrackingUserDivider
        isTrackingUserDivider = true
        defer { isTrackingUserDivider = wasTracking }
        body()
    }

    override func mouseDown(with event: NSEvent) {
        if isOnDivider(event) {
            withUserDividerTracking {
                super.mouseDown(with: event)
            }
        } else {
            super.mouseDown(with: event)
        }
    }

    private func isOnDivider(_ event: NSEvent) -> Bool {
        guard arrangedSubviews.count >= 2 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let first = arrangedSubviews[0].frame
        let second = arrangedSubviews[1].frame
        let dividerCenter: CGFloat
        if isFlipped {
            dividerCenter = (first.maxY + second.minY) / 2
        } else {
            dividerCenter = (second.maxY + first.minY) / 2
        }
        return abs(point.y - dividerCenter) <= dividerThickness + 6
    }
}
