import Darwin
import XCTest
@testable import UsageCore

actor ScriptedTransport: AppServerTransport {
    private var lines: [Data?]

    init(lines: [Data?]) {
        self.lines = lines
    }

    func start() async throws {}
    func send(line: Data) async throws {}

    func nextLine() async throws -> Data? {
        guard !lines.isEmpty else {
            return nil
        }
        return lines.removeFirst()
    }

    func stop() async {
        lines.removeAll()
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
                lines: [malformed, malformedNotification, response]
            ),
            requestTimeout: .seconds(1)
        )

        let result = try await client.initialize()

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
}
