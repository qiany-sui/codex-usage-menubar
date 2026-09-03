import AppKit
import OSLog

private let companionWatcherLogger = Logger(
    subsystem: "com.local.CodexUsage",
    category: "CompanionWatcher"
)

@MainActor
final class CodexApplicationWatcher: NSObject {
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let usageBundleIdentifier = "com.local.CodexUsage"

    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        super.init()
    }

    func start() {
        let center = workspace.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        perform(
            CompanionLifecyclePolicy.action(
                for: .initialState(codexRunning: isCodexRunning)
            )
        )
    }

    @objc
    private func applicationDidLaunch(_ notification: Notification) {
        guard isCodexNotification(notification) else {
            return
        }

        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(verifyCodexTermination),
            object: nil
        )
        perform(CompanionLifecyclePolicy.action(for: .codexLaunched))
    }

    @objc
    private func applicationDidTerminate(_ notification: Notification) {
        guard isCodexNotification(notification) else {
            return
        }

        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(verifyCodexTermination),
            object: nil
        )
        perform(
            #selector(verifyCodexTermination),
            with: nil,
            afterDelay: 1
        )
    }

    @objc
    private func verifyCodexTermination() {
        perform(
            CompanionLifecyclePolicy.action(
                for: .terminationCheck(codexRunning: isCodexRunning)
            )
        )
    }

    private var isCodexRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.codexBundleIdentifier
        ).isEmpty
    }

    private func isCodexNotification(_ notification: Notification) -> Bool {
        let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication
        return application?.bundleIdentifier == Self.codexBundleIdentifier
    }

    private func perform(_ action: CompanionLifecycleAction) {
        switch action {
        case .none:
            break
        case .launchUsage:
            launchUsage()
        case .terminateUsage:
            terminateUsage()
        }
    }

    private func launchUsage() {
        guard let appURL = containingAppURL else {
            companionWatcherLogger.error("无法定位 Codex Usage 应用包")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        workspace.openApplication(
            at: appURL,
            configuration: configuration,
            completionHandler: Self.handleLaunchCompletion
        )
    }

    private func terminateUsage() {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.usageBundleIdentifier
        )
        for application in applications where !application.terminate() {
            companionWatcherLogger.error("Codex Usage 拒绝了退出请求")
        }
    }

    nonisolated private static func handleLaunchCompletion(
        _ application: NSRunningApplication?,
        _ error: Error?
    ) {
        if let error {
            companionWatcherLogger.error(
                "启动 Codex Usage 失败：\(error.localizedDescription)"
            )
        }
    }

    private var containingAppURL: URL? {
        guard let executableURL = CompanionAppLocator.currentExecutableURL else {
            return nil
        }
        return CompanionAppLocator.containingAppURL(forExecutableURL: executableURL)
    }
}
