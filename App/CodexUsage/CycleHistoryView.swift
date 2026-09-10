import SwiftUI

struct CycleHistoryView: View {
    @Environment(\.usageColors) private var colors

    let presentation: CycleHistoryPresentation
    let onBack: () -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if presentation.entries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    HStack(spacing: 10) {
                        Text("周期")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Token")
                            .frame(width: 74, alignment: .trailing)
                        Text("额度已用")
                            .frame(width: 64, alignment: .trailing)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(colors.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 14)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(presentation.entries) { entry in
                                cycleRow(entry)
                                    .padding(.bottom, entry.isCurrent ? 3 : 0)
                            }
                        }
                    }

                    Text("— 表示额度记录不足")
                        .font(.system(size: 9))
                        .foregroundStyle(colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 11)
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
    }

    private func cycleRow(_ entry: CycleEntryPresentation) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.range)
                    if entry.isCurrent {
                        Text("当前")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(colors.accent)
                    }
                }
                .frame(height: 15.4)

                HStack(spacing: 6) {
                    Text(entry.statusLabel)
                    if entry.boundaryIsEstimated {
                        Text("边界估算")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(colors.secondaryText)
                .frame(height: 14)
            }
            .font(.system(size: 11))

            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.formattedTokens)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .frame(width: 74, alignment: .trailing)

            Text(entry.quotaPercent == "--" ? "—" : entry.quotaPercent)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(entry.isCurrent ? colors.accent : colors.secondaryText)
                .frame(width: 64, alignment: .trailing)
                .accessibilityLabel(entry.quotaUsage)
                .help(entry.isCurrent
                    ? "当前周期累计已用额度，来自最近一次官方额度记录。— 表示额度记录不足。"
                    : "该周期结束前 10 分钟内的最后一条官方额度记录。记录不足或边界为估算时不推算百分比；Token 校准状态单独判断。")
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(entry.isCurrent ? colors.tint : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottom) {
            if !entry.isCurrent && entry.id != presentation.entries.last?.id {
                Rectangle().fill(colors.border.opacity(0.5)).frame(height: 0.5)
            }
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

#if DEBUG
#Preview("周期历史") {
    CycleHistoryView(
        presentation: CycleHistoryPresentation(
            snapshot: UsagePreviewData.fullSnapshot,
            timeZone: UsagePreviewData.timeZone
        ),
        onBack: {}
    )
    .modifier(UsagePopoverSurface(style: .native))
    .preferredColorScheme(.dark)
}
#endif
