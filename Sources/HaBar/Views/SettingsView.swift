import SwiftUI
import AppKit
import ServiceManagement

public struct SettingsView: View {
    @ObservedObject public var store: HomeAssistantStore
    @ObservedObject private var launchManager = LaunchAtLoginManager.shared
    @ObservedObject private var bonjour = BonjourDiscovery.shared
    @ObservedObject private var auditLogger: AuditLogger
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var urlInput = ""
    @State private var tokenInput = ""
    @State private var showToken = false
    @State private var testing = false
    @State private var result: ConnectionTestResult?
    @State private var saved = false
    @State private var showHistory = false
    @State private var savingError: String?

    public init(store: HomeAssistantStore) {
        self.store = store
        self.auditLogger = store.isScreenshotPreview ? AuditLogger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("habar-preview-history.json")) : .shared
    }
    public var body: some View {
        VStack(spacing: 0) {
            Form {
                connectionSection
                preferencesSection
                securitySection
                updatesSection
                historySection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button { store.openHomeAssistantInBrowser() } label: {
                    Label(L10n.t("Abrir Home Assistant", "Open Home Assistant"), systemImage: "safari")
                }
                Spacer()
                Button(L10n.t("Concluído", "Done")) { store.isShowingSettings = false }
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
        }
        .background(AppTheme.solidBackground)
        .preferredColorScheme(store.themeMode.colorScheme)
        .transaction { if reduceMotion { $0.animation = nil } }
        .onAppear {
            urlInput = store.serverURLString; tokenInput = store.accessToken
            if !store.isScreenshotPreview { launchManager.refreshStatus(); bonjour.startBrowsing() }
        }
        .onDisappear { showToken = false; bonjour.stopBrowsing() }
        .onChange(of: store.isShowingSettings) { _, visible in
            showToken = false
            if visible { urlInput = store.serverURLString; tokenInput = store.accessToken }
            else { tokenInput = "" }
        }
        .onChange(of: urlInput) { _, _ in result = nil; saved = false }
        .onChange(of: tokenInput) { _, _ in result = nil; saved = false }
    }

    private var connectionSection: some View {
        Section {
            TextField(L10n.t("URL do servidor", "Server URL"), text: $urlInput, prompt: Text("https://homeassistant.example"))
                .textFieldStyle(.roundedBorder)
            if URL(string: urlInput)?.scheme?.lowercased() == "http" {
                Label(L10n.t("HTTP não criptografa seu token. Use HTTPS para acesso remoto.", "HTTP doesn't encrypt your token. Use HTTPS for remote access."), systemImage: "lock.open")
                    .font(.caption).foregroundColor(.orange)
            }
            if let error = bonjour.errorMessage { Text(error).font(.caption).foregroundColor(.secondary) }
            ForEach(bonjour.discoveredServers) { server in
                Button { urlInput = server.urlString } label: {
                    Label("\(server.name) — \(server.urlString)", systemImage: "network")
                }
            }
            HStack {
                Group {
                    if showToken { TextField(L10n.t("Token de acesso", "Access token"), text: $tokenInput) }
                    else { SecureField(L10n.t("Token de acesso", "Access token"), text: $tokenInput) }
                }.textFieldStyle(.roundedBorder)
                Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                    .accessibilityLabel(showToken ? L10n.t("Ocultar token", "Hide token") : L10n.t("Mostrar token", "Show token"))
                Button(L10n.t("Colar", "Paste")) {
                    if let text = NSPasteboard.general.string(forType: .string) { tokenInput = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
            Text(L10n.t("Crie um token de longa duração em Perfil → Segurança no Home Assistant. A credencial é armazenada somente no Chaves do macOS.", "Create a long-lived token under Profile → Security in Home Assistant. The credential is stored only in macOS Keychain."))
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button(testing ? L10n.t("Testando…", "Testing…") : L10n.t("Testar conexão", "Test connection")) { testConnection() }
                    .disabled(testing || tokenInput.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.t("Salvar e conectar", "Save and connect")) {
                    saved = store.saveSettingsAndConnect(url: urlInput, token: tokenInput)
                    savingError = saved ? nil : store.toast?.text
                    if saved { showToken = false }
                }.buttonStyle(.borderedProminent)
                .disabled(HomeAssistantURL.normalized(urlInput) == nil)
            }
            if let result { connectionResult(result) }
            if saved { Label(L10n.t("Configurações salvas.", "Settings saved."), systemImage: "checkmark.circle").foregroundColor(.green) }
            if let savingError { Text(savingError).foregroundColor(.red) }
        } header: { Text(L10n.t("Conexão", "Connection")) }
    }

    private func testConnection() {
        testing = true; result = nil
        let url = urlInput; let token = tokenInput
        Task {
            let response = await store.testConnection(url: url, token: token)
            if url == urlInput && token == tokenInput { result = response }
            testing = false
        }
    }
    private func connectionResult(_ value: ConnectionTestResult) -> some View {
        let message: String
        switch value {
        case .success(let version): message = L10n.t("Conectado ao Home Assistant \(version)", "Connected to Home Assistant \(version)")
        case .invalidURL: message = HAAPIError.invalidURL.localizedDescription
        case .unauthorized: message = HAAPIError.unauthorized.localizedDescription
        case .forbidden: message = HAAPIError.forbidden.localizedDescription
        case .unreachable: message = HAAPIError.connection.localizedDescription
        }
        return Text(message).font(.callout).foregroundColor(.secondary)
    }

    private var preferencesSection: some View {
        Section {
            Picker(L10n.t("Aparência", "Appearance"), selection: $store.themeMode) {
                ForEach(AppThemeMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker(L10n.t("Idioma", "Language"), selection: $store.language) {
                ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker(L10n.t("Cômodo inicial", "Opening room"), selection: $store.defaultOpeningRoomId) {
                ForEach(store.rooms) { Text($0.displayName).tag($0.id) }
            }
            Picker(L10n.t("Barra de menus", "Menu bar"), selection: $store.menuBarDisplayMode) {
                ForEach(MenuBarDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            sensorPickers
            Toggle(L10n.t("Atalho global ⌥⌘H", "Global shortcut ⌥⌘H"), isOn: $store.hotKeyEnabled)
            Toggle(L10n.t("Iniciar com o macOS", "Launch at login"), isOn: Binding(get: { launchManager.isEnabled }, set: { launchManager.setEnabled($0) }))
            if let error = launchManager.errorMessage { Text(error).font(.caption).foregroundColor(.red) }
            if launchManager.needsApproval {
                Button(L10n.t("Autorizar nos Ajustes do Sistema", "Approve in System Settings")) { SMAppService.openSystemSettingsLoginItems() }
            }
        } header: { Text(L10n.t("Preferências", "Preferences")) }
    }
    private var sensorPickers: some View {
        Group {
            Picker(L10n.t("Sensor de temperatura", "Temperature sensor"), selection: $store.temperatureSensorId) {
                Text(L10n.t("Automático, se houver apenas um", "Automatic, if only one exists")).tag("")
                ForEach(store.devices.filter { $0.deviceClass == "temperature" }) { Text($0.name).tag($0.id) }
            }
            Picker(L10n.t("Sensor de potência", "Power sensor"), selection: $store.powerSensorId) {
                Text(L10n.t("Automático, se houver apenas um", "Automatic, if only one exists")).tag("")
                ForEach(store.devices.filter { $0.deviceClass == "power" }) { Text($0.name).tag($0.id) }
            }
        }
    }
    private var securitySection: some View {
        Section {
            Toggle(L10n.t("Exigir autenticação para abrir acessos", "Require authentication to open access controls"), isOn: $store.requireBiometricsForSensitiveActions)
            Text(L10n.t("Usa a autenticação do macOS, incluindo Touch ID ou senha. Se ela falhar, nenhum comando de abertura é enviado.", "Uses macOS authentication, including Touch ID or password. If authentication fails, no opening command is sent."))
                .font(.caption).foregroundColor(.secondary)
            Toggle(L10n.t("Confirmar antes de apagar todas as luzes", "Confirm before turning off all lights"), isOn: $store.confirmTurnOffAll)
        } header: { Text(L10n.t("Segurança", "Security")) }
    }
    private var updatesSection: some View {
        Section {
            HStack {
                Text("HaBar \(AppInfo.version)")
                Spacer()
                Button(L10n.t("Buscar atualização", "Check for updates")) { Task { await store.checkForUpdates(userInitiated: true) } }
                    .disabled(updateBusy)
            }
            Toggle(L10n.t("Verificar atualizações ao iniciar", "Check for updates on launch"), isOn: $store.autoCheckUpdates)
            if let message = store.updateCheckMessage { Text(message).font(.callout) }
            if !AppUpdater.supportsSecureUpdates {
                Text(L10n.t("Esta instalação não contém uma chave pública de atualização válida. Instale uma versão oficial do HaBar.", "This installation has no valid update public key. Install an official HaBar release."))
                    .font(.caption).foregroundColor(.secondary)
            }
            if let release = store.availableUpdate {
                Text(release.body).font(.caption).lineLimit(6)
                updateActions(release)
            }
        } header: { Text(L10n.t("Atualizações", "Updates")) }
    }
    private var updateBusy: Bool {
        switch store.updateStatus { case .checking, .downloading, .readyToInstall, .installing: return true; default: return false }
    }
    @ViewBuilder private func updateActions(_ release: ReleaseInfo) -> some View {
        switch store.updateStatus {
        case .downloading(let progress, _, _): ProgressView(value: progress)
        case .readyToInstall: Button(L10n.t("Reiniciar e atualizar", "Restart and update")) { store.applyUpdateAndRestart() }
        case .installing: ProgressView()
        default:
            if case .failed(let reason) = store.updateStatus { Text(reason).foregroundColor(.red) }
            HStack {
                if AppUpdater.supportsSecureUpdates && release.downloadURL != nil {
                    Button(L10n.t("Baixar atualização", "Download update")) { Task { await store.startInAppUpdate() } }
                }
                Link(L10n.t("Ver versão no GitHub", "View release on GitHub"), destination: release.url)
            }
        }
    }
    private var historySection: some View {
        Section {
            if let error = auditLogger.persistenceError { Text(error).font(.callout).foregroundColor(.red) }
            DisclosureGroup(L10n.t("Últimos 50 registros", "Last 50 entries"), isExpanded: $showHistory) {
                if auditLogger.entries.isEmpty { Text(L10n.t("Nenhuma ação registrada", "No recorded actions")) }
                ForEach(auditLogger.entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(entry.formattedTime) · \(entry.entityName)").font(.callout)
                        Text("\(entry.action) · \(entry.outcomeLabel)").font(.caption).foregroundColor(.secondary)
                        if entry.authenticated == true { Text(L10n.t("Autenticado pelo macOS", "Authenticated by macOS")).font(.caption) }
                    }
                }
                Button(L10n.t("Limpar histórico", "Clear history"), role: .destructive) { auditLogger.clear() }
            }
        } header: { Text(L10n.t("Histórico local", "Local history")) }
    }
}
