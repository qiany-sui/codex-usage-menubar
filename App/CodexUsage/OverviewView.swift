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
        style: Binding<UsageStyle> = .constant(.aurora),
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
                .padding(.top, style.hasAccentCards ? 9 : 12)
            todaySection
                .padding(.top, style.hasAccentCards ? 9 : 11)
            cycleSection
                .padding(.top, style.hasAccentCards ? 8 : 9)
            navigationRow
                .padding(.top, style.hasAccentCards ? 8 : 9)
            Spacer(minLength: 0)
            footer
                .padding(.top, 10)
        }
        .padding(.horizontal, style.hasAccentCards ? 16 : UsageTheme.pagePadding)
        .padding(.top, UsageTheme.pagePadding)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(colors.primaryText)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Group {
                if style.hasAccentCards {
                    Text(">_").font(.system(size: 18, weight: .medium, design: .monospaced))
                } else {
                    Image(systemName: "terminal").font(.system(size: 15, weight: .regular))
                }
            }
                .foregroundStyle(style.hasAccentCards ? colors.primaryText : colors.accent)
                .frame(width: 30, height: 30)
                .background(
                    style.hasAccentCards ? colors.surface : colors.tint,
                    in: RoundedRectangle(cornerRadius: style == .orbit ? 15 : 9)
                )
                .overlay {
                    if style.hasAccentCards {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(colors.secondaryText.opacity(0.5), lineWidth: 1.2)
                    }
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("Codex Usage")
                    .font(.system(size: style.hasAccentCards ? 14 : 13, weight: .semibold))
                    .tracking(-0.15)
                    .frame(height: style.hasAccentCards ? 17 : 16)
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
        if style == .aurora {
            auroraQuotaSection
        } else {
            HStack(spacing: style == .neon ? 12 : 21) {
                if style == .neon {
                    NeonQuotaGauge(progress: presentation.progress)
                        .overlay {
                            remainingQuota(numberSize: 38, unitSize: 22)
                                .offset(y: 9)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("周额度剩余")
                        .accessibilityValue(presentation.remainingPercent)
                    Rectangle().fill(colors.border).frame(width: 1, height: 104)
                } else {
                    quotaRing
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("周额度剩余")
                        .font(.system(size: style == .neon ? 14 : 12, weight: .medium))
                        .frame(height: style == .neon ? 20 : 16.8)
                    resetDetails(alignment: .leading)
                        .padding(.top, style == .neon ? 9 : 10)
                    if style == .neon {
                        Rectangle().fill(colors.border).frame(height: 1)
                            .padding(.top, 10)
                    }
                    Text(usedQuotaText)
                        .font(.system(size: 11))
                        .foregroundStyle(colors.secondaryText)
                        .frame(height: 15.4)
                        .padding(.top, style == .neon ? 8 : 11)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, style == .neon ? 0 : 7)
            .padding(.top, style == .neon ? 0 : 3)
            .frame(height: style == .neon ? 122 : 120)
        }
    }

    private var usedQuotaText: String {
        presentation.resetTime == nil
            ? "暂无额度数据"
            : "已使用 \(UsageFormatters.remainingPercent((1 - presentation.progress) * 100))"
    }

    private var auroraQuotaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("周额度剩余")
                        .font(.system(size: 12, weight: .medium))
                        .frame(height: 17)
                    remainingQuota(numberSize: 45, unitSize: 27)
                        .foregroundStyle(colors.accent)
                        .frame(height: 50)
                }
                Spacer(minLength: 8)
                resetDetails(alignment: .trailing)
            }
            SegmentedQuotaBar(progress: presentation.progress)
            Text(usedQuotaText)
                .font(.system(size: 10))
                .foregroundStyle(colors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(height: 122)
        .modifier(UsageAccentCard(style: style, emphasized: true))
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
            .font(.system(size: numberSize, weight: style.hasAccentCards ? .semibold : .medium))
            .tracking(style.hasAccentCards ? -1.8 : -0.8)
            if presentation.remainingPercent.hasSuffix("%") {
                Text("%")
                    .font(.system(size: unitSize, weight: style.hasAccentCards ? .semibold : .medium))
                    .tracking(-1)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.remainingPercent)
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

    @ViewBuilder
    private var todaySection: some View {
        if style.hasAccentCards {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("今日 Token")
                            .font(.system(size: 11, weight: .medium))
                            .frame(height: 16)
                        todayTotal.frame(height: 36)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(colors.border).frame(width: 1, height: 46)
                        .padding(.top, 5)
                    Button(action: onShowTrend) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当日额度消耗")
                                .font(.system(size: 11, weight: .medium))
                                .frame(height: 16)
                            todayQuotaValue.frame(height: 36)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(presentation.todayQuota.help + "\n点击查看最近 7 天。")
                    .accessibilityLabel(presentation.todayQuota.summary + "，查看最近 7 天")
                }
                Rectangle().fill(colors.border).frame(height: 1)
                    .padding(.top, 6)
                HStack(spacing: 0) {
                    tokenDetail("输入", value: presentation.inputTokens, showsDivider: false)
                    tokenDetail("其中缓存", value: presentation.cachedInputTokens, showsDivider: true)
                    tokenDetail("输出", value: presentation.outputTokens, showsDivider: true)
                }
                .frame(height: 36)
                .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .modifier(UsageAccentCard(style: style, illuminated: style == .neon))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("今日 Token")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(colors.secondaryText)
                            .frame(height: 15.4)
                        todayTotal.frame(height: 31.86)
                    }
                    Spacer(minLength: 0)
                    Button(action: onShowTrend) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("当日额度消耗")
                                .font(.system(size: 10))
                                .foregroundStyle(colors.secondaryText)
                                .frame(height: 15.4)
                            todayQuotaValue.frame(height: 31.86)
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
                .padding(.top, 8)
            }
            .padding(.horizontal, 13)
            .padding(.top, 11)
            .padding(.bottom, 12)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var todayQuotaColor: Color {
        style == .aurora ? colors.primaryText : (colors.accentText ?? colors.accent)
    }

    @ViewBuilder
    private var todayQuotaValue: some View {
        let quota = presentation.todayQuota
        if quota.segments.isEmpty {
            VStack(alignment: style.hasAccentCards ? .leading : .trailing, spacing: 1) {
                Text(quota.percent == "--" ? "—" : quota.percent)
                    .font(.system(size: style.hasAccentCards ? (quota.isPartial ? 20 : 30) : 18, weight: style.hasAccentCards ? .semibold : .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .foregroundStyle(quota.percent == "--" ? colors.secondaryText : todayQuotaColor)
                if quota.isPartial {
                    Text("已记录 · 记录不完整")
                        .font(.system(size: 8))
                        .foregroundStyle(colors.secondaryText)
                }
            }
        } else if quota.segments.count <= 2 {
            HStack(spacing: 12) {
                ForEach(quota.segments) { segment in
                    VStack(alignment: style.hasAccentCards ? .leading : .trailing, spacing: 1) {
                        Text(segment.label + (segment.isPartial ? " · 已记录" : ""))
                            .font(.system(size: style.hasAccentCards ? 8 : 9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(colors.secondaryText)
                        Text(segment.percent == "记录不足" ? "—" : segment.percent)
                            .font(.system(size: style.hasAccentCards ? 18 : 14, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(segment.percent == "记录不足" ? colors.secondaryText : todayQuotaColor)
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

    @ViewBuilder
    private var todayTotal: some View {
        let value = presentation.todayTotal
        let hasUnit = value.hasSuffix("万") || value.hasSuffix("亿")
        Group {
            if style.hasAccentCards {
                Text(value)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-1.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(hasUnit ? String(value.dropLast()) : value)
                        .font(.system(size: 27, weight: .medium))
                        .tracking(-0.8)
                    if hasUnit {
                        Text(String(value.suffix(1)))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(colors.secondaryText)
                    }
                }
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value + " Token")
    }

    private func tokenDetail(_ label: String, value: String, showsDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: style.hasAccentCards ? 2 : 1) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(style.hasAccentCards ? colors.primaryText : colors.secondaryText)
                .frame(height: 15.4)
            Text(value)
                .font(.system(size: style.hasAccentCards ? 17 : 13, weight: style.hasAccentCards ? .semibold : .medium))
                .monospacedDigit()
                .frame(height: style.hasAccentCards ? 20 : 18.2)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.leading, showsDivider ? (style.hasAccentCards ? 12 : 13) : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if showsDivider {
                Rectangle().fill(colors.border).frame(width: 1)
            }
        }
    }

    private var cycleStatusColor: Color {
        presentation.currentCycleStatus == "数据可能已过期" ? colors.warning : colors.secondaryText
    }

    @ViewBuilder
    private var cycleSection: some View {
        if style.hasAccentCards {
            HStack(spacing: 5) {
                Text("当前周期 Token")
                    .font(.system(size: 10, weight: .medium))
                    .fixedSize()
                Text(presentation.currentCycleStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(cycleStatusColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(colors.soft.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(colors.border, lineWidth: 1)
                    }
                Spacer(minLength: 0)
                Rectangle().fill(colors.border).frame(width: 1, height: 18)
                Text(presentation.currentCycleTokens)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.5)
                    .monospacedDigit()
                Spacer(minLength: 0)
                cycleQuota.font(.system(size: 10))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .modifier(UsageAccentCard(style: style))
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前周期 Token")
                        .font(.system(size: 11, weight: .medium))
                        .frame(height: 15.4)
                    Text(presentation.currentCycleStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(cycleStatusColor)
                        .frame(height: 15.4)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(presentation.currentCycleTokens)
                        .font(.system(size: 18, weight: .medium))
                        .tracking(-0.5)
                        .monospacedDigit()
                    cycleQuota.font(.system(size: 10))
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 2)
            .frame(height: 36)
        }
    }

    private var cycleQuota: some View {
        HStack(spacing: 4) {
            Text("额度已用")
            Text(presentation.currentCycleQuotaPercent == "--" ? "—" : presentation.currentCycleQuotaPercent)
                .monospacedDigit()
        }
        .foregroundStyle(style.hasAccentCards ? colors.primaryText : colors.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.currentCycleQuota)
        .help("该周期累计已用额度，来自最近一次官方额度记录，可能有刷新延迟。— 表示额度记录不足。")
    }

    private var navigationRow: some View {
        HStack(spacing: 8) {
            NavigationTileButton(title: "最近 7 天", systemImage: "chart.bar", style: style, action: onShowTrend)
            NavigationTileButton(title: "历史周期", systemImage: "clock.arrow.circlepath", style: style, action: onShowHistory)
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
        .overlay(alignment: .top) {
            if style == .neon {
                Rectangle().fill(colors.border.opacity(0.7)).frame(height: 1).offset(y: -6)
            }
        }
    }
}

private struct NavigationTileButton: View {
    @Environment(\.usageColors) private var colors
    let title: String
    let systemImage: String
    let style: UsageStyle
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: style.hasAccentCards ? 15 : 13))
                    .foregroundStyle(style.hasAccentCards ? colors.primaryText : colors.secondaryText)
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: style.hasAccentCards ? 12 : 11))
                    .foregroundStyle(colors.secondaryText)
            }
            .font(.system(size: style.hasAccentCards ? 12 : 11, weight: style.hasAccentCards ? .medium : .regular))
            .padding(.horizontal, style.hasAccentCards ? 12 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(NavigationTileButtonStyle(colors: colors, style: style, isHovering: isHovering))
        .foregroundStyle(colors.primaryText)
        .overlay {
            if style.hasAccentCards {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(colors.accentGradient, lineWidth: 1)
                    .opacity(isHovering ? 1 : (style == .neon ? 0.75 : 0.2))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isHovering ? colors.accent : colors.border, lineWidth: 1)
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }
}

private struct NavigationTileButtonStyle: ButtonStyle {
    let colors: UsageColors
    let style: UsageStyle
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: style.hasAccentCards ? 11 : 8)
                    .fill(isHovering || configuration.isPressed ? colors.tint : colors.surface)
                    .overlay {
                        if style.hasAccentCards {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(colors.accentGradient)
                                .opacity(style == .neon ? 0.12 : 0.045)
                        }
                    }
            }
    }
}

#if DEBUG
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

#Preview("霓光仪表") {
    OverviewView(
        presentation: OverviewPresentation(
            snapshot: UsagePreviewData.fullSnapshot,
            now: UsagePreviewData.now,
            timeZone: UsagePreviewData.timeZone
        ),
        style: .constant(.neon)
    )
    .modifier(UsagePopoverSurface(style: .neon))
    .preferredColorScheme(.dark)
}

#Preview("极光卡片") {
    OverviewView(
        presentation: OverviewPresentation(
            snapshot: UsagePreviewData.fullSnapshot,
            now: UsagePreviewData.now,
            timeZone: UsagePreviewData.timeZone
        ),
        style: .constant(.aurora)
    )
    .modifier(UsagePopoverSurface(style: .aurora))
    .preferredColorScheme(.dark)
}
#endif
