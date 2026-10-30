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
        }
        .frame(width: AppTheme.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }

    // MARK: - Main Dashboard

    private var dashboardContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            headerSection

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

    private var searchFieldSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))

            TextField("Buscar lâmpada ou dispositivo...", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(.white)

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
                            store.turnOffAllLights()
                        }
                    } label: {
                        Text("• Apagar Tudo")
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
                    hasActive: store.hasActiveDevice(in: room)
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        store.selectedRoom = room
                    }
                }
            }
        }
    }

    // MARK: - Devices Section

    private var devicesSection: some View {
        let items = store.filteredDevices

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Iluminação & Dispositivos — \(store.selectedRoom.name)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))

                Spacer()

                Text("\(items.count) \(items.count == 1 ? "item" : "itens")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }

            if items.isEmpty {
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
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    store.toggleDevice(device.id)
                                }
                            },
                            onOpenDetail: {
                                if device.domain == .light && device.supportsColor {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                        store.selectedDeviceForDetail = device
                                    }
                                } else {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        store.toggleDevice(device.id)
                                    }
                                }
                            },
                            onBrightnessChange: { newPct in
                                store.setBrightness(for: device.id, percentage: newPct)
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
                    fullText: room.name,
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
        .onHover { hovering in
            isHovered = hovering
        }
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
        .zIndex(isHovered ? 100 : 1)
    }
}

// MARK: - Device Control Card (Shows Popover when Name is Truncated)

private struct DeviceControlCard: View {
    let device: HADeviceItem
    let onToggle: () -> Void
    let onOpenDetail: () -> Void
    let onBrightnessChange: (Double) -> Void

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
                } else if device.domain == .light && device.supportsColor {
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
        .onHover { hovering in
            isHovered = hovering
        }
        .zIndex(isHovered ? 100 : 1)
    }
}
