import Charts
import SwiftUI
import UsageCore

struct TrendDetailView: View {
    @Environment(\.usageColors) private var colors
    @State private var selectedDay: LocalDay?
    @State private var expandedDay: LocalDay?

    let presentation: TrendPresentation
    let onBack: () -> Void

    private var activeDay: LocalDay? {
        presentation.days.first { $0.day == selectedDay }?.day
            ?? presentation.days.last?.day
    }
    private var hasResets: Bool {
        presentation.days.contains { !$0.quotaSegments.isEmpty }
    }

    private var chartMaximum: Double {
        let maximum = max(Double(presentation.days.map(\.tokens).max() ?? 0), 1)
        let step = pow(10, floor(log10(maximum))) / 2
        return ceil(maximum / step) * step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            summary.padding(.top, hasResets ? 12 : 15)
            chart.padding(.top, 11)
            ScrollViewReader { proxy in
                ScrollView {
                    dayRows
                        .padding(.trailing, 14)
                }
                .onChange(of: expandedDay) { day in
                    if let day {
                        proxy.scrollTo(day, anchor: .top)
                    }
                }
            }
            .padding(.top, hasResets ? 8 : 11)
            if hasResets {
                Text("额度按重置分段；Token 为全天总量。")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.secondaryText)
                    .padding(.top, 6)
            }
        }
        .padding(UsageTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(colors.primaryText)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14))
                    .foregroundStyle(colors.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回概览")

            Text("最近 7 天")
                .font(.system(size: 14, weight: .medium))
            Spacer(minLength: 6)
            if let first = presentation.days.first, let last = presentation.days.last {
                Text("\(first.label) – \(last.label)")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.secondaryText)
            }
        }
        .frame(height: 32)
    }

    private var summary: some View {
        HStack(spacing: 38) {
            summaryMetric(title: "总 Token", value: UsageFormatters.tokens(presentation.totalTokens))
            summaryMetric(title: "日均 Token", value: UsageFormatters.tokens(presentation.averageTokens))
            Spacer(minLength: 0)
        }
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colors.secondaryText)
                .frame(height: 15.4)
            Text(value)
                .font(.system(size: 23, weight: .medium))
                .tracking(-0.8)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 32.2)
        }
    }

    private var chart: some View {
        Chart(presentation.days) { day in
            BarMark(
                x: .value("日期", day.label),
                y: .value("Token", day.tokens),
                width: .ratio(0.65)
            )
            .foregroundStyle(colors.accent.opacity(day.day == activeDay ? 1 : 0.3))
            .cornerRadius(4)
        }
        .chartYScale(domain: 0...chartMaximum)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, chartMaximum / 2, chartMaximum]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(colors.border)
                AxisValueLabel {
                    if let tokens = value.as(Double.self) {
                        Text(UsageFormatters.tokens(Int64(tokens)))
                            .font(.system(size: 11))
                            .foregroundStyle(colors.secondaryText)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(presentation.days.first(where: { $0.label == label })?.day == presentation.today ? "今天" : label)
                            .font(.system(size: 11))
                            .foregroundStyle(colors.secondaryText)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        let x = value.location.x - geometry[proxy.plotAreaFrame].minX
                        if let label: String = proxy.value(atX: x),
                           let day = presentation.days.first(where: { $0.label == label }) {
                            selectedDay = day.day
                            expandedDay = day.day
                        }
                    })
            }
        }
        .frame(height: 76)
        .overlay {
            if presentation.days.isEmpty {
                Text("暂无趋势数据")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.secondaryText)
            }
        }
        .accessibilityLabel("最近 7 天 Token 柱状图")
    }

    private var dayRows: some View {
        VStack(spacing: 0) {
            HStack {
                Text("日期").frame(width: 48, alignment: .leading)
                Text("Token")
                Spacer(minLength: 8)
                Text("当日额度消耗")
                    .help("官方已用额度在当天的增量，与 Token 数量无关；点击日期查看记录详情。")
            }
            .font(.system(size: 11))
            .foregroundStyle(colors.secondaryText)
            .padding(.horizontal, 7)
            .padding(.bottom, 5)

            ForEach(presentation.days.reversed()) { day in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        selectedDay = day.day
                        expandedDay = expandedDay == day.day ? nil : day.day
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(day.label).frame(width: 40, alignment: .leading)
                                Text(day.formattedTokens).monospacedDigit()
                                Spacer(minLength: 0)
                                Text(day.quotaSegments.isEmpty ? day.quotaPercent : "分 \(day.quotaSegments.count) 段")
                                    .monospacedDigit()
                                Image(systemName: expandedDay == day.day ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(colors.secondaryText)
                            }
                            .font(.system(size: 13, weight: .medium))
                            HStack(spacing: 6) {
                                Text(day.statusLabel)
                                    .foregroundStyle(statusColor(day.status))
                                if let reset = day.resetLabel {
                                    Text(reset).foregroundStyle(colors.accent)
                                }
                                Spacer(minLength: 0)
                                if day.quotaIsPartial {
                                    Text("已记录 · 不完整")
                                        .foregroundStyle(colors.warning)
                                }
                            }
                            .font(.system(size: 11))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(day.day == activeDay ? colors.tint : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(day.day == activeDay ? .isSelected : [])
                    .accessibilityValue(expandedDay == day.day ? "已展开" : "已收起")
                    .accessibilityHint("显示或收起当日用量详情")

                    if expandedDay == day.day {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("完整 Token")
                                Spacer(minLength: 4)
                                Text(day.tokens, format: .number.locale(Locale(identifier: "zh_CN")))
                                    .monospacedDigit()
                                    .textSelection(.enabled)
                            }
                            .foregroundStyle(colors.primaryText)
                            Text(day.quotaHelp)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(colors.secondaryText)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(colors.surface, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 3)
                        .padding(.bottom, 6)
                    }
                    if day.id != presentation.days.first?.id {
                        Rectangle().fill(colors.border).frame(height: 1)
                    }
                }
                .id(day.day)
            }
        }
    }

    private func statusColor(_ status: UsageCalibrationStatus) -> Color {
        switch status {
        case .localLive: colors.accent
        case .partiallyCalibrated, .stale: colors.warning
        case .calibrated, .unavailable: colors.secondaryText
        }
    }
}

#if DEBUG
#Preview("7 天趋势") {
    TrendDetailView(
        presentation: TrendPresentation(snapshot: UsagePreviewData.fullSnapshot),
        onBack: {}
    )
    .modifier(UsagePopoverSurface(style: .aurora))
    .preferredColorScheme(.dark)
}
#endif
