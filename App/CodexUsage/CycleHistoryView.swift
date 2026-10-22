import SwiftUI

struct CycleHistoryView: View {
    @Environment(\.usageColors) private var colors
    @State private var detailCycle: Date?

    let presentation: CycleHistoryPresentation
    let onBack: () -> Void

    private let tokenColumnWidth: CGFloat = 70
    private let quotaColumnWidth: CGFloat = 64
    private let disclosureWidth: CGFloat = 8
    private let rowHorizontalPadding: CGFloat = 8
    private let scrollbarGutter: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if presentation.entries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("周期")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Token")
                            .frame(width: tokenColumnWidth, alignment: .leading)
                        Text("额度已用")
                            .frame(width: quotaColumnWidth, alignment: .leading)
                        Color.clear.frame(width: disclosureWidth, height: 1)
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(colors.secondaryText)
                    .padding(.horizontal, rowHorizontalPadding)
                    .padding(.trailing, scrollbarGutter)
                    .frame(height: 14)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(presentation.entries) { entry in
                                cycleRow(entry)
                                    .padding(.bottom, entry.isCurrent ? 3 : 0)
                            }
                        }
                        .padding(.trailing, scrollbarGutter)
                    }

                    Text("点按周期查看详情 · — 表示额度记录不足")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, rowHorizontalPadding)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            .frame(width: 14)
            .accessibilityLabel("返回概览")

            Text("历史周期")
                .font(.system(size: 14, weight: .medium))
            Spacer(minLength: 6)
            if !presentation.entries.isEmpty {
                Text(
                    presentation.entries.first?.isCurrent == true
                        ? "当前 + 最近 \(presentation.entries.count - 1) 个"
                        : "最近 \(presentation.entries.count) 个"
                )
                .font(.system(size: 11))
                .foregroundStyle(colors.secondaryText)
            }
        }
        .frame(height: 32)
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.trailing, scrollbarGutter)
    }

    private func cycleRow(_ entry: CycleEntryPresentation) -> some View {
        Button {
            detailCycle = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(entry.range)
                        if entry.isCurrent {
                            Text("当前")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(colors.accent)
                        }
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.formattedTokens)
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .frame(width: tokenColumnWidth, alignment: .leading)
                    Text(entry.quotaPercent == "--" ? "—" : entry.quotaPercent)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(entry.isCurrent ? colors.accent : colors.primaryText)
                        .frame(width: quotaColumnWidth, alignment: .leading)
                        .accessibilityLabel(entry.quotaUsage)
                        .help(entry.quotaHelp)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(colors.secondaryText.opacity(0.65))
                        .frame(width: disclosureWidth)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.statusLabel + (entry.boundaryIsEstimated ? " · 边界估算" : ""))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.quotaIsPartial ? "记录不完整" : "")
                        .frame(width: quotaColumnWidth, alignment: .leading)
                        .foregroundStyle(colors.warning)
                        .help(entry.quotaHelp)
                    Color.clear.frame(width: disclosureWidth, height: 1)
                        .accessibilityHidden(true)
                }
                .font(.system(size: 11))
                .foregroundStyle(colors.secondaryText)
            }
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, 8)
            .background(entry.isCurrent ? colors.tint : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !entry.isCurrent && entry.id != presentation.entries.last?.id {
                    Rectangle().fill(colors.border.opacity(0.5)).frame(height: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看每天的 Token、额度消耗和周期详情")
        .popover(isPresented: Binding(
            get: { detailCycle == entry.id },
            set: { if !$0, detailCycle == entry.id { detailCycle = nil } }
        ), arrowEdge: .trailing) {
            CycleDetailView(entry: entry, onClose: { detailCycle = nil })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .light))
            Text("暂无周期历史")
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .foregroundStyle(colors.secondaryText)
        .frame(maxWidth: .infinity)
    }
}

struct CycleDetailView: View {
    @Environment(\.usageColors) private var colors

    let entry: CycleEntryPresentation
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entry.isCurrent ? "当前周期详情" : "历史周期详情")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭周期详情")
            }
            Rectangle().fill(colors.border.opacity(0.6)).frame(height: 1)
            ViewThatFits(in: .vertical) {
                detailContent
                ScrollView {
                    detailContent.padding(.trailing, 12)
                }
            }
            .frame(maxHeight: 390)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(colors.primaryText)
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(colors.background)
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailRow("开始时间", value: entry.startTime)
            detailRow(entry.isCurrent ? "预计重置" : "结束时间", value: entry.endTime)
            if entry.boundaryIsEstimated {
                Text("周期起止时间为估算值，不能视为实际重置时间。")
                    .foregroundStyle(colors.warning)
            }
            Rectangle().fill(colors.border.opacity(0.6)).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                Text("完整 Token")
                Spacer(minLength: 4)
                Text(entry.tokens, format: .number.locale(Locale(identifier: "zh_CN")))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(colors.primaryText)
                    .textSelection(.enabled)
            }
            detailRow("Token 校准状态", value: entry.statusLabel)
            Text(entry.calibrationHelp)
                .font(.system(size: 10))
                .lineSpacing(2)
                .textSelection(.enabled)
            if let days = entry.dailyUsage, !days.isEmpty {
                dailyUsage(days)
            }
            Rectangle().fill(colors.border.opacity(0.6)).frame(height: 1)
            Text(entry.quotaUsage)
                .fontWeight(.medium)
                .foregroundStyle(entry.quotaIsPartial ? colors.warning : colors.primaryText)
            Text(entry.quotaHelp)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
        .foregroundStyle(colors.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func dailyUsage(_ days: [CycleDayPresentation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(colors.border.opacity(0.6)).frame(height: 1)
            Text("每天的消耗")
                .fontWeight(.semibold)
                .foregroundStyle(colors.primaryText)
            HStack {
                Text("日期")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Token")
                    .frame(width: 104, alignment: .trailing)
                Text("额度消耗")
                    .frame(width: 80, alignment: .trailing)
            }
            VStack(spacing: 0) {
                ForEach(days) { day in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Text(day.dateLabel)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(colors.primaryText)
                                Text(day.sourceLabel)
                                    .font(.system(size: 10))
                            }
                            Text(day.timeRange)
                                .font(.system(size: 10))
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(day.tokens, format: .number.locale(Locale(identifier: "zh_CN")))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(colors.primaryText)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .frame(width: 104, alignment: .trailing)
                        Text(day.quotaLabel)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(day.quotaIsPartial ? colors.warning : colors.primaryText)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    if day.id != days.last?.id {
                        Rectangle().fill(colors.border.opacity(0.45)).frame(height: 1)
                    }
                }
            }
            Text("仅统计该周期内的时段。额度“已记录”表示记录不完整，— 表示记录不足。")
                .font(.system(size: 10))
                .lineSpacing(2)
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 4)
            Text(value)
                .foregroundStyle(colors.primaryText)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }
}

#if DEBUG
#Preview("周期历史") {
    CycleHistoryView(
        presentation: CycleHistoryPresentation(
            snapshot: UsagePreviewData.fullSnapshot,
            timeZone: UsagePreviewData.timeZone
        ),
        onBack: {}
    )
    .modifier(UsagePopoverSurface(style: .aurora))
    .preferredColorScheme(.dark)
}
#endif
