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
    @State private var trackerList: [String] = []
    @State private var isPrivate: Bool = false
    @State private var pieceSizeIndex: Int = 0 // 0 = Automatic
    @State private var comment: String = ""
    @State private var source: String = ""
    @State private var startSeeding: Bool = true
    @State private var includeHiddenFiles: Bool = false

    // State
    @State private var inspection: CreateSourceInspection?
    @State private var inspecting: Bool = false
    @State private var committing: Bool = false
    @State private var errorMessage: String?
    @State private var showExclusionsSheet: Bool = false
    @State private var manifestEntries: [CreatorManifestEntry] = []
    @State private var loadingManifest: Bool = false

    private let pieceSizesKiB: [(label: String, val: Int64?)] = [
        ("Automatic", nil),
        ("16 KiB", 16),
        ("32 KiB", 32),
        ("64 KiB", 64),
        ("128 KiB", 128),
        ("256 KiB", 256),
        ("512 KiB", 512),
        ("1024 KiB (1 MiB)", 1024),
        ("2048 KiB (2 MiB)", 2048),
        ("4096 KiB (4 MiB)", 4096),
        ("8192 KiB (8 MiB)", 8192),
        ("16384 KiB (16 MiB)", 16384)
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
                                    Text(fmt.displayName).tag(fmt)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        GridRow {
                            Text(String(localized: "creator.piece_size"))
                                .font(.subheadline)
                            Picker("", selection: $pieceSizeIndex) {
                                ForEach(0..<pieceSizesKiB.count, id: \.self) { idx in
                                    Text(pieceSizesKiB[idx].label).tag(idx)
                                }
                            }
                            .pickerStyle(.menu)
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
                                addTracker()
                            }
                            .disabled(trackerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if !trackerList.isEmpty {
                            List {
                                ForEach(trackerList.indices, id: \.self) { idx in
                                    HStack {
                                        Text(trackerList[idx])
                                            .font(.caption)
                                            .monospaced()
                                        Spacer()
                                        Button(action: { trackerList.remove(at: idx) }) {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(height: 90)
                            .border(Color.gray.opacity(0.3))
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
                        }

                        HStack {
                            Text(String(localized: "creator.source_tag"))
                                .font(.subheadline)
                            TextField("", text: $source)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    // Toggles
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(String(localized: "creator.start_seeding"), isOn: $startSeeding)
                        Toggle(String(localized: "creator.private_torrent"), isOn: $isPrivate)
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
                                Text(String(localized: "creator.summary_file_count"))
                                Text(": \(inspection.summary.fileCount)").bold()
                                Spacer()
                                Text(String(localized: "creator.summary_total_size"))
                                Text(": \(ByteCountFormatter.string(fromByteCount: inspection.summary.totalBytes, countStyle: .file))").bold()
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

                    // Error presentation
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    // Progress bar when committing
                    if committing {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(viewModel.creatorProgressStage) (\(Int(viewModel.creatorProgressFraction * 100))%)")
                                .font(.caption)
                            ProgressView(value: viewModel.creatorProgressFraction)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Actions Footer
            HStack {
                Button(String(localized: "creator.cancel")) {
                    if committing {
                        viewModel.cancelCreation()
                    }
                    dismiss()
                }

                Spacer()

                Button(String(localized: "creator.create_button")) {
                    startCreation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(sourcePath.isEmpty || committing || inspecting)
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
                    Text("Excluded files: \(inspection.exclusions.joined(separator: ", "))")
                        .font(.caption)
                    if inspection.summary.skippedSymlinksCount > 0 {
                        Text("Skipped symlinks: \(inspection.summary.skippedSymlinksCount)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Divider()

                Text("File Manifest Preview:")
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
            triggerInspection()
        }
    }

    private func selectOutputPath() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "torrent")!]
        panel.nameFieldStringValue = sourcePath.isEmpty ? "new.torrent" : (URL(fileURLWithPath: sourcePath).lastPathComponent + ".torrent")
        if panel.runModal() == .OK, let url = panel.url {
            outputPath = url.path
        }
    }

    private func addTracker() {
        let trimmed = trackerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !trackerList.contains(trimmed) {
            trackerList.append(trimmed)
        }
        trackerInput = ""
    }

    private func triggerInspection() {
        guard !sourcePath.isEmpty else { return }
        inspecting = true
        errorMessage = nil
        let opts = CreateOptions(
            outputPath: outputPath,
            format: format,
            trackers: [trackerList],
            isPrivate: isPrivate,
            pieceSizeKiB: pieceSizesKiB[pieceSizeIndex].val,
            comment: comment,
            source: source,
            seedWhileDownloading: startSeeding,
            includeHiddenFiles: includeHiddenFiles
        )
        Task {
            do {
                let res = try await viewModel.inspectCreateSource(sourcePath: sourcePath, options: opts)
                inspection = res
                inspecting = false
            } catch {
                inspecting = false
                errorMessage = error.localizedDescription
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
            }
        }
    }

    private func startCreation() {
        guard let token = inspection?.token ?? viewModel.activeCreatorToken else {
            errorMessage = "Please inspect source first."
            return
        }
        committing = true
        errorMessage = nil
        Task {
            do {
                try await viewModel.commitCreate(token: token)
                committing = false
                dismiss()
            } catch {
                committing = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
