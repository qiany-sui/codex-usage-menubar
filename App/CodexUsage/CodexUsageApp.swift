import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var prepareToTerminate: (() async -> Void)?

    private var isTerminating = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateNow
        }
        isTerminating = true

        Task {
            if let prepareToTerminate {
                await prepareToTerminate()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: UsageViewModel

    init() {
        let container = AppContainer.live()
        _viewModel = StateObject(
            wrappedValue: UsageViewModel(
                runtimeBuilder: container,
                bookmarkStore: CodexHomeBookmarkStore(),
                chooseCodexHome: AppContainer.chooseCodexHome
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(viewModel: viewModel)
                .onAppear {
                    Task { await viewModel.openPopover() }
                }
        } label: {
            Text(viewModel.menuBarTitle)
                .accessibilityLabel(
                    "Codex 周额度 " + viewModel.menuBarTitle
                )
                .task {
                    appDelegate.prepareToTerminate = {
                        await viewModel.stop()
                    }
                    await viewModel.start()
                }
                .onReceive(
                    NSWorkspace.shared.notificationCenter.publisher(
                        for: NSWorkspace.didWakeNotification
                    )
                ) { _ in
                    Task { await viewModel.handleWake() }
                }
        }
        .menuBarExtraStyle(.window)
    }
}
