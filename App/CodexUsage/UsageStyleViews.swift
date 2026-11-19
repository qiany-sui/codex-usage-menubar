import SwiftUI
import UsageCore

struct ModelUsageRows: View {
    let rows: [ModelTokenUsage]
    @Binding var expandedModel: String?
    @Environment(\.usageColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.model) { row in
                modelRow(row)
            }
        }
    }

    private func modelRow(_ row: ModelTokenUsage) -> some View {
        let name = row.model ?? "未知模型"
        let key = row.model ?? ""
        let isExpanded = expandedModel == key

        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(colors.border.opacity(0.65)).frame(height: 1)
            Button {
                expandedModel = isExpanded ? nil : key
            } label: {
                HStack(spacing: 8) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(UsageFormatters.tokens(row.totalTokens))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(colors.secondaryText)
                        .frame(width: 8)
                        .accessibilityHidden(true)
                }
                .font(.system(size: 12))
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(name + " · " + row.totalTokens.formatted() + " Token")
            .accessibilityLabel(name)
            .accessibilityValue(row.totalTokens.formatted() + " Token")
            .accessibilityHint(isExpanded ? "收起明细" : "展开输入、其中缓存和输出")

            if isExpanded {
                HStack(spacing: 8) {
                    metric("输入", tokens: row.usage.inputTokens)
                    metric("其中缓存", tokens: row.usage.cachedInputTokens)
                    metric("输出", tokens: row.usage.outputTokens)
                }
                .padding(.top, 3)
                .padding(.bottom, 7)
            }
        }
        .padding(.horizontal, 5)
        .background(isExpanded ? colors.tint.opacity(0.30) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func metric(_ label: String, tokens: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(colors.secondaryText)
            Text(UsageFormatters.tokens(tokens))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(tokens.formatted() + " Token")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(tokens.formatted() + " Token")
    }
}

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
