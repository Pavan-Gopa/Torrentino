// Layer: UI (SwiftUI main window).
// Role: hosts the WP-07 transfer window (sidebar + table + files + status
// bar), with a degraded-agent banner on top when the lifecycle VM reports
// SMAppService problems.
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
        VStack(spacing: 0) {
            if viewModel.degraded {
                degradedBanner
            }
            TorrentListView(viewModel: transfers)
        }
        .frame(minWidth: 860, minHeight: 520)
        .task { viewModel.refreshServiceStatus() }
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
