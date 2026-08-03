// Layer: UI (WP-08 Inspector window / sheet).
// Role: native macOS Inspector (⌘I) with General, Activity, Files, and Settings tabs,
// synchronized with table selection.
// Must-not: mutate engine state directly (routes through TorrentListViewModel command lane).
// Invariants: Accessibility-compliant (VoiceOver labels/hints, high contrast, reduce motion).

import SwiftUI
import TorrentinoIPC

struct InspectorView: View {
    let torrent: TorrentSnapshot?
    @ObservedObject var viewModel: TorrentListViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var selectedTab: InspectorTab = .general
    @State private var trackers: [TrackerEntry] = []
    @State private var newTrackerURL = ""

    enum InspectorTab: Hashable, CaseIterable {
        case general
        case activity
        case files
        case settings

        var title: String {
            switch self {
            case .general: return String(localized: "inspector.tab.general")
            case .activity: return String(localized: "inspector.tab.activity")
            case .files: return String(localized: "inspector.tab.files")
            case .settings: return String(localized: "inspector.tab.settings")
            }
        }

        var icon: String {
            switch self {
            case .general: return "info.circle"
            case .activity: return "chart.bar"
            case .files: return "doc.on.doc"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem { Label(InspectorTab.general.title, systemImage: InspectorTab.general.icon) }
                    .tag(InspectorTab.general)

                activityTab
                    .tabItem { Label(InspectorTab.activity.title, systemImage: InspectorTab.activity.icon) }
                    .tag(InspectorTab.activity)

                filesTab
                    .tabItem { Label(InspectorTab.files.title, systemImage: InspectorTab.files.icon) }
                    .tag(InspectorTab.files)

                settingsTab
                    .tabItem { Label(InspectorTab.settings.title, systemImage: InspectorTab.settings.icon) }
                    .tag(InspectorTab.settings)
            }
            .padding(16)
        }
        .frame(width: 480, height: 420)
        .task(id: torrent?.id) {
            await loadTrackers()
            loadLimitFields()
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedTab)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    contrast == .increased ? Color.primary : Color.secondary.opacity(0.25),
                    lineWidth: contrast == .increased ? 2 : 1
                )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 32))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(torrent?.displayName ?? String(localized: "inspector.no_selection"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let torrent {
                    Text("\(byteCount(torrent.progress.totalBytes)) · \(stateText(torrent))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(String(localized: "common.close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            if let torrent {
                LabeledContent(String(localized: "inspector.general.name"), value: torrent.displayName)
                LabeledContent(String(localized: "inspector.general.size"), value: byteCount(torrent.progress.totalBytes))
                LabeledContent(String(localized: "inspector.general.downloaded"), value: byteCount(torrent.progress.downloadedBytes))
                LabeledContent(String(localized: "inspector.general.uploaded"), value: byteCount(torrent.progress.uploadedBytes))
                LabeledContent(String(localized: "inspector.general.save_path"), value: torrent.saveLocation.path)
                LabeledContent(String(localized: "inspector.general.info_hash"), value: torrent.contentIdentity?.infoHashV1?.map { String(format: "%02x", $0) }.joined() ?? String(localized: "common.unknown"))
            } else {
                Text(String(localized: "inspector.no_selection"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activityTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let torrent {
                HStack(spacing: 24) {
                    VStack(alignment: .leading) {
                        Text(String(localized: "inspector.activity.down_rate"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(byteRate(torrent.rates.downloadBytesPerSec))")
                            .font(.title3.weight(.medium))
                    }
                    VStack(alignment: .leading) {
                        Text(String(localized: "inspector.activity.up_rate"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(byteRate(torrent.rates.uploadBytesPerSec))")
                            .font(.title3.weight(.medium))
                    }
                    VStack(alignment: .leading) {
                        Text(String(localized: "inspector.activity.peers"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(torrent.peers.connected) / \(torrent.peers.total)")
                            .font(.title3.weight(.medium))
                    }
                }

                Divider()

                HStack {
                    Text(String(localized: "inspector.activity.trackers"))
                        .font(.headline)
                    Spacer()
                    Button(String(localized: "inspector.activity.reannounce")) {
                        Task {
                            await viewModel.reannounce(torrent.id)
                            await loadTrackers()
                        }
                    }
                    .accessibilityLabel(String(localized: "inspector.activity.reannounce.hint"))
                }

                if let commandError = viewModel.commandError {
                    Label(commandError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                }

                List {
                    ForEach(trackers, id: \.url) { tracker in
                        HStack {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                            Text(tracker.url)
                                .lineLimit(1)
                            Spacer()
                            Text(String(localized: "inspector.tracker.active"))
                                .font(.caption)
                                .foregroundStyle(.green)
                            Button {
                                removeTracker(tracker.url)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "inspector.activity.remove_tracker"))
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField(String(localized: "inspector.activity.tracker_url"), text: $newTrackerURL)
                        .textFieldStyle(.roundedBorder)
                    Button(String(localized: "inspector.activity.add_tracker")) {
                        addTracker()
                    }
                    .disabled(newTrackerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(String(localized: "inspector.no_selection"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var filesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.files.isEmpty {
                Text(String(localized: "torrents.files.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.files, id: \.relativePath) { entry in
                    HStack {
                        Image(systemName: entry.kind == .directory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        Text(entry.relativePath)
                            .lineLimit(1)
                        Spacer()
                        Text(byteCount(entry.sizeBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @State private var maxDownKB: String = ""
    @State private var maxUpKB: String = ""
    @State private var ratioLimit: String = ""
    @State private var seedTimeSeconds: String = ""

    private var settingsTab: some View {
        Form {
            if let torrent {
                Section(String(localized: "inspector.settings.bandwidth")) {
                    TextField(String(localized: "inspector.settings.max_down"), text: $maxDownKB)
                        .textFieldStyle(.roundedBorder)
                    TextField(String(localized: "inspector.settings.max_up"), text: $maxUpKB)
                        .textFieldStyle(.roundedBorder)
                    TextField(String(localized: "inspector.settings.ratio_limit"), text: $ratioLimit)
                        .textFieldStyle(.roundedBorder)
                    TextField(String(localized: "inspector.settings.seed_time"), text: $seedTimeSeconds)
                        .textFieldStyle(.roundedBorder)
                    Text(String(localized: "inspector.settings.unlimited"))
                        .font(.caption)
                        .foregroundStyle(contrast == .increased ? .primary : .secondary)
                    Button(String(localized: "inspector.settings.apply")) {
                        switch parsedLimits() {
                        case .success(let limits):
                            Task { await viewModel.setLimits(torrent.id, limits: limits) }
                        case .failure(let error):
                            // Keep malformed text as a typed command error; it
                            // must never become an implicit unlimited value.
                            viewModel.surfaceCommandError(
                                EngineFault.invalidArgument(details: error.description, recordID: torrent.id),
                                fallback: "limits.failed"
                            )
                        }
                    }
                    if let commandError = viewModel.commandError {
                        Label(commandError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text(String(localized: "inspector.no_selection"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private enum LimitInputError: Error, CustomStringConvertible {
        case invalid(field: String)
        case overflow(field: String)

        var description: String {
            switch self {
            case .invalid(let field): return "\(field) is not a valid limit"
            case .overflow(let field): return "\(field) is outside the supported range"
            }
        }
    }

    private func parsedLimits() -> Result<TransferLimits, LimitInputError> {
        do {
            let down = try parseBandwidth(maxDownKB, field: "maxDownloadBytesPerSec")
            let up = try parseBandwidth(maxUpKB, field: "maxUploadBytesPerSec")
            let ratio = try parseRatio(ratioLimit, field: "ratioLimit")
            let seed = try parseSeed(seedTimeSeconds, field: "seedTimeSeconds")
            return .success(TransferLimits(
                maxDownloadBytesPerSec: down,
                maxUploadBytesPerSec: up,
                ratioLimit: ratio,
                seedTimeSeconds: seed
            ))
        } catch let error as LimitInputError {
            return .failure(error)
        } catch {
            return .failure(.invalid(field: "limits"))
        }
    }

    private func parseBandwidth(_ raw: String, field: String) throws -> Int64 {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return 0 }
        guard let kilobytes = Int64(value), kilobytes >= 0 else {
            throw LimitInputError.invalid(field: field)
        }
        let (bytes, overflow) = kilobytes.multipliedReportingOverflow(by: 1024)
        guard !overflow, bytes <= TransferLimits.maxBandwidthBytesPerSec else {
            throw LimitInputError.overflow(field: field)
        }
        return bytes
    }

    private func parseRatio(_ raw: String, field: String) throws -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let ratio = Double(value), ratio.isFinite, ratio >= 0 else {
            throw LimitInputError.invalid(field: field)
        }
        return ratio
    }

    private func parseSeed(_ raw: String, field: String) throws -> Int64? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let seconds = Int64(value), seconds >= 0 else {
            throw LimitInputError.invalid(field: field)
        }
        return seconds
    }

    private func loadLimitFields() {
        guard let torrent else { return }
        maxDownKB = torrent.limits.maxDownloadBytesPerSec.map { String($0 / 1024) } ?? ""
        maxUpKB = torrent.limits.maxUploadBytesPerSec.map { String($0 / 1024) } ?? ""
        ratioLimit = torrent.limits.ratioLimit.map { String($0) } ?? ""
        seedTimeSeconds = torrent.limits.seedTimeSeconds.map { String($0) } ?? ""
    }

    private func loadTrackers() async {
        guard let torrent else { return }
        let command = EngineCommandV1.fetchTrackers(FetchTrackersRequest(
            requestID: RequestID(),
            recordID: torrent.id,
            cursor: nil,
            pageSize: 50,
            expectedRevision: torrent.revision
        ))
        do {
            guard case .trackers(let page) = try await viewModel.client.sendCommand(command) else {
                throw EngineClientError.protocolMismatch(details: "unexpected fetchTrackers reply")
            }
            trackers = page.items
        } catch {
            viewModel.surfaceCommandError(error, fallback: "trackers.failed")
        }
    }

    private func addTracker() {
        guard let torrent else { return }
        let value = newTrackerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        newTrackerURL = ""
        Task {
            await viewModel.editTrackers(torrent.id, addedURLs: [value], removedURLs: [])
            await loadTrackers()
        }
    }

    private func removeTracker(_ url: String) {
        guard let torrent else { return }
        Task {
            await viewModel.editTrackers(torrent.id, addedURLs: [], removedURLs: [url])
            await loadTrackers()
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func byteRate(_ bytesPerSec: Int64) -> String {
        "\(byteCount(bytesPerSec))/s"
    }

    private func stateText(_ torrent: TorrentSnapshot) -> String {
        if torrent.desiredState == .paused {
            return String(localized: "torrents.status.paused")
        }
        switch torrent.activity {
        case .downloading: return String(localized: "torrents.status.downloading")
        case .seeding: return String(localized: "torrents.status.seeding")
        case .checking: return String(localized: "torrents.status.checking")
        case .fetchingMetadata: return String(localized: "torrents.status.fetching_metadata")
        case .queued: return String(localized: "torrents.status.queued")
        case .pendingAdd, .moving, .removing, .idle: return String(localized: "torrents.status.idle")
        }
    }
}
