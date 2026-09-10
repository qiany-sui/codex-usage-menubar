import CryptoKit
import Foundation
import OSLog
import ServiceManagement

enum CompanionServiceRegistration {
    private static let plistName = "com.local.CodexUsage.Watcher.plist"
    private static let helperRelativePath = "Contents/MacOS/CodexUsageWatcher"
    // 复用旧键，旧版只记录助手的指纹会自然触发一次注册更新。
    private static let fingerprintDefaultsKey = "companionHelperFingerprint"
    private static let logger = Logger(
        subsystem: "com.local.CodexUsage",
        category: "CompanionRegistration"
    )

    static func shouldRegister(status: SMAppService.Status, isTestProcess: Bool) -> Bool {
        !isTestProcess && (status == .notRegistered || status == .notFound)
    }

    static func shouldRefreshRegistration(
        status: SMAppService.Status,
        isTestProcess: Bool,
        storedFingerprint: String?,
        currentFingerprint: String?
    ) -> Bool {
        guard !isTestProcess, status == .enabled, let currentFingerprint else {
            return false
        }
        return storedFingerprint != currentFingerprint
    }

    static func registerIfNeeded() {
        let isTestProcess = ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        guard !isTestProcess else {
            return
        }

        let service = SMAppService.agent(plistName: plistName)
        let currentFingerprint = registrationFingerprint()
        let storedFingerprint = UserDefaults.standard.string(
            forKey: fingerprintDefaultsKey
        )

        if shouldRefreshRegistration(
            status: service.status,
            isTestProcess: isTestProcess,
            storedFingerprint: storedFingerprint,
            currentFingerprint: currentFingerprint
        ) {
            refresh(service: service, fingerprint: currentFingerprint)
            return
        }

        guard shouldRegister(status: service.status, isTestProcess: isTestProcess) else {
            if service.status == .requiresApproval {
                logger.notice("辅助服务正在等待用户批准")
            }
            return
        }

        do {
            try service.register()
            store(fingerprint: currentFingerprint)
            logger.notice("辅助服务注册成功")
        } catch {
            logger.error("辅助服务注册失败：\(error.localizedDescription)")
        }
    }

    private static func refresh(service: SMAppService, fingerprint: String?) {
        do {
            try service.unregister()
            try service.register()
            store(fingerprint: fingerprint)
            logger.notice("辅助服务已随应用更新")
        } catch {
            logger.error("辅助服务更新失败：\(error.localizedDescription)")
        }
    }

    static func registrationFingerprint(for bundle: Bundle = .main) -> String? {
        guard let executableURL = bundle.executableURL else {
            return nil
        }
        let appURL = bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        var fingerprint = SHA256()
        fingerprint.update(data: Data(appURL.path.utf8))

        // 本机签名随主 App 更新而变化；只比较助手会漏掉已失效的系统注册。
        for url in [
            executableURL,
            appURL.appendingPathComponent(helperRelativePath),
            appURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
        ] {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return nil
            }
            fingerprint.update(data: Data(SHA256.hash(data: data)))
        }
        return fingerprint.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func store(fingerprint: String?) {
        guard let fingerprint else {
            return
        }
        UserDefaults.standard.set(fingerprint, forKey: fingerprintDefaultsKey)
    }
}
