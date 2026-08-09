// Layer: UI (SwiftUI main window).
// Role: hosts the WP-07 transfer window (sidebar + table + files + status
// bar), with a degraded-agent banner on top when the lifecycle VM reports
// SMAppService problems, and the native empty state when the authoritative
// list is empty.
// Must-not: invent torrents, edit engine state, or hide degraded agent status.
// Invariants: UI is not source of truth; the list view model talks to the
// agent over the command lane; empty copy comes from String Catalog.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: EngineViewModel
    @StateObject private var transfers: TorrentListViewModel

    init() {
        _transfers = StateObject(wrappedValue: AppContext.transfers)
    }

    var body: some View {
        Group {
            if transfers.torrents.isEmpty {
                VStack(spacing: 0) {
                    if viewModel.degraded {
                        degradedBanner
                    }
                    emptyState
                }
            } else {
                VStack(spacing: 0) {
                    if viewModel.degraded {
                        degradedBanner
                    }
                    TorrentListView(viewModel: transfers)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .task { viewModel.refreshServiceStatus() }
        .task { await transfers.start() }
        .sheet(isPresented: $transfers.showAddSheet) {
            AddTorrentSheet(viewModel: transfers)
        }
        .sheet(isPresented: $transfers.showCreateSheet) {
            CreateTorrentSheet(viewModel: transfers)
        }
    }

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
            Button {
                transfers.showAddSheet = true
            } label: {
                Label(String(localized: "torrents.add"), systemImage: "plus")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var degradedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(String(localized: "error.xpc_unavailable"))
                .font(.callout)
            Text("· \(viewModel.statusText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.18))
    }
}
