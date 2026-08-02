// Layer: UI (Settings shell).
// Role: placeholder Settings window with navigable tabs (General/Downloads/Connection).
// Must-not: persist settings or invent engine configuration in WP-03.
// Invariants: tabs only; empty content; strings from Localizable catalog.

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            SettingsPlaceholderTab()
                .tabItem {
                    Label(String(localized: "settings.general"), systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            SettingsPlaceholderTab()
                .tabItem {
                    Label(String(localized: "settings.downloads"), systemImage: "arrow.down.circle")
                }
                .tag(SettingsTab.downloads)

            SettingsPlaceholderTab()
                .tabItem {
                    Label(String(localized: "settings.connection"), systemImage: "network")
                }
                .tag(SettingsTab.connection)
        }
        .frame(width: 480, height: 280)
        .padding(16)
    }
}

private enum SettingsTab: Hashable {
    case general
    case downloads
    case connection
}

private struct SettingsPlaceholderTab: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(String(localized: "settings.placeholder"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
