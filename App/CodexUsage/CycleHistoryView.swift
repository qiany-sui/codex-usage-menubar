import SwiftUI

struct CycleHistoryView: View {
    @Environment(\.usageColors) private var colors

    let presentation: CycleHistoryPresentation
    let onBack: () -> Void

    private let tokenColumnWidth: CGFloat = 74
    private let quotaColumnWidth: CGFloat = 64
    private let rowHorizontalPadding: CGFloat = 8
    private let scrollbarGutter: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if presentation.entries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("周期")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Token")
                            .frame(width: tokenColumnWidth, alignment: .leading)
                        Text("额度已用")
                            .frame(width: quotaColumnWidth, alignment: .leading)
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

                    Text("记录不完整时显示最后记录；— 表示额度记录不足")
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(entry.range)
                    if entry.isCurrent {
                        Text("当前")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(colors.accent)
                    }
                }
                .font(.system(size: 12))
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
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.statusLabel + (entry.boundaryIsEstimated ? " · 边界估算" : ""))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.quotaIsPartial ? "记录不完整" : "")
                    .frame(width: quotaColumnWidth, alignment: .leading)
                    .foregroundStyle(colors.warning)
                    .help(entry.quotaHelp)
            }
            .font(.system(size: 11))
            .foregroundStyle(colors.secondaryText)
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, 8)
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
    .modifier(UsagePopoverSurface(style: .aurora))
    .preferredColorScheme(.dark)
}
#endif
