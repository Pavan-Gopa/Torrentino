// Layer: UI (WP-08 transfer window).
// Role: native SwiftUI table of authoritative torrents with column sorting, search filtering,
// multi-selection batch operations, drag-and-drop, context menus, and Inspector pane sync.
// Must-not: show invented data as authoritative, block main actor, or bypass command lane.
// Invariants: every cell renders snapshot fields; accessibility & localization fully supported.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TorrentinoIPC

struct TorrentListView: View {
    @ObservedObject var viewModel: TorrentListViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var selectedFilter: TorrentListFilter? = .all
    @State private var sortOrder = [KeyPathComparator(\TorrentSnapshot.displayName)]
    @AppStorage(FilesPaneSizing.persistenceKey) private var persistedFilesPaneHeight = 0.0

    var body: some View {
        NavigationSplitView {
            filterSidebar
                .navigationSplitViewColumnWidth(min: 140, ideal: 180, max: 240)
        } detail: {
            GeometryReader { geometry in
                ZStack {
                    filesSplitView(availableHeight: geometry.size.height)
                }
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL, .url, .item, .data, .plainText], isTargeted: nil) { providers in
                    handleDrop(providers)
                }
            }
            .searchable(text: $viewModel.searchText, prompt: String(localized: "torrents.search.prompt"))
            .background(SearchFieldFocusBridge(request: viewModel.searchFocusRequest))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        viewModel.showAddSheet = true
                    } label: {
                        Label(String(localized: "torrents.add"), systemImage: "plus")
                    }
                    .help(String(localized: "torrents.add.help"))
                    .accessibilityLabel(String(localized: "torrents.add"))
                    Button {
                        viewModel.showCreateSheet = true
                    } label: {
                        Label(String(localized: "torrents.create"), systemImage: "doc.badge.plus")
                    }
                    .help(String(localized: "torrents.create.help"))
                    .accessibilityLabel(String(localized: "torrents.create"))

                    Button {
                        viewModel.toggleInspector()
                    } label: {
                        Label(String(localized: "menu.torrent.inspector"), systemImage: "info.circle")
                    }
                    .help(String(localized: "menu.torrent.inspector"))
                    .accessibilityLabel(String(localized: "menu.torrent.inspector"))

                    Button {
                        viewModel.restartEngineSafely()
                    } label: {
                        Label(String(localized: "recovery.restart_engine"), systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(viewModel.usingFixture)
                    .help(String(localized: "recovery.restart_engine.help"))
                }
            }
        }
        .navigationTitle("Torrentino")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                removalRecoveryBanner
                statusBar
            }
        }
        .sheet(isPresented: $viewModel.showInspector) {
            InspectorView(torrent: viewModel.selectedTorrent, viewModel: viewModel)
        }
        .onChange(of: viewModel.selection) { _ in
            viewModel.selectionDidChange()
        }
        .onChange(of: viewModel.searchFocusRequest) { _ in
            SearchFieldFocusBridge.focusFirstResponder()
        }
        .onChange(of: viewModel.showAddSheet) { isPresented in
            if !isPresented { viewModel.focusSearch() }
        }
        .onChange(of: viewModel.connectionGeneration) { _ in
            // Reconnect tears down the AppKit responder chain; request the
            // same explicit first-responder restoration used by Cmd+F.
            viewModel.focusSearch()
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.torrents)
    }

    // MARK: - Sidebar

    private var filterSidebar: some View {
        List(selection: Binding(get: { selectedFilter }, set: { selectedFilter = $0 })) {
            Section(String(localized: "torrents.sidebar.library")) {
                ForEach(TorrentListFilter.allCases, id: \.self) { filter in
                        Label(filter.title, systemImage: filter.icon)
                            .badge(viewModel.statusBar.count(matching: filter))
                        .accessibilityLabel(
                            "\(filter.title), \(viewModel.statusBar.count(matching: filter)) " +
                            String(localized: "torrents.accessibility.items")
                        )
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Table Filtering & Sorting

    private var filteredTorrents: [TorrentSnapshot] {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = query.isEmpty
            ? viewModel.torrents
            : viewModel.torrents.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        return TorrentListProjection.project(
            candidates,
            filter: selectedFilter ?? .all,
            sortOrder: sortOrder
        )
    }

    private func filesSplitView(availableHeight: CGFloat) -> some View {
        let fixedHeight = FilesPaneSizing.fixedHeight(
            persistedValue: persistedFilesPaneHeight,
            availableHeight: availableHeight
        )
        return ControlledFilesSplitView(
            top: AnyView(
                transferTable
                    .frame(minHeight: FilesPaneSizing.tableMinimumHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            ),
            bottom: AnyView(
                filesPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            ),
            bottomHeight: fixedHeight,
            minimumTopHeight: FilesPaneSizing.tableMinimumHeight,
            minimumBottomHeight: FilesPaneSizing.minimumHeight,
            maximumBottomHeight: FilesPaneSizing.windowMaximumHeight(
                availableHeight: availableHeight
            ),
            onUserResize: { height in
                persistFilesPaneHeight(height, availableHeight: availableHeight)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Files pane sizing (WP13-LIVE-PANE-UX-001)

    private func persistFilesPaneHeight(_ height: CGFloat, availableHeight: CGFloat) {
        guard height.isFinite, availableHeight.isFinite,
              height >= FilesPaneSizing.minimumHeight - 1 else { return }
        let userHeight = FilesPaneSizing.clampedHeight(height, availableHeight: availableHeight)
        persistedFilesPaneHeight = Double(userHeight)
    }

    // MARK: - Table

    private var transferTable: some View {
        Table(filteredTorrents, selection: $viewModel.selection, sortOrder: $sortOrder) {
            TableColumn(String(localized: "torrents.col.name"), value: \.displayName) { torrent in
                TorrentRowNameView(torrent: torrent)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        viewModel.revealTorrentFolder(torrent)
                    }
                    .accessibilityLabel("\(String(localized: "torrents.accessibility.torrent")): \(torrent.displayName)")
            }
            .width(min: 100, ideal: 240)

            TableColumn(String(localized: "torrents.col.state"), value: \.stateSortKey) { torrent in
                Text(Self.stateText(for: torrent))
                    .foregroundStyle(torrent.desiredState == .paused ? .secondary : .primary)
            }
            .width(min: 65, ideal: 90)

            TableColumn(String(localized: "torrents.col.progress"), value: \.progress.fraction) { torrent in
                ProgressView(value: torrent.progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
            }
            .width(min: 60, ideal: 120)

            TableColumn(String(localized: "torrents.col.down"), value: \.rates.downloadBytesPerSec) { torrent in
                Text(Self.byteRate(torrent.rates.downloadBytesPerSec))
            }
            .width(min: 55, ideal: 75)

            TableColumn(String(localized: "torrents.col.up"), value: \.rates.uploadBytesPerSec) { torrent in
                Text(Self.byteRate(torrent.rates.uploadBytesPerSec))
            }
            .width(min: 55, ideal: 75)

            TableColumn(String(localized: "torrents.col.size"), value: \.progress.totalBytes) { torrent in
                Text(TorrentListRowProjection(torrent: torrent).downloadedAmountText)
                    .monospacedDigit()
            }
            .width(min: 120, ideal: 160)

            TableColumn(String(localized: "torrents.col.eta")) { torrent in
                Text(TorrentListRowProjection(torrent: torrent).etaText)
                    .monospacedDigit()
            }
            .width(min: 55, ideal: 85)
        }
        .onTapGesture(count: 2) {
            if let torrent = viewModel.selectedTorrent {
                viewModel.revealTorrentFolder(torrent)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    contrast == .increased ? Color.primary : Color.secondary.opacity(0.25),
                    lineWidth: contrast == .increased ? 2 : 1
                )
        }
        .contextMenu(forSelectionType: TorrentRecordID.self) { ids in
            let targetIDs = ids.isEmpty ? viewModel.selection : ids
            Button(String(localized: "torrents.action.pause")) {
                viewModel.pauseIDs(targetIDs)
            }
            .disabled(!viewModel.canPause(targetIDs))

            Button(String(localized: "torrents.action.resume")) {
                viewModel.resumeIDs(targetIDs)
            }
            .disabled(!viewModel.canResume(targetIDs))
            Button(String(localized: "torrents.action.remove")) {
                viewModel.removeSelected()
            }
            .disabled(viewModel.selection.isEmpty)

            Divider()

            Button(String(localized: "menu.torrent.reveal")) {
                viewModel.revealSelected()
            }
            .disabled(viewModel.selectedTorrent == nil)

            Button(String(localized: "menu.torrent.inspector")) {
                viewModel.toggleInspector()
            }
        }
        .overlay {
            if filteredTorrents.isEmpty {
                emptyState
            }
        }
    }

    // MARK: - Files pane

    private var filesPane: some View {
        Group {
            if viewModel.selectedTorrent == nil {
                panePlaceholder(
                    title: String(localized: "torrents.files.none_selected"),
                    icon: "doc.text"
                )
            } else if viewModel.filesLoading && viewModel.files.isEmpty {
                ProgressView(String(localized: "torrents.files.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.files.isEmpty {
                panePlaceholder(
                    title: String(localized: "torrents.files.empty"),
                    icon: "doc"
                )
            } else {
                fileList
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Layer: App (Features).
        // Role: native NSSplitView files pane.
        // Why: the split wrapper owns divider tracking without a hit-test overlay.
    }

    private func panePlaceholder(title: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        List(viewModel.files, id: \.relativePath) { entry in
            FileRow(
                entry: entry,
                directoryStack: viewModel.directoryStack,
                onEnter: { viewModel.enterDirectory($0) },
                onUp: { viewModel.goUpDirectory() },
                onToggle: { path, priority in
                    Task { await viewModel.setSelection(path, priority: priority) }
                },
                onOpenFile: { entry in
                    viewModel.openSelectedFile(entry)
                }
            )
        }
        .safeAreaInset(edge: .top) {
            filesHeaderBar
        }
    }

    private var filesHeaderBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Layer: App (Features).
                // Role: native files pane header bar.
                // Why: remove fake drag icon so header bar relies cleanly on native split view divider.
                if !viewModel.directoryStack.isEmpty {
                    Button(action: { viewModel.goUpDirectory() }) {
                        Label(String(localized: "torrents.files.up"), systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Text(viewModel.directoryStack.joined(separator: " / "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(String(localized: "torrents.files.header"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "torrents.files.select_all")) {
                    Task { await viewModel.selectAllFiles() }
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button(String(localized: "torrents.files.deselect_all")) {
                    Task { await viewModel.deselectAllFiles() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .help(String(localized: "torrents.files.resize_help"))

            Divider()
        }
    }

    // MARK: - Removal recovery (WP-10 Gate 4/9)

    /// Surfaces pending removal batches from a previous session (guided
    /// recovery) and non-completed removal outcomes inline — never silently
    /// discarded. Hidden entirely when there is nothing to report.
    private var removalRecoveryBanner: some View {
        let pending = viewModel.pendingRemovals
        let result = viewModel.lastRemovalResult
        if pending.isEmpty && (result == nil || result?.outcome == .completed) {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pending, id: \.token.rawValue) { summary in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "remove.pending.title"))
                                .font(.subheadline.weight(.semibold))
                            Text(String(localized: "remove.pending.detail"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "remove.pending.resume")) {
                            viewModel.retryRemoval(summary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                }
                if let result, result.outcome != .completed {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(Self.removalResultText(result))
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        )
    }

    /// Stable, machine-readable outcome text for the recovery banner.
    private static func removalResultText(_ result: RemovalBatchResult) -> String {
        let total = result.trashedItems + result.skippedSharedItems + result.failedItems.count
        switch result.outcome {
        case .completed:
            return String(localized: "remove.result.completed")
        case .partial:
            return String(format: NSLocalizedString("remove.result.partial", comment: ""), result.trashedItems, total, result.failedItems.count)
        case .failed:
            return String(format: NSLocalizedString("remove.result.failed", comment: ""), result.failedItems.count)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        let stats = viewModel.statusBar
        return HStack(spacing: 14) {
            Text("Torrentino v0.1")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
                .frame(height: 12)
            Label {
                Text("\(stats.downloading + stats.seeding)")
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
            .help(String(localized: "torrents.status.active"))
            Text(Self.byteRate(stats.downloadBytesPerSec))
                .monospacedDigit()
            Label {
                Text("\(stats.paused)")
            } icon: {
                Image(systemName: "pause.circle")
            }
            .help(String(localized: "torrents.status.paused"))
            Text(Self.byteRate(stats.uploadBytesPerSec))
                .monospacedDigit()
            Spacer()
            if let note = viewModel.commandError {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if viewModel.usingFixture, let note = viewModel.connectionNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let note = viewModel.connectionNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(String(localized: "torrents.status.total") + ": \(stats.total)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(nsImage: AppLogo.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                .accessibilityHidden(true)
            Text(String(localized: "empty.no_torrents"))
                .font(.title3.weight(.semibold))
            Text(String(localized: "empty.subtitle"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Drag & Drop Handler

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, TorrentDropRouting.isTorrentDropURL(url) else { return }
                    Task { @MainActor in
                        viewModel.importIncomingTorrent(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                accepted = true
                let typeId = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    ? UTType.fileURL.identifier
                    : (provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                        ? UTType.url.identifier
                        : (provider.hasItemConformingToTypeIdentifier(UTType.item.identifier)
                            ? UTType.item.identifier
                            : UTType.data.identifier))
                provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, _ in
                    guard let url = Self.fileURL(from: item),
                          TorrentDropRouting.isTorrentDropURL(url) else { return }
                    Task { @MainActor in
                        viewModel.importIncomingTorrent(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    guard let rawText = Self.text(from: item) else { return }
                    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.hasPrefix("magnet:") else { return }
                    Task { @MainActor in
                        await viewModel.addMagnet(text, startPaused: false)
                    }
                }
            }
        }
        return accepted
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let data = item as? NSData {
            return URL(dataRepresentation: data as Data, relativeTo: nil)
        }
        if let string = item as? String {
            if let url = URL(string: string), url.isFileURL { return url }
            return URL(fileURLWithPath: string)
        }
        if let string = item as? NSString {
            let value = string as String
            if let url = URL(string: value), url.isFileURL { return url }
            return URL(fileURLWithPath: value)
        }
        return nil
    }

    /// `.torrent` gate now lives in the dependency-free shared helper
    /// (`TorrentDropRouting`) so the app tests run the identical logic.
    nonisolated private static func text(from item: NSSecureCoding?) -> String? {
        if let text = item as? String { return text }
        if let text = item as? NSString { return text as String }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        if let data = item as? NSData { return String(data: data as Data, encoding: .utf8) }
        return nil
    }

    // MARK: - Formatting helpers

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func byteRate(_ bytesPerSecond: Int64) -> String {
        byteFormatter.string(fromByteCount: bytesPerSecond) + "/s"
    }

    private static func stateText(for torrent: TorrentSnapshot) -> String {
        if torrent.desiredState == .paused {
            return String(localized: "torrents.status.paused")
        }
        if torrent.desiredState == .running && torrent.activity == .downloading && torrent.rates.downloadBytesPerSec == 0 && torrent.peers.connected == 0 {
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

/// Native split view wrapper that keeps the files pane at the persisted
/// baseline. AppKit owns divider tracking; only its divider-drag callbacks
/// write the AppStorage value. Selection and file-list updates only replace
/// the hosted content, never the pane position.
private struct ControlledFilesSplitView: NSViewRepresentable {
    let top: AnyView
    let bottom: AnyView
    let bottomHeight: CGFloat
    let minimumTopHeight: CGFloat
    let minimumBottomHeight: CGFloat
    let maximumBottomHeight: CGFloat
    let onUserResize: (CGFloat) -> Void

    func makeCoordinator() -> ControlledNSSplitViewCoordinator {
        ControlledNSSplitViewCoordinator()
    }

    func makeNSView(context: Context) -> ControlledNSSplitView {
        let splitView = ControlledNSSplitView()
        splitView.delegate = context.coordinator
        context.coordinator.onUserResize = onUserResize

        let topView = NSHostingView(rootView: top)
        let bottomView = NSHostingView(rootView: bottom)
        splitView.addArrangedSubview(topView)
        splitView.addArrangedSubview(bottomView)
        splitView.updateFixedHeight(
            bottomHeight,
            minimumTopHeight: minimumTopHeight,
            minimumBottomHeight: minimumBottomHeight,
            maximumBottomHeight: maximumBottomHeight
        )
        return splitView
    }

    func updateNSView(_ splitView: ControlledNSSplitView, context: Context) {
        context.coordinator.onUserResize = onUserResize
        if let topView = splitView.arrangedSubviews.first as? NSHostingView<AnyView> {
            topView.rootView = top
        }
        if let bottomView = splitView.arrangedSubviews.dropFirst().first as? NSHostingView<AnyView> {
            bottomView.rootView = bottom
        }
        splitView.updateFixedHeight(
            bottomHeight,
            minimumTopHeight: minimumTopHeight,
            minimumBottomHeight: minimumBottomHeight,
            maximumBottomHeight: maximumBottomHeight
        )
    }

}

/// AppKit bridge for the SwiftUI `.searchable` field. SwiftUI does not expose
/// an NSResponder binding, so Cmd+F and reconnect/sheet restoration locate the
/// actual search field and make it first responder explicitly.
private struct SearchFieldFocusBridge: NSViewRepresentable {
    let request: Int

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard request > 0 else { return }
        Self.focusFirstResponder(in: nsView.window)
    }

    static func focusFirstResponder() {
        focusFirstResponder(in: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    private static func focusFirstResponder(in window: NSWindow?) {
        guard let window else { return }
        DispatchQueue.main.async {
            guard let searchField = Self.searchField(in: window.contentView) else { return }
            window.makeFirstResponder(searchField)
            searchField.selectText(nil)
        }
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let searchField = view as? NSSearchField { return searchField }
        for child in view.subviews {
            if let searchField = searchField(in: child) { return searchField }
        }
        return nil
    }
}

// MARK: - Sidebar filters

private extension TorrentStatusBarModel {
    func count(matching filter: TorrentListFilter) -> Int {
        switch filter {
        case .all: return total
        case .downloading: return downloading
        case .seeding: return seeding
        case .paused: return paused
        }
    }

    func matches(_ torrent: TorrentSnapshot, _ filter: TorrentListFilter) -> Bool {
        filter.matches(torrent)
    }
}

// MARK: - File row

private struct FileRow: View {
    let entry: FileEntry
    let directoryStack: [String]
    let onEnter: (String) -> Void
    let onUp: () -> Void
    let onToggle: (String, FileSelectionPriority) -> Void
    let onOpenFile: (FileEntry) -> Void
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func byteCount(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    var body: some View {
        HStack(spacing: 8) {
            switch entry.kind {
            case .directory:
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(entry.name)
                    .lineLimit(1)
            case .file:
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(entry.name)
                    .lineLimit(1)
                Spacer()
                Text(Self.byteCount(entry.sizeBytes))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(
                    get: { entry.selection != .skip },
                    set: { onToggle(entry.relativePath, $0 ? .normal : .skip) }
                ))
                .labelsHidden()
                .accessibilityLabel("\(String(localized: "torrents.files.selection")): \(entry.relativePath)")
                .toggleStyle(.checkbox)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.kind == .directory {
                onEnter(entry.name)
            } else {
                onOpenFile(entry)
            }
        }
    }
}

private struct TorrentRowNameView: View {
    let torrent: TorrentSnapshot

    var body: some View {
        HStack(spacing: 8) {
            if torrent.health != .healthy {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Text(torrent.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
