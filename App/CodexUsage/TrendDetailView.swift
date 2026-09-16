import Charts
import SwiftUI
import UsageCore

struct TrendDetailView: View {
    @Environment(\.usageColors) private var colors
    @State private var selectedDay: LocalDay?

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
            ScrollView {
                dayRows
            }
            .padding(.top, hasResets ? 8 : 11)
            if hasResets {
                Text("额度按重置分段；Token 为全天总量。")
                    .font(.system(size: 9))
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
                        }
                    })
            }
        }
        .frame(height: hasResets ? 56 : 96)
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
            HStack(spacing: 0) {
                Text("日期").frame(width: 55, alignment: .leading)
                Text("Token")
                Spacer(minLength: 8)
                Text("当日额度消耗")
                    .frame(width: 90, alignment: .trailing)
                    .help("官方已用额度在当天的增量。发生重置时，各段分别对应各自周期额度；悬停数值可查看时间段。“已记录消耗”表示记录不完整，仅展示可确认的增量；没有记录时不推算，也不记作 0。按官方快照统计，可能有刷新延迟。")
                Text("Token 状态").frame(width: 64, alignment: .trailing)
                    .help("仅表示 Token 的校准状态，额度快照是否完整单独判断。")
            }
            .font(.system(size: 10))
            .foregroundStyle(colors.secondaryText)
            .padding(.horizontal, 5)
            .frame(height: 18)

            ForEach(presentation.days) { day in
                Button {
                    selectedDay = day.day
                } label: {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(day.label)
                            if let reset = day.resetLabel {
                                Text(reset)
                                    .font(.system(size: 8))
                                    .foregroundStyle(colors.accent)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 55, alignment: .leading)
                        Text(day.formattedTokens)
                            .fontWeight(.medium)
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        quotaConsumption(day)
                            .frame(width: 90, alignment: .trailing)
                            .help(day.quotaHelp)
                        Text(day.statusLabel)
                            .foregroundStyle(statusColor(day.status))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 5)
                    .frame(height: max(24, CGFloat(day.quotaSegments.count) * 14 + 6
                        + (day.quotaIsPartial && !day.quotaSegments.isEmpty ? 10 : 0)))
                    .background(day.day == activeDay ? colors.tint : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(alignment: .bottom) {
                        if day.id != presentation.days.last?.id {
                            Rectangle().fill(colors.border).frame(height: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(day.day == activeDay ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func quotaConsumption(_ day: TrendDayPresentation) -> some View {
        if day.quotaSegments.isEmpty {
            VStack(alignment: .trailing, spacing: 1) {
                Text(day.quotaIsPartial ? "已记录消耗 " + day.quotaPercent : day.quotaPercent)
                    .font(.system(size: day.quotaIsPartial ? 9 : 11))
                    .monospacedDigit()
                if day.quotaIsPartial {
                    Text("记录不完整").font(.system(size: 8))
                }
            }
            .foregroundStyle(colors.secondaryText)
            .accessibilityLabel(day.quotaIsPartial
                ? "已记录消耗 \(day.quotaPercent)，记录不完整" : "当日额度消耗 \(day.quotaPercent)")
        } else {
            VStack(spacing: 1) {
                ForEach(day.quotaSegments) { part in
                    HStack(spacing: 4) {
                        Text(part.label)
                        Spacer(minLength: 0)
                        Text(part.isPartial ? "已记录 " + part.percent : part.percent).monospacedDigit()
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(colors.secondaryText)
                    .frame(height: 13)
                    .accessibilityElement(children: .combine)
                }
                if day.quotaIsPartial {
                    Text("记录不完整")
                        .font(.system(size: 8))
                        .foregroundStyle(colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
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
