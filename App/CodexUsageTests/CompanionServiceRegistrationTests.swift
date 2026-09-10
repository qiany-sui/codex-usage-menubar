import ServiceManagement
import XCTest
@testable import CodexUsage

final class CompanionServiceRegistrationTests: XCTestCase {
    func testMainAppUpdateRefreshesRegistrationEvenWhenHelperIsUnchanged() throws {
        let bundle = try makeAppBundle()
        let previous = try XCTUnwrap(
            CompanionServiceRegistration.registrationFingerprint(for: bundle)
        )
        try Data("app-v2".utf8).write(to: XCTUnwrap(bundle.executableURL))

        XCTAssertTrue(
            CompanionServiceRegistration.shouldRefreshRegistration(
                status: .enabled,
                isTestProcess: false,
                storedFingerprint: previous,
                currentFingerprint: CompanionServiceRegistration.registrationFingerprint(for: bundle)
            )
        )
    }

    func testHelperUpdateRefreshesRegistration() throws {
        try assertFileUpdateRefreshesRegistration(
            relativePath: "Contents/MacOS/CodexUsageWatcher"
        )
    }

    func testLaunchAgentConfigurationUpdateRefreshesRegistration() throws {
        try assertFileUpdateRefreshesRegistration(
            relativePath: "Contents/Library/LaunchAgents/com.local.CodexUsage.Watcher.plist"
        )
    }

    func testMovingIdenticalAppRefreshesRegistration() throws {
        let bundle = try makeAppBundle()
        let previous = try XCTUnwrap(
            CompanionServiceRegistration.registrationFingerprint(for: bundle)
        )
        let movedURL = bundle.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Moved.app", isDirectory: true)
        try FileManager.default.copyItem(at: bundle.bundleURL, to: movedURL)
        let movedBundle = try XCTUnwrap(Bundle(url: movedURL))

        XCTAssertTrue(
            CompanionServiceRegistration.shouldRefreshRegistration(
                status: .enabled,
                isTestProcess: false,
                storedFingerprint: previous,
                currentFingerprint: CompanionServiceRegistration.registrationFingerprint(for: movedBundle)
            )
        )
    }

    func testUnchangedAppDoesNotRefreshRegistration() throws {
        let bundle = try makeAppBundle()
        let previous = try XCTUnwrap(
            CompanionServiceRegistration.registrationFingerprint(for: bundle)
        )

        XCTAssertFalse(
            CompanionServiceRegistration.shouldRefreshRegistration(
                status: .enabled,
                isTestProcess: false,
                storedFingerprint: previous,
                currentFingerprint: CompanionServiceRegistration.registrationFingerprint(for: bundle)
            )
        )
    }

    func testIncompleteAppHasNoRegistrationFingerprint() throws {
        let bundle = try makeAppBundle()
        try FileManager.default.removeItem(at: XCTUnwrap(bundle.executableURL))

        XCTAssertNil(CompanionServiceRegistration.registrationFingerprint(for: bundle))
    }

    private func assertFileUpdateRefreshesRegistration(
        relativePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bundle = try makeAppBundle()
        let previous = try XCTUnwrap(
            CompanionServiceRegistration.registrationFingerprint(for: bundle)
        )
        try Data("updated".utf8).write(
            to: bundle.bundleURL.appendingPathComponent(relativePath)
        )

        XCTAssertTrue(
            CompanionServiceRegistration.shouldRefreshRegistration(
                status: .enabled,
                isTestProcess: false,
                storedFingerprint: previous,
                currentFingerprint: CompanionServiceRegistration.registrationFingerprint(for: bundle)
            ),
            file: file,
            line: line
        )
    }

    private func makeAppBundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Codex Usage.app", isDirectory: true)
        for (relativePath, contents) in [
            ("Contents/MacOS/Codex Usage", "app-v1"),
            ("Contents/MacOS/CodexUsageWatcher", "helper-v1"),
            ("Contents/Library/LaunchAgents/com.local.CodexUsage.Watcher.plist", "agent-v1")
        ] {
            let url = appURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        let info = [
            "CFBundleIdentifier": "com.local.CodexUsage.FingerprintTests",
            "CFBundleExecutable": "Codex Usage",
            "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(Bundle(url: appURL))
    }

    func testUnregisteredAndNotFoundStatusesRequestRegistration() {
        XCTAssertTrue(
            CompanionServiceRegistration.shouldRegister(
                status: .notRegistered,
                isTestProcess: false
            )
        )
        XCTAssertFalse(
            CompanionServiceRegistration.shouldRegister(
                status: .enabled,
                isTestProcess: false
            )
        )
        XCTAssertFalse(
            CompanionServiceRegistration.shouldRegister(
                status: .requiresApproval,
                isTestProcess: false
            )
        )
        XCTAssertTrue(
            CompanionServiceRegistration.shouldRegister(
                status: .notFound,
                isTestProcess: false
            )
        )
    }

    func testTestProcessNeverRequestsRegistration() {
        XCTAssertFalse(
            CompanionServiceRegistration.shouldRegister(
                status: .notRegistered,
                isTestProcess: true
            )
        )
    }

    func testEnabledServiceRefreshesWhenHelperFingerprintChanges() {
        XCTAssertTrue(
            CompanionServiceRegistration.shouldRefreshRegistration(
                status: .enabled,
                isTestProcess: false,
                storedFingerprint: "old",
                currentFingerprint: "new"
            )
        )
    }

    func testEnabledServiceRefreshesWhenNoFingerprintWasStored() {
        XCTAssertTrue(
            CompanionServiceRegistration.shouldRefreshRegistration(
                status: .enabled,
                isTestProcess: false,
                storedFingerprint: nil,
                currentFingerprint: "new"
            )
        )
    }

    func testEnabledServiceDoesNotRefreshWhenFingerprintMatches() {
        XCTAssertFalse(
            CompanionServiceRegistration.shouldRefreshRegistration(
                status: .enabled,
                isTestProcess: false,
                storedFingerprint: "same",
                currentFingerprint: "same"
            )
        )
    }

    func testServiceDoesNotRefreshWithoutCurrentFingerprintOrDuringTests() {
        XCTAssertFalse(
            CompanionServiceRegistration.shouldRefreshRegistration(
                status: .enabled,
                isTestProcess: false,
                storedFingerprint: "old",
                currentFingerprint: nil
            )
        )
        XCTAssertFalse(
            CompanionServiceRegistration.shouldRefreshRegistration(
                status: .enabled,
                isTestProcess: true,
                storedFingerprint: "old",
                currentFingerprint: "new"
            )
        )
    }
}
