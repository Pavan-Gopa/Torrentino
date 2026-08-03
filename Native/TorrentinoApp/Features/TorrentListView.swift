// Layer: UI (WP-07 transfer window).
// Role: native SwiftUI table of authoritative torrents with a filter sidebar,
// a files detail pane (paginated + drill-down), and an aggregate status bar.
// Must-not: show invented data as authoritative (the demo fixture is always
// labeled), block the main actor, or bypass the command lane.
// Invariants: every cell renders only snapshot fields; selection drives the
// detail pane; state/progress columns are localized through String Catalog.

import SwiftUI
import TorrentinoIPC

struct TorrentListView: View {
    @ObservedObject var viewModel: TorrentListViewModel

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
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        viewModel.showAddSheet = true
                    } label: {
                        Label(String(localized: "torrents.add"), systemImage: "plus")
                    }
                    .help(String(localized: "torrents.add.help"))
                }
            }
        }
        .navigationTitle(String(localized: "torrents.title"))
        .sheet(isPresented: $viewModel.showAddSheet) {
            AddTorrentSheet(viewModel: viewModel)
        }
        .task {
            await viewModel.start()
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
    }

    // MARK: - Sidebar

    private var filterSidebar: some View {
        List(selection: Binding(get: { selectedFilter }, set: { selectedFilter = $0 })) {
            Section(String(localized: "torrents.sidebar.library")) {
                ForEach(SidebarFilter.allCases, id: \.self) { filter in
                    Label(filter.title, systemImage: filter.icon)
                        .badge(viewModel.statusBar.count(matching: filter))
                }
            }
        }
        .listStyle(.sidebar)
    }

    @State private var selectedFilter: SidebarFilter? = .all

    // MARK: - Table

    private var filteredTorrents: [TorrentSnapshot] {
        let filtered = selectedFilter.map { filter in
            viewModel.torrents.filter { viewModel.statusBar.matches($0, filter) }
        } ?? viewModel.torrents
        return filtered
    }

    private var transferTable: some View {
        Table(filteredTorrents, selection: $viewModel.selection) {
            TableColumn(String(localized: "torrents.col.name")) { torrent in
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
            .width(min: 200, ideal: 320)
            TableColumn(String(localized: "torrents.col.state")) { torrent in
                Text(Self.stateText(for: torrent))
                    .foregroundStyle(torrent.desiredState == .paused ? .secondary : .primary)
            }
            .width(110)
            TableColumn(String(localized: "torrents.col.progress")) { torrent in
                ProgressView(value: torrent.progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
            }
            .width(170)
            TableColumn(String(localized: "torrents.col.down")) { torrent in
                Text(Self.byteRate(torrent.rates.downloadBytesPerSec))
            }
            .width(80)
            TableColumn(String(localized: "torrents.col.up")) { torrent in
                Text(Self.byteRate(torrent.rates.uploadBytesPerSec))
            }
            .width(80)
            TableColumn(String(localized: "torrents.col.size")) { torrent in
                Text(Self.byteCount(torrent.progress.totalBytes))
            }
            .width(90)
        }
        .contextMenu(forSelectionType: TorrentRecordID.self) { ids in
            if let id = ids.first {
                Button(String(localized: "torrents.action.pause")) {
                    Task { await viewModel.pause(id) }
                }
                .disabled(viewModel.torrents.first { $0.id == id }?.desiredState == .paused)
                Button(String(localized: "torrents.action.resume")) {
                    Task { await viewModel.resume(id) }
                }
                .disabled(viewModel.torrents.first { $0.id == id }?.desiredState == .running)
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
            if viewModel.usingFixture, let note = viewModel.connectionNote {
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

// MARK: - Sidebar filters

private enum SidebarFilter: String, CaseIterable, Identifiable, Hashable {
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
}

private extension TorrentStatusBarModel {
    func count(matching filter: SidebarFilter) -> Int {
        switch filter {
        case .all: return total
        case .downloading: return downloading
        case .seeding: return seeding
        case .paused: return paused
        }
    }

    func matches(_ torrent: TorrentSnapshot, _ filter: SidebarFilter) -> Bool {
        switch filter {
        case .all: return true
        case .downloading:
            return torrent.desiredState != .paused
                && [.downloading, .fetchingMetadata, .checking, .queued].contains(torrent.activity)
        case .seeding: return torrent.activity == .seeding
        case .paused: return torrent.desiredState == .paused
        }
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
