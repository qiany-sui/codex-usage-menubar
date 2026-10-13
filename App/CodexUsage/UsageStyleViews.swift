import SwiftUI

struct UsageAccentCard: ViewModifier {
    let style: UsageStyle
    var emphasized = false
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
                                    colors: [colors.accent.opacity(0.015), .clear],
                                    center: .topLeading,
                                    startRadius: 0,
                                    endRadius: 220
                                ))
                        }
                }
            }
            .overlay {
                if style.hasAccentCards {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            emphasized ? colors.accent : colors.border,
                            lineWidth: 1
                        )
                        .opacity(emphasized ? 0.3 : 0.7)
                        .allowsHitTesting(false)
                }
            }
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
