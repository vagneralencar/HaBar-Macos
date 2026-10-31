import SwiftUI

public struct TactileSlider: View {
    @Binding public var percentage: Double
    public var fillColor: Color
    public var height: CGFloat = 22
    public var showPercentageInside: Bool = false
    public var onChanged: (Double) -> Void

    @State private var isDragging: Bool = false

    public init(
        percentage: Binding<Double>,
        fillColor: Color,
        height: CGFloat = 22,
        showPercentageInside: Bool = false,
        onChanged: @escaping (Double) -> Void
    ) {
        self._percentage = percentage
        self.fillColor = fillColor
        self.height = height
        self.showPercentageInside = showPercentageInside
        self.onChanged = onChanged
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let clamped = min(100, max(0, percentage))
            let fillWidth = max(height, width * CGFloat(clamped / 100.0))

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color.black.opacity(0.38))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )

                // Active fill with gradient & subtle thumb
                ZStack(alignment: .trailing) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    fillColor.opacity(0.75),
                                    fillColor
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: fillColor.opacity(0.45), radius: showPercentageInside ? 8 : 4, x: 0, y: 0)

                    if showPercentageInside {
                        Text("\(Int(clamped.rounded()))%")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.black.opacity(0.78))
                            .padding(.trailing, 12)
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.95))
                            .frame(width: height - 4, height: height - 4)
                            .padding(.trailing, 2)
                            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                    }
                }
                .frame(width: clamped > 1 ? fillWidth : height, height: height)

                // Left sun icon inside track
                Image(systemName: "sun.max.fill")
                    .font(.system(size: showPercentageInside ? 13 : 10, weight: .semibold))
                    .foregroundColor(clamped > 12 ? Color.black.opacity(0.65) : Color.white.opacity(0.5))
                    .padding(.leading, showPercentageInside ? 12 : 7)

                // Floating live percentage tooltip when dragging compact slider
                if isDragging && !showPercentageInside {
                    Text("\(Int(clamped.rounded()))%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.85))
                                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.8))
                        )
                        .offset(x: max(0, min(width - 34, fillWidth - 17)), y: -height - 2)
                        .transition(.opacity)
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let ratio = min(1.0, max(0.0, value.location.x / width))
                        let newPct = Double(ratio * 100.0)
                        percentage = newPct
                        onChanged(newPct)
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isDragging = false
                        }
                    }
            )
        }
        .frame(height: height)
    }
}
