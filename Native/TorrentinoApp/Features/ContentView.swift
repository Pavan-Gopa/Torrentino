// Layer: UI (SwiftUI main window).
// Role: native empty state when the authoritative torrent list is empty.
// Must-not: invent torrents, edit engine state, or hide degraded agent status.
// Invariants: UI is not source of truth; empty copy comes from String Catalog.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: EngineViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.degraded {
                degradedBanner
            }
            emptyState
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { viewModel.refreshServiceStatus() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "empty.no_torrents"))
                .font(.title2.weight(.semibold))
            Text(String(localized: "empty.subtitle"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
