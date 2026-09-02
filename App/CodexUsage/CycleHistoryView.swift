import SwiftUI

struct CycleHistoryView: View {
    let presentation: CycleHistoryPresentation
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if presentation.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(presentation.entries) { entry in
                            cycleRow(entry)
                            if entry.id != presentation.entries.last?.id {
                                Divider().overlay(UsageTheme.border)
                            }
                        }
                    }
                    .padding(.trailing, 12)
                }
            }
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

            Text("历史周期")
                .font(.system(size: 15, weight: .semibold))
        }
    }

    private func cycleRow(_ entry: CycleEntryPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.range)
                        .font(.system(size: 12, weight: .medium))
                    if entry.isCurrent {
                        Text("当前周期")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(UsageTheme.accentBlue)
                    }
                }

                HStack(spacing: 6) {
                    Text(entry.statusLabel)
                    if entry.boundaryIsEstimated {
                        Text("边界估算")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(UsageTheme.secondaryText)
            }

            Spacer(minLength: 12)

            Text(entry.formattedTokens)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 20)
        .padding(.trailing, 7)
        .frame(height: 46)
        .background(entry.isCurrent ? UsageTheme.surface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            if entry.isCurrent {
                RoundedRectangle(cornerRadius: 2)
                    .fill(UsageTheme.accent)
                    .frame(width: 3, height: 34)
                    .padding(.leading, 7)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(UsageTheme.secondaryText)
            Text("暂无周期历史")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UsageTheme.secondaryText)
            Spacer()
        }
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
    .frame(
        width: UsageTheme.popoverSize.width,
        height: UsageTheme.popoverSize.height
    )
    .background(UsageTheme.background)
    .preferredColorScheme(.dark)
}
#endif
