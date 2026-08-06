// Layer: UI (Torrent Creator Sheet).
// Role: Native SwiftUI + AppKit sheet for creating BitTorrent v1, v2, or hybrid metainfo.
// Must-not: run disk IO on main actor; inspect & commit route through EngineClient.
// Invariants: MainActor UI; two-phase inspect → commit flow; progress & cancel support.

import SwiftUI
import AppKit
import TorrentinoIPC
import TorrentinoDomain

@MainActor
struct CreateTorrentSheet: View {
    @ObservedObject var viewModel: TorrentListViewModel
    @Environment(\.dismiss) private var dismiss

    // Form fields
    @State private var sourcePath: String = ""
    @State private var outputPath: String = ""
    @State private var format: TorrentFormat = .hybrid
    @State private var trackerInput: String = ""
    /// Tracker tiers (BEP-12): each entry is a tier of fallback trackers; the
    /// first non-empty tier is also written to "announce".
    @State private var trackerTiers: [[String]] = []
    @State private var isPrivate: Bool = false
    @State private var pieceSizeIndex: Int = 0 // 0 = Automatic
    @State private var comment: String = ""
    @State private var source: String = ""
    @State private var startSeeding: Bool = true
    @State private var includeHiddenFiles: Bool = true

    // State
    @State private var inspection: CreateSourceInspection?
    @State private var inspectionRevision: UInt64?
    @State private var formRevision: UInt64 = 0
    @State private var inspecting: Bool = false
    @State private var committing: Bool = false
    @State private var errorMessage: String?
    @State private var showExclusionsSheet: Bool = false
    @State private var manifestEntries: [CreatorManifestEntry] = []
    @State private var loadingManifest: Bool = false

    private let pieceSizesKiB: [Int64?] = [
        nil, 16, 32, 64, 128, 256, 512,
        1024, 2048, 4096, 8192, 16384
    ]

    init(viewModel: TorrentListViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(String(localized: "creator.title"))
                    .font(.title2)
                    .bold()
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Source section
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "creator.source_path"))
                            .font(.headline)
                        HStack {
                            TextField(String(localized: "creator.source_placeholder"), text: $sourcePath)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: sourcePath) { _ in
                                    triggerInspection()
                                }

                            Button(String(localized: "creator.browse")) {
                                selectSourcePath()
                            }
                        }
                    }

                    // Output section
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "creator.output_path"))
                            .font(.headline)
                        HStack {
                            TextField(String(localized: "creator.output_placeholder"), text: $outputPath)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: outputPath) { _ in
                                    triggerInspection()
                                }

                            Button(String(localized: "creator.browse")) {
                                selectOutputPath()
                            }
                        }
                    }

                    // Options Grid
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text(String(localized: "creator.format"))
                                .font(.subheadline)
                            Picker("", selection: $format) {
                                ForEach(TorrentFormat.allCases, id: \.self) { fmt in
                                    Text(formatDisplayName(fmt)).tag(fmt)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: format) { _ in
                                triggerInspection()
                            }
                        }

                        GridRow {
                            Text(String(localized: "creator.piece_size"))
                                .font(.subheadline)
                            Picker("", selection: $pieceSizeIndex) {
                                ForEach(0..<pieceSizesKiB.count, id: \.self) { idx in
                                    Text(pieceSizeLabel(pieceSizesKiB[idx])).tag(idx)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: pieceSizeIndex) { _ in
                                triggerInspection()
                            }
                        }
                    }

                    Divider()

                    // Trackers Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "creator.trackers"))
                            .font(.headline)
                        HStack {
                            TextField(String(localized: "creator.tracker_placeholder"), text: $trackerInput)
                                .textFieldStyle(.roundedBorder)
                            Button(String(localized: "creator.add_tracker")) {
                                addTrackers()
                            }
                            .disabled(trackerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if !trackerTiers.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(trackerTiers.indices, id: \.self) { tierIndex in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                             Text(String.localizedStringWithFormat(
                                                 NSLocalizedString("creator.tier", comment: "Creator tracker tier label"),
                                                 Int64(tierIndex + 1)
                                             ))
                                                .font(.caption)
                                                .bold()
                                            Spacer()
                                            Button {
                                                moveTier(tierIndex, by: -1)
                                            } label: {
                                                Image(systemName: "arrow.up")
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(tierIndex == 0)
                                            Button {
                                                moveTier(tierIndex, by: 1)
                                            } label: {
                                                Image(systemName: "arrow.down")
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(tierIndex == trackerTiers.count - 1)
                                            Button {
                                                removeTier(tierIndex)
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        ForEach(trackerTiers[tierIndex].indices, id: \.self) { urlIndex in
                                            HStack {
                                                Text(trackerTiers[tierIndex][urlIndex])
                                                    .font(.caption)
                                                    .monospaced()
                                                Spacer()
                                                Button {
                                                    removeTracker(tierIndex: tierIndex, urlIndex: urlIndex)
                                                } label: {
                                                    Image(systemName: "xmark.circle")
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        if tierIndex < trackerTiers.count - 1 {
                                            Divider()
                                        }
                                    }
                                }
                                Button(String(localized: "creator.new_tier")) {
                                    trackerTiers.append([])
                                }
                                .font(.caption)
                            }
                            .padding(6)
                                .border(Color.gray.opacity(0.3))
                                .onChange(of: trackerTiers) { _ in
                                    triggerInspection()
                                }
                            }
                    }

                    Divider()

                    // Metadata Section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(localized: "creator.comment"))
                                .font(.subheadline)
                            TextField("", text: $comment)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: comment) { _ in
                                    triggerInspection()
                                }
                        }

                        HStack {
                            Text(String(localized: "creator.source_tag"))
                                .font(.subheadline)
                            TextField("", text: $source)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: source) { _ in
                                    triggerInspection()
                                }
                        }
                    }

                    // Toggles
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(String(localized: "creator.start_seeding"), isOn: $startSeeding)
                            .onChange(of: startSeeding) { _ in
                                triggerInspection()
                            }
                        Toggle(String(localized: "creator.private_torrent"), isOn: $isPrivate)
                            .onChange(of: isPrivate) { _ in
                                triggerInspection()
                            }
                        Toggle(String(localized: "creator.include_hidden"), isOn: $includeHiddenFiles)
                            .onChange(of: includeHiddenFiles) { _ in
                                triggerInspection()
                            }
                    }

                    // Inspection summary & Exclusions
                    if inspecting {
                        ProgressView(String(localized: "creator.inspecting"))
                    } else if let inspection {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(String.localizedStringWithFormat(
                                    NSLocalizedString("creator.summary_file_count_format", comment: "Creator file count summary"),
                                    Int64(inspection.summary.fileCount)
                                )).bold()
                                Spacer()
                                Text(String.localizedStringWithFormat(
                                    NSLocalizedString("creator.summary_total_size_format", comment: "Creator total size summary"),
                                    ByteCountFormatter.string(fromByteCount: inspection.summary.totalBytes, countStyle: .file)
                                )).bold()
                            }
                            .font(.caption)

                            if !inspection.exclusions.isEmpty || inspection.summary.skippedSymlinksCount > 0 {
                                Button(String(localized: "creator.review_exclusions")) {
                                    loadManifest(token: inspection.token)
                                    showExclusionsSheet = true
                                }
                                .font(.caption)
                            }
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                    }

                    // Error presentation uses only catalog-backed messages;
                    // diagnostics context never crosses into this view.
                    if let errorMessage = errorMessage ?? viewModel.creatorError {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    // Keep the projection visible while the agent operation is
                    // active and after its matching terminal event.
                    if committing || viewModel.creatorOperationActive || viewModel.creatorTerminalOutcome != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(progressStageText)
                                    .font(.caption)
                                Spacer()
                                Text(String.localizedStringWithFormat(
                                    NSLocalizedString("creator.progress_percent", comment: "Creator progress percentage"),
                                    Int64(max(0, min(1, viewModel.creatorProgressFraction)) * 100)
                                ))
                                    .font(.caption.monospacedDigit())
                            }
                            ProgressView(value: viewModel.creatorProgressFraction)
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("creator.progress_backend_format", comment: "Creator progress backend"),
                                progressBackendText
                            ))
                                .font(.caption2)
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("creator.progress_bytes_format", comment: "Creator progress bytes"),
                                progressBytesText
                            ))
                                .font(.caption2)
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("creator.progress_files_format", comment: "Creator progress files"),
                                progressFilesText
                            ))
                                .font(.caption2)
                            Text(String.localizedStringWithFormat(
                                NSLocalizedString("creator.progress_eta_format", comment: "Creator progress ETA"),
                                progressETAText
                            ))
                                .font(.caption2)
                            if viewModel.creatorCancellationRequested {
                                Text(viewModel.creatorTerminalCancellation
                                     ? String(localized: "creator.progress_cancelled")
                                     : String(localized: "creator.progress_cancelling"))
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Actions Footer
            HStack {
                Button(String(localized: "creator.cancel")) {
                    if committing || viewModel.creatorOperationActive {
                        viewModel.cancelCreation()
                    } else {
                        dismiss()
                    }
                }

                Spacer()

                Button(String(localized: "creator.create_button")) {
                    startCreation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCommit)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 540, height: 640)
        .sheet(isPresented: $showExclusionsSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "creator.exclusions_title"))
                    .font(.headline)

                if let inspection {
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("creator.excluded_files_format", comment: "Creator excluded files"),
                        inspection.exclusions.joined(separator: ", ")
                    ))
                        .font(.caption)
                    if inspection.summary.skippedSymlinksCount > 0 {
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("creator.skipped_symlinks_format", comment: "Creator skipped symlinks"),
                            Int64(inspection.summary.skippedSymlinksCount)
                        ))
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Divider()

                Text(String(localized: "creator.manifest_preview"))
                    .font(.subheadline)

                if loadingManifest {
                    ProgressView()
                } else {
                    List(manifestEntries, id: \.relativePath) { entry in
                        HStack {
                            Text(entry.relativePath)
                                .font(.caption)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button(String(localized: "creator.close")) {
                        showExclusionsSheet = false
                    }
                }
            }
            .padding()
            .frame(width: 480, height: 400)
        }
    }

    // MARK: - AppKit File Panels

    private func selectSourcePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            if outputPath.isEmpty {
                let defaultOutputName = url.lastPathComponent + ".torrent"
                let parentDir = url.deletingLastPathComponent().path
                outputPath = (parentDir as NSString).appendingPathComponent(defaultOutputName)
            }
        }
    }

    private func selectOutputPath() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "torrent")!]
        panel.nameFieldStringValue = sourcePath.isEmpty
            ? String(localized: "creator.default_output_filename")
            : (URL(fileURLWithPath: sourcePath).lastPathComponent + ".torrent")
        if panel.runModal() == .OK, let url = panel.url {
            outputPath = url.path
        }
    }

    private func addTrackers() {
        // Paste support: pasted text may contain several URLs separated by
        // newlines or commas; each valid one is added to the last tier.
        let trimmed = trackerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidates = trimmed
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isValidTrackerURL($0) }
        guard !candidates.isEmpty else {
            errorMessage = String(localized: "creator.invalid_tracker")
            return
        }
        if trackerTiers.isEmpty {
            trackerTiers.append([])
        }
        var lastTier = trackerTiers.removeLast()
        for url in candidates {
            lastTier.append(url)
        }
        trackerTiers.append(lastTier)
        trackerInput = ""
    }

    private func isValidTrackerURL(_ url: String) -> Bool {
        guard url.count <= 2048,
              let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return ["http", "https", "udp"].contains(scheme)
    }

    private func removeTracker(tierIndex: Int, urlIndex: Int) {
        trackerTiers[tierIndex].remove(at: urlIndex)
        if trackerTiers[tierIndex].isEmpty {
            trackerTiers.remove(at: tierIndex)
        }
    }

    private func removeTier(_ index: Int) {
        trackerTiers.remove(at: index)
    }

    private func moveTier(_ index: Int, by delta: Int) {
        let target = index + delta
        guard target >= 0, target < trackerTiers.count else { return }
        trackerTiers.swapAt(index, target)
    }

    private func triggerInspection() {
        formRevision &+= 1
        let revision = formRevision
        inspection = nil
        inspectionRevision = nil
        viewModel.invalidateCreatorInspection()
        manifestEntries = []
        guard !sourcePath.isEmpty else {
            inspecting = false
            return
        }
        inspecting = true
        errorMessage = nil
        let opts = currentCreateOptions()
        Task {
            do {
                let res = try await viewModel.inspectCreateSource(sourcePath: sourcePath, options: opts)
                guard revision == formRevision else { return }
                inspection = res
                inspectionRevision = revision
                inspecting = false
            } catch {
                guard revision == formRevision else { return }
                inspecting = false
                errorMessage = viewModel.creatorUserMessage(for: error)
            }
        }
    }

    private func loadManifest(token: CreatorPlanToken) {
        loadingManifest = true
        Task {
            do {
                let page = try await viewModel.fetchCreatorManifestPage(token: token, cursor: nil, pageSize: 100)
                manifestEntries = page.items
                loadingManifest = false
            } catch {
                loadingManifest = false
                errorMessage = viewModel.creatorUserMessage(for: error)
            }
        }
    }

    private func startCreation() {
        guard let inspection, inspectionRevision == formRevision, !inspecting else {
            errorMessage = String(localized: "creator.reinspect_first")
            return
        }
        let token = inspection.token
        let options = currentCreateOptions()
        committing = true
        errorMessage = nil
        Task {
            do {
                try await viewModel.commitCreate(token: token, options: options)
                committing = false
            } catch {
                committing = false
                errorMessage = viewModel.creatorUserMessage(for: error)
            }
        }
    }

    private var canCommit: Bool {
        !sourcePath.isEmpty && !committing && !viewModel.creatorOperationActive
            && viewModel.creatorTerminalOutcome == nil && !inspecting
            && inspection != nil && inspectionRevision == formRevision
    }

    private func currentCreateOptions() -> CreateOptions {
        CreateOptions(
            outputPath: outputPath,
            format: format,
            trackers: trackerTiers,
            isPrivate: isPrivate,
            pieceSizeKiB: pieceSizesKiB[pieceSizeIndex],
            comment: comment,
            source: source,
            seedWhileDownloading: startSeeding,
            includeHiddenFiles: includeHiddenFiles
        )
    }

    private var progressStageText: String {
        switch viewModel.creatorProgressStage {
        case "Scanning": return String(localized: "creator.stage.scanning")
        case "Hashing": return String(localized: "creator.stage.hashing")
        case "Building Metadata": return String(localized: "creator.stage.metadata")
        case "Writing Torrent": return String(localized: "creator.stage.writing")
        case "Verification": return String(localized: "creator.stage.verification")
        case "Seeding": return String(localized: "creator.stage.seeding")
        case "Completed": return String(localized: "creator.stage.completed")
        case "Cancelled": return String(localized: "creator.progress_cancelled")
        case "Cancelling": return String(localized: "creator.progress_cancelling")
        case "Failed": return String(localized: "creator.stage.failed")
        default: return String(localized: "creator.progress_unavailable")
        }
    }

    private var progressBackendText: String {
        switch viewModel.creatorProgressBackend.lowercased() {
        case "cpu": return String(localized: "creator.backend_cpu")
        default: return String(localized: "creator.progress_unavailable")
        }
    }

    private var progressBytesText: String {
        guard let processed = viewModel.creatorProcessedBytes,
              let total = viewModel.creatorTotalBytes else {
            return String(localized: "creator.progress_unavailable")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("creator.progress_bytes_value", comment: "Creator processed and total bytes"),
            ByteCountFormatter.string(fromByteCount: processed, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        )
    }

    private var progressFilesText: String {
        guard let processed = viewModel.creatorProcessedFiles,
              let total = viewModel.creatorTotalFiles else {
            return String(localized: "creator.progress_unavailable")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("creator.progress_files_value", comment: "Creator processed and total files"),
            Int64(processed),
            Int64(total)
        )
    }

    private var progressETAText: String {
        guard let seconds = viewModel.creatorETASeconds else {
            return String(localized: "creator.progress_eta_unavailable")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("creator.progress_seconds", comment: "Creator ETA seconds"),
            seconds
        )
    }

    private func formatDisplayName(_ format: TorrentFormat) -> String {
        switch format {
        case .hybrid: return String(localized: "creator.format_hybrid")
        case .v1: return String(localized: "creator.format_v1")
        case .v2: return String(localized: "creator.format_v2")
        }
    }

    private func pieceSizeLabel(_ sizeKiB: Int64?) -> String {
        guard let sizeKiB else { return String(localized: "creator.piece_size_automatic") }
        if sizeKiB >= 1024, sizeKiB % 1024 == 0 {
            return String.localizedStringWithFormat(
                NSLocalizedString("creator.piece_size_mib", comment: "Creator piece size in MiB"),
                sizeKiB / 1024
            )
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("creator.piece_size_kib", comment: "Creator piece size in KiB"),
            sizeKiB
        )
    }
}
