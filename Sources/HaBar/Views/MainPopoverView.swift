import SwiftUI

public struct MainPopoverView: View {
    @ObservedObject public var store: HomeAssistantStore
    @State private var showAllScenes: Bool = false

    private static let twoColumnGrid = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private static let fourColumnRoomGrid = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    public init(store: HomeAssistantStore) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            if store.isScreenshotPreview {
                Color(red: 0.10, green: 0.10, blue: 0.12)
                    .ignoresSafeArea()
            } else {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    .ignoresSafeArea()

                AppTheme.popoverBackground
                    .ignoresSafeArea()
            }

            if store.isShowingSettings {
                SettingsView(store: store)
                    .padding(16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let detailDevice = store.selectedDeviceForDetail {
                LightDetailView(store: store, deviceId: detailDevice.id)
                    .padding(16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                dashboardContent
                    .padding(16)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Toast overlay
            if let toast = store.toast {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(toast.isError ? AppTheme.dangerRed : AppTheme.greenOnline)
                        Text(toast.text)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.88))
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

            // Confirmation Modal overlay
            if let confirmation = store.pendingConfirmation {
                ZStack {
                    Color.black.opacity(0.60)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation { store.pendingConfirmation = nil }
                        }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 18))
                                .foregroundColor(AppTheme.amberAccent)
                            Text(confirmation.title)
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(.white)
                        }

                        Text(confirmation.message)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundColor(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button {
                                withAnimation { store.pendingConfirmation = nil }
                            } label: {
                                Text("Cancelar")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .glassCard(cornerRadius: 8, fill: Color.white.opacity(0.08), borderColor: Color.white.opacity(0.12))
                            }
                            .buttonStyle(.plain)

                            Button {
                                let act = confirmation.action
                                withAnimation { store.pendingConfirmation = nil }
                                act()
                            } label: {
                                Text(confirmation.confirmTitle)
                                    .font(.system(size: 11.5, weight: .bold))
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
                    }
                    .padding(14)
                    .frame(width: 310)
                    .glassCard(cornerRadius: 14, fill: Color(red: 0.14, green: 0.14, blue: 0.16), borderColor: Color.white.opacity(0.20), lineWidth: 1.2)
                    .shadow(color: .black.opacity(0.7), radius: 24, x: 0, y: 12)
                }
                .transition(.opacity)
                .zIndex(300)
            }
        }
        .frame(width: AppTheme.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(store.themeMode.colorScheme)
        .onExitCommand {
            if store.isShowingSettings {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    store.isShowingSettings = false
                }
            } else if store.selectedDeviceForDetail != nil {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    store.selectedDeviceForDetail = nil
                }
            } else {
                NSApp.keyWindow?.performClose(nil)
            }
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard !store.isShowingSettings && !store.isSearchVisible else { return .ignored }
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
            headerSection

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
                .background(Color.white.opacity(0.09))

            scenesSection
            roomTabsSection
            devicesSection

            Divider()
                .background(Color.white.opacity(0.09))

            footerSection
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
                    .foregroundColor(.white)

                HStack(spacing: 6) {
                    let dotColor = store.connectionStatus.isHealthy ? AppTheme.greenOnline : Color.orange
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: dotColor.opacity(0.8), radius: 4)

                    Text(store.connectionStatus.labelText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                }
            }

            Spacer()

            HStack(spacing: 8) {
                CircularIconButton(
                    systemName: "arrow.clockwise",
                    helpText: "Atualizar estados do Home Assistant"
                ) {
                    store.connectToHomeAssistant()
                }

                CircularIconButton(
                    systemName: "gearshape",
                    helpText: "Configurações do Home Assistant"
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        store.isShowingSettings = true
                    }
                }

                CircularIconButton(
                    systemName: "magnifyingglass",
                    isHighlighted: store.isSearchVisible,
                    helpText: "Filtrar dispositivos"
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
                .foregroundColor(.white.opacity(0.95))

            Spacer()

            if update.downloadURL != nil {
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
                Text("Ver ↗")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppTheme.amberAccent)
            }
            .buttonStyle(.plain)

            Button {
                store.dismissUpdateBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
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
                    .foregroundColor(.white.opacity(0.95))
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
                .foregroundColor(.white.opacity(0.95))

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
                .foregroundColor(.white.opacity(0.95))

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
                    .foregroundColor(.white.opacity(0.55))
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
                    .foregroundColor(.white.opacity(0.5))

                TextField(L10n.t("Buscar ou comandar (ex: sala 50, apagar tudo)...", "Search or command (e.g. living 50, turn off all)..."), text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white)
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
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassCard(
                cornerRadius: AppTheme.controlCornerRadius,
                fill: Color.black.opacity(0.32),
                borderColor: Color.white.opacity(0.12)
            )

            if let action = spotlightAction {
                Button {
                    executeSpotlightAction(action)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: action.icon)
                            .foregroundColor(AppTheme.amberAccent)
                        Text(action.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
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

    private var spotlightAction: SpotlightAction? {
        let q = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }

        if q == "apagar tudo" || q == "desligar tudo" || q == "off all" || q == "turn off all" {
            return .turnOffAll
        }

        if let scene = store.scenes.first(where: { $0.name.lowercased().contains(q) }) {
            return .runScene(scene)
        }

        let parts = q.split(separator: " ")
        if parts.count >= 2, let lastNum = Double(parts.last!), (0...100).contains(lastNum) {
            let nameQuery = parts.dropLast().joined(separator: " ")
            if let dev = store.devices.first(where: { $0.domain == .light && $0.name.lowercased().contains(nameQuery) }) {
                return .setBrightness(dev, lastNum)
            }
        }

        return nil
    }

    private enum SpotlightAction {
        case turnOffAll
        case runScene(HASceneItem)
        case setBrightness(HADeviceItem, Double)

        var title: String {
            switch self {
            case .turnOffAll:
                return L10n.t("Apagar todas as lâmpadas [Enter ↵]", "Turn off all lights [Enter ↵]")
            case .runScene(let scene):
                return L10n.t("Executar cena: \(scene.name) [Enter ↵]", "Activate scene: \(scene.name) [Enter ↵]")
            case .setBrightness(let dev, let pct):
                return L10n.t("Definir \(dev.name) para \(Int(pct))% [Enter ↵]", "Set \(dev.name) to \(Int(pct))% [Enter ↵]")
            }
        }

        var icon: String {
            switch self {
            case .turnOffAll: return "lightbulb.slash"
            case .runScene: return "sparkles"
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
                Text("Cenas Rápidas")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))

                Spacer()

                if allScenes.count > 4 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showAllScenes.toggle()
                        }
                    } label: {
                        Text(showAllScenes ? "Mostrar 4" : "Ver todas (\(allScenes.count))")
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
                        Text(L10n.t("• Apagar Tudo", "• Turn Off All"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }

            LazyVGrid(columns: Self.twoColumnGrid, spacing: 8) {
                ForEach(visibleScenes) { scene in
                    ScenePillCard(scene: scene) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.activateScene(scene.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Zero-Scroll Room Selector Grid

    private var roomTabsSection: some View {
        LazyVGrid(columns: Self.fourColumnRoomGrid, spacing: 6) {
            ForEach(store.rooms) { room in
                RoomPillButton(
                    room: room,
                    isSelected: store.selectedRoom.id == room.id,
                    hasActive: store.hasActiveDevice(in: room),
                    action: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            store.selectedRoom = room
                        }
                    },
                    onSetRoomPower: { turnOn in
                        store.setRoomPower(room, on: turnOn)
                    }
                )
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
                    .foregroundColor(.white.opacity(0.92))

                Spacer()

                Text("\(items.count) \(items.count == 1 ? "item" : "itens")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }

            if store.isLoading && items.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 6)
                    Text("Carregando dispositivos…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                }
                .padding(.vertical, 22)
                .glassCard()
            } else if items.isEmpty {
                HStack {
                    Spacer()
                    Text("Nenhum dispositivo neste cômodo")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
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
                                if (device.domain == .light && device.supportsColor) || device.domain == .climate {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                        store.selectedDeviceForDetail = device
                                    }
                                } else {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        store.requestToggle(device)
                                    }
                                }
                            },
                            onBrightnessChange: { newPct in
                                store.setBrightness(for: device.id, percentage: newPct)
                            },
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
            let count = store.activeLightsCount
            let lightLabel = count == 1 ? "1 dispositivo ligado" : "\(count) dispositivos ligados"
            Text("\(lightLabel) • \(store.scenes.count) cenas •")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)

            Button {
                store.openHomeAssistantInBrowser()
            } label: {
                Text("Abrir Home Assistant ↗")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

// MARK: - Room Pill Button (Shows Popover when Abbreviated)

private struct RoomPillButton: View {
    let room: HARoom
    let isSelected: Bool
    let hasActive: Bool
    let action: () -> Void
    let onSetRoomPower: (Bool) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: room.iconSystemName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(
                        isSelected
                            ? AppTheme.amberAccent
                            : (hasActive ? AppTheme.amberAccent.opacity(0.85) : .white.opacity(0.52))
                    )

                TruncatedTextWithPopover(
                    room.shortDisplayName,
                    fullText: room.displayName,
                    font: .system(size: 11, weight: isSelected ? .semibold : .medium),
                    foregroundColor: .white.opacity(isSelected ? 1.0 : 0.72),
                    isParentHovered: isHovered
                )

                if hasActive && room.id != HARoom.favorites.id {
                    Circle()
                        .fill(AppTheme.amberAccent)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? Color.white.opacity(0.28) : Color.white.opacity(0.07),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onSetRoomPower(true)
            } label: {
                Label(L10n.t("Ligar tudo em \(room.displayName)", "Turn on all in \(room.displayName)"), systemImage: "lightbulb.fill")
            }

            Button {
                onSetRoomPower(false)
            } label: {
                Label(L10n.t("Desligar tudo em \(room.displayName)", "Turn off all in \(room.displayName)"), systemImage: "lightbulb.slash")
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(room.displayName)
        .accessibilityValue(hasActive ? L10n.t("Dispositivos ligados", "Active devices") : L10n.t("Desligado", "Off"))
        .accessibilityHint(L10n.t("Toque para ver este cômodo.", "Tap to view this room."))
        .zIndex(isHovered ? 100 : 1)
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
                        .fill(scene.isActive ? Color.white.opacity(0.22) : Color.white.opacity(0.08))
                        .frame(width: 32, height: 32)

                    Image(systemName: scene.iconSystemName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(scene.isActive ? .white : .white.opacity(0.78))
                }

                TruncatedTextWithPopover(
                    scene.name,
                    font: .system(size: 12.5, weight: .semibold),
                    foregroundColor: .white.opacity(scene.isActive ? 1.0 : 0.88),
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
                            .fill(Color.white.opacity(0.06))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                    .stroke(
                        scene.isActive
                            ? AppTheme.activeSceneBorder
                            : LinearGradient(
                                colors: [Color.white.opacity(0.10), Color.white.opacity(0.10)],
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
        .accessibilityValue(scene.isActive ? L10n.t("Ativa", "Active") : L10n.t("Inativa", "Inactive"))
        .accessibilityHint(L10n.t("Toque para ativar esta cena.", "Tap to activate this scene."))
        .zIndex(isHovered ? 100 : 1)
    }
}

// MARK: - Device Control Card (Shows Popover when Name is Truncated)

private struct DeviceControlCard: View {
    let device: HADeviceItem
    let serverURLString: String
    let onToggle: () -> Void
    let onOpenDetail: () -> Void
    let onBrightnessChange: (Double) -> Void
    let onToggleFavorite: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        let accent = device.accentColor
        let hasSlider = (device.domain == .light && device.supportsBrightness && device.isOn)

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .fill(device.isOn ? accent.opacity(0.26) : Color.white.opacity(0.08))
                            .frame(width: 32, height: 32)

                        Image(systemName: device.iconSystemName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(device.isOn ? accent : .white.opacity(0.45))
                    }
                }
                .buttonStyle(.plain)
                .disabled(device.isReadOnly)

                Button(action: onOpenDetail) {
                    VStack(alignment: .leading, spacing: 2) {
                        TruncatedTextWithPopover(
                            device.name,
                            font: .system(size: 12, weight: .semibold),
                            foregroundColor: .white.opacity(device.isOn ? 0.98 : 0.82),
                            isParentHovered: isHovered
                        )

                        Text(device.formattedStatusLine)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(device.isOn ? accent.opacity(0.95) : .white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if device.domain == .switch {
                    Button(action: onToggle) {
                        Image(systemName: "power.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(device.isOn ? accent : .white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                } else if device.domain == .lock {
                    Button(action: onToggle) {
                        Image(systemName: device.isOn ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 14))
                            .foregroundColor(device.isOn ? AppTheme.amberAccent : AppTheme.greenOnline)
                    }
                    .buttonStyle(.plain)
                } else if (device.domain == .light && device.supportsColor) || device.domain == .climate {
                    Button(action: onOpenDetail) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.38))
                    }
                    .buttonStyle(.plain)
                }
            }

            if hasSlider {
                TactileSlider(
                    percentage: Binding(
                        get: { device.brightnessPct },
                        set: { onBrightnessChange($0) }
                    ),
                    fillColor: accent,
                    height: 20,
                    showPercentageInside: false,
                    onChanged: onBrightnessChange
                )
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: hasSlider ? 84 : 56, alignment: .center)
        .glassCard(
            cornerRadius: AppTheme.cardCornerRadius,
            fill: device.isOn ? accent.opacity(0.14) : Color.white.opacity(0.05),
            borderColor: device.isOn ? accent.opacity(0.42) : Color.white.opacity(0.09),
            lineWidth: 1.1
        )
        .contextMenu {
            if !device.isReadOnly {
                Button {
                    onToggle()
                } label: {
                    Label(device.isOn ? "Desligar" : "Ligar", systemImage: "power")
                }
            }

            Button {
                onToggleFavorite()
            } label: {
                Label(
                    device.isFavorite ? "Remover dos Favoritos" : "Adicionar aos Favoritos",
                    systemImage: device.isFavorite ? "star.slash" : "star.fill"
                )
            }

            if let url = URL(string: "\(serverURLString)/config/entities") {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Ver no Home Assistant", systemImage: "arrow.up.right.square")
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
