import Foundation
import UsageCore
import XCTest
@testable import CodexUsage

final class AppContainerTests: XCTestCase {
    func testDatabaseURLUsesApplicationSupportCodexUsageDirectory() {
        let support = URL(
            fileURLWithPath: "/tmp/test-support",
            isDirectory: true
        )

        XCTAssertEqual(
            AppContainer.databaseURL(applicationSupport: support),
            support
                .appendingPathComponent("Codex Usage", isDirectory: true)
                .appendingPathComponent("usage.sqlite")
        )
    }

    func testRuntimeWithoutExecutableStillIndexesExplicitCodexHome() async throws {
        let support = try trackedTemporaryAppDirectory()
        let codexHome = try trackedValidCodexHome()
        let homeDirectory = try trackedTemporaryAppDirectory()
        try Data(
            (tokenJSONLine(input: 100, cached: 40, output: 20) + "\n").utf8
        ).write(
            to: codexHome
                .appendingPathComponent("sessions")
                .appendingPathComponent("local.jsonl")
        )
        let container = AppContainer(
            applicationSupport: support,
            homeDirectory: homeDirectory,
            environment: [:],
            executableURL: nil,
            calendar: utcCalendar()
        )
        let runtime = try await container.makeRuntime(codexHome: codexHome)
        let snapshot: UsageSnapshot
        do {
            snapshot = try await runtime.service.refresh(
                reason: .startup,
                now: try fixedDate("2026-09-01T08:00:00Z")
            )
        } catch {
            await runtime.stop()
            throw error
        }

        XCTAssertEqual(snapshot.today.localUsage.totalTokens, 120)
        XCTAssertEqual(snapshot.status, .stale)
        let resolvedCodexHome = await runtime.service.resolvedCodexHome()
        XCTAssertEqual(
            resolvedCodexHome,
            codexHome.standardizedFileURL
        )
        await runtime.stop()
    }

    func testRuntimeStopGateRunsCleanupOnlyOnce() async {
        let gate = RuntimeStopGate()
        let recorder = StopRecorder()

        await gate.run { await recorder.record() }
        await gate.run { await recorder.record() }

        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    private func trackedTemporaryAppDirectory() throws -> URL {
        let url = try temporaryAppDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func trackedValidCodexHome() throws -> URL {
        let root = try validCodexHome()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}

private actor StopRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
