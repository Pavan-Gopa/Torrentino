// Layer: UI (SwiftUI).
// Role: lifecycle spike control panel — one button per XPC/registration
// action, live status banner, event log.
// Must-not: edit engine state directly, or hide degraded mode.
// Invariants: renders EngineViewModel only; all actions are user-initiated;
// degraded banner is shown whenever SMAppService status != enabled.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: EngineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if viewModel.degraded {
                degradedBanner
            }
            controls
            logPane
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 500)
        .task { viewModel.refreshServiceStatus() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Torrentino Engine Lifecycle (WP-02 spike)")
                .font(.title2.bold())
            Text("Agent: \(AgentServiceRegistration.label) · Mach: \(TorrentinoXPCSecurity.machServiceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var degradedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Engine service degraded — SMAppService status: \(viewModel.statusText). " +
                 "Register the agent (and approve it in System Settings > Login Items if asked).")
                .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Service").font(.headline).frame(width: 70, alignment: .leading)
                Button("Register") { viewModel.register() }
                Button("Unregister") { viewModel.unregister() }
                Button("Refresh Status") { viewModel.refreshServiceStatus() }
            }
            HStack(spacing: 8) {
                Text("Engine").font(.headline).frame(width: 70, alignment: .leading)
                Button("Hello") { viewModel.hello() }
                Button("Health") { viewModel.health() }
                Button("Increment") { viewModel.increment() }
                Button("Get Counter") { viewModel.getCounter() }
                Button("Shutdown Agent", role: .destructive) { viewModel.shutdownAgent() }
            }
        }
        .disabled(viewModel.busy)
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: viewModel.logLines.count) { count in
                if count > 0 {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }
}
