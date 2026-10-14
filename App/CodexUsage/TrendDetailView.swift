import SwiftUI
import UsageCore

struct TrendDetailView: View {
    @Environment(\.usageColors) private var colors
    @State private var selectedDay: LocalDay?
    @State private var detailDay: LocalDay?
    @State private var listContentWidth: CGFloat?
    @State private var showsQuotaExplanation = false

    let presentation: TrendPresentation
    let onBack: () -> Void

    private let dateColumnWidth: CGFloat = 45
    private let quotaColumnWidth: CGFloat = 67
    private let disclosureWidth: CGFloat = 8
    private let columnSpacing: CGFloat = 12
    private let rowHorizontalPadding: CGFloat = 8
    private let scrollbarGutter: CGFloat = 16

    private var activeDay: LocalDay? {
        presentation.days.first { $0.day == selectedDay }?.day
            ?? presentation.days.last?.day
    }

    private var maximumDayTokens: Double {
        Double(max(presentation.days.map(\.tokens).max() ?? 0, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(width: listContentWidth, alignment: .leading)
            summary
                .frame(width: listContentWidth, alignment: .leading)
                .padding(.top, 17)
                .padding(.bottom, 18)
            if presentation.days.isEmpty {
                emptyState
            } else {
                tableHeader
                    .frame(width: listContentWidth, alignment: .leading)
                    .padding(.bottom, 6)
                ScrollView {
                    dayRows
                        .background {
                            // 测量不含滚动条留白的行宽，让固定栏与列表保持对齐。
                            GeometryReader { geometry in
                                Color.clear.preference(key: TrendListWidthKey.self, value: geometry.size.width)
                            }
                        }
                        .padding(.trailing, scrollbarGutter)
                }
                .clipped()
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                    Text("点按日期查看当日详情")
                }
                .font(.system(size: 10))
                .foregroundStyle(colors.secondaryText)
                .padding(.horizontal, rowHorizontalPadding)
                .padding(.top, 8)
                .frame(width: listContentWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, UsageTheme.pagePadding)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(colors.primaryText)
        .onPreferenceChange(TrendListWidthKey.self) { width in
            listContentWidth = width > 0 ? width : nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 14)
            .accessibilityLabel("返回概览")

            Text("最近 7 天")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 6)
            if let first = presentation.days.first, let last = presentation.days.last {
                Text("\(first.label) – \(last.label)")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.secondaryText)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, rowHorizontalPadding)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("合计")
                .foregroundStyle(colors.secondaryText)
            Text(UsageFormatters.tokens(presentation.totalTokens))
                .font(.system(size: 21, weight: .semibold))
                .monospacedDigit()
            Spacer(minLength: 8)
            Text("日均")
                .foregroundStyle(colors.secondaryText)
            Text(UsageFormatters.tokens(presentation.averageTokens))
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, rowHorizontalPadding)
    }

    private var tableHeader: some View {
        HStack(spacing: columnSpacing) {
            Text("日期")
                .frame(width: dateColumnWidth, alignment: .leading)
            Text("Token")
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                Text("额度消耗")
                Button {
                    showsQuotaExplanation = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("额度消耗说明")
                .help("查看额度消耗说明")
                .popover(isPresented: $showsQuotaExplanation, arrowEdge: .top) {
                    quotaExplanation
                }
            }
            .frame(width: quotaColumnWidth, alignment: .leading)
            Color.clear.frame(width: disclosureWidth, height: 1)
                .accessibilityHidden(true)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(colors.secondaryText)
        .padding(.horizontal, rowHorizontalPadding)
    }

    private var quotaExplanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("额度消耗说明")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.primaryText)
            Text("每段按各自周期额度计算；Token 为全天总量。")
            VStack(alignment: .leading, spacing: 4) {
                Text("记录不完整")
                    .fontWeight(.medium)
                    .foregroundStyle(colors.primaryText)
                Text("已记录消耗仅包含可确认的增量，不代表整个时间段的最终消耗。")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(colors.secondaryText)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(colors.background)
    }

    private var dayRows: some View {
        VStack(spacing: 0) {
            ForEach(presentation.days.reversed()) { day in
                let quotaIsUnavailable = day.quotaSegments.isEmpty && day.quotaPercent == "--"
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        selectedDay = day.day
                        detailDay = day.day
                    } label: {
                        HStack(spacing: columnSpacing) {
                            Text(day.label)
                                .font(.system(size: 12, weight: day.day == activeDay ? .semibold : .regular))
                                .foregroundStyle(day.day == activeDay ? colors.accent : colors.primaryText)
                                .frame(width: dateColumnWidth, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(day.formattedTokens)
                                    .font(.system(size: 13, weight: day.tokens > 0 ? .semibold : .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(day.tokens > 0 ? colors.primaryText : colors.secondaryText)
                                GeometryReader { geometry in
                                    Capsule().fill(colors.border.opacity(0.35))
                                    Capsule().fill(colors.accent.opacity(day.day == activeDay ? 0.85 : 0.35))
                                        .frame(width: geometry.size.width * Double(day.tokens) / maximumDayTokens)
                                }
                                .frame(height: 3)
                                .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help("\(day.statusLabel)。横条按七天最高单日 Token 对比。")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(quotaIsUnavailable ? "—" : day.quotaSegments.isEmpty
                                     ? day.quotaPercent : "分 \(day.quotaSegments.count) 段")
                                    .font(.system(size: 12, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(quotaIsUnavailable ? colors.secondaryText : colors.primaryText)
                                if day.quotaIsPartial {
                                    Text("记录不完整")
                                        .font(.system(size: 10))
                                        .foregroundStyle(colors.warning)
                                }
                            }
                            .frame(width: quotaColumnWidth, alignment: .leading)
                            .help(day.quotaHelp)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(colors.secondaryText.opacity(0.65))
                                .frame(width: disclosureWidth)
                        }
                        .padding(.horizontal, rowHorizontalPadding)
                        .frame(height: 38)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(day.day == activeDay ? colors.accent.opacity(0.06) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(day.day == activeDay ? .isSelected : [])
                    .accessibilityHint("打开当日用量、校准状态和重置详情")
                    .popover(isPresented: Binding(
                        get: { detailDay == day.day },
                        set: { if !$0, detailDay == day.day { detailDay = nil } }
                    ), arrowEdge: .trailing) {
                        dayDetails(day)
                    }
                }
                .id(day.day)
            }
        }
    }

    private func dayDetails(_ day: TrendDayPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(day.label) 用量详情")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Button { detailDay = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭当日详情")
            }
            Rectangle().fill(colors.border.opacity(0.6)).frame(height: 1)
            // 普通日期按内容收紧，多次重置时仅让详情滚动，七天列表保持原位。
            ViewThatFits(in: .vertical) {
                dayDetailContent(day)
                ScrollView {
                    dayDetailContent(day)
                        .padding(.trailing, 12)
                }
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(colors.primaryText)
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(colors.background)
    }

    private func dayDetailContent(_ day: TrendDayPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("完整 Token")
                Spacer(minLength: 4)
                Text(day.tokens, format: .number.locale(Locale(identifier: "zh_CN")))
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            .foregroundStyle(colors.primaryText)
            HStack(alignment: .firstTextBaseline) {
                Text("Token 校准状态")
                Spacer(minLength: 4)
                Text(day.statusLabel)
                    .foregroundStyle(statusColor(day.status))
            }
            if let reset = day.resetLabel {
                Label(reset, systemImage: "arrow.clockwise")
                    .foregroundStyle(colors.accent)
            }
            Text(day.quotaDetails)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
        .foregroundStyle(colors.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar")
                .font(.system(size: 28, weight: .light))
            Text("暂无趋势数据")
                .font(.system(size: 13))
        }
        .foregroundStyle(colors.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusColor(_ status: UsageCalibrationStatus) -> Color {
        switch status {
        case .partiallyCalibrated, .stale:
            colors.warning
        case .localLive, .calibrated, .unavailable:
            colors.secondaryText
        }
    }
}

private struct TrendListWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#if DEBUG
#Preview("7 天趋势") {
    TrendDetailView(presentation: TrendPresentation(snapshot: UsagePreviewData.fullSnapshot), onBack: {})
        .modifier(UsagePopoverSurface(style: .aurora))
        .preferredColorScheme(.dark)
}
#endif
