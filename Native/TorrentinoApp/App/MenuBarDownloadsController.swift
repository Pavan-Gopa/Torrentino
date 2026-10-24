// Layer: UI (AppKit status item).
// Role: paints the WP-27 dot on a copy of the logo and shows the current-download
// rows in the existing status-item menu. Pause, Play, and Reveal are injected.
// Must-not: add a status item, decide row or green rules (MenuBarDownloads owns
// them), or surface Pause/Play errors (the main window keeps those).
// Invariants: rows are fixed from menuWillOpen to menuDidClose and update in place
// by id; the dot repaints only when the badge changes.

import AppKit
import Combine
import TorrentinoIPC

@MainActor
final class MenuBarDownloadsController: NSObject, NSMenuDelegate {
    private static let iconSize = NSSize(width: 18, height: 18)

    private struct OpenRow {
        let id: TorrentRecordID
        let item: NSMenuItem
        let view: MenuBarDownloadRowView
    }

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let baseImage: NSImage
    private let pauseTorrents: (Set<TorrentRecordID>) -> Void
    private let resumeTorrents: (Set<TorrentRecordID>) -> Void
    private let revealTorrent: (TorrentSnapshot) -> Void
    private var model = MenuBarDownloads()
    private var shownBadge: MenuBarDownloads.Badge?
    private var openRows: [OpenRow] = []
    private var openSeparator: NSMenuItem?
    private var subscription: AnyCancellable?

    init<Torrents: Publisher>(
        statusItem: NSStatusItem,
        menu: NSMenu,
        baseImage: NSImage,
        torrents: Torrents,
        pause: @escaping (Set<TorrentRecordID>) -> Void,
        resume: @escaping (Set<TorrentRecordID>) -> Void,
        reveal: @escaping (TorrentSnapshot) -> Void
    ) where Torrents.Output == [TorrentSnapshot], Torrents.Failure == Never {
        self.statusItem = statusItem
        self.menu = menu
        self.baseImage = baseImage
        pauseTorrents = pause
        resumeTorrents = resume
        revealTorrent = reveal
        super.init()
        baseImage.size = Self.iconSize
        menu.delegate = self
        // Row items carry no action, so autoenabling would disable them; their buttons must stay live.
        menu.autoenablesItems = false
        subscription = torrents.sink { [weak self] torrents in
            self?.apply(torrents)
        }
        refreshBadge()
    }

    func menuWillOpen(_ menu: NSMenu) {
        removeOpenRows()
        openRows = model.menuWillOpen().map { id in
            let view = MenuBarDownloadRowView()
            let item = NSMenuItem()
            item.view = view
            return OpenRow(id: id, item: item, view: view)
        }
        if !openRows.isEmpty {
            let separator = NSMenuItem.separator()
            for (index, row) in openRows.enumerated() {
                menu.insertItem(row.item, at: index)
            }
            menu.insertItem(separator, at: openRows.count)
            openSeparator = separator
        }
        refreshBadge()
        refreshOpenRows()
    }

    func menuDidClose(_ menu: NSMenu) {
        model.menuDidClose()
        removeOpenRows()
    }

    /// Routes a row button or a row click. Pause and Play keep the menu open.
    func press(_ id: TorrentRecordID) {
        guard let row = model.row(for: id) else { return }
        switch row.kind {
        case .active:
            if row.snapshot.desiredState == .running {
                pauseTorrents([id])
            }
        case .paused:
            resumeTorrents([id])
        case .finished:
            revealFinished(id)
        }
    }

    private func apply(_ torrents: [TorrentSnapshot]) {
        model.apply(torrents)
        refreshBadge()
        refreshOpenRows()
    }

    private func refreshBadge() {
        let badge = model.badge
        guard badge != shownBadge else { return }
        shownBadge = badge
        let label = Self.label(for: badge)
        statusItem.button?.image = Self.statusImage(base: baseImage, badge: badge)
        statusItem.button?.toolTip = label
        statusItem.button?.setAccessibilityLabel(label)
    }

    /// Updates every frozen row in place. A row that can no longer show is disabled, not removed.
    private func refreshOpenRows() {
        for row in openRows {
            // Capture the id only: the row owns its view, and the view owns these closures.
            row.view.update(
                model.row(for: row.id),
                onPress: { [weak self, id = row.id] in self?.press(id) },
                onBodyClick: { [weak self, id = row.id] in self?.revealFinished(id) }
            )
        }
    }

    /// The folder button and a finished-row body click both reveal, then close the menu.
    /// Any other row kind ignores a body click.
    private func revealFinished(_ id: TorrentRecordID) {
        guard let row = model.row(for: id), row.kind == .finished else { return }
        menu.cancelTracking()
        revealTorrent(row.snapshot)
    }

    private func removeOpenRows() {
        for row in openRows {
            menu.removeItem(row.item)
        }
        if let separator = openSeparator {
            menu.removeItem(separator)
        }
        openRows = []
        openSeparator = nil
    }

    private static func label(for badge: MenuBarDownloads.Badge) -> String {
        switch badge {
        case .clear: return "Torrentino"
        case .downloading: return String(localized: "menu.badge.downloading")
        case .finished: return String(localized: "menu.badge.finished")
        }
    }

    /// A copy of the logo, never a template, with a steady dot bottom-right.
    /// A clear badge returns the logo itself.
    private static func statusImage(base: NSImage, badge: MenuBarDownloads.Badge) -> NSImage {
        let color: NSColor
        switch badge {
        case .clear:
            return base
        case .downloading:
            color = .systemOrange
        case .finished:
            color = .systemGreen
        }
        return NSImage(size: iconSize, flipped: false) { rect in
            base.draw(in: rect)
            let ring = NSRect(x: rect.maxX - 9, y: rect.minY, width: 9, height: 9)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: ring).fill()
            color.setFill()
            NSBezierPath(ovalIn: ring.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }
}

/// One current-download row: the name truncated in the middle, a bar, a caption, and one button.
@MainActor
private final class MenuBarDownloadRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let button = NSButton()
    private var onPress: (() -> Void)?
    private var onBodyClick: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 46))

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(pressed)

        let detail = NSStackView(views: [bar, captionLabel])
        detail.orientation = .horizontal
        detail.alignment = .centerY
        detail.spacing = 8

        let parts: [NSView] = [nameLabel, detail, button]
        for part in parts {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            detail.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            bar.widthAnchor.constraint(equalToConstant: 110),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("MenuBarDownloadRowView is built in code only")
    }

    /// A nil row can no longer show: it keeps its last name, dims, and its button is disabled.
    func update(_ row: MenuBarDownloads.Row?, onPress: @escaping () -> Void, onBodyClick: @escaping () -> Void) {
        self.onPress = onPress
        self.onBodyClick = onBodyClick
        guard let row else {
            nameLabel.textColor = .disabledControlTextColor
            button.isEnabled = false
            return
        }
        nameLabel.textColor = .labelColor
        nameLabel.stringValue = row.snapshot.displayName
        captionLabel.stringValue = Self.captionText(for: row)
        bar.doubleValue = row.fraction
        let action = Self.action(for: row.kind)
        button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.label)
        button.toolTip = action.label
        button.setAccessibilityLabel(action.label)
        button.isEnabled = row.kind != .active || row.snapshot.desiredState == .running
    }

    /// Everything but the button is the row body, so the name, bar, and caption never swallow a click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === button ? hit : self
    }

    override func mouseUp(with event: NSEvent) {
        onBodyClick?()
    }

    @objc private func pressed() {
        onPress?()
    }

    private static func action(for kind: MenuBarDownloads.Row.Kind) -> (symbol: String, label: String) {
        switch kind {
        case .active: return ("pause.fill", String(localized: "torrents.action.pause"))
        case .paused: return ("play.fill", String(localized: "torrents.action.resume"))
        case .finished: return ("folder", String(localized: "menu.torrent.reveal"))
        }
    }

    private static func captionText(for row: MenuBarDownloads.Row) -> String {
        switch row.caption {
        case .finished:
            return String(localized: "menu.torrent.finished")
        case .percent(let percent):
            return "\(percent)%"
        case .status:
            return statusText(for: row.snapshot)
        case .paused:
            return String(localized: "torrents.status.paused")
        case .pausedPercent(let percent):
            return String(format: String(localized: "torrents.status.paused_percent"), percent)
        }
    }

    /// Mirrors the Downloads table's `stateText` for running rows. That helper is private to TorrentListView,
    /// which is outside this change, so the same keys are repeated here.
    private static func statusText(for torrent: TorrentSnapshot) -> String {
        if torrent.desiredState == .running && torrent.activity == .downloading
            && torrent.rates.downloadBytesPerSec == 0 && torrent.peers.connected == 0 {
            return String(localized: "torrents.status.connecting")
        }
        switch torrent.activity {
        case .pendingAdd: return String(localized: "torrents.status.pending_add")
        case .fetchingMetadata: return String(localized: "torrents.status.fetching_metadata")
        case .queued: return String(localized: "torrents.status.queued")
        case .checking: return String(localized: "torrents.status.checking")
        case .downloading: return String(localized: "torrents.status.downloading")
        case .seeding: return String(localized: "torrents.status.seeding")
        case .moving: return String(localized: "torrents.status.moving")
        case .removing: return String(localized: "torrents.status.removing")
        case .idle: return String(localized: "torrents.status.idle")
        }
    }
}
