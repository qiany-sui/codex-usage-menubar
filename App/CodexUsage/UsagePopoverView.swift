import AppKit
import SwiftUI
import UsageCore

struct UsagePopoverView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var viewModel: UsageViewModel

    private let now: () -> Date
    private let timeZone: TimeZone

    init(
        viewModel: UsageViewModel,
        now: @escaping () -> Date = Date.init,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.viewModel = viewModel
        self.now = now
        self.timeZone = timeZone
    }

    var body: some View {
        stateContent
            .frame(
                width: UsageTheme.popoverSize.width,
                height: UsageTheme.popoverSize.height
            )
            .background(UsageTheme.background)
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var stateContent: some View {
        if viewModel.fatalErrorMessage != nil {
            FatalUsageState {
                Task { await viewModel.retryFatalError() }
            }
        } else if viewModel.isInitialLoading {
            LoadingUsageState()
        } else if viewModel.needsCodexHomeSelection,
                  viewModel.snapshot == nil {
            CodexHomeSelectionState {
                Task { await viewModel.chooseCodexHome() }
            }
        } else if let snapshot = viewModel.snapshot {
            routedContent(snapshot: snapshot)
        } else {
            EmptyUsageState {
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
                    isRefreshing: viewModel.isRefreshing,
                    showsCodexHomeAction: viewModel.needsCodexHomeSelection,
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
                    presentation: TrendPresentation(snapshot: snapshot),
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
        .id(viewModel.page)
        .transition(pageTransition)
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: UsageTheme.transitionDuration),
            value: viewModel.page
        )
    }

    private var pageTransition: AnyTransition {
        reduceMotion
            ? .identity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
    }
}

private struct LoadingUsageState: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text("正在读取本机用量…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UsageTheme.secondaryText)
        }
    }
}

private struct CodexHomeSelectionState: View {
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(UsageTheme.accentBlue)
            VStack(spacing: 6) {
                Text("需要访问 Codex Home")
                    .font(.system(size: 16, weight: .semibold))
                Text("请选择包含 sessions 或 archived_sessions 的目录。\n应用只读取本机用量事件，不读取对话正文。")
                    .font(.system(size: 12))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            Button("选择 Codex Home", action: onChoose)
                .buttonStyle(.borderedProminent)
                .tint(UsageTheme.accent)
                .accessibilityLabel("选择 Codex Home")
        }
        .padding(36)
    }
}

private struct FatalUsageState: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(UsageTheme.danger)
            VStack(spacing: 6) {
                Text("无法读取本地用量")
                    .font(.system(size: 16, weight: .semibold))
                Text(UsageViewModel.databaseFailureMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(UsageTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            Button("重试", action: onRetry)
                .buttonStyle(.borderedProminent)
                .tint(UsageTheme.accent)
                .accessibilityLabel("重试读取用量")
        }
        .padding(36)
    }
}

private struct EmptyUsageState: View {
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(UsageTheme.secondaryText)
            Text("暂时没有可显示的用量数据")
                .font(.system(size: 14, weight: .semibold))
            Button("刷新", action: onRefresh)
                .buttonStyle(.bordered)
                .accessibilityLabel("刷新用量")
        }
    }
}
