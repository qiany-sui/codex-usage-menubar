import XCTest
@testable import CodexUsage

final class CompanionLifecyclePolicyTests: XCTestCase {
    func testInitialStateLaunchesUsageWhenCodexIsAlreadyRunning() {
        XCTAssertEqual(
            CompanionLifecyclePolicy.action(
                for: .initialState(codexRunning: true)
            ),
            .launchUsage
        )
    }

    func testInitialStateDoesNothingWhenCodexIsNotRunning() {
        XCTAssertEqual(
            CompanionLifecyclePolicy.action(
                for: .initialState(codexRunning: false)
            ),
            .none
        )
    }

    func testCodexLaunchRequestsUsageLaunch() {
        XCTAssertEqual(
            CompanionLifecyclePolicy.action(for: .codexLaunched),
            .launchUsage
        )
    }

    func testTerminationCheckKeepsUsageOpenWhenCodexRelaunched() {
        XCTAssertEqual(
            CompanionLifecyclePolicy.action(
                for: .terminationCheck(codexRunning: true)
            ),
            .none
        )
    }

    func testTerminationCheckClosesUsageWhenNoCodexInstanceRemains() {
        XCTAssertEqual(
            CompanionLifecyclePolicy.action(
                for: .terminationCheck(codexRunning: false)
            ),
            .terminateUsage
        )
    }
}
