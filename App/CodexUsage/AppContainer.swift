import Foundation
import UsageCore

enum AppRuntimeError: Error, Equatable, Sendable {
    case codexExecutableNotFound
}

struct AppContainer: UsageRuntimeBuilding {
    let applicationSupport: URL
    let homeDirectory: URL
    let environment: [String: String]
    let executableURL: URL?
    let calendar: Calendar

    static func live() -> AppContainer {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let executableURL = CodexExecutableResolver().resolve(
            environment: environment
        )
        return AppContainer(
            applicationSupport: fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!,
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            environment: environment,
            executableURL: executableURL,
            calendar: Calendar.autoupdatingCurrent
        )
    }

    static func databaseURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("Codex Usage", isDirectory: true)
            .appendingPathComponent("usage.sqlite")
    }

    func makeRuntime(codexHome: URL?) async throws -> UsageRuntime {
        let databaseURL = Self.databaseURL(
            applicationSupport: applicationSupport
        )
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = try SQLiteUsageStore(databaseURL: databaseURL)

        let transport: any AppServerTransport
        if let executableURL {
            transport = ProcessJSONLTransport(
                executableURL: executableURL,
                arguments: ["app-server"]
            )
        } else {
            transport = UnavailableAppServerTransport()
        }
        let client = CodexAppServerClient(transport: transport)
        let indexer = SessionUsageIndexer(store: store)
        var runtimeEnvironment = environment
        if let codexHome {
            runtimeEnvironment["CODEX_HOME"] = codexHome
                .standardizedFileURL.path
        }
        let service = UsageService(
            accountClient: client,
            indexer: indexer,
            store: store,
            environment: runtimeEnvironment,
            homeDirectory: homeDirectory,
            calendar: calendar
        )
        let watcher = SessionDirectoryWatcher()
        let stopGate = RuntimeStopGate()

        return UsageRuntime(
            service: service,
            watcher: watcher,
            stop: {
                await stopGate.run {
                    await watcher.stop()
                    await client.stop()
                    try? await store.close()
                }
            }
        )
    }
}

private actor UnavailableAppServerTransport: AppServerTransport {
    func start() async throws {
        throw AppRuntimeError.codexExecutableNotFound
    }

    func send(line: Data) async throws {
        throw AppRuntimeError.codexExecutableNotFound
    }

    func nextLine() async throws -> Data? {
        nil
    }

    func stop() async {}
}
