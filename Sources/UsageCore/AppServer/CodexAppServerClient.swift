import Foundation

public enum AppServerClientError: Error, Equatable, Sendable {
    case transportClosed
    case requestTimedOut
    case invalidResponse
}

private struct RPCOutgoingMessage: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int64?
    let method: String
    let params: JSONValue?
}

public actor CodexAppServerClient {
    private enum Lifecycle {
        case idle
        case starting
        case running
        case closed
        case stopped
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let transport: any AppServerTransport
    private let requestTimeout: Duration
    private let notificationStream: AsyncStream<AppServerNotification>
    private let notificationContinuation:
        AsyncStream<AppServerNotification>.Continuation

    private var nextRequestID: Int64 = 1
    private var pending: [Int64: PendingRequest] = [:]
    private var startTask: Task<Void, Error>?
    private var receiveTask: Task<Void, Never>?
    private var lifecycle = Lifecycle.idle

    public init(
        transport: any AppServerTransport,
        requestTimeout: Duration = .seconds(10)
    ) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        let pair = AsyncStream<AppServerNotification>.makeStream()
        notificationStream = pair.stream
        notificationContinuation = pair.continuation
    }

    public func initialize() async throws -> InitializeResult {
        let result: InitializeResult = try await request(
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("codex_usage_menubar"),
                    "title": .string("Codex Usage"),
                    "version": .string("0.1.0")
                ])
            ])
        )
        try await sendNotification(method: "initialized", params: .object([:]))
        return result
    }

    public func readRateLimits() async throws -> RateLimitsResponse {
        try await request(method: "account/rateLimits/read")
    }

    public func readAccountUsage() async throws -> AccountUsageResponse {
        try await request(method: "account/usage/read")
    }

    public func nextNotification() async -> AppServerNotification? {
        for await notification in notificationStream {
            return notification
        }
        return nil
    }

    public func stop() async {
        guard lifecycle != .stopped else { return }
        lifecycle = .stopped
        let receiveTaskToJoin = receiveTask
        receiveTask = nil
        receiveTaskToJoin?.cancel()
        failAllPending(with: AppServerClientError.transportClosed)
        notificationContinuation.finish()
        await transport.stop()
        await receiveTaskToJoin?.value
    }

    private func request<Response: Decodable & Sendable>(
        method: String,
        params: JSONValue? = nil
    ) async throws -> Response {
        try Task.checkCancellation()
        try await ensureStarted()
        try Task.checkCancellation()

        let id = nextRequestID
        nextRequestID += 1
        let outgoing = RPCOutgoingMessage(
            id: id,
            method: method,
            params: params
        )
        guard let line = try? encodeOutgoing(outgoing) else {
            throw AppServerClientError.invalidResponse
        }

        let result = try await waitForResponse(id: id, line: line)
        guard
            let resultData = try? JSONEncoder().encode(result),
            let response = try? JSONDecoder().decode(
                Response.self,
                from: resultData
            )
        else {
            throw AppServerClientError.invalidResponse
        }
        return response
    }

    private func waitForResponse(id: Int64, line: Data) async throws -> JSONValue {
        guard lifecycle == .running else {
            throw AppServerClientError.transportClosed
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<JSONValue, Error>) in
                let timeout = requestTimeout
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(id)
                }
                pending[id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self] in
                    await self?.sendRequestLine(line, id: id)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(id)
            }
        }
    }

    private func ensureStarted() async throws {
        switch lifecycle {
        case .closed, .stopped:
            throw AppServerClientError.transportClosed
        case .idle:
            lifecycle = .starting
            let transport = transport
            startTask = Task {
                try await transport.start()
            }
        case .starting, .running:
            break
        }
        guard let startTask else {
            throw AppServerClientError.transportClosed
        }
        do {
            try await startTask.value
        } catch {
            if lifecycle != .stopped {
                lifecycle = .closed
                notificationContinuation.finish()
            }
            throw error
        }
        guard lifecycle != .closed, lifecycle != .stopped else {
            throw AppServerClientError.transportClosed
        }
        if lifecycle == .starting {
            lifecycle = .running
            let transport = transport
            receiveTask = Task { [weak self] in
                do {
                    while let line = try await transport.nextLine() {
                        await self?.handle(line: line)
                    }
                } catch {
                    // 对外只暴露固定错误分类，不记录响应正文或底层错误内容。
                }
                await self?.transportDidClose()
            }
        }
    }

    private func sendNotification(
        method: String,
        params: JSONValue
    ) async throws {
        try await ensureStarted()
        let outgoing = RPCOutgoingMessage(
            id: nil,
            method: method,
            params: params
        )
        guard let line = try? encodeOutgoing(outgoing) else {
            throw AppServerClientError.invalidResponse
        }
        do {
            try await transport.send(line: line)
        } catch {
            throw AppServerClientError.transportClosed
        }
    }

    private func sendRequestLine(_ line: Data, id: Int64) async {
        guard lifecycle == .running, pending[id] != nil else { return }
        do {
            try await transport.send(line: line)
        } catch {
            failPending(id: id, with: AppServerClientError.transportClosed)
        }
    }

    private func handle(line: Data) {
        guard let message = try? JSONDecoder().decode(
            RPCIncomingMessage.self,
            from: line
        ) else {
            return
        }

        if let id = message.id {
            guard let request = pending.removeValue(forKey: id) else {
                return
            }
            request.timeoutTask.cancel()
            if let error = message.error {
                request.continuation.resume(throwing: error)
            } else if let result = message.result {
                request.continuation.resume(returning: result)
            } else {
                request.continuation.resume(
                    throwing: AppServerClientError.invalidResponse
                )
            }
            return
        }

        guard
            message.method == "account/rateLimits/updated",
            let params = message.params,
            let paramsData = try? JSONEncoder().encode(params),
            let update = try? JSONDecoder().decode(
                RateLimitsUpdatedParams.self,
                from: paramsData
            )
        else {
            return
        }
        notificationContinuation.yield(.rateLimitsUpdated(update))
    }

    private func timeoutRequest(_ id: Int64) {
        failPending(id: id, with: AppServerClientError.requestTimedOut)
    }

    private func cancelRequest(_ id: Int64) {
        failPending(id: id, with: CancellationError())
    }

    private func failPending(id: Int64, with error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func transportDidClose() {
        guard lifecycle != .closed, lifecycle != .stopped else { return }
        lifecycle = .closed
        receiveTask = nil
        failAllPending(with: AppServerClientError.transportClosed)
        notificationContinuation.finish()
    }

    private func failAllPending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func encodeOutgoing(_ message: RPCOutgoingMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(message)
    }
}
