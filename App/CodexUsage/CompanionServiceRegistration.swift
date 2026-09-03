import CryptoKit
import Foundation
import OSLog
import ServiceManagement

enum CompanionServiceRegistration {
    private static let plistName = "com.local.CodexUsage.Watcher.plist"
    private static let helperRelativePath = "Contents/MacOS/CodexUsageWatcher"
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
        let currentFingerprint = helperFingerprint()
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

    private static func helperFingerprint() -> String? {
        let helperURL = Bundle.main.bundleURL.appendingPathComponent(
            helperRelativePath,
            isDirectory: false
        )
        guard let data = try? Data(contentsOf: helperURL, options: .mappedIfSafe) else {
            return nil
        }
        return SHA256.hash(data: data)
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
