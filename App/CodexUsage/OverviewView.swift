import SwiftUI

struct OverviewView: View {
    let presentation: OverviewPresentation
    let isRefreshing: Bool
    let showsCodexHomeAction: Bool
    let onRefresh: () -> Void
    let onShowTrend: () -> Void
    let onShowHistory: () -> Void
    let onChooseCodexHome: () -> Void
    let onExit: () -> Void

    init(
        presentation: OverviewPresentation,
        isRefreshing: Bool = false,
        showsCodexHomeAction: Bool = false,
        onRefresh: @escaping () -> Void = {},
        onShowTrend: @escaping () -> Void = {},
        onShowHistory: @escaping () -> Void = {},
        onChooseCodexHome: @escaping () -> Void = {},
        onExit: @escaping () -> Void = {}
    ) {
        self.presentation = presentation
        self.isRefreshing = isRefreshing
        self.showsCodexHomeAction = showsCodexHomeAction
        self.onRefresh = onRefresh
        self.onShowTrend = onShowTrend
        self.onShowHistory = onShowHistory
        self.onChooseCodexHome = onChooseCodexHome
        self.onExit = onExit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UsageTheme.sectionSpacing) {
            header
            quotaSection
            todaySection
            Divider().overlay(UsageTheme.border)
            cycleSection
            VStack(spacing: 12) {
                navigationRow
                footer
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
        VStack(spacing: UsageTheme.rowSpacing) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Usage")
                        .font(.system(size: 15, weight: .semibold))

                    HStack(spacing: 6) {
                        Text(headerStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(headerStatusColor)
                        if showsCodexHomeAction {
                            Button("重新选择", action: onChooseCodexHome)
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(UsageTheme.warning)
                                .accessibilityLabel(
                                    "重新选择 Codex Home"
                                )
                        }
                    }
                }

                Spacer()

                Button(action: onRefresh) {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .frame(width: 26, height: 26)
                    .background(UsageTheme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新用量")
                .help("刷新")
            }

            Rectangle()
                .fill(UsageTheme.border)
                .frame(height: 1)
        }
    }

    private var headerStatus: String {
        if isRefreshing {
            return "正在刷新…"
        }
        return presentation.staleMessage ?? "本机用量"
    }

    private var headerStatusColor: Color {
        presentation.staleMessage == nil
            ? UsageTheme.secondaryText
            : UsageTheme.warning
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("周额度剩余")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UsageTheme.secondaryText)
                    Text(presentation.remainingPercent)
                        .font(.system(size: 38, weight: .semibold))
                        .monospacedDigit()
                }

                Spacer()

                Text(presentation.resetCountdown)
                    .font(.system(size: 11))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .padding(.bottom, 6)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(UsageTheme.border)
                    Capsule()
                        .fill(UsageTheme.accent)
                        .frame(
                            width: geometry.size.width
                                * presentation.progress
                        )
                }
            }
            .frame(height: 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("周额度剩余进度")
            .accessibilityValue(presentation.remainingPercent)
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("今日 Token")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(UsageTheme.secondaryText)
            Text(presentation.todayTotal)
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()

            HStack(spacing: 0) {
                tokenDetail(
                    "输入",
                    value: presentation.inputTokens,
                    horizontalAlignment: .leading,
                    frameAlignment: .leading
                )
                tokenDetail(
                    "缓存输入",
                    value: presentation.cachedInputTokens,
                    horizontalAlignment: .center,
                    frameAlignment: .center
                )
                tokenDetail(
                    "输出",
                    value: presentation.outputTokens,
                    horizontalAlignment: .trailing,
                    frameAlignment: .trailing
                )
            }
        }
    }

    private func tokenDetail(
        _ label: String,
        value: String,
        horizontalAlignment: HorizontalAlignment,
        frameAlignment: Alignment
    ) -> some View {
        VStack(alignment: horizontalAlignment, spacing: 2) {
            Text(label)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(UsageTheme.primaryText.opacity(0.78))
        }
        .font(.system(size: 12))
        .foregroundStyle(UsageTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var cycleSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("当前周期 Token")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UsageTheme.secondaryText)
                Text(presentation.currentCycleStatus)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(cycleStatusColor)
            }

            Spacer()

            Text(presentation.currentCycleTokens)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
        }
    }

    private var cycleStatusColor: Color {
        presentation.currentCycleStatus == "数据可能已过期"
            ? UsageTheme.warning
            : UsageTheme.secondaryText
    }

    private var navigationRow: some View {
        HStack(spacing: 0) {
            NavigationTileButton(
                title: "最近 7 天",
                action: onShowTrend
            )
            Divider()
                .overlay(UsageTheme.border)
                .frame(height: 18)
            NavigationTileButton(
                title: "历史周期",
                action: onShowHistory
            )
        }
        .frame(height: 34)
        .background(UsageTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Text(presentation.lastUpdated)
                .font(.system(size: 10))
                .foregroundStyle(UsageTheme.secondaryText)
            Spacer()
            Button("退出", action: onExit)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(UsageTheme.secondaryText)
                .accessibilityLabel("退出 Codex Usage")
        }
    }
}

private struct NavigationTileButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UsageTheme.secondaryText)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(NavigationTileButtonStyle(isHovering: isHovering))
        .foregroundStyle(UsageTheme.primaryText)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }
}

private struct NavigationTileButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                UsageTheme.primaryText.opacity(
                    configuration.isPressed ? 0.10 : isHovering ? 0.05 : 0
                )
            )
    }
}

#if DEBUG
#Preview("完整数据") {
    OverviewView(
        presentation: OverviewPresentation(
            snapshot: UsagePreviewData.fullSnapshot,
            now: UsagePreviewData.now,
            timeZone: UsagePreviewData.timeZone
        )
    )
    .frame(
        width: UsageTheme.popoverSize.width,
        height: UsageTheme.popoverSize.height
    )
    .background(UsageTheme.background)
    .preferredColorScheme(.dark)
}

#Preview("数据过期") {
    OverviewView(
        presentation: OverviewPresentation(
            snapshot: UsagePreviewData.staleSnapshot,
            now: UsagePreviewData.now,
            timeZone: UsagePreviewData.timeZone
        ),
        showsCodexHomeAction: true
    )
    .frame(
        width: UsageTheme.popoverSize.width,
        height: UsageTheme.popoverSize.height
    )
    .background(UsageTheme.background)
    .preferredColorScheme(.dark)
}

#Preview("无额度数据") {
    OverviewView(
        presentation: OverviewPresentation(
            snapshot: UsagePreviewData.snapshotWithoutQuota,
            now: UsagePreviewData.now,
            timeZone: UsagePreviewData.timeZone
        )
    )
    .frame(
        width: UsageTheme.popoverSize.width,
        height: UsageTheme.popoverSize.height
    )
    .background(UsageTheme.background)
    .preferredColorScheme(.dark)
}
#endif
