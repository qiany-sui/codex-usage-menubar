import XCTest
@testable import CodexUsage

final class CompanionAppLocatorTests: XCTestCase {
    func testReturnsContainingAppForEmbeddedWatcherExecutable() {
        let executableURL = URL(
            fileURLWithPath: "/Applications/Codex Usage.app/Contents/MacOS/CodexUsageWatcher"
        )

        XCTAssertEqual(
            CompanionAppLocator.containingAppURL(forExecutableURL: executableURL),
            URL(fileURLWithPath: "/Applications/Codex Usage.app", isDirectory: true)
        )
    }

    func testRejectsExecutableOutsideAppBundle() {
        let executableURL = URL(fileURLWithPath: "/usr/local/bin/CodexUsageWatcher")

        XCTAssertNil(
            CompanionAppLocator.containingAppURL(forExecutableURL: executableURL)
        )
    }
}
