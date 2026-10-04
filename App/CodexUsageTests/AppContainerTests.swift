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

    func testExplicitHomeRemainsSelectedAfterChildInitialization() async throws {
        let support = try trackedTemporaryAppDirectory()
        let selectedHome = try trackedValidCodexHome()
        let inheritedHome = try trackedValidCodexHome()
        for (home, input) in [(selectedHome, Int64(100)), (inheritedHome, Int64(900))] {
            try Data((tokenJSONLine(input: input, cached: 0, output: 20) + "\n").utf8)
                .write(to: home.appendingPathComponent("sessions/local.jsonl"))
        }
        let executable = support.appendingPathComponent("fake-codex")
        // 子进程按实际收到的 CODEX_HOME 回报 initialize，默认目录也只指向测试 fixture。
        let script = """
        #!/bin/sh
        fixture_home="${CODEX_HOME:-\(inheritedHome.path)}"
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              printf '{"id":1,"result":{"codexHome":"%s","platformFamily":"unix","platformOs":"macos","userAgent":"fixture"}}\\n' "$fixture_home"
              ;;
            *'"method":"account/rateLimits/read"'*)
              printf '%s\\n' '{"id":2,"result":{"rateLimits":{"limitId":"weekly","primary":null,"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1788336000}}}}'
              ;;
            *'"method":"account/usage/read"'*)
              printf '%s\\n' '{"id":3,"result":{"dailyUsageBuckets":[],"summary":{"lifetimeTokens":0}}}'
              ;;
          esac
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let container = AppContainer(
            applicationSupport: support,
            homeDirectory: support,
            environment: ["CODEX_HOME": inheritedHome.path],
            executableURL: executable,
            calendar: utcCalendar()
        )
        let runtime = try await container.makeRuntime(codexHome: selectedHome)
        do {
            let snapshot = try await runtime.service.refresh(
                reason: .startup,
                now: try fixedDate("2026-09-01T08:00:00Z")
            )
            let resolved = await runtime.service.resolvedCodexHome()
            XCTAssertEqual(resolved, selectedHome.standardizedFileURL)
            XCTAssertEqual(snapshot.today.localUsage.totalTokens, 120)
        } catch {
            await runtime.stop()
            throw error
        }
        await runtime.stop()
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
