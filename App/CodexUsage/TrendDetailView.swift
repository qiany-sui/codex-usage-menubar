import Charts
import SwiftUI
import UsageCore

struct TrendDetailView: View {
    let presentation: TrendPresentation
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            summary
            chart
            dayRows
        }
        .padding(UsageTheme.pagePadding)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .foregroundStyle(UsageTheme.primaryText)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(UsageTheme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回概览")

            Text("最近 7 天")
                .font(.system(size: 15, weight: .semibold))
        }
    }

    private var summary: some View {
        HStack(spacing: 30) {
            summaryMetric(
                title: "总 Token",
                value: UsageFormatters.tokens(presentation.totalTokens)
            )
            summaryMetric(
                title: "日均 Token",
                value: UsageFormatters.tokens(presentation.averageTokens)
            )
            Spacer()
        }
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(UsageTheme.secondaryText)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
        }
    }

    private var chart: some View {
        Chart(presentation.days) { day in
            BarMark(
                x: .value("日期", day.label),
                y: .value("Token", day.tokens)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [UsageTheme.accent, UsageTheme.accentBlue],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .cornerRadius(3)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.system(size: 9))
                            .foregroundStyle(UsageTheme.secondaryText)
                    }
                }
            }
        }
        .frame(height: 132)
        .overlay {
            if presentation.days.isEmpty {
                Text("暂无趋势数据")
                    .font(.system(size: 12))
                    .foregroundStyle(UsageTheme.secondaryText)
            }
        }
        .accessibilityLabel("最近 7 天 Token 柱状图")
    }

    @ViewBuilder
    private var dayRows: some View {
        if presentation.days.isEmpty {
            Spacer(minLength: 0)
        } else {
            VStack(spacing: 0) {
                ForEach(presentation.days) { day in
                    HStack(spacing: 8) {
                        Text(day.label)
                            .frame(width: 36, alignment: .leading)
                        Text(day.formattedTokens)
                            .monospacedDigit()
                        Spacer()
                        Text(day.statusLabel)
                            .foregroundStyle(statusColor(day.status))
                    }
                    .font(.system(size: 10))
                    .frame(height: 20)

                    if day.id != presentation.days.last?.id {
                        Divider().overlay(UsageTheme.border)
                    }
                }
            }
        }
    }

    private func statusColor(_ status: UsageCalibrationStatus) -> Color {
        switch status {
        case .localLive:
            UsageTheme.accentBlue
        case .calibrated:
            UsageTheme.secondaryText
        case .partiallyCalibrated, .stale:
            UsageTheme.warning
        case .unavailable:
            UsageTheme.secondaryText
        }
    }
}

#if DEBUG
#Preview("7 天趋势") {
    TrendDetailView(
        presentation: TrendPresentation(
            snapshot: UsagePreviewData.fullSnapshot
        ),
        onBack: {}
    )
    .frame(
        width: UsageTheme.popoverSize.width,
        height: UsageTheme.popoverSize.height
    )
    .background(UsageTheme.background)
    .preferredColorScheme(.dark)
}
#endif
