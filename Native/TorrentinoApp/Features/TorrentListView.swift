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

    var body: some View {
        NavigationSplitView {
            filterSidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VSplitView {
                transferTable
                    .frame(minHeight: 200)
                filesPane
                    .frame(minHeight: 120)
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
                        viewModel.toggleInspector()
                    } label: {
                        Label(String(localized: "menu.torrent.inspector"), systemImage: "info.circle")
                    }
                    .help(String(localized: "menu.torrent.inspector"))
                    .accessibilityLabel(String(localized: "menu.torrent.inspector"))
                }
            }
        }
        .navigationTitle(String(localized: "torrents.title"))
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .sheet(isPresented: $viewModel.showInspector) {
            InspectorView(torrent: viewModel.selectedTorrent, viewModel: viewModel)
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
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

    // MARK: - Table

    private var transferTable: some View {
        Table(filteredTorrents, selection: $viewModel.selection, sortOrder: $sortOrder) {
            TableColumn(String(localized: "torrents.col.name"), value: \.displayName) { torrent in
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
                .accessibilityLabel("\(String(localized: "torrents.accessibility.torrent")): \(torrent.displayName)")
            }
            .width(min: 200, ideal: 320)

            TableColumn(String(localized: "torrents.col.state"), value: \.stateSortKey) { torrent in
                Text(Self.stateText(for: torrent))
                    .foregroundStyle(torrent.desiredState == .paused ? .secondary : .primary)
            }
            .width(110)

            TableColumn(String(localized: "torrents.col.progress"), value: \.progress.fraction) { torrent in
                ProgressView(value: torrent.progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
            }
            .width(170)

            TableColumn(String(localized: "torrents.col.down"), value: \.rates.downloadBytesPerSec) { torrent in
                Text(Self.byteRate(torrent.rates.downloadBytesPerSec))
            }
            .width(80)

            TableColumn(String(localized: "torrents.col.up"), value: \.rates.uploadBytesPerSec) { torrent in
                Text(Self.byteRate(torrent.rates.uploadBytesPerSec))
            }
            .width(80)

            TableColumn(String(localized: "torrents.col.size"), value: \.progress.totalBytes) { torrent in
                Text(Self.byteCount(torrent.progress.totalBytes))
            }
            .width(90)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    contrast == .increased ? Color.primary : Color.secondary.opacity(0.25),
                    lineWidth: contrast == .increased ? 2 : 1
                )
        }
        .contextMenu(forSelectionType: TorrentRecordID.self) { ids in
            Button(String(localized: "torrents.action.pause")) {
                viewModel.pauseSelected()
            }
            .disabled(!viewModel.canPauseSelected)

            Button(String(localized: "torrents.action.resume")) {
                viewModel.resumeSelected()
            }
            .disabled(!viewModel.canResumeSelected)

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
                }
            )
        }
        .overlay(alignment: .topLeading) {
            if !viewModel.directoryStack.isEmpty {
                HStack(spacing: 6) {
                    Button(action: { viewModel.goUpDirectory() }) {
                        Label(String(localized: "torrents.files.up"), systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Text(viewModel.directoryStack.joined(separator: " / "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(8)
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        let stats = viewModel.statusBar
        return HStack(spacing: 16) {
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
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
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
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = Self.fileURL(from: item),
                          url.isFileURL,
                          url.pathExtension.lowercased() == "torrent" else { return }
                    Task { @MainActor in
                        await viewModel.addTorrentFile(url, startPaused: false)
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
            return URL(fileURLWithPath: string)
        }
        return nil
    }

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

    private static func byteCount(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    private static func byteRate(_ bytesPerSecond: Int64) -> String {
        byteFormatter.string(fromByteCount: bytesPerSecond) + "/s"
    }

    private static func stateText(for torrent: TorrentSnapshot) -> String {
        if torrent.desiredState == .paused {
            return String(localized: "torrents.status.paused")
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
            }
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func byteCount(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }
}
