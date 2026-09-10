import SwiftUI

struct OverviewView: View {
    let presentation: OverviewPresentation
    @Binding var style: UsageStyle
    let isRefreshing: Bool
    let showsCodexHomeAction: Bool
    let onRefresh: () -> Void
    let onShowTrend: () -> Void
    let onShowHistory: () -> Void
    let onChooseCodexHome: () -> Void
    let onExit: () -> Void

    @Environment(\.usageColors) private var colors

    init(
        presentation: OverviewPresentation,
        style: Binding<UsageStyle> = .constant(.native),
        isRefreshing: Bool = false,
        showsCodexHomeAction: Bool = false,
        onRefresh: @escaping () -> Void = {},
        onShowTrend: @escaping () -> Void = {},
        onShowHistory: @escaping () -> Void = {},
        onChooseCodexHome: @escaping () -> Void = {},
        onExit: @escaping () -> Void = {}
    ) {
        self.presentation = presentation
        _style = style
        self.isRefreshing = isRefreshing
        self.showsCodexHomeAction = showsCodexHomeAction
        self.onRefresh = onRefresh
        self.onShowTrend = onShowTrend
        self.onShowHistory = onShowHistory
        self.onChooseCodexHome = onChooseCodexHome
        self.onExit = onExit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            quotaSection
                .padding(.top, style == .native ? 14 : 12)
            todaySection
                .padding(.top, style == .native ? 14 : 11)
            cycleSection
                .padding(.top, style == .native ? 12 : 9)
            navigationRow
                .padding(.top, style == .native ? 12 : 9)
            Spacer(minLength: 0)
            footer
                .padding(.top, 10)
        }
        .padding(.horizontal, UsageTheme.pagePadding)
        .padding(.top, UsageTheme.pagePadding)
        .padding(.bottom, style == .native ? UsageTheme.pagePadding : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(colors.primaryText)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(colors.accent)
                .frame(width: 30, height: 30)
                .background(
                    colors.tint,
                    in: RoundedRectangle(cornerRadius: style == .native ? 9 : 15)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("Codex Usage")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.15)
                    .frame(height: 16)
                HStack(spacing: 5) {
                    Circle()
                        .fill(presentation.staleMessage == nil ? colors.good : colors.warning)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(isRefreshing ? "正在刷新…" : presentation.staleMessage ?? "本机用量")
                        .foregroundStyle(
                            presentation.staleMessage == nil ? colors.secondaryText : colors.warning
                        )
                    if showsCodexHomeAction {
                        Button("重新选择", action: onChooseCodexHome)
                            .buttonStyle(.plain)
                            .foregroundStyle(colors.warning)
                            .accessibilityLabel("重新选择 Codex Home")
                    }
                }
                .font(.system(size: 11))
                .frame(height: 15.4)
            }

            Spacer(minLength: 0)
            HStack(spacing: 2) {
                styleMenu
                Button(action: onRefresh) {
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .regular))
                        }
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(colors.secondaryText)
                .disabled(isRefreshing)
                .accessibilityLabel("刷新用量")
                .help("刷新")
            }
        }
        .frame(height: 32)
    }

    private var styleMenu: some View {
        Menu {
            Picker("界面样式", selection: $style) {
                ForEach(UsageStyle.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 14))
                .foregroundStyle(colors.secondaryText)
                .frame(width: 28, height: 28)
        }
        .tint(colors.secondaryText)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("界面样式")
        .accessibilityValue(style.title)
        .help("界面样式")
    }

    @ViewBuilder
    private var quotaSection: some View {
        if style == .native {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("周额度剩余")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(colors.secondaryText)
                            .frame(height: 15.4)
                        remainingQuota(numberSize: 44, unitSize: 23)
                            .frame(height: 46.2)
                    }
                    Spacer(minLength: 8)
                    resetDetails(alignment: .trailing)
                }
                quotaBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .frame(height: 114, alignment: .top)
            .frame(maxWidth: .infinity)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 11))
        } else {
            HStack(spacing: 21) {
                quotaRing
                VStack(alignment: .leading, spacing: 0) {
                    Text("周额度剩余")
                        .font(.system(size: 12, weight: .medium))
                        .frame(height: 16.8)
                    resetDetails(alignment: .leading)
                        .padding(.top, 10)
                    Text(
                        presentation.resetTime == nil
                            ? "暂无额度数据"
                            : "已使用 \(UsageFormatters.remainingPercent((1 - presentation.progress) * 100))"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(colors.secondaryText)
                    .frame(height: 15.4)
                    .padding(.top, 11)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.top, 3)
            .frame(height: 120)
        }
    }

    private func resetDetails(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(presentation.resetTime == nil ? "暂无重置时间" : presentation.resetCountdown)
                .font(.system(size: 12, weight: .medium))
                .frame(height: 16.8)
            Text(presentation.resetTime ?? "等待官方数据")
                .font(.system(size: 11))
                .foregroundStyle(colors.secondaryText)
                .frame(height: 15.4)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
    }

    private func remainingQuota(numberSize: CGFloat, unitSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(
                presentation.remainingPercent.hasSuffix("%")
                    ? String(presentation.remainingPercent.dropLast())
                    : "—"
            )
            .font(.system(size: numberSize, weight: .medium))
            .tracking(style == .native ? -1.8 : -0.8)
            if presentation.remainingPercent.hasSuffix("%") {
                Text("%")
                    .font(.system(size: unitSize, weight: .medium))
                    .tracking(-1)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.remainingPercent)
    }

    private var quotaBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(colors.soft)
                Capsule()
                    .fill(colors.accent)
                    .frame(width: geometry.size.width * presentation.progress)
            }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("周额度剩余进度")
        .accessibilityValue(presentation.remainingPercent)
    }

    private var quotaRing: some View {
        ZStack {
            Circle().stroke(colors.soft, lineWidth: 8 * 116 / 126)
            if presentation.progress > 0 {
                Circle()
                    .trim(from: 0, to: presentation.progress)
                    .stroke(colors.accent, style: StrokeStyle(lineWidth: 8 * 116 / 126, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 106 * 116 / 126, height: 106 * 116 / 126)
        .frame(width: 116, height: 116)
        .overlay {
            VStack(spacing: 0) {
                remainingQuota(numberSize: 36, unitSize: 19)
                    .frame(height: 39.6)
                Text("剩余额度")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colors.secondaryText)
                    .frame(height: 18.2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("周额度剩余")
        .accessibilityValue(presentation.remainingPercent)
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: style == .native ? 3 : 2) {
                    Text("今日 Token")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.secondaryText)
                        .frame(height: 15.4)
                    todayTotal
                        .frame(height: style == .native ? 34.22 : 31.86)
                }
                Spacer(minLength: 0)
                Button(action: onShowTrend) {
                    VStack(alignment: .trailing, spacing: style == .native ? 3 : 2) {
                        Text("当日额度消耗")
                            .font(.system(size: 10))
                            .foregroundStyle(colors.secondaryText)
                            .frame(height: 15.4)
                        todayQuotaValue
                            .frame(height: style == .native ? 34.22 : 31.86)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(presentation.todayQuota.help + "\n点击查看最近 7 天。")
                .accessibilityLabel(presentation.todayQuota.summary + "，查看最近 7 天")
            }

            GeometryReader { geometry in
                let available = geometry.size.width - 18
                HStack(spacing: 9) {
                    tokenDetail("输入", value: presentation.inputTokens, showsDivider: false)
                        .frame(width: available / 3.11, alignment: .leading)
                    tokenDetail("其中缓存", value: presentation.cachedInputTokens, showsDivider: true)
                        .frame(width: available * 1.26 / 3.11, alignment: .leading)
                    tokenDetail("输出", value: presentation.outputTokens, showsDivider: true)
                        .frame(width: available * 0.85 / 3.11, alignment: .leading)
                }
            }
            .frame(height: 34.6)
            .padding(.top, style == .native ? 10 : 8)
        }
        .padding(.horizontal, style == .orbit ? 13 : 0)
        .padding(.top, style == .orbit ? 11 : 0)
        .padding(.bottom, style == .orbit ? 12 : 0)
        .background(
            style == .orbit ? colors.surface : .clear,
            in: RoundedRectangle(cornerRadius: 11)
        )
    }

    @ViewBuilder
    private var todayQuotaValue: some View {
        let quota = presentation.todayQuota
        if quota.segments.isEmpty {
            Text(quota.percent == "--" ? "—" : quota.percent)
                .font(.system(size: 18, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(quota.percent == "--" ? colors.secondaryText : colors.accent)
        } else if quota.segments.count <= 2 {
            HStack(spacing: 12) {
                ForEach(quota.segments) { segment in
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(segment.label)
                            .font(.system(size: 9))
                            .foregroundStyle(colors.secondaryText)
                        Text(segment.percent == "记录不足" ? "—" : segment.percent)
                            .font(.system(size: 14, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(segment.percent == "记录不足" ? colors.secondaryText : colors.accent)
                    }
                }
            }
        } else {
            HStack(spacing: 4) {
                Text("分 \(quota.segments.count) 段")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
            }
            .foregroundStyle(colors.accent)
        }
    }

    private var todayTotal: some View {
        let value = presentation.todayTotal
        let hasUnit = value.hasSuffix("万") || value.hasSuffix("亿")
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(hasUnit ? String(value.dropLast()) : value)
                .font(.system(size: style == .native ? 29 : 27, weight: .medium))
                .tracking(-0.8)
            if hasUnit {
                Text(String(value.suffix(1)))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(colors.secondaryText)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value + " Token")
    }

    private func tokenDetail(_ label: String, value: String, showsDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(colors.secondaryText)
                .frame(height: 15.4)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .frame(height: 18.2)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.leading, showsDivider ? 13 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if showsDivider {
                Rectangle().fill(colors.border).frame(width: 1)
            }
        }
    }

    private var cycleSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("当前周期 Token")
                    .font(.system(size: 11, weight: .medium))
                    .frame(height: 15.4)
                Text(presentation.currentCycleStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        presentation.currentCycleStatus == "数据可能已过期"
                            ? colors.warning : colors.secondaryText
                    )
                    .frame(height: 15.4)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(presentation.currentCycleTokens)
                    .font(.system(size: style == .native ? 20 : 18, weight: .medium))
                    .tracking(-0.5)
                    .monospacedDigit()
                HStack(spacing: 4) {
                    Text("额度已用")
                        .foregroundStyle(colors.secondaryText)
                    Text(presentation.currentCycleQuotaPercent == "--" ? "—" : presentation.currentCycleQuotaPercent)
                        .monospacedDigit()
                        .foregroundStyle(colors.secondaryText)
                }
                .font(.system(size: 10))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.currentCycleQuota)
                .help("该周期累计已用额度，来自最近一次官方额度记录，可能有刷新延迟。— 表示额度记录不足。")
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, style == .native ? 0 : 2)
        .padding(.top, style == .native ? 10 : 0)
        .frame(height: style == .native ? 46 : 36)
        .overlay(alignment: .top) {
            if style == .native {
                Rectangle().fill(colors.border).frame(height: 1)
            }
        }
    }

    private var navigationRow: some View {
        HStack(spacing: 8) {
            NavigationTileButton(title: "最近 7 天", systemImage: "chart.bar", action: onShowTrend)
            NavigationTileButton(title: "历史周期", systemImage: "clock.arrow.circlepath", action: onShowHistory)
        }
        .frame(height: 33)
    }

    private var footer: some View {
        HStack {
            Text(presentation.lastUpdated)
            Spacer()
            Button("退出", action: onExit)
                .buttonStyle(.plain)
                .accessibilityLabel("退出 Codex Usage")
        }
        .font(.system(size: 11))
        .foregroundStyle(colors.secondaryText)
        .frame(height: 15.4)
    }
}

private struct NavigationTileButton: View {
    @Environment(\.usageColors) private var colors
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(colors.secondaryText)
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.secondaryText)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(NavigationTileButtonStyle(colors: colors, isHovering: isHovering))
        .foregroundStyle(colors.primaryText)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHovering ? colors.accent : colors.border, lineWidth: 1)
        }
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }
}

private struct NavigationTileButtonStyle: ButtonStyle {
    let colors: UsageColors
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isHovering || configuration.isPressed ? colors.tint : colors.surface,
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}

#if DEBUG
#Preview("原生精修") {
    OverviewView(presentation: OverviewPresentation(
        snapshot: UsagePreviewData.fullSnapshot,
        now: UsagePreviewData.now,
        timeZone: UsagePreviewData.timeZone
    ))
    .modifier(UsagePopoverSurface(style: .native))
    .preferredColorScheme(.dark)
}

#Preview("环形仪表") {
    OverviewView(
        presentation: OverviewPresentation(
            snapshot: UsagePreviewData.fullSnapshot,
            now: UsagePreviewData.now,
            timeZone: UsagePreviewData.timeZone
        ),
        style: .constant(.orbit)
    )
    .modifier(UsagePopoverSurface(style: .orbit))
    .preferredColorScheme(.dark)
}
#endif
