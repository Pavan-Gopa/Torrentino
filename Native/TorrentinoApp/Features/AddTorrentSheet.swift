// Layer: UI (WP-07 add-torrent sheet).
// Role: collects a magnet/HTTP URL, a local .torrent file, or a torrent URL,
// plus the start-paused option, and drives the inspect → commitAdd lane.
// Must-not: bypass the agent's preflight (inspection happens agent-side), or
// touch disk on the main actor.
// Invariants: commitAdd is keyed by a fresh IdempotencyKey; the sheet closes
// only after the commit succeeds (the new record shows in the table).

import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentSheet: View {
    @ObservedObject var viewModel: TorrentListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var startPaused = false
    @State private var pickingFile = false
    @State private var fileURL: URL?
    @State private var errorMessage: String?
    @State private var committing = false

    private var canCommit: Bool {
        !committing && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fileURL != nil)
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

            HStack {
                Button(String(localized: "torrents.add.pick_file")) {
                    pickingFile = true
                }
                if let fileURL {
                    Label(fileURL.lastPathComponent, systemImage: "doc")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Toggle(String(localized: "torrents.add.start_paused"), isOn: $startPaused)
                .toggleStyle(.checkbox)

            if let errorMessage {
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
        .frame(width: 460)
        .fileImporter(
            isPresented: $pickingFile,
            allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                fileURL = urls.first
                text = ""
            case .failure:
                errorMessage = String(localized: "torrents.add.pick_failed")
            }
        }
    }

    private func commit() {
        guard canCommit else { return }
        committing = true
        defer { committing = false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fileURL {
            Task {
                await viewModel.addTorrentFile(fileURL, startPaused: startPaused)
                dismiss()
            }
        } else if trimmed.hasPrefix("magnet:") {
            Task {
                await viewModel.addMagnet(trimmed, startPaused: startPaused)
                dismiss()
            }
        } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            Task {
                await viewModel.addTorrentFileURL(trimmed, startPaused: startPaused)
                dismiss()
            }
        } else {
            errorMessage = String(localized: "torrents.add.invalid_source")
        }
    }
}
