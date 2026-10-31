import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject public var store: HomeAssistantStore
    @ObservedObject private var launchManager = LaunchAtLoginManager.shared
    @ObservedObject private var bonjour = BonjourDiscovery.shared

    @State private var urlInput: String = ""
    @State private var tokenInput: String = ""
    @State private var showPlainToken: Bool = false
    @State private var savedBannerVisible: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var testResult: ConnectionTestResult? = nil
    @State private var isCheckingUpdates: Bool = false

    public init(store: HomeAssistantStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            // Header
            HStack {
                NavigationBackButton {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        store.isShowingSettings = false
                    }
                }

                Spacer()

                Text("Ajustes — HaBar")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()
            }

            // Server URL Section
            VStack(alignment: .leading, spacing: 5) {
                Text("URL do Servidor Home Assistant")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))

                TextField("http://homeassistant.local:8123", text: $urlInput)
                    .glassInputField()

                if !bonjour.discoveredServers.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Servidor detectado na rede:")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))

                        ForEach(bonjour.discoveredServers) { srv in
                            Button {
                                urlInput = srv.urlString
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "network.badge.shield.half.filled")
                                    Text("\(srv.name) — \(srv.urlString)")
                                        .lineLimit(1)
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(AppTheme.amberAccent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            // Access Token Section
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Long-Lived Access Token")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))

                    Spacer()

                    Button {
                        if let pasted = NSPasteboard.general.string(forType: .string) {
                            tokenInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Colar")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.amberAccent)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showPlainToken.toggle()
                    } label: {
                        Image(systemName: showPlainToken ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                }

                if showPlainToken {
                    TextField("Cole seu token do Home Assistant...", text: $tokenInput)
                        .glassInputField()
                } else {
                    SecureField("Cole seu token do Home Assistant...", text: $tokenInput)
                        .glassInputField()
                }
            }

            // Test Connection & Save Action Row
            HStack(spacing: 8) {
                Button {
                    Task {
                        isTestingConnection = true
                        testResult = nil
                        let res = await store.testConnection(url: urlInput, token: tokenInput)
                        withAnimation {
                            testResult = res
                            isTestingConnection = false
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "network")
                        }
                        Text(isTestingConnection ? "Testando…" : "Testar Conexão")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .glassCard(cornerRadius: 8, fill: Color.white.opacity(0.08), borderColor: Color.white.opacity(0.12))
                }
                .buttonStyle(.plain)
                .disabled(isTestingConnection)

                Button {
                    store.saveSettingsAndConnect(url: urlInput, token: tokenInput)
                    withAnimation { savedBannerVisible = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation { savedBannerVisible = false }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        Text("Salvar & Sincronizar")
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 11.5))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.amberAccent)
                    )
                }
                .buttonStyle(.plain)
            }

            // Test Result Banner
            if let result = testResult {
                testResultBanner(for: result)
            }

            if savedBannerVisible {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(AppTheme.greenOnline)
                    Text("Configurações salvas e sincronização iniciada!")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Preferences
            VStack(alignment: .leading, spacing: 8) {
                Text("Preferências")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))

                HStack {
                    Text("Aparência")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Picker("", selection: $store.themeMode) {
                        ForEach(AppThemeMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 195)
                }

                HStack {
                    Text(L10n.t("Idioma", "Language"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Picker("", selection: $store.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { lang in
                            Text(lang.title).tag(lang)
                        }
                    }
                    .frame(width: 195)
                }

                HStack {
                    Text(L10n.t("Cômodo inicial", "Opening room"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Picker("", selection: $store.defaultOpeningRoomId) {
                        ForEach(store.rooms) { room in
                            Text(room.displayName).tag(room.id)
                        }
                    }
                    .frame(width: 195)
                }

                Toggle(isOn: $store.hotKeyEnabled) {
                    HStack {
                        Text("Atalho global no teclado")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                        Spacer()
                        Text("⌥⌘H")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { launchManager.isEnabled },
                    set: { launchManager.setEnabled($0) }
                )) {
                    Text("Iniciar automaticamente com o macOS")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $store.autoCheckUpdates) {
                    Text("Verificar atualizações automaticamente ao iniciar")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }
                .toggleStyle(.checkbox)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Updates & App Info
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HaBar v\(AppInfo.version)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))

                    if let msg = store.updateCheckMessage {
                        Text(msg)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(store.availableUpdate != nil ? AppTheme.amberAccent : .white.opacity(0.55))
                    }
                }

                Spacer()

                if let update = store.availableUpdate {
                    Button {
                        NSWorkspace.shared.open(update.url)
                    } label: {
                        Text("Baixar v\(update.version) ↗")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(AppTheme.amberAccent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task {
                            isCheckingUpdates = true
                            await store.checkForUpdates(userInitiated: true)
                            isCheckingUpdates = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isCheckingUpdates {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(isCheckingUpdates ? "Buscando…" : "Buscar Atualização")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .disabled(isCheckingUpdates)
                }
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Footer actions
            HStack {
                Button {
                    store.openHomeAssistantInBrowser()
                } label: {
                    Label("Abrir Web UI (:8123)", systemImage: "safari")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Encerrar HaBar", systemImage: "power")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(AppTheme.dangerRed)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            urlInput = store.serverURLString
            tokenInput = store.accessToken
            launchManager.refreshStatus()
            bonjour.startBrowsing()
        }
        .onDisappear {
            bonjour.stopBrowsing()
        }
    }

    @ViewBuilder
    private func testResultBanner(for result: ConnectionTestResult) -> some View {
        HStack(spacing: 6) {
            switch result {
            case .success(let version):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(AppTheme.greenOnline)
                Text("Conectado com sucesso! Home Assistant \(version)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            case .unauthorized:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppTheme.dangerRed)
                Text("Erro 401: Token inválido ou expirado.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.dangerRed)
            case .unreachable:
                Image(systemName: "wifi.exclamationmark")
                    .foregroundColor(.orange)
                Text("Servidor inacessível. Verifique rede e porta.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
            case .invalidURL:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("URL inválida. Use formato http://ip:8123")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 8, fill: Color.white.opacity(0.04), borderColor: Color.white.opacity(0.09))
    }
}
