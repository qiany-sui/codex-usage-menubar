import Foundation

public enum ProcessJSONLTransportError: Error, Equatable, Sendable {
    case notStarted
    case processExited(Int32)
    case writeFailed
}

private final class JSONLStreamBridge: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var framer = JSONLLineFramer()
    private var isFinished = false

    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func append(_ data: Data) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        for line in framer.append(data) {
            continuation.yield(line)
        }
        lock.unlock()
    }

    func discardPartialLine() {
        lock.lock()
        framer.finish()
        lock.unlock()
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        framer.finish()
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        lock.unlock()
    }
}

private actor TransportLineMailbox {
    private enum State {
        case open
        case finished(Error?)
    }

    private var state = State.open
    private var lines: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Error>] = []

    func enqueue(_ line: Data) {
        guard case .open = state else { return }
        if waiters.isEmpty {
            lines.append(line)
        } else {
            waiters.removeFirst().resume(returning: line)
        }
    }

    func finish(throwing error: Error? = nil) {
        guard case .open = state else { return }
        state = .finished(error)
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: nil)
            }
        }
    }

    func next() async throws -> Data? {
        if !lines.isEmpty {
            return lines.removeFirst()
        }
        switch state {
        case .open:
            return try await withCheckedThrowingContinuation {
                waiters.append($0)
            }
        case let .finished(error):
            if let error {
                throw error
            }
            return nil
        }
    }
}

public actor ProcessJSONLTransport: AppServerTransport {
    private let executableURL: URL
    private let arguments: [String]
    private let bridge = JSONLStreamBridge()
    private let mailbox = TransportLineMailbox()

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var consumerTask: Task<Void, Never>?
    private var didStart = false
    private var didStop = false

    public init(executableURL: URL, arguments: [String] = []) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public func start() async throws {
        guard !didStart else { return }
        didStart = true

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let bridge = bridge
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                bridge.discardPartialLine()
            } else {
                bridge.append(data)
            }
        }
        process.terminationHandler = { process in
            if process.terminationStatus == 0 {
                bridge.finish()
            } else {
                bridge.finish(
                    throwing: ProcessJSONLTransportError.processExited(
                        process.terminationStatus
                    )
                )
            }
        }

        let stream = bridge.stream
        let mailbox = mailbox
        consumerTask = Task {
            do {
                for try await line in stream {
                    await mailbox.enqueue(line)
                }
                await mailbox.finish()
            } catch {
                await mailbox.finish(throwing: error)
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            bridge.finish(throwing: error)
            throw error
        }
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
    }

    public func send(line: Data) async throws {
        guard let inputPipe else {
            throw ProcessJSONLTransportError.notStarted
        }
        var framedLine = line
        while framedLine.last == 0x0A || framedLine.last == 0x0D {
            framedLine.removeLast()
        }
        framedLine.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: framedLine)
        } catch {
            throw ProcessJSONLTransportError.writeFailed
        }
    }

    public func nextLine() async throws -> Data? {
        guard didStart else {
            throw ProcessJSONLTransportError.notStarted
        }
        return try await mailbox.next()
    }

    public func stop() async {
        guard !didStop else { return }
        didStop = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        bridge.finish()
        consumerTask?.cancel()
        await mailbox.finish()
    }
}
