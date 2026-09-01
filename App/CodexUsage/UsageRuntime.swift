import Foundation
import UsageCore

protocol UsageServicing: Actor {
    func refresh(
        reason: RefreshReason,
        now: Date
    ) async throws -> UsageSnapshot
    func processNextAccountNotification(
        now: Date
    ) async throws -> UsageSnapshot?
    func currentSnapshot(now: Date) async throws -> UsageSnapshot
    func resolvedCodexHome() async -> URL?
}

extension UsageService: UsageServicing {}

protocol SessionChangeWatching: Actor {
    func changes(for directories: [URL]) async -> AsyncStream<Void>
    func stop() async
}

extension SessionDirectoryWatcher: SessionChangeWatching {}

struct UsageRuntime: Sendable {
    let service: any UsageServicing
    let watcher: any SessionChangeWatching
    private let stopAction: @Sendable () async -> Void

    init(
        service: any UsageServicing,
        watcher: any SessionChangeWatching,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.service = service
        self.watcher = watcher
        stopAction = stop
    }

    func stop() async {
        await stopAction()
    }
}

protocol UsageRuntimeBuilding: Sendable {
    func makeRuntime(codexHome: URL?) async throws -> UsageRuntime
}

actor RuntimeStopGate {
    private var didStop = false

    func run(_ cleanup: @Sendable () async -> Void) async {
        guard !didStop else {
            return
        }
        didStop = true
        await cleanup()
    }
}
