import SwiftUI

struct UsageAccentCard: ViewModifier {
    let style: UsageStyle
    var emphasized = false
    var illuminated = false
    var cornerRadius: CGFloat = 12
    @Environment(\.usageColors) private var colors

    func body(content: Content) -> some View {
        content
            .background {
                if style.hasAccentCards {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(emphasized ? colors.background : colors.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(LinearGradient(
                                    colors: [colors.tint.opacity(emphasized ? 1 : 0.08), colors.tint.opacity(emphasized ? 0.35 : 0)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(RadialGradient(
                                    colors: [colors.accent.opacity(style == .neon ? 0.04 : 0.015), .clear],
                                    center: .topLeading,
                                    startRadius: 0,
                                    endRadius: 220
                                ))
                        }
                        .overlay {
                            if style == .neon && illuminated {
                                RoundedRectangle(cornerRadius: cornerRadius)
                                    .fill(RadialGradient(
                                        colors: [(colors.accentEnd ?? colors.accent).opacity(0.16), .clear],
                                        center: .topTrailing,
                                        startRadius: 0,
                                        endRadius: 140
                                    ))
                            }
                        }
                }
            }
            .overlay {
                if style.hasAccentCards {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            (style == .neon && illuminated) || emphasized
                                ? AnyShapeStyle(colors.accentGradient)
                                : AnyShapeStyle(colors.border),
                            lineWidth: 1
                        )
                        .opacity(illuminated ? 0.95 : (emphasized ? 0.3 : 0.7))
                        .shadow(color: colors.accent.opacity(style == .neon && illuminated ? 0.35 : 0), radius: 6)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct NeonQuotaGauge: View {
    let progress: Double
    @Environment(\.usageColors) private var colors
    @Environment(\.colorScheme) private var colorScheme

    private var gradient: AngularGradient {
        AngularGradient(
            stops: [
                .init(color: colors.accentEnd ?? colors.accent, location: 0),
                .init(color: colors.accent, location: 0.2),
                .init(color: colors.accent, location: 0.55),
                .init(color: colors.accentMiddle ?? colors.accent, location: 0.8),
                .init(color: colors.accentEnd ?? colors.accent, location: 1)
            ],
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(270 * progress)
        )
    }

    var body: some View {
        ZStack {
            ForEach(0...48, id: \.self) { index in
                Capsule()
                    .fill(index < 24 ? colors.accent : (colors.accentEnd ?? colors.accent))
                    .opacity(0.85)
                    .frame(width: 1, height: index.isMultiple(of: 6) ? 5 : 4)
                    .offset(y: -68)
                    .rotationEffect(.degrees(225 + Double(index) * 270 / 48))
            }
            Circle()
                .stroke(colors.accentMiddle ?? colors.accent, lineWidth: 0.8)
                .opacity(0.55)
                .frame(width: 94, height: 94)
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(colors.soft, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: 112, height: 112)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: 0.75 * progress)
                    .stroke(gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: 112, height: 112)
                    .shadow(color: colors.accent.opacity(colorScheme == .dark ? 0.85 : 0.15), radius: 5)
                Circle()
                    .trim(from: 0, to: 0.75 * progress)
                    .stroke(colors.primaryText.opacity(0.65), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: 120, height: 120)
                let angle = (135 + 270 * progress) * .pi / 180
                Circle()
                    .fill(colors.primaryText)
                    .frame(width: 8, height: 8)
                    .shadow(color: colors.accentEnd ?? colors.accent, radius: 4)
                    .offset(x: cos(angle) * 56, y: sin(angle) * 56)
            }
        }
        .frame(width: 140, height: 140)
        .frame(height: 122, alignment: .top)
        .accessibilityHidden(true)
    }
}

struct SegmentedQuotaBar: View {
    let progress: Double
    @Environment(\.usageColors) private var colors

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<25, id: \.self) { index in
                GeometryReader { geometry in
                    // 保留尾段的小数部分，让分段条也精确表达剩余额度。
                    let fill = min(1, max(0, progress * 25 - Double(index)))
                    Capsule()
                        .fill(colors.soft)
                        .overlay {
                            Capsule()
                                .fill(colors.accent)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: geometry.size.width * fill)
                                }
                        }
                }
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}
