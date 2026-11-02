import SwiftUI

/// Native color selection provides the same color for display, keyboard and pointer input.
public struct ColorSpectrumView: View {
    public let activePresetId: String?
    public let currentRGB: RGBColor
    public let onSelectPreset: (HAColorPreset) -> Void
    public let onSelectCustomRGB: (RGBColor) -> Void
    public init(activePresetId: String?, currentRGB: RGBColor, onSelectPreset: @escaping (HAColorPreset) -> Void, onSelectCustomRGB: @escaping (RGBColor) -> Void) {
        self.activePresetId = activePresetId; self.currentRGB = currentRGB
        self.onSelectPreset = onSelectPreset; self.onSelectCustomRGB = onSelectCustomRGB
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ColorPicker(L10n.t("Cor da luz", "Light color"), selection: Binding(get: { currentRGB.swiftUIColor }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                onSelectCustomRGB(RGBColor(Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())))
            }), supportsOpacity: false)
            HStack {
                ForEach(HAColorPreset.defaultPresets.filter { $0.kelvin == nil }) { preset in
                    Button { onSelectPreset(preset) } label: {
                        VStack(spacing: 5) {
                            Circle().fill(preset.swiftUIColor).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(AppTheme.text.opacity(currentRGB == preset.rgb ? 1 : 0.15), lineWidth: 2))
                            Text(preset.name).font(.caption)
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(currentRGB == preset.rgb ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .glassCard()
    }
}
