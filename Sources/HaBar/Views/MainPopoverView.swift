import SwiftUI

public struct MainPopoverView: View {
    @ObservedObject public var store: HomeAssistantStore
    @State private var showAllScenes: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var searchFocused: Bool

    private static let twoColumnGrid = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    public init(store: HomeAssistantStore) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            if store.isScreenshotPreview {
                AppTheme.solidBackground
                    .ignoresSafeArea()
            } else {
                if !reduceTransparency {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow).ignoresSafeArea()
                } else { AppTheme.solidBackground.ignoresSafeArea() }

                AppTheme.popoverBackground
                    .ignoresSafeArea()
            }

            if let detailDevice = store.selectedDeviceForDetail {
                ScrollView { LightDetailView(store: store, deviceId: detailDevice.id).padding(16) }
            } else {
                VStack(spacing: 0) {
                    headerSection.padding(16)
                    Divider()
                    ScrollView { dashboardContent.padding(16) }
                    Divider()
                    footerSection.padding(12)
                }
            }

            // Toast overlay
            if let toast = store.toast {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(toast.isError ? AppTheme.dangerRed : AppTheme.greenOnline)
                        Text(toast.text)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(AppTheme.text)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.solidBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(toast.isError ? AppTheme.dangerRed.opacity(0.6) : AppTheme.greenOnline.opacity(0.6), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 3)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))

                    Spacer()
                }
                .zIndex(200)
            }

        }
        .frame(width: AppTheme.popoverWidth, height: min(680, max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 70)))
        .preferredColorScheme(store.themeMode.colorScheme)
        .transaction { if reduceMotion { $0.animation = nil } }
        .alert(store.pendingConfirmation?.title ?? "", isPresented: Binding(get: { store.pendingConfirmation != nil }, set: { if !$0 { store.pendingConfirmation = nil } })) {
            if let confirmation = store.pendingConfirmation {
                Button(L10n.t("Cancelar", "Cancel"), role: .cancel) { store.pendingConfirmation = nil }
                Button(confirmation.confirmTitle) { store.pendingConfirmation = nil; confirmation.action() }
            }
        } message: { Text(store.pendingConfirmation?.message ?? "") }
        .onExitCommand {
            if store.pendingConfirmation != nil { store.pendingConfirmation = nil }
            else if store.isSearchVisible { store.isSearchVisible = false; store.searchQuery = "" }
            else if store.selectedDeviceForDetail != nil { store.selectedDeviceForDetail = nil }
            else { NSApp.keyWindow?.performClose(nil) }
        }
        .onChange(of: store.isSearchVisible) { _, visible in searchFocused = visible }
        .onKeyPress(characters: .decimalDigits) { press in
            guard store.pendingConfirmation == nil && store.selectedDeviceForDetail == nil && !store.isSearchVisible else { return .ignored }
            if let digit = Int(press.characters), (1...9).contains(digit) {
                let roomIndex = digit - 1
                if store.rooms.indices.contains(roomIndex) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        store.selectedRoom = store.rooms[roomIndex]
                    }
                    return .handled
                }
            }
            return .ignored
        }
    }

    // MARK: - Main Dashboard

    private var dashboardContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !store.hasCredentials {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("Demonstração — nenhum dispositivo real é controlado", "Demo — no real devices are controlled")).font(.callout)
                    Button(L10n.t("Conectar ao Home Assistant", "Connect to Home Assistant")) { store.isShowingSettings = true }
                }.padding(12).glassCard()
            }
            if !store.connectionStatus.isHealthy {
                HStack {
                    Text(store.connectionStatus.labelText).font(.callout)
                    Spacer()
                    Button(L10n.t("Conectar", "Connect")) { store.isShowingSettings = true }
                }.padding(10).glassCard()
            }
            if !store.isDismissedUpdateBanner {
                switch store.updateStatus {
                case .available(let update):
                    updateBanner(update)
                case .downloading(let progress, _, _):
                    downloadingBanner(progress: progress)
                case .readyToInstall(let update, _):
                    readyToInstallBanner(update)
                case .failed(let error):
                    failedUpdateBanner(error)
                default:
                    EmptyView()
                }
            }

            if store.isSearchVisible {
                searchFieldSection
            }

            Divider()
                .background(AppTheme.surface.opacity(0.09))

            roomTabsSection
            devicesSection
            if !store.scenes.isEmpty && !store.isSearchVisible { scenesSection }
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            if let appIcon = NSApplication.shared.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("HaBar")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(AppTheme.text)

                HStack(spacing: 6) {
                    let dotColor = store.connectionStatus.isHealthy ? AppTheme.greenOnline : Color.orange
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: dotColor.opacity(0.8), radius: 4)

                    Text(store.connectionStatus.labelText)
                        .lineLimit(1).truncationMode(.middle)
                        .help(store.connectionStatus.labelText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.text.opacity(0.62))
                }
            }

            Spacer()

            HStack(spacing: 8) {
                CircularIconButton(
                    systemName: "arrow.clockwise",
                    helpText: L10n.t("Atualizar estados do Home Assistant", "Refresh Home Assistant states")
                ) {
                    store.connectToHomeAssistant()
                }

                CircularIconButton(
                    systemName: "gearshape",
                    helpText: L10n.t("Configurações do Home Assistant", "Home Assistant settings")
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        store.isShowingSettings = true
                    }
                }

                CircularIconButton(
                    systemName: "magnifyingglass",
                    isHighlighted: store.isSearchVisible,
                    helpText: L10n.t("Filtrar dispositivos", "Search devices")
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.isSearchVisible.toggle()
                        if !store.isSearchVisible {
                            store.searchQuery = ""
                        }
                    }
                }
            }
        }
    }

    private func updateBanner(_ update: ReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundColor(AppTheme.amberAccent)
            Text(L10n.t("HaBar v\(update.version) disponível!", "HaBar v\(update.version) available!"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.text.opacity(0.95))

            Spacer()

            if update.downloadURL != nil && AppUpdater.supportsSecureUpdates {
                Button {
                    Task { await store.startInAppUpdate() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(L10n.t("Atualizar", "Update"))
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AppTheme.amberAccent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                NSWorkspace.shared.open(update.url)
            } label: {
                Text(L10n.t("Ver ↗", "View ↗"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppTheme.amberAccent)
            }
            .buttonStyle(.plain)

            Button {
                store.dismissUpdateBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(AppTheme.text.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCard(cornerRadius: 8, fill: AppTheme.amberAccent.opacity(0.15), borderColor: AppTheme.amberAccent.opacity(0.35))
    }

    private func downloadingBanner(progress: Double) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(AppTheme.amberAccent)
                Text(L10n.t("Baixando atualização... \(Int(progress * 100))%", "Downloading update... \(Int(progress * 100))%"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.text.opacity(0.95))
                Spacer()
            }

            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(AppTheme.amberAccent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCard(cornerRadius: 8, fill: AppTheme.amberAccent.opacity(0.15), borderColor: AppTheme.amberAccent.opacity(0.35))
    }

    private func readyToInstallBanner(_ update: ReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(L10n.t("v\(update.version) pronta para reiniciar!", "v\(update.version) ready to restart!"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.text.opacity(0.95))

            Spacer()

            Button {
                store.applyUpdateAndRestart()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                    Text(L10n.t("Reiniciar Agora", "Restart Now"))
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AppTheme.amberAccent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCard(cornerRadius: 8, fill: Color.green.opacity(0.15), borderColor: Color.green.opacity(0.35))
    }

    private func failedUpdateBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(L10n.t("Falha ao atualizar.", "Update failed."))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.text.opacity(0.95))

            Spacer()

            if let update = store.availableUpdate {
                Button {
                    NSWorkspace.shared.open(update.url)
                } label: {
                    Text(L10n.t("Baixar Manualmente ↗", "Manual Download ↗"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.amberAccent)
                }
                .buttonStyle(.plain)
            }

            Button {
                store.dismissUpdateBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(AppTheme.text.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCard(cornerRadius: 8, fill: Color.red.opacity(0.12), borderColor: Color.red.opacity(0.3))
    }

    private var searchFieldSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.text.opacity(0.5))

                TextField(L10n.t("Buscar ou comandar (ex: sala 50, apagar tudo)...", "Search or command (e.g. living 50, turn off all)..."), text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(AppTheme.text)
                    .focused($searchFocused)
                    .onSubmit {
                        if let action = spotlightAction {
                            executeSpotlightAction(action)
                        }
                    }

                if !store.searchQuery.isEmpty {
                    Button {
                        store.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.text.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassCard(
                cornerRadius: AppTheme.controlCornerRadius,
                fill: AppTheme.surface.opacity(0.06),
                borderColor: AppTheme.surface.opacity(0.12)
            )

            ForEach(Array(spotlightActions.enumerated()), id: \.offset) { _, action in
                Button {
                    executeSpotlightAction(action)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: action.icon)
                            .foregroundColor(AppTheme.amberAccent)
                        Text(action.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.text)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassCard(
                        cornerRadius: 6,
                        fill: AppTheme.amberAccent.opacity(0.18),
                        borderColor: AppTheme.amberAccent.opacity(0.35)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var spotlightAction: SpotlightAction? { spotlightActions.count == 1 ? spotlightActions.first : nil }
    private var spotlightActions: [SpotlightAction] {
        let q = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !q.isEmpty else { return [] }
        if ["apagar tudo", "desligar tudo", "off all", "turn off all"].contains(q) { return [.turnOffAll] }
        let parts = q.split(separator: " ")
        if parts.count >= 2, let value = Double(parts.last!.replacingOccurrences(of: ",", with: ".")), (0...100).contains(value) {
            let name = parts.dropLast().joined(separator: " ")
            let lights = store.devices.filter { $0.domain == .light && $0.supportsBrightness && $0.canControl && $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(name) }
            let rooms = store.rooms.filter { $0.id != HARoom.favorites.id && $0.displayName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(name) }
            return rooms.map { .roomBrightness($0, value) } + lights.map { .setBrightness($0, value) }
        }
        return store.scenes.filter { $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(q) }.map { .runScene($0) }
    }

    private enum SpotlightAction {
        case turnOffAll
        case runScene(HASceneItem)
        case setBrightness(HADeviceItem, Double)
        case roomBrightness(HARoom, Double)

        var title: String {
            switch self {
            case .turnOffAll:
                return L10n.t("Apagar todas as lâmpadas", "Turn off all lights")
            case .runScene(let scene):
                return L10n.t("Executar cena: \(scene.name)", "Activate scene: \(scene.name)")
            case .roomBrightness(let room, let pct):
                return L10n.t("Cômodo: \(room.displayName) → \(Int(pct))%", "Room: \(room.displayName) → \(Int(pct))%")
            case .setBrightness(let dev, let pct):
                return L10n.t("Definir \(dev.name) para \(Int(pct))%", "Set \(dev.name) to \(Int(pct))%")
            }
        }

        var icon: String {
            switch self {
            case .turnOffAll: return "lightbulb.slash"
            case .runScene: return "sparkles"
            case .roomBrightness: return "house.fill"
            case .setBrightness: return "slider.horizontal.3"
            }
        }
    }

    private func executeSpotlightAction(_ action: SpotlightAction) {
        switch action {
        case .turnOffAll:
            store.requestTurnOffAllLights()
        case .runScene(let scene):
            store.activateScene(scene.id)
        case .roomBrightness(let room, let pct):
            for device in store.devices where device.room.id == room.id { store.setBrightness(for: device.id, percentage: pct) }
        case .setBrightness(let dev, let pct):
            store.setBrightness(for: dev.id, percentage: pct)
        }
        store.searchQuery = ""
        store.isSearchVisible = false
    }

    private var scenesSection: some View {
        let allScenes = store.filteredScenes
        let visibleScenes = showAllScenes ? allScenes : Array(allScenes.prefix(4))

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.t("Cenas Rápidas", "Quick scenes"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(AppTheme.text.opacity(0.92))

                Spacer()

                if allScenes.count > 4 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showAllScenes.toggle()
                        }
                    } label: {
                        Text(showAllScenes ? L10n.t("Mostrar 4", "Show 4") : L10n.t("Ver todas (\(allScenes.count))", "Show all (\(allScenes.count))"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.amberAccent)
                    }
                    .buttonStyle(.plain)
                }

                if store.activeLightsCount > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.requestTurnOffAllLights()
                        }
                    } label: {
                        Text(L10n.t("Apagar luzes", "Turn off lights"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(AppTheme.text.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: Self.twoColumnGrid, spacing: 8) {
                ForEach(visibleScenes) { scene in
                    VStack(alignment: .leading, spacing: 4) {
                    ScenePillCard(scene: scene) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.activateScene(scene.id)
                        }
                    }
                    if let status = store.commandStatuses[scene.id] {
                        Text(status.label).font(.caption).foregroundColor(.secondary)
                    } else if scene.isActive {
                        Text(L10n.t("Última executada", "Last activated")).font(.caption).foregroundColor(.secondary)
                    }
                    }
                }
            }
        }
    }

    // MARK: - Room buttons

    private var roomTabsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("Cômodos", "Rooms"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Menu {
                    Button(L10n.t("Ligar dispositivos: \(store.selectedRoom.displayName)", "Turn on devices: \(store.selectedRoom.displayName)")) { store.setRoomPower(store.selectedRoom, on: true) }
                    Button(L10n.t("Desligar dispositivos: \(store.selectedRoom.displayName)", "Turn off devices: \(store.selectedRoom.displayName)")) { store.setRoomPower(store.selectedRoom, on: false) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 28)
                .accessibilityLabel(L10n.t("Ações de \(store.selectedRoom.displayName)", "Actions for \(store.selectedRoom.displayName)"))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                ForEach(store.rooms) { room in
                    let selected = room.id == store.selectedRoom.id
                    Button { store.selectedRoom = room } label: {
                        HStack(spacing: 7) {
                            Image(systemName: room.iconSystemName).font(.system(size: 12))
                                .frame(width: 16)
                            Text(room.displayName).font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .foregroundColor(AppTheme.text)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? AppTheme.amberAccent.opacity(0.22) : AppTheme.surface.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? AppTheme.amberAccent.opacity(0.75) : AppTheme.surface.opacity(0.12), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .help(room.displayName)
                    .accessibilityLabel(room.displayName)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Devices Section

    private var devicesSection: some View {
        let items = store.filteredDevices

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.t("Iluminação & Dispositivos — \(store.selectedRoom.displayName)", "Lighting & Devices — \(store.selectedRoom.displayName)"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.text.opacity(0.92))

                Spacer()

                Text(L10n.t("\(items.count) \(items.count == 1 ? "item" : "itens")", "\(items.count) \(items.count == 1 ? "item" : "items")"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.text.opacity(0.45))
            }

            if store.isLoading && items.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 6)
                    Text(L10n.t("Carregando dispositivos…", "Loading devices…"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.text.opacity(0.6))
                    Spacer()
                }
                .padding(.vertical, 22)
                .glassCard()
            } else if items.isEmpty {
                HStack {
                    Spacer()
                    Text(store.isSearchVisible ? L10n.t("Nenhum dispositivo encontrado", "No devices found") : L10n.t("Nenhum dispositivo neste cômodo. Use a busca ou escolha outro cômodo.", "No devices in this room. Search or choose another room."))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.text.opacity(0.45))
                        .padding(.vertical, 18)
                    Spacer()
                }
                .glassCard()
            } else {
                LazyVGrid(columns: Self.twoColumnGrid, spacing: 10) {
                    ForEach(items) { device in
                        DeviceControlCard(
                            device: device,
                            serverURLString: store.serverURLString,
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    store.requestToggle(device)
                                }
                            },
                            onOpenDetail: {
                                store.selectedDeviceForDetail = device
                            },
                            onBrightnessChange: { newPct in
                                store.setBrightness(for: device.id, percentage: newPct)
                            },
                            commandStatus: store.commandStatuses[device.id],
                            onRetry: { store.retryCommand(for: device.id) },
                            onToggleFavorite: {
                                withAnimation {
                                    store.toggleFavorite(device.id)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private var footerSection: some View {
        HStack(spacing: 5) {
            Spacer()
            let count = store.activeDevicesCount
            let lightLabel = L10n.t("\(count) dispositivos ativos", "\(count) active devices")
            Text(lightLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(AppTheme.text.opacity(0.55))
                .lineLimit(1)

            Button {
                store.openHomeAssistantInBrowser()
            } label: {
                Text(L10n.t("Abrir Home Assistant ↗", "Open Home Assistant ↗"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.text.opacity(0.78))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

// MARK: - Scene Pill Card (Shows Popover when Truncated)

private struct ScenePillCard: View {
    let scene: HASceneItem
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(scene.isActive ? AppTheme.surface.opacity(0.22) : AppTheme.surface.opacity(0.08))
                        .frame(width: 32, height: 32)

                    Image(systemName: scene.iconSystemName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(scene.isActive ? .white : AppTheme.text.opacity(0.78))
                }

                TruncatedTextWithPopover(
                    scene.name,
                    font: .system(size: 12.5, weight: .semibold),
                    foregroundColor: AppTheme.text.opacity(scene.isActive ? 1.0 : 0.88),
                    isParentHovered: isHovered
                )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    if scene.isActive {
                        RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                            .fill(AppTheme.activeSceneFill)
                    } else {
                        RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                            .fill(AppTheme.surface.opacity(0.06))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                    .stroke(
                        scene.isActive
                            ? AppTheme.activeSceneBorder
                            : LinearGradient(
                                colors: [AppTheme.surface.opacity(0.10), AppTheme.surface.opacity(0.10)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                        lineWidth: 1.2
                    )
            )
            .shadow(
                color: scene.isActive ? Color(red: 0.58, green: 0.35, blue: 0.85).opacity(0.32) : .clear,
                radius: 8,
                x: 0,
                y: 3
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Cena \(scene.name)", "Scene \(scene.name)"))
        .accessibilityValue(scene.isActive ? L10n.t("Última executada", "Last activated") : L10n.t("Executar", "Activate"))
        .accessibilityHint(L10n.t("Toque para ativar esta cena.", "Tap to activate this scene."))
        .zIndex(isHovered ? 100 : 1)
    }
}

// MARK: - Device Control Card (Shows Popover when Name is Truncated)

private struct DeviceControlCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let device: HADeviceItem
    let serverURLString: String
    let onToggle: () -> Void
    let onOpenDetail: () -> Void
    let onBrightnessChange: (Double) -> Void
    let commandStatus: DeviceCommandStatus?
    let onRetry: () -> Void
    let onToggleFavorite: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        let accent = device.accentColor
        let hasSlider = (device.domain == .light && device.supportsBrightness && device.isOn && device.canControl)

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .fill(device.isOn ? accent.opacity(0.26) : AppTheme.surface.opacity(0.08))
                            .frame(width: 32, height: 32)

                        Image(systemName: device.iconSystemName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(device.isOn ? (colorScheme == .light ? AppTheme.text.opacity(0.85) : accent) : AppTheme.text.opacity(0.45))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!device.canToggle)
                .accessibilityLabel(L10n.t("Alternar \(device.name)", "Toggle \(device.name)"))

                Button(action: onOpenDetail) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .help(device.name)

                        Text(device.formattedStatusLine)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button(action: onOpenDetail) {
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("Detalhes de \(device.name)", "Details for \(device.name)"))

            }

            if let status = commandStatus {
                HStack(alignment: .top) {
                    Text(status.label).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if case .failed = status {
                        Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel(L10n.t("Revisar e tentar novamente", "Review and retry"))
                    }
                }.foregroundColor(.secondary)
            }
            if hasSlider {
                TactileSlider(
                    percentage: Binding(
                        get: { device.brightnessPct },
                        set: { onBrightnessChange($0) }
                    ),
                    fillColor: accent,
                    height: 20,
                    showPercentageInside: false
                )
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: hasSlider ? 84 : 56, alignment: .center)
        .glassCard(
            cornerRadius: AppTheme.cardCornerRadius,
            fill: device.isOn ? accent.opacity(0.14) : AppTheme.surface.opacity(0.05),
            borderColor: device.isOn ? accent.opacity(0.42) : AppTheme.surface.opacity(0.09),
            lineWidth: 1.1
        )
        .contextMenu {
            if device.canToggle {
                Button {
                    onToggle()
                } label: {
                    Label(device.isOn ? L10n.t("Desligar / fechar", "Turn off / close") : L10n.t("Ligar / abrir", "Turn on / open"), systemImage: "power")
                }
            }

            Button {
                onToggleFavorite()
            } label: {
                Label(
                    device.isFavorite ? L10n.t("Remover dos favoritos", "Remove from favorites") : L10n.t("Adicionar aos favoritos", "Add to favorites"),
                    systemImage: device.isFavorite ? "star.slash" : "star.fill"
                )
            }

            if let url = URL(string: "\(serverURLString)/config/entities") {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(L10n.t("Ver no Home Assistant", "View in Home Assistant"), systemImage: "arrow.up.right.square")
                }
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(device.name)
        .accessibilityValue(device.formattedStatusLine)
        .accessibilityHint(device.isReadOnly ? "" : L10n.t("Toque para alternar o estado.", "Tap to toggle state."))
        .zIndex(isHovered ? 100 : 1)
    }
}
