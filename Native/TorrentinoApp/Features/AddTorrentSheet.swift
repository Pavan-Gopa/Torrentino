// Layer: UI (WP-07 add-torrent sheet).
// Role: collects a magnet/HTTP URL, a local .torrent file, or a torrent URL,
// plus the start-paused option, and drives the inspect → commitAdd lane.
// Must-not: bypass the agent's preflight (inspection happens agent-side), or
// touch disk on the main actor.
// Invariants: commitAdd is keyed by a fresh IdempotencyKey; the sheet closes
// only after the commit succeeds (the new record shows in the table).

import SwiftUI
import UniformTypeIdentifiers
import TorrentinoIPC

struct AddTorrentSheet: View {
    @ObservedObject var viewModel: TorrentListViewModel
    @Environment(\.dismiss) private var dismiss

    private enum AddTorrentPickerMode {
        case torrent
        case destination

        var allowedContentTypes: [UTType] {
            switch self {
            case .torrent:
                return [UTType(filenameExtension: "torrent") ?? .data, .data]
            case .destination:
                return [.folder]
            }
        }
    }

    @State private var text: String = ""
    @State private var startPaused = true
    @State private var isFileImporterPresented = false
    @State private var pickerMode: AddTorrentPickerMode?
    @State private var fileURL: URL?
    @State private var destinationURL: URL?
    @State private var inspectionPresentation = AddTorrentInspectionPresentation()
    @State private var committing = false
    @State private var inspectionState = LatestInspectionState<AddTorrentPreview>()
    private let preferences = AddSheetPreferences()

    /// The presented source: a ready magnet preflight wins over the local
    /// `.torrent` inspection; only one is ever active.
    private var activePreview: AddTorrentPreview? {
        viewModel.magnetInspection?.preview ?? inspectionPresentation.preview
    }

    private var isPreflightWorking: Bool {
        viewModel.magnetInspection?.phase == .retrievingMetadata
            || inspectionPresentation.inspecting
    }

    private var activeErrorMessage: String? {
        viewModel.magnetInspection?.errorMessage ?? inspectionPresentation.errorMessage
    }

    private var canCommit: Bool {
        guard !committing else { return false }
        if let magnet = viewModel.magnetInspection {
            // A retrieving or failed magnet can never commit; once the D8
            // inspection is ready, this is the explicit confirmation gate.
            return magnet.phase == .readyToCommit && magnet.preview != nil
        }
        guard !inspectionPresentation.inspecting else { return false }
        if fileURL != nil {
            return inspectionPresentation.canCommit
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedBytes: Int64 {
        guard let preview = activePreview else { return 0 }
        return preview.files.reduce(into: Int64(0)) { result, file in
            if inspectionPresentation.selectedPaths.contains(file.relativePath) {
                result += file.sizeBytes
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "torrents.add.title"))
                .font(.title2.weight(.semibold))
            Text(String(localized: "torrents.add.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(String(localized: "torrents.add.magnet"), text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
                .onChange(of: text) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, fileURL != nil {
                        fileURL = nil
                        inspectionPresentation.preview = nil
                        inspectionPresentation.selectedPaths.removeAll()
                        inspectionPresentation.inspecting = false
                        _ = inspectionState.begin()
                    }
                    // Editing away from (or clearing) the presented magnet
                    // abandons its retrieval; the operation is cancelled at
                    // most once. Re-setting the same URI is a no-op.
                    if trimmed != viewModel.magnetInspection?.uri {
                        viewModel.abandonMagnetInspection()
                    }
                }

            HStack {
                Button(String(localized: "torrents.add.pick_file")) {
                    pickerMode = .torrent
                    isFileImporterPresented = true
                }
                if let fileURL {
                    Label(fileURL.lastPathComponent, systemImage: "doc")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack {
                Button(String(localized: "torrents.add.destination")) {
                    pickerMode = .destination
                    isFileImporterPresented = true
                }
                if let destinationPath {
                    Label(destinationPath, systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(String(localized: "torrents.add.destination_default"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if isPreflightWorking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "torrents.add.reading_torrent"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if let preview = activePreview {
                inspectionSummary(preview)
            }

            Toggle(String(localized: "torrents.add.start_paused"), isOn: $startPaused)
                .toggleStyle(.checkbox)

            if let errorMessage = activeErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(String(localized: "torrents.add.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "torrents.add.confirm")) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 560)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: pickerMode?.allowedContentTypes ?? [.data],
            allowsMultipleSelection: false
        ) { result in
            // SwiftUI sets `isFileImporterPresented` to false before this
            // callback. Keep `pickerMode` separate so that write does not
            // discard which result handler must consume the selected URL.
            let mode = pickerMode
            pickerMode = nil
            guard let mode else {
                inspectionPresentation.errorMessage = String(localized: "torrents.add.pick_failed")
                return
            }

            switch mode {
            case .torrent:
                switch result {
                case .success(let urls):
                    guard let url = urls.first, TorrentDropRouting.isTorrentDropURL(url) else {
                        inspectionPresentation.errorMessage = String(localized: "torrents.add.pick_failed")
                        return
                    }
                    beginInspection(for: url)
                case .failure(let error):
                    if !Self.isPickerCancellation(error) {
                        inspectionPresentation.errorMessage = String(localized: "torrents.add.pick_failed")
                    }
                }
            case .destination:
                switch result {
                case .success(let urls):
                    destinationURL = urls.first
                    inspectionPresentation.errorMessage = nil
                case .failure(let error):
                    if !Self.isPickerCancellation(error) {
                        inspectionPresentation.errorMessage = String(localized: "torrents.add.destination_failed")
                    }
                }
            }
        }
        .onAppear {
            seedPreferences()
            consumePendingFile()
            consumePendingMagnet()
        }
        .onChange(of: viewModel.pendingAddFileURL) { newURL in
            if let newURL {
                consumePendingFile(newURL)
                viewModel.pendingAddFileURL = nil
            }
        }
        .onChange(of: viewModel.pendingAddMagnetURI) { newURI in
            if let newURI {
                consumePendingMagnet(newURI)
                _ = viewModel.consumePendingMagnetURI()
            }
        }
        .onChange(of: viewModel.magnetInspection) { magnet in
            // A ready preflight feeds the existing selection tree exactly like
            // a local `.torrent` inspection does.
            if let preview = magnet?.preview {
                inspectionPresentation.selectedPaths = Set(preview.files.map(\.relativePath))
            }
        }
        .onDisappear {
            // Sheet-lifecycle cancellation: every exit path stops polling and
            // cancels the current operation at most once. A committed
            // preflight was already promoted and cleared, so dismissal never
            // touches a durable record.
            viewModel.abandonMagnetInspection()
        }
        .task {
            await viewModel.loadDefaultDownloadLocation()
        }
    }

    private func commit() {
        guard canCommit else { return }
        committing = true
        inspectionPresentation.errorMessage = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { committing = false }
            if viewModel.magnetInspection != nil {
                // WP22.D9: a ready preflight commits exactly the presented
                // operation with the chosen files, destination and start mode.
                await commitReadyMagnet()
            } else if let preview = inspectionPresentation.preview {
                finish(await viewModel.commitInspectedTorrent(
                    preview,
                    saveLocation: saveLocation(),
                    fileSelection: selectionItems(for: preview),
                    startPaused: startPaused
                ))
            } else if MagnetURIRouting.isMagnetURI(trimmed) {
                // A pasted magnet begins inspection; commit stays impossible
                // until the D8 metadata is ready and the user confirms again.
                beginMagnetInspection(trimmed)
            } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                finish(await viewModel.addTorrentFileURL(trimmed, startPaused: startPaused))
            } else {
                inspectionPresentation.errorMessage = String(localized: "torrents.add.invalid_source")
            }
        }
    }

    private func commitReadyMagnet() async {
        guard let magnet = viewModel.magnetInspection,
              magnet.phase == .readyToCommit,
              let preview = magnet.preview else { return }
        finish(await viewModel.commitReadyMagnet(
            saveLocation: saveLocation(),
            fileSelection: selectionItems(for: preview),
            startPaused: startPaused
        ))
    }

    private func finish(_ success: Bool) {
        if success {
            finishSuccessfulAdd()
        } else if let err = viewModel.lastAddError {
            inspectionPresentation.errorMessage = err
        }
    }

    private func saveLocation() -> PersistedLocation? {
        destinationURL.map { PersistedLocation(path: $0.path) }
    }

    private func selectionItems(for preview: AddTorrentPreview) -> [FileSelectionItem] {
        preview.files.map { file in
            FileSelectionItem(
                relativePath: file.relativePath,
                priority: inspectionPresentation.selectedPaths.contains(file.relativePath) ? .normal : .skip
            )
        }
    }

    private func seedPreferences() {
        let seeded = preferences.seed()
        startPaused = seeded.startPaused
        destinationURL = seeded.destinationURL
    }

    private func finishSuccessfulAdd() {
        preferences.recordSuccessfulAdd(
            destinationURL: destinationURL,
            startPaused: startPaused
        )
        dismiss()
    }

    private var destinationPath: String? {
        destinationURL?.path ?? viewModel.defaultDownloadLocation
    }

    @ViewBuilder
    private func inspectionSummary(_ preview: AddTorrentPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let sizeBytes = preview.inspection.sizeBytes {
                    Text(Self.localizedSize("torrents.add.total", bytes: sizeBytes))
                }
                Spacer()
                if !preview.files.isEmpty {
                    Text(Self.localizedSize("torrents.add.selected", bytes: selectedBytes))
                        .foregroundStyle(.secondary)
                }
            }

            if !preview.files.isEmpty {
                HStack {
                    Text(String(localized: "torrents.add.files_title"))
                        .font(.headline)
                    Spacer()
                    Button(String(localized: "torrents.files.select_all")) {
                        inspectionPresentation.selectedPaths = Set(preview.files.map(\.relativePath))
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Button(String(localized: "torrents.files.deselect_all")) {
                        inspectionPresentation.selectedPaths.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(treeNodes(preview)) { node in
                            treeRow(node)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 220)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func treeRow(_ node: AddTorrentTreeNode) -> some View {
        HStack(spacing: 8) {
            if node.kind == .file {
                Toggle("", isOn: Binding(
                    get: { inspectionPresentation.selectedPaths.contains(node.relativePath) },
                    set: { isSelected in
                        if isSelected {
                            inspectionPresentation.selectedPaths.insert(node.relativePath)
                        } else {
                            inspectionPresentation.selectedPaths.remove(node.relativePath)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }

            Image(systemName: node.kind == .file ? "doc.fill" : "folder.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(node.name)
                .lineLimit(1)
            Spacer()
            Text(Self.byteCount(node.sizeBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(node.depth) * 16)
    }

    private func consumePendingFile(_ pending: URL? = nil) {
        let url = pending ?? viewModel.pendingAddFileURL
        guard let url else { return }
        viewModel.pendingAddFileURL = nil
        beginInspection(for: url)
    }

    /// Takes the one-shot browser/paste token exactly once and starts the D8
    /// retrieval for it. Replacing any current source cancels it at most once.
    private func consumePendingMagnet(_ pending: String? = nil) {
        guard let uri = pending ?? viewModel.consumePendingMagnetURI() else { return }
        beginMagnetInspection(uri)
    }

    private func beginMagnetInspection(_ uri: String) {
        // Invalidate any in-flight local inspection first: once the magnet
        // owns the preview, a late local result is dropped by generation.
        _ = inspectionState.begin()
        fileURL = nil
        inspectionPresentation = AddTorrentInspectionPresentation()
        text = uri
        viewModel.beginMagnetInspection(uri)
    }

    private func beginInspection(for url: URL) {
        let requestID = inspectionState.begin()
        guard TorrentDropRouting.isTorrentDropURL(url) else {
            inspectionPresentation.inspecting = false
            inspectionPresentation.errorMessage = String(localized: "torrents.add.pick_failed")
            return
        }
        // Local inspection takes preview ownership; release any presented
        // magnet first (single cancel; synchronous no-op when none shown).
        viewModel.abandonMagnetInspection()
        fileURL = url
        text = ""
        inspectionPresentation = AddTorrentInspectionPresentation(inspecting: true)
        Task { @MainActor in
            // The localized failure travels with this attempt; lastAddError is
            // shared by other add commands and is not an inspection result.
            let outcome = await viewModel.inspectTorrentFile(url)
            _ = AddTorrentInspectionResultApplication.apply(
                outcome,
                for: requestID,
                to: &inspectionState,
                presentation: &inspectionPresentation
            )
        }
    }

    private static func isPickerCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private func treeNodes(_ preview: AddTorrentPreview) -> [AddTorrentTreeNode] {
        var directorySizes: [String: Int64] = [:]
        var fileByPath: [String: FileEntry] = [:]

        for file in preview.files {
            fileByPath[file.relativePath] = file
            let components = file.relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            var path = ""
            for component in components.dropLast() {
                path = path.isEmpty ? component : "\(path)/\(component)"
                directorySizes[path, default: 0] += file.sizeBytes
            }
        }

        let paths = Array(Set(directorySizes.keys).union(fileByPath.keys)).sorted(by: Self.pathComesBefore)
        return paths.compactMap { path in
            let components = path.split(separator: "/").map(String.init)
            guard let name = components.last else { return nil }
            if let size = directorySizes[path] {
                return AddTorrentTreeNode(
                    id: path,
                    relativePath: path,
                    name: name,
                    sizeBytes: size,
                    kind: .directory,
                    depth: max(0, components.count - 1)
                )
            }
            guard let file = fileByPath[path] else { return nil }
            return AddTorrentTreeNode(
                id: file.relativePath,
                relativePath: file.relativePath,
                name: file.name,
                sizeBytes: file.sizeBytes,
                kind: .file,
                depth: max(0, components.count - 1)
            )
        }
    }

    private static func pathComesBefore(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/").map(String.init)
        let right = rhs.split(separator: "/").map(String.init)
        for (leftPart, rightPart) in zip(left, right) where leftPart != rightPart {
            return leftPart.localizedCaseInsensitiveCompare(rightPart) == .orderedAscending
        }
        return left.count < right.count
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func byteCount(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    private static func localizedSize(_ key: String, bytes: Int64) -> String {
        String(format: NSLocalizedString(key, comment: ""), byteCount(bytes))
    }
}

private struct AddTorrentTreeNode: Identifiable {
    let id: String
    let relativePath: String
    let name: String
    let sizeBytes: Int64
    let kind: FileKind
    let depth: Int
}
