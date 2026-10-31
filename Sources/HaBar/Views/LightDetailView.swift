import SwiftUI

public struct LightDetailView: View {
    @ObservedObject public var store: HomeAssistantStore
    public let deviceId: String

    public init(store: HomeAssistantStore, deviceId: String) {
        self.store = store
        self.deviceId = deviceId
    }

    private var currentDevice: HADeviceItem {
        store.devices.first(where: { $0.id == deviceId }) ?? HADeviceItem.defaultMockupDevices[0]
    }

    public var body: some View {
        let item = currentDevice
        let accent = item.accentColor

        VStack(alignment: .leading, spacing: 14) {
            NavigationBackButton {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    store.selectedDeviceForDetail = nil
                }
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)

                    Text("\(item.room.name) • \(item.formattedStatusLine)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if item.domain == .climate {
                            let nextMode = item.isOn ? "off" : (item.hvacModes.first(where: { $0 != "off" }) ?? "cool")
                            store.setClimateMode(nextMode, for: item.id)
                        } else {
                            store.toggleDevice(item.id)
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(item.isOn ? accent.opacity(0.28) : Color.white.opacity(0.08))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Circle()
                                    .stroke(item.isOn ? accent.opacity(0.65) : Color.white.opacity(0.15), lineWidth: 1.2)
                            )
                            .shadow(color: item.isOn ? accent.opacity(0.55) : .clear, radius: 10)

                        Image(systemName: "power")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(item.isOn ? accent : .white.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
            }

            if item.domain == .climate {
                climateControlsSection(for: item, accent: accent)
            } else {
                lightControlsSection(for: item, accent: accent)
            }

            Divider()
                .background(Color.white.opacity(0.10))
                .padding(.top, 2)

            HStack {
                Spacer()
                Text("Entidade: \(item.id)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.48))
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func lightControlsSection(for item: HADeviceItem, accent: Color) -> some View {
        if item.supportsBrightness {
            TactileSlider(
                percentage: Binding(
                    get: { item.isOn ? item.brightnessPct : 0 },
                    set: { store.setBrightness(for: item.id, percentage: $0) }
                ),
                fillColor: item.isOn ? accent : Color.white.opacity(0.35),
                height: 36,
                showPercentageInside: true,
                onChanged: { store.setBrightness(for: item.id, percentage: $0) }
            )
            .padding(.vertical, 2)

            HStack(spacing: 6) {
                ForEach([25, 50, 75, 100], id: \.self) { pct in
                    Button {
                        store.setBrightness(for: item.id, percentage: Double(pct))
                    } label: {
                        Text("\(pct)%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(Int(item.brightnessPct.rounded()) == pct && item.isOn ? .black : .white.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Int(item.brightnessPct.rounded()) == pct && item.isOn ? accent : Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(pct) por cento de brilho")
                }
            }
            .padding(.bottom, 2)
        }

        if item.supportsColor {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cores & Temperatura")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))

                ColorSpectrumView(
                    activePresetId: item.activePresetId,
                    currentRGB: item.rgbColor,
                    onSelectPreset: { store.applyColorPreset($0, to: item.id) },
                    onSelectCustomRGB: { store.setCustomRGB($0, for: item.id) }
                )
            }
        }

        if !item.availableEffects.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Efeitos")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))

                HStack(spacing: 8) {
                    ForEach(item.availableEffects, id: \.self) { effect in
                        let isSelected = (item.activeEffect == effect)
                        Button {
                            store.setEffect(effect, for: item.id)
                        } label: {
                            Text(effect)
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(.white.opacity(isSelected ? 0.98 : 0.72))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? accent.opacity(0.26) : Color.white.opacity(0.06))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? accent.opacity(0.75) : Color.white.opacity(0.12), lineWidth: 1.1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func climateControlsSection(for item: HADeviceItem, accent: Color) -> some View {
        let temp = item.targetTemperature ?? 24.0

        // Temperature Stepper Card
        HStack {
            Button {
                store.setClimateTemperature(temp - 1, for: item.id)
            } label: {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "minus").font(.system(size: 14, weight: .bold)).foregroundColor(.white))
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text("\(Int(temp.rounded())) °C")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Temperatura Alvo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            Button {
                store.setClimateTemperature(temp + 1, for: item.id)
            } label: {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundColor(.white))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 14, fill: Color.white.opacity(0.05), borderColor: Color.white.opacity(0.10))

        // HVAC Modes
        if !item.hvacModes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Modo de Operação")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(item.hvacModes, id: \.self) { mode in
                        let isSelected = (item.hvacMode == mode)
                        Button {
                            store.setClimateMode(mode, for: item.id)
                        } label: {
                            Text(HADeviceItem.modeTitle(mode))
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(.white.opacity(isSelected ? 0.98 : 0.72))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? AppTheme.cyanClimate.opacity(0.28) : Color.white.opacity(0.06))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? AppTheme.cyanClimate.opacity(0.75) : Color.white.opacity(0.12), lineWidth: 1.1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        // Fan Modes
        if !item.fanModes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ventilação")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))

                HStack(spacing: 8) {
                    ForEach(item.fanModes, id: \.self) { fMode in
                        let isSelected = (item.fanMode == fMode)
                        Button {
                            store.setClimateFan(fMode, for: item.id)
                        } label: {
                            Text(HADeviceItem.fanTitle(fMode))
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(.white.opacity(isSelected ? 0.98 : 0.72))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? AppTheme.cyanClimate.opacity(0.28) : Color.white.opacity(0.06))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? AppTheme.cyanClimate.opacity(0.75) : Color.white.opacity(0.12), lineWidth: 1.1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
