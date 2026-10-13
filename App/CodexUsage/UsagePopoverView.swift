import AppKit
import SwiftUI
import UsageCore

struct UsagePopoverView: View {
    @ObservedObject var viewModel: UsageViewModel
    @AppStorage(UsageStyle.storageKey) var style: UsageStyle = .aurora
    @State private var isRetrying = false

    private let now: () -> Date
    private let timeZone: TimeZone

    init(
        viewModel: UsageViewModel,
        now: @escaping () -> Date = Date.init,
        timeZone: TimeZone = .autoupdatingCurrent,
        styleDefaults: UserDefaults = .standard
    ) {
        self.viewModel = viewModel
        if let savedStyle = styleDefaults.string(forKey: UsageStyle.storageKey),
           savedStyle == "native" || savedStyle == "neon" {
            styleDefaults.set(UsageStyle.aurora.rawValue, forKey: UsageStyle.storageKey)
        }
        _style = AppStorage(
            wrappedValue: .aurora,
            UsageStyle.storageKey,
            store: styleDefaults
        )
        self.now = now
        self.timeZone = timeZone
    }

    var body: some View {
        stateContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if viewModel.snapshot == nil || viewModel.fatalErrorMessage != nil
                    || viewModel.isInitialLoading || isRetrying {
                    Button("退出") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .accessibilityLabel("退出 Codex Usage")
                        .padding(18)
                }
            }
            .modifier(UsagePopoverSurface(
                style: style,
                isLowQuota: (viewModel.snapshot?.quota?.remainingPercent ?? 100) <= 10
            ))
    }

    @ViewBuilder
    private var stateContent: some View {
        if viewModel.fatalErrorMessage != nil || isRetrying {
            FatalUsageState(isRetrying: isRetrying) {
                isRetrying = true
                Task {
                    await viewModel.retryFatalError()
                    isRetrying = false
                }
            }
        } else if viewModel.isInitialLoading {
            LoadingUsageState()
        } else if viewModel.needsCodexHomeSelection,
                  viewModel.snapshot == nil {
            CodexHomeSelectionState(message: viewModel.codexHomeSelectionMessage) {
                Task { await viewModel.chooseCodexHome() }
            }
        } else if let snapshot = viewModel.snapshot {
            routedContent(snapshot: snapshot)
        } else {
            EmptyUsageState(isRefreshing: viewModel.isRefreshing) {
                Task { await viewModel.refreshManually() }
            }
        }
    }

    private func routedContent(snapshot: UsageSnapshot) -> some View {
        Group {
            switch viewModel.page {
            case .overview:
                OverviewView(
                    presentation: OverviewPresentation(
                        snapshot: snapshot,
                        now: now(),
                        timeZone: timeZone
                    ),
                    style: $style,
                    isRefreshing: viewModel.isRefreshing,
                    showsCodexHomeAction: viewModel.needsCodexHomeSelection,
                    codexHomeSelectionMessage: viewModel.codexHomeSelectionMessage,
                    onRefresh: {
                        Task { await viewModel.refreshManually() }
                    },
                    onShowTrend: viewModel.showTrend,
                    onShowHistory: viewModel.showHistory,
                    onChooseCodexHome: {
                        Task { await viewModel.chooseCodexHome() }
                    },
                    onExit: {
                        NSApplication.shared.terminate(nil)
                    }
                )
            case .trend:
                TrendDetailView(
                    presentation: TrendPresentation(snapshot: snapshot, timeZone: timeZone),
                    onBack: viewModel.showOverview
                )
            case .history:
                CycleHistoryView(
                    presentation: CycleHistoryPresentation(
                        snapshot: snapshot,
                        timeZone: timeZone
                    ),
                    onBack: viewModel.showOverview
                )
            }
        }
    }
}

private struct LoadingUsageState: View {
    @Environment(\.usageColors) private var colors
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text("正在读取本机用量…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colors.secondaryText)
        }
    }
}

private struct CodexHomeSelectionState: View {
    @Environment(\.usageColors) private var colors
    let message: String?
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(colors.accent)
            VStack(spacing: 6) {
                Text("需要访问 Codex Home")
                    .font(.system(size: 16, weight: .semibold))
                Text("请选择包含 sessions 或 archived_sessions 的目录。\n应用只读取本机用量事件，不读取对话正文。")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("选择 Codex Home", action: onChoose)
                .buttonStyle(.borderedProminent)
                .tint(colors.accent)
                .accessibilityLabel("选择 Codex Home")
        }
        .padding(36)
    }
}

private struct FatalUsageState: View {
    @Environment(\.usageColors) private var colors
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(colors.danger)
            VStack(spacing: 6) {
                Text("无法读取本地用量")
                    .font(.system(size: 16, weight: .semibold))
                Text(UsageViewModel.databaseFailureMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            Button(action: onRetry) {
                HStack(spacing: 6) {
                    if isRetrying { ProgressView().controlSize(.small) }
                    Text(isRetrying ? "正在重试…" : "重试")
                }
            }
                .buttonStyle(.borderedProminent)
                .tint(colors.accent)
                .disabled(isRetrying)
                .accessibilityLabel("重试读取用量")
        }
        .padding(36)
    }
}

private struct EmptyUsageState: View {
    @Environment(\.usageColors) private var colors
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(colors.secondaryText)
            Text("暂时没有可显示的用量数据")
                .font(.system(size: 14, weight: .semibold))
            Button(isRefreshing ? "正在刷新…" : "刷新", action: onRefresh)
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
                .accessibilityLabel("刷新用量")
        }
    }
}
