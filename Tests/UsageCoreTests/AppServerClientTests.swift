import Darwin
import XCTest
@testable import UsageCore

actor ScriptedTransport: AppServerTransport {
    private var lines: [Data?]
    private let closeWhenExhausted: Bool
    private var lineWaiters: [CheckedContinuation<Data?, Never>] = []

    init(lines: [Data?], closeWhenExhausted: Bool = true) {
        self.lines = lines
        self.closeWhenExhausted = closeWhenExhausted
    }

    func start() async throws {}
    func send(line: Data) async throws {}

    func nextLine() async throws -> Data? {
        guard !lines.isEmpty else {
            if closeWhenExhausted {
                return nil
            }
            return await withCheckedContinuation {
                lineWaiters.append($0)
            }
        }
        return lines.removeFirst()
    }

    func stop() async {
        lines.removeAll()
        let waiters = lineWaiters
        lineWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }
}

actor StallingTransport: AppServerTransport {
    func start() async throws {}
    func send(line: Data) async throws {}

    func nextLine() async throws -> Data? {
        try await Task.sleep(for: .seconds(60))
        return nil
    }

    func stop() async {}
}

actor ControlledStartTransport: AppServerTransport {
    private var didEnterStart = false
    private var didReleaseStart = false
    private var didCloseLines = false
    private var startObservers: [CheckedContinuation<Void, Never>] = []
    private var startRelease: CheckedContinuation<Void, Never>?
    private var lineWaiters: [CheckedContinuation<Data?, Never>] = []

    func start() async throws {
        didEnterStart = true
        let observers = startObservers
        startObservers.removeAll()
        for observer in observers {
            observer.resume()
        }
        guard !didReleaseStart else { return }
        await withCheckedContinuation {
            startRelease = $0
        }
    }

    func send(line: Data) async throws {}

    func nextLine() async throws -> Data? {
        guard !didCloseLines else { return nil }
        return await withCheckedContinuation {
            lineWaiters.append($0)
        }
    }

    func stop() async {}

    func waitUntilStartEntered() async {
        guard !didEnterStart else { return }
        await withCheckedContinuation {
            startObservers.append($0)
        }
    }

    func releaseStart() {
        didReleaseStart = true
        startRelease?.resume()
        startRelease = nil
    }

    func closeLines() {
        didCloseLines = true
        let waiters = lineWaiters
        lineWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }
}

actor OutOfOrderTransport: AppServerTransport {
    private struct Request {
        let id: Int64
        let method: String
    }

    private var requests: [Request] = []
    private var lines: [Data] = []
    private var lineWaiters: [CheckedContinuation<Data?, Never>] = []
    private var didStop = false

    func start() async throws {}

    func send(line: Data) async throws {
        guard
            let object = try? JSONSerialization.jsonObject(with: line)
                as? [String: Any],
            let id = (object["id"] as? NSNumber)?.int64Value,
            let method = object["method"] as? String
        else {
            return
        }
        requests.append(Request(id: id, method: method))
        guard requests.count == 2 else { return }

        enqueue(
            Data(#"{"id":999,"result":{"ignored":true}}"#.utf8)
        )
        for request in requests.reversed() {
            enqueue(try response(for: request))
        }
    }

    func nextLine() async throws -> Data? {
        if !lines.isEmpty {
            return lines.removeFirst()
        }
        guard !didStop else { return nil }
        return await withCheckedContinuation {
            lineWaiters.append($0)
        }
    }

    func stop() async {
        didStop = true
        let waiters = lineWaiters
        lineWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func enqueue(_ line: Data) {
        if lineWaiters.isEmpty {
            lines.append(line)
        } else {
            lineWaiters.removeFirst().resume(returning: line)
        }
    }

    private func response(for request: Request) throws -> Data {
        let result: [String: Any]
        switch request.method {
        case "account/rateLimits/read":
            result = [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": ["usedPercent": 25],
                    "secondary": NSNull()
                ],
                "rateLimitsByLimitId": NSNull()
            ]
        case "account/usage/read":
            result = [
                "summary": ["lifetimeTokens": 42],
                "dailyUsageBuckets": []
            ]
        default:
            result = [:]
        }
        return try JSONSerialization.data(
            withJSONObject: ["id": request.id, "result": result]
        )
    }
}

final class AppServerClientTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testExecutableResolverUsesPATHThenChatGPTBundleFallback() throws {
        let root = try temporaryDirectory()
        temporaryDirectories.append(root)
        let pathDirectory = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(
            at: pathDirectory,
            withIntermediateDirectories: true
        )
        let pathCodex = pathDirectory.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: pathCodex)
        XCTAssertEqual(
            chmod(pathCodex.path, S_IRUSR | S_IWUSR | S_IXUSR),
            0
        )
        let fallback = root.appendingPathComponent("ChatGPT-codex")
        try Data("#!/bin/sh\n".utf8).write(to: fallback)
        XCTAssertEqual(
            chmod(fallback.path, S_IRUSR | S_IWUSR | S_IXUSR),
            0
        )

        XCTAssertEqual(
            CodexExecutableResolver().resolve(
                environment: ["PATH": pathDirectory.path],
                standardLocations: [fallback]
            ),
            pathCodex
        )
        XCTAssertEqual(
            CodexExecutableResolver().resolve(
                environment: ["PATH": ""],
                standardLocations: [fallback]
            ),
            fallback
        )
    }

    func testExecutableResolverSkipsDirectoriesAndNonExecutableFiles() throws {
        let root = try temporaryDirectory()
        temporaryDirectories.append(root)
        let pathDirectory = root.appendingPathComponent("bin")
        let directoryCandidate = pathDirectory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(
            at: directoryCandidate,
            withIntermediateDirectories: true
        )
        let nonExecutable = root.appendingPathComponent("non-executable-codex")
        try Data("#!/bin/sh\n".utf8).write(to: nonExecutable)
        let fallback = root.appendingPathComponent("fallback-codex")
        try Data("#!/bin/sh\n".utf8).write(to: fallback)
        XCTAssertEqual(
            chmod(fallback.path, S_IRUSR | S_IWUSR | S_IXUSR),
            0
        )

        let resolved = CodexExecutableResolver().resolve(
            environment: ["PATH": pathDirectory.path],
            standardLocations: [nonExecutable, fallback]
        )

        XCTAssertEqual(resolved, fallback)
    }

    func testLineFramerReturnsCompleteLinesAndDiscardsTrailingPartialLine() {
        var framer = JSONLLineFramer()

        XCTAssertEqual(
            framer.append(Data(#"{"id":1}"#.utf8)),
            []
        )
        XCTAssertEqual(
            framer.append(Data("\n{\"id\":2}\npartial".utf8)),
            [Data(#"{"id":1}"#.utf8), Data(#"{"id":2}"#.utf8)]
        )
        framer.finish()
        XCTAssertEqual(framer.append(Data("next\n".utf8)), [Data("next".utf8)])
    }

    func testProcessDeliversFinalLineBeforeZeroExit() async throws {
        let transport = try processTransport(mode: "response-exit")

        try await transport.start()
        let line = try await transport.nextLine()
        let eof = try await transport.nextLine()
        await transport.stop()

        XCTAssertEqual(line, Data("response".utf8))
        XCTAssertNil(eof)
    }

    func testProcessFinishesAtStdoutEOFBeforeProcessExit() async throws {
        let transport = try processTransport(mode: "stdout-eof")
        let clock = ContinuousClock()

        try await transport.start()
        let startedAt = clock.now
        let eof = try await transport.nextLine()
        let elapsed = startedAt.duration(to: clock.now)
        await transport.stop()

        XCTAssertNil(eof)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testProcessDeliversFinalLineThenReportsNonzeroExit() async throws {
        let transport = try processTransport(mode: "nonzero-exit")

        try await transport.start()
        let line = try await transport.nextLine()

        XCTAssertEqual(line, Data("response".utf8))
        await XCTAssertThrowsErrorAsync(
            try await transport.nextLine()
        ) { error in
            XCTAssertEqual(
                error as? ProcessJSONLTransportError,
                .processExited(7)
            )
        }
        await transport.stop()
    }

    func testProcessStartsOnlyOnceAndStopIsIdempotent() async throws {
        let root = try temporaryDirectory()
        temporaryDirectories.append(root)
        let marker = root.appendingPathComponent("starts")
        let transport = try processTransport(
            mode: "start-marker",
            arguments: [marker.path]
        )

        try await transport.start()
        try await transport.start()
        let line = try await transport.nextLine()
        let starts = try Data(contentsOf: marker)
        await transport.stop()
        await transport.stop()

        XCTAssertEqual(line, Data("started".utf8))
        XCTAssertEqual(starts, Data("x".utf8))
    }

    func testProcessSendAppendsExactlyOneNewline() async throws {
        let transport = try processTransport(mode: "exact-newline")

        try await transport.start()
        try await transport.send(line: Data("payload\n\n".utf8))
        let line = try await transport.nextLine()
        await transport.stop()

        XCTAssertEqual(line, Data("single:payload".utf8))
    }

    func testClientCompletesHandshakeAndReadsUsageThroughJSONLProcess() async throws {
        let executable = try XCTUnwrap(
            Bundle.module.url(
                forResource: "fake-app-server",
                withExtension: "sh",
                subdirectory: "Fixtures"
            )
        )
        let transport = ProcessJSONLTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [executable.path]
        )
        let client = CodexAppServerClient(
            transport: transport,
            requestTimeout: .seconds(2)
        )

        let initialized = try await client.initialize()
        let limits = try await client.readRateLimits()
        let notification = await client.nextNotification()
        let usage = try await client.readAccountUsage()
        await client.stop()

        XCTAssertEqual(initialized.codexHome, "/tmp/codex-home")
        XCTAssertEqual(limits.rateLimits.primary?.usedPercent, 25)
        guard case let .rateLimitsUpdated(update) = notification else {
            return XCTFail("expected rate-limit update")
        }
        guard
            case let .value(windowPatch?) = update.rateLimits.primary,
            case let .value(usedPercent?) = windowPatch.usedPercent
        else {
            return XCTFail("expected sparse primary usedPercent")
        }
        XCTAssertEqual(usedPercent, 31)
        XCTAssertEqual(usage.dailyUsageBuckets?.first?.tokens, 400)
    }

    func testRPCErrorPreservesCodeAndMessage() async throws {
        let line = Data(
            #"{"id":1,"error":{"code":-32600,"message":"authentication required"}}"#.utf8
        )
        let client = CodexAppServerClient(
            transport: ScriptedTransport(lines: [line]),
            requestTimeout: .seconds(1)
        )

        do {
            _ = try await client.initialize()
            XCTFail("expected RPC error")
        } catch let error as RPCErrorPayload {
            XCTAssertEqual(error.code, -32600)
            XCTAssertEqual(error.message, "authentication required")
        }
    }

    func testMalformedLineDoesNotPreventLaterResponse() async throws {
        let malformed = Data("not-json".utf8)
        let malformedNotification = Data(
            #"{"method":"account/rateLimits/updated","params":{"unexpected":true}}"#.utf8
        )
        let response = Data(
            #"{"id":1,"result":{"codexHome":null,"platformFamily":"unix","platformOs":"macos","userAgent":"test"}}"#.utf8
        )
        let client = CodexAppServerClient(
            transport: ScriptedTransport(
                lines: [malformed, malformedNotification, response],
                closeWhenExhausted: false
            ),
            requestTimeout: .seconds(1)
        )

        let result = try await client.initialize()
        await client.stop()

        XCTAssertEqual(result.platformOs, "macos")
    }

    func testEOFClosesPendingRequest() async throws {
        let client = CodexAppServerClient(
            transport: ScriptedTransport(lines: [nil]),
            requestTimeout: .seconds(1)
        )

        await XCTAssertThrowsErrorAsync(
            try await client.initialize()
        ) { error in
            XCTAssertEqual(
                error as? AppServerClientError,
                .transportClosed
            )
        }
    }

    func testRequestAfterEOFImmediatelyReturnsTransportClosed() async {
        let client = CodexAppServerClient(
            transport: ScriptedTransport(lines: [nil]),
            requestTimeout: .milliseconds(50)
        )

        await XCTAssertThrowsErrorAsync(
            try await client.initialize()
        ) { error in
            XCTAssertEqual(error as? AppServerClientError, .transportClosed)
        }
        await XCTAssertThrowsErrorAsync(
            try await client.readRateLimits()
        ) { error in
            XCTAssertEqual(error as? AppServerClientError, .transportClosed)
        }
    }

    func testStopDuringStartPreventsReceiveLoopAndPendingRequest() async {
        let transport = ControlledStartTransport()
        let client = CodexAppServerClient(
            transport: transport,
            requestTimeout: .milliseconds(50)
        )
        let request = Task {
            try await client.initialize()
        }

        await transport.waitUntilStartEntered()
        await client.stop()
        await transport.releaseStart()

        await XCTAssertThrowsErrorAsync(
            try await request.value
        ) { error in
            XCTAssertEqual(error as? AppServerClientError, .transportClosed)
        }
        await transport.closeLines()
    }

    func testMultiplePendingRequestsIgnoreUnknownIDAndRouteOutOfOrderResponses() async throws {
        let client = CodexAppServerClient(
            transport: OutOfOrderTransport(),
            requestTimeout: .seconds(1)
        )

        async let limits = client.readRateLimits()
        async let usage = client.readAccountUsage()
        let (resolvedLimits, resolvedUsage) = try await (limits, usage)
        await client.stop()

        XCTAssertEqual(
            resolvedLimits.rateLimits.primary?.usedPercent,
            25
        )
        XCTAssertEqual(resolvedUsage.summary.lifetimeTokens, 42)
    }

    func testRequestTimeoutRemovesPendingContinuation() async throws {
        let client = CodexAppServerClient(
            transport: StallingTransport(),
            requestTimeout: .milliseconds(50)
        )

        await XCTAssertThrowsErrorAsync(
            try await client.initialize()
        ) { error in
            XCTAssertEqual(
                error as? AppServerClientError,
                .requestTimedOut
            )
        }
        await client.stop()
    }

    func testCancellationClosesPendingRequest() async {
        let client = CodexAppServerClient(
            transport: StallingTransport(),
            requestTimeout: .seconds(10)
        )
        let request = Task {
            try await client.initialize()
        }

        try? await Task.sleep(for: .milliseconds(10))
        request.cancel()

        await XCTAssertThrowsErrorAsync(
            try await request.value
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        await client.stop()
    }


    private func processTransport(
        mode: String,
        arguments: [String] = []
    ) throws -> ProcessJSONLTransport {
        let fixture = try XCTUnwrap(
            Bundle.module.url(
                forResource: "process-transport-fixture",
                withExtension: "sh",
                subdirectory: "Fixtures"
            )
        )
        return ProcessJSONLTransport(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [fixture.path, mode] + arguments
        )
    }
}
