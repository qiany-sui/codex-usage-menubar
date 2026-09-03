import ServiceManagement
import XCTest
@testable import CodexUsage

final class CompanionServiceRegistrationTests: XCTestCase {
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
