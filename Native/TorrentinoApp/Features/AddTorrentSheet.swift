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

    private var canCommit: Bool {
        guard !committing, !inspectionPresentation.inspecting else { return false }
        if fileURL != nil {
            return inspectionPresentation.canCommit
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedBytes: Int64 {
        guard let preview = inspectionPresentation.preview else { return 0 }
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
                    guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          fileURL != nil else { return }
                    fileURL = nil
                    inspectionPresentation.preview = nil
                    inspectionPresentation.selectedPaths.removeAll()
                    inspectionPresentation.inspecting = false
                    _ = inspectionState.begin()
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

            if inspectionPresentation.inspecting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "torrents.add.reading_torrent"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let preview = inspectionPresentation.preview {
                inspectionSummary(preview)
            }

            Toggle(String(localized: "torrents.add.start_paused"), isOn: $startPaused)
                .toggleStyle(.checkbox)

            if let errorMessage = inspectionPresentation.errorMessage {
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
            consumePendingFile()
        }
        .onChange(of: viewModel.pendingAddFileURL) { newURL in
            if let newURL {
                consumePendingFile(newURL)
                viewModel.pendingAddFileURL = nil
            }
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
            if let preview = inspectionPresentation.preview {
                let selection = preview.files.map { file in
                    FileSelectionItem(
                        relativePath: file.relativePath,
                        priority: inspectionPresentation.selectedPaths.contains(file.relativePath) ? .normal : .skip
                    )
                }
                let saveLocation = destinationURL.map { PersistedLocation(path: $0.path) }
                let success = await viewModel.commitInspectedTorrent(
                    preview,
                    saveLocation: saveLocation,
                    fileSelection: selection,
                    startPaused: startPaused
                )
                if success {
                    dismiss()
                } else if let err = viewModel.lastAddError {
                    inspectionPresentation.errorMessage = err
                }
            } else if trimmed.hasPrefix("magnet:") {
                let success = await viewModel.addMagnet(trimmed, startPaused: startPaused)
                if success {
                    dismiss()
                } else if let err = viewModel.lastAddError {
                    inspectionPresentation.errorMessage = err
                }
            } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                let success = await viewModel.addTorrentFileURL(trimmed, startPaused: startPaused)
                if success {
                    dismiss()
                } else if let err = viewModel.lastAddError {
                    inspectionPresentation.errorMessage = err
                }
            } else {
                inspectionPresentation.errorMessage = String(localized: "torrents.add.invalid_source")
            }
        }
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

    private func beginInspection(for url: URL) {
        let requestID = inspectionState.begin()
        guard TorrentDropRouting.isTorrentDropURL(url) else {
            inspectionPresentation.inspecting = false
            inspectionPresentation.errorMessage = String(localized: "torrents.add.pick_failed")
            return
        }
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
