import SwiftUI

public struct LightDetailView: View {
    @ObservedObject public var store: HomeAssistantStore
    public let deviceId: String

    public init(store: HomeAssistantStore, deviceId: String) {
        self.store = store
        self.deviceId = deviceId
    }

    private var currentDevice: HADeviceItem? { store.device(id: deviceId) }

    public var body: some View {
        Group {
            if let item = currentDevice { detailContent(item) }
            else { Text(L10n.t("Dispositivo removido", "Device removed")) }
        }
    }

    @ViewBuilder private func detailContent(_ item: HADeviceItem) -> some View {
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
                        .foregroundColor(AppTheme.text)

                    Text("\(item.room.name) • \(item.formattedStatusLine)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppTheme.text.opacity(0.62))
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
                            .fill(item.isOn ? accent.opacity(0.28) : AppTheme.surface.opacity(0.08))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Circle()
                                    .stroke(item.isOn ? accent.opacity(0.65) : AppTheme.surface.opacity(0.15), lineWidth: 1.2)
                            )
                            .shadow(color: item.isOn ? accent.opacity(0.55) : .clear, radius: 10)

                        Image(systemName: "power")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(item.isOn ? accent : AppTheme.text.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!item.canToggle)
                .accessibilityLabel(L10n.t("Alternar \(item.name)", "Toggle \(item.name)"))
            }

            if let status = store.commandStatuses[item.id] {
                Text(status.label).font(.callout).foregroundColor(.secondary)
                if case .failed = status { Button(L10n.t("Revisar e tentar novamente", "Review and retry")) { store.retryCommand(for: item.id) } }
            }
            if item.domain == .climate {
                climateControlsSection(for: item, accent: accent).disabled(!item.canControl)
            } else if item.domain == .light {
                lightControlsSection(for: item, accent: accent).disabled(!item.canControl)
            } else {
                Text(item.formattedStatusLine).font(.title2).padding(.vertical, 16)
                if item.domain == .sensor || item.domain == .binarySensor {
                    Label(L10n.t("Somente leitura", "Read only"), systemImage: "info.circle").foregroundColor(.secondary)
                }
            }
            Button { store.toggleFavorite(item.id) } label: {
                Label(item.isFavorite ? L10n.t("Remover dos favoritos", "Remove from favorites") : L10n.t("Adicionar aos favoritos", "Add to favorites"), systemImage: item.isFavorite ? "star.fill" : "star")
            }

            Divider()
                .background(AppTheme.surface.opacity(0.10))
                .padding(.top, 2)

            HStack {
                Spacer()
                Text(L10n.t("Entidade: \(item.id)", "Entity: \(item.id)"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.text.opacity(0.48))
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
                fillColor: item.isOn ? accent : AppTheme.surface.opacity(0.35),
                height: 36,
                showPercentageInside: true
            )
            .padding(.vertical, 2)

            HStack(spacing: 6) {
                ForEach([25, 50, 75, 100], id: \.self) { pct in
                    Button {
                        store.setBrightness(for: item.id, percentage: Double(pct))
                    } label: {
                        Text("\(pct)%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(Int(item.brightnessPct.rounded()) == pct && item.isOn ? .black : AppTheme.text.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Int(item.brightnessPct.rounded()) == pct && item.isOn ? accent : AppTheme.surface.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(AppTheme.surface.opacity(0.12), lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("\(pct) por cento de brilho", "\(pct) percent brightness"))
                }
            }
            .padding(.bottom, 2)
        }

        if item.supportsRGB {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Cor", "Color"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(AppTheme.text.opacity(0.92))

                ColorSpectrumView(
                    activePresetId: item.activePresetId,
                    currentRGB: item.rgbColor,
                    onSelectPreset: { store.applyColorPreset($0, to: item.id) },
                    onSelectCustomRGB: { store.setCustomRGB($0, for: item.id) }
                )
            }
        }

        if item.supportsColorTemperature {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Temperatura de branco", "White temperature")).font(.headline)
                Slider(value: Binding(get: { Double(item.colorTempKelvin ?? item.minKelvin) }, set: { store.setColorTemperature(Int($0), for: item.id) }), in: Double(item.minKelvin)...Double(max(item.minKelvin + 1, item.maxKelvin)))
                    .accessibilityLabel(L10n.t("Temperatura de branco", "White temperature"))
                    .accessibilityValue("\(item.colorTempKelvin ?? item.minKelvin) K")
                Text("\(item.colorTempKelvin ?? item.minKelvin) K").font(.callout).monospacedDigit()
                HStack {
                    ForEach(HAColorPreset.defaultPresets.filter { preset in preset.kelvin.map { (item.minKelvin...item.maxKelvin).contains($0) } ?? false }) { preset in
                        Button(preset.name.replacingOccurrences(of: "\n", with: " ")) { store.applyColorPreset(preset, to: item.id) }
                    }
                }
            }.padding(12).glassCard()
        }

        if !item.availableEffects.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Efeitos", "Effects"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(AppTheme.text.opacity(0.92))

                Picker(L10n.t("Efeito", "Effect"), selection: Binding(get: { item.activeEffect }, set: { store.setEffect($0, for: item.id) })) {
                    ForEach(item.availableEffects, id: \.self) { effect in Text(effect == "off" ? L10n.t("Nenhum", "None") : effect).tag(effect) }
                }.labelsHidden()

            }
        }
    }

    @ViewBuilder
    private func climateControlsSection(for item: HADeviceItem, accent: Color) -> some View {
        let temp = item.targetTemperature ?? 24.0

        // Temperature Stepper Card
        if item.targetTemperature != nil {
        HStack {
            Button {
                store.setClimateTemperature(temp - item.temperatureStep, for: item.id)
            } label: {
                Circle()
                    .fill(AppTheme.surface.opacity(0.10))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "minus").font(.system(size: 14, weight: .bold)).foregroundColor(AppTheme.text))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("Diminuir temperatura", "Decrease temperature"))
            .disabled(temp <= item.minTemperature)

            Spacer()

            VStack(spacing: 2) {
                Text(item.temperatureLabel)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.text)
                Text(L10n.t("Temperatura Alvo", "Target temperature"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.text.opacity(0.55))
            }

            Spacer()

            Button {
                store.setClimateTemperature(temp + item.temperatureStep, for: item.id)
            } label: {
                Circle()
                    .fill(AppTheme.surface.opacity(0.10))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundColor(AppTheme.text))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("Aumentar temperatura", "Increase temperature"))
            .disabled(temp >= item.maxTemperature)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 14, fill: AppTheme.surface.opacity(0.05), borderColor: AppTheme.surface.opacity(0.10))

        }
        // HVAC Modes
        if !item.hvacModes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Modo de Operação", "Operating mode"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(AppTheme.text.opacity(0.92))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(item.hvacModes, id: \.self) { mode in
                        let isSelected = (item.hvacMode == mode)
                        Button {
                            store.setClimateMode(mode, for: item.id)
                        } label: {
                            Text(HADeviceItem.modeTitle(mode))
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(AppTheme.text.opacity(isSelected ? 0.98 : 0.72))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? AppTheme.cyanClimate.opacity(0.28) : AppTheme.surface.opacity(0.06))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? AppTheme.cyanClimate.opacity(0.75) : AppTheme.surface.opacity(0.12), lineWidth: 1.1)
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
                Text(L10n.t("Ventilação", "Fan mode"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(AppTheme.text.opacity(0.92))

                Picker(L10n.t("Ventilação", "Fan mode"), selection: Binding(get: { item.fanMode ?? "" }, set: { store.setClimateFan($0, for: item.id) })) {
                    ForEach(item.fanModes, id: \.self) { mode in Text(HADeviceItem.fanTitle(mode)).tag(mode) }
                }

            }
        }
    }
}
