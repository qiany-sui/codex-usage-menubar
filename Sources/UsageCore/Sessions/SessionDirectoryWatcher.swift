import CoreServices
import Foundation

public actor SessionDirectoryWatcher {
    private let coalescingDelay: Duration
    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<Void>.Continuation?
    private var trailingTask: Task<Void, Never>?
    private var hasPendingTrailingChange = false
    private var generation: UInt64 = 0
    private var stopped = false

    public init(coalescingDelay: Duration = .seconds(1)) {
        self.coalescingDelay = coalescingDelay
    }

    public func changes(for directories: [URL]) -> AsyncStream<Void> {
        guard !stopped else {
            return AsyncStream { $0.finish() }
        }
        stopResources()
        generation &+= 1
        let currentGeneration = generation
        let pair = AsyncStream<Void>.makeStream()
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.consumerTerminated(generation: currentGeneration)
            }
        }

        let paths = existingDirectoryPaths(directories)
        guard !paths.isEmpty else {
            return pair.stream
        }

        let callbackBox = WatcherCallbackBox { [weak self] in
            Task {
                await self?.recordChange()
            }
        }
        let callbackInfo = Unmanaged.passRetained(callbackBox).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: callbackInfo,
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<WatcherCallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, eventCount, _, _, _ in
                guard eventCount > 0, let info else { return }
                Unmanaged<WatcherCallbackBox>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                    .handleEvent()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.01,
            flags
        ) else {
            Unmanaged<WatcherCallbackBox>.fromOpaque(callbackInfo).release()
            pair.continuation.finish()
            continuation = nil
            return pair.stream
        }

        FSEventStreamSetDispatchQueue(
            created,
            DispatchQueue(label: "CodexUsage.SessionDirectoryWatcher")
        )
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            pair.continuation.finish()
            continuation = nil
            return pair.stream
        }
        stream = created
        return pair.stream
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        stopResources()
    }

    private func recordChange() {
        guard !stopped, stream != nil, continuation != nil else { return }
        if trailingTask == nil {
            continuation?.yield()
            hasPendingTrailingChange = false
            let delay = coalescingDelay
            trailingTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                await self?.finishCoalescingWindow()
            }
        } else {
            hasPendingTrailingChange = true
        }
    }

    private func finishCoalescingWindow() {
        trailingTask = nil
        guard !stopped, stream != nil else {
            hasPendingTrailingChange = false
            return
        }
        if hasPendingTrailingChange {
            hasPendingTrailingChange = false
            continuation?.yield()
        }
    }

    private func consumerTerminated(generation: UInt64) {
        guard generation == self.generation else { return }
        stop()
    }

    private func stopResources() {
        trailingTask?.cancel()
        trailingTask = nil
        hasPendingTrailingChange = false
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        let activeContinuation = continuation
        continuation = nil
        activeContinuation?.finish()
    }

    private func existingDirectoryPaths(_ directories: [URL]) -> [String] {
        var seen: Set<String> = []
        return directories.compactMap { directory in
            let standardized = directory.standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard standardized.isFileURL,
                  FileManager.default.fileExists(
                      atPath: standardized.path,
                      isDirectory: &isDirectory
                  ),
                  isDirectory.boolValue,
                  seen.insert(standardized.path).inserted else {
                return nil
            }
            return standardized.path
        }
    }
}

private final class WatcherCallbackBox: @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func handleEvent() {
        handler()
    }
}
