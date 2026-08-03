// Layer: UI (Settings window).
// Role: full Settings window with General, Bandwidth, Network, Transfers, and Notifications tabs,
// utilizing SettingsTransaction for transactional validate -> persist -> apply -> rollback.
// Must-not: store passwords in UserDefaults or skip validation.
// Invariants: password stored in KeychainStore; invalid candidate shows inline errors.

import SwiftUI
import ServiceManagement
import TorrentinoIPC

struct SettingsView: View {
    @ObservedObject var viewModel: EngineViewModel = AppContext.shared

    @State private var selectedTab: SettingsTab = .general
    @State private var downloadDir: String = "~/Downloads"
    @State private var maxDownKB: String = "0"
    @State private var maxUpKB: String = "0"
    @State private var listenPort: String = "6881"
    @State private var dhtEnabled: Bool = true
    @State private var lsdEnabled: Bool = true
    @State private var upnpEnabled: Bool = true
    @State private var natPmpEnabled: Bool = true
    @State private var encryptionEnabled: Bool = true
    @State private var launchAtLogin: Bool = false

    // Proxy settings
    @State private var proxyKind: ProxyConfiguration.Kind = .none
    @State private var proxyHost: String = ""
    @State private var proxyPort: String = "1080"
    @State private var proxyUsername: String = ""
    @State private var proxyPassword: String = ""

    // Notifications
    @State private var notifyComplete: Bool = true
    @State private var notifyAllComplete: Bool = true
    @State private var notifyError: Bool = true

    // Inline errors & feedback
    @State private var validationErrors: [SettingsValidationError] = []
    @State private var applyStatus: String?
    @State private var applyStatusIsError = false
    @State private var settingsRevision: SettingsRevision?
    @State private var isLoadingSettings = true

    enum SettingsTab: Hashable, CaseIterable {
        case general
        case bandwidth
        case network
        case transfers
        case notifications

        var title: String {
            switch self {
            case .general: return String(localized: "settings.tab.general")
            case .bandwidth: return String(localized: "settings.tab.bandwidth")
            case .network: return String(localized: "settings.tab.network")
            case .transfers: return String(localized: "settings.tab.transfers")
            case .notifications: return String(localized: "settings.tab.notifications")
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .bandwidth: return "arrow.up.arrow.down"
            case .network: return "network"
            case .transfers: return "tray.and.arrow.down"
            case .notifications: return "bell"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.icon) }
                    .tag(SettingsTab.general)

                bandwidthTab
                    .tabItem { Label(SettingsTab.bandwidth.title, systemImage: SettingsTab.bandwidth.icon) }
                    .tag(SettingsTab.bandwidth)

                networkTab
                    .tabItem { Label(SettingsTab.network.title, systemImage: SettingsTab.network.icon) }
                    .tag(SettingsTab.network)

                transfersTab
                    .tabItem { Label(SettingsTab.transfers.title, systemImage: SettingsTab.transfers.icon) }
                    .tag(SettingsTab.transfers)

                notificationsTab
                    .tabItem { Label(SettingsTab.notifications.title, systemImage: SettingsTab.notifications.icon) }
                    .tag(SettingsTab.notifications)
            }
            .padding(16)

            footerBar
        }
        .frame(width: 520, height: 420)
        .task { await loadCurrentSettings() }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section(String(localized: "settings.general.launch")) {
                Toggle(String(localized: "settings.general.launch_at_login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        updateLaunchAtLogin(newValue)
                    }
            }

            Section(String(localized: "settings.general.save_location")) {
                HStack {
                    TextField(String(localized: "settings.general.default_path"), text: $downloadDir)
                        .textFieldStyle(.roundedBorder)
                    Button(String(localized: "settings.general.browse")) {
                        selectSaveDirectory()
                    }
                }
            }
        }
    }

    // MARK: - Bandwidth Tab

    private var bandwidthTab: some View {
        Form {
            Section(String(localized: "settings.bandwidth.limits")) {
                LabeledContent(String(localized: "settings.bandwidth.max_download")) {
                    HStack {
                        TextField("0", text: $maxDownKB)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        Text(String(localized: "settings.bandwidth.unlimited_suffix"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(String(localized: "settings.bandwidth.max_upload")) {
                    HStack {
                        TextField("0", text: $maxUpKB)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        Text(String(localized: "settings.bandwidth.unlimited_suffix"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Network Tab

    private var networkTab: some View {
        Form {
            Section(String(localized: "settings.network.port")) {
                LabeledContent(String(localized: "settings.network.listen_port")) {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("6881", text: $listenPort)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        if let error = validationErrors.first(where: { $0.field == "listenPort" }) {
                            Text(localizedValidationMessage(error))
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Section(String(localized: "settings.network.features")) {
                Toggle(String(localized: "settings.network.dht"), isOn: $dhtEnabled)
                Toggle(String(localized: "settings.network.lsd"), isOn: $lsdEnabled)
                Toggle(String(localized: "settings.network.upnp"), isOn: $upnpEnabled)
                Toggle(String(localized: "settings.network.nat_pmp"), isOn: $natPmpEnabled)
                Toggle(String(localized: "settings.network.encryption"), isOn: $encryptionEnabled)
            }

            Section(String(localized: "settings.network.proxy")) {
                Picker(String(localized: "settings.network.proxy_kind"), selection: $proxyKind) {
                    Text(String(localized: "settings.proxy.none")).tag(ProxyConfiguration.Kind.none)
                    Text(String(localized: "settings.proxy.socks5")).tag(ProxyConfiguration.Kind.socks5)
                    Text(String(localized: "settings.proxy.http")).tag(ProxyConfiguration.Kind.http)
                }
                if proxyKind != .none {
                    TextField(String(localized: "settings.proxy.host"), text: $proxyHost)
                        .textFieldStyle(.roundedBorder)
                    TextField(String(localized: "settings.proxy.port"), text: $proxyPort)
                        .textFieldStyle(.roundedBorder)
                    TextField(String(localized: "settings.proxy.username"), text: $proxyUsername)
                        .textFieldStyle(.roundedBorder)
                    SecureField(String(localized: "settings.proxy.password"), text: $proxyPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: - Transfers Tab

    private var transfersTab: some View {
        Form {
            Section(String(localized: "settings.transfers.behavior")) {
                Text(String(localized: "settings.transfers.info"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Notifications Tab

    private var notificationsTab: some View {
        Form {
            Section(String(localized: "settings.notifications.events")) {
                Toggle(String(localized: "settings.notifications.torrent_complete"), isOn: $notifyComplete)
                    .onChange(of: notifyComplete) { newValue in
                        NotificationManager.shared.notifyOnTorrentComplete = newValue
                        if newValue { NotificationManager.shared.requestAuthorization() }
                    }
                Toggle(String(localized: "settings.notifications.all_complete"), isOn: $notifyAllComplete)
                    .onChange(of: notifyAllComplete) { newValue in
                        NotificationManager.shared.notifyOnAllComplete = newValue
                        if newValue { NotificationManager.shared.requestAuthorization() }
                    }
                Toggle(String(localized: "settings.notifications.error"), isOn: $notifyError)
                    .onChange(of: notifyError) { newValue in
                        NotificationManager.shared.notifyOnError = newValue
                        if newValue { NotificationManager.shared.requestAuthorization() }
                    }
            }
        }
    }

    // MARK: - Footer & Save

    private var footerBar: some View {
        VStack(spacing: 4) {
            if !validationErrors.isEmpty {
                ForEach(validationErrors, id: \.field) { err in
                    Text("\(localizedFieldName(err.field)): \(localizedValidationMessage(err))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if let applyStatus {
                Text(applyStatus)
                    .font(.caption)
                    .foregroundStyle(applyStatusIsError ? .red : .green)
            }
            HStack {
                Spacer()
                Button(String(localized: "settings.apply")) {
                    applySettings()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoadingSettings || settingsRevision == nil)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Actions

    private func loadCurrentSettings() async {
        isLoadingSettings = true
        do {
            let command = EngineCommandV1.fetchSettings(FetchSettingsRequest(requestID: RequestID()))
            guard case .settingsFetch(let result) = try await viewModel.client.sendCommand(command) else {
                throw EngineClientError.protocolMismatch(details: "unexpected fetchSettings reply")
            }
            let storedPassword = await KeychainStore.loadProxyPassword()
            applyFormValues(result.settings)
            proxyPassword = storedPassword ?? ""
            settingsRevision = result.revision
            validationErrors = []
            applyStatus = nil
            applyStatusIsError = false
        } catch {
            settingsRevision = nil
            applyStatus = String(localized: "settings.load_failed")
            applyStatusIsError = true
        }
        isLoadingSettings = false
    }

    private func applyFormValues(_ settings: EngineSettings) {
        downloadDir = settings.downloadDirectory
        maxDownKB = String(settings.maxDownloadBytesPerSec / 1024)
        maxUpKB = String(settings.maxUploadBytesPerSec / 1024)
        listenPort = String(settings.listenPort)
        dhtEnabled = settings.dhtEnabled
        lsdEnabled = settings.lsdEnabled
        upnpEnabled = settings.upnpEnabled
        natPmpEnabled = settings.natPmpEnabled
        encryptionEnabled = settings.encryptionEnabled
        proxyKind = settings.proxy.kind
        proxyHost = settings.proxy.host
        proxyPort = String(settings.proxy.port)
        proxyUsername = settings.proxy.username ?? ""
    }

    private func applySettings() {
        validationErrors.removeAll()
        applyStatus = nil
        applyStatusIsError = false
        guard let expectedRevision = settingsRevision else {
            applyStatus = String(localized: "settings.load_failed")
            applyStatusIsError = true
            return
        }

        guard let downRate = parseRate(maxDownKB, field: "maxDownloadBytesPerSec"),
              let upRate = parseRate(maxUpKB, field: "maxUploadBytesPerSec") else {
            return
        }
        let port = UInt16(listenPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let proxyPortValue = UInt16(proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        let candidate = EngineSettings(
            downloadDirectory: downloadDir,
            maxDownloadBytesPerSec: downRate,
            maxUploadBytesPerSec: upRate,
            listenPort: port,
            dhtEnabled: dhtEnabled,
            lsdEnabled: lsdEnabled,
            upnpEnabled: upnpEnabled,
            natPmpEnabled: natPmpEnabled,
            encryptionEnabled: encryptionEnabled,
            proxy: ProxyConfiguration(
                kind: proxyKind,
                host: proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
                port: proxyPortValue,
                username: proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: nil
            )
        )

        // Pure client-side validation check first
        let errors = SettingsRules.validate(candidate)
        guard errors.isEmpty else {
            validationErrors = errors
            return
        }

        // This is a side-effect-free UI preflight. The agent repeats the same
        // transaction with its real persistence/apply/rollback context below.
        let preflight = SettingsTransaction.run(
            candidate: candidate,
            expectedRevision: expectedRevision,
            context: SettingsTransaction.Context(
                currentRevision: expectedRevision,
                persist: { _, revision in revision + 1 },
                apply: { _ in .success(()) },
                rollback: { _, _ in }
            )
        )
        guard case .applied = preflight else { return }

        Task {
            let command = EngineCommandV1.applySettings(ApplySettingsRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                candidate: candidate,
                expectedRevision: expectedRevision
            ))
            do {
                guard case .settingsApply(let result) = try await viewModel.client.sendCommand(command) else {
                    throw EngineClientError.protocolMismatch(details: "unexpected applySettings reply")
                }
                settingsRevision = result.revision
                // Credentials are committed only after the agent accepted the
                // complete settings transaction; the password never crosses IPC.
                let credentialsSaved: Bool
                if proxyKind != .none && !proxyPassword.isEmpty {
                    credentialsSaved = await KeychainStore.saveProxyPassword(proxyPassword)
                } else {
                    credentialsSaved = await KeychainStore.deleteProxyPassword()
                }
                if credentialsSaved {
                    applyStatus = String(localized: "settings.saved_successfully")
                    applyStatusIsError = false
                } else {
                    applyStatus = String(localized: "settings.keychain_failed")
                    applyStatusIsError = true
                }
            } catch {
                applyStatus = localizedApplyError(error)
                applyStatusIsError = true
            }
        }
    }

    private func parseRate(_ value: String, field: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        guard let kilobytes = Int64(trimmed) else {
            validationErrors.append(SettingsValidationError(field: field, message: "settings.validation.number_required"))
            return nil
        }
        let conversion = kilobytes.multipliedReportingOverflow(by: 1024)
        guard !conversion.overflow else {
            validationErrors.append(SettingsValidationError(field: field, message: "settings.validation.number_required"))
            return nil
        }
        return conversion.partialValue
    }

    private func localizedValidationMessage(_ error: SettingsValidationError) -> String {
        String(localized: String.LocalizationValue(error.message))
    }

    private func localizedFieldName(_ field: String) -> String {
        switch field {
        case "downloadDirectory": return String(localized: "settings.field.download_directory")
        case "maxDownloadBytesPerSec": return String(localized: "settings.field.max_download")
        case "maxUploadBytesPerSec": return String(localized: "settings.field.max_upload")
        case "listenPort": return String(localized: "settings.field.listen_port")
        case "proxyHost": return String(localized: "settings.field.proxy_host")
        case "proxyPort": return String(localized: "settings.field.proxy_port")
        default: return String(localized: "settings.field.value")
        }
    }

    private func localizedApplyError(_ error: Error) -> String {
        guard let clientError = error as? EngineClientError else {
            return String(localized: "settings.apply_failed")
        }
        if case .fault(let fault) = clientError {
            switch fault.code {
            case .settingsRevisionConflict:
                return String(localized: "settings.conflict_retry")
            case .settingsValidationFailed:
                return String(localized: "settings.validation_failed")
            case .engineBusy, .engineNotReady, .operationTimeout:
                return String(localized: "settings.engine_apply_failed")
            default:
                break
            }
        }
        return String(localized: "settings.apply_failed")
    }

    private func selectSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            downloadDir = url.path
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                applyStatus = String(localized: "settings.launch_login_failed")
            }
        }
    }
}
