import SwiftUI

struct CycleHistoryView: View {
    @Environment(\.usageColors) private var colors

    let presentation: CycleHistoryPresentation
    let onBack: () -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            if presentation.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(presentation.entries) { entry in
                            cycleRow(entry)
                                .padding(.bottom, entry.isCurrent ? 3 : 0)
                        }
                    }
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
                        Text("当前").foregroundStyle(colors.accent)
                    }
                }
                .frame(height: 15.4)

                HStack(spacing: 6) {
                    Text(entry.statusLabel)
                    if entry.boundaryIsEstimated {
                        Text("边界估算")
                    }
                }
                .foregroundStyle(colors.secondaryText)
                .frame(height: 15.4)
            }
            .font(.system(size: 11))

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(entry.formattedTokens)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                Text(entry.quotaUsage)
                    .font(.system(size: 10))
                    .foregroundStyle(colors.secondaryText)
                    .monospacedDigit()
                    .help(entry.isCurrent
                        ? "当前周期累计已用额度，来自最近一次官方额度记录。"
                        : "该周期结束前 10 分钟内的最后一条官方额度记录。记录不足或边界为估算时不推算百分比；Token 校准状态单独判断。")
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(entry.isCurrent ? colors.tint : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottom) {
            if !entry.isCurrent && entry.id != presentation.entries.last?.id {
                Rectangle().fill(colors.border).frame(height: 1)
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
