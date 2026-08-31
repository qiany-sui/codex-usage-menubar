import CryptoKit
import Darwin
import Foundation

public struct SessionIndexResult: Equatable, Sendable {
    public let scannedFileCount: Int
    public let insertedEventCount: Int

    public init(scannedFileCount: Int, insertedEventCount: Int) {
        self.scannedFileCount = scannedFileCount
        self.insertedEventCount = insertedEventCount
    }
}

public enum SessionUsageIndexerError: Error, Equatable, Sendable {
    case invalidFileMetadata
    case fileChangedDuringOpen
    case offsetOverflow
    case invalidLocalDay
}

public actor SessionUsageIndexer {
    private let store: any UsageStore
    private let parser = SessionLineParser()
    private let scanner = SessionFileScanner()
    private let beforeSnapshotRead: (@Sendable (URL) throws -> Void)?
    private var filesRequiringFullRescan: Set<Data> = []

    public init(store: any UsageStore) {
        self.store = store
        beforeSnapshotRead = nil
    }

    init(
        store: any UsageStore,
        beforeSnapshotRead: @escaping @Sendable (URL) throws -> Void
    ) {
        self.store = store
        self.beforeSnapshotRead = beforeSnapshotRead
    }

    public func index(
        codexHome: URL,
        modifiedSince: Date,
        calendar: Calendar
    ) async throws -> SessionIndexResult {
        let files = try scanner.files(
            in: codexHome,
            modifiedSince: modifiedSince
        )
        var insertedEventCount = 0
        for file in files {
            insertedEventCount += try await index(file: file, calendar: calendar)
        }
        return SessionIndexResult(
            scannedFileCount: files.count,
            insertedEventCount: insertedEventCount
        )
    }

    private func index(file: URL, calendar: Calendar) async throws -> Int {
        let standardized = file.standardizedFileURL
        let pathHash = Data(
            SHA256.hash(data: Data(standardized.path.utf8))
        )
        let existingCursor = try await store.cursor(for: pathHash)
        let opened = try openRegularFile(at: standardized)
        defer {
            try? opened.handle.close()
        }

        let forceFullRescan = filesRequiringFullRescan.contains(pathHash)
        let canResume = !forceFullRescan
            && existingCursor?.deviceID == opened.snapshot.deviceID
            && existingCursor?.inode == opened.snapshot.inode
            && (existingCursor?.committedOffset ?? -1) >= 0
            && (existingCursor?.committedOffset ?? -1) <= opened.snapshot.size
        let startingOffset = canResume
            ? existingCursor?.committedOffset ?? 0
            : 0
        let initialState = canResume
            ? existingCursor?.counterState ?? SessionCounterState(previousTotal: nil)
            : SessionCounterState(previousTotal: nil)

        guard let seekOffset = UInt64(exactly: startingOffset) else {
            throw SessionUsageIndexerError.offsetOverflow
        }
        try opened.handle.seek(toOffset: seekOffset)
        try beforeSnapshotRead?(standardized)
        let readCount64 = opened.snapshot.size - startingOffset
        guard let readCount = Int(exactly: readCount64) else {
            throw SessionUsageIndexerError.offsetOverflow
        }
        let unread = try read(
            from: opened.handle,
            count: readCount
        )
        guard unread.count == readCount,
              try snapshot(of: opened.handle) == opened.snapshot else {
            filesRequiringFullRescan.insert(pathHash)
            return 0
        }
        let completeByteCount: Int
        if let newline = unread.lastIndex(of: 0x0A) {
            completeByteCount = unread.distance(
                from: unread.startIndex,
                to: unread.index(after: newline)
            )
        } else {
            completeByteCount = 0
        }
        guard let completeByteCount64 = Int64(exactly: completeByteCount) else {
            throw SessionUsageIndexerError.offsetOverflow
        }
        let (committedOffset, overflow) = startingOffset
            .addingReportingOverflow(completeByteCount64)
        guard !overflow else {
            throw SessionUsageIndexerError.offsetOverflow
        }

        var accumulator = SessionUsageAccumulator(state: initialState)
        var events: [StoredUsageEvent] = []
        let completeData = unread.prefix(completeByteCount)
        for line in completeData.split(
            separator: 0x0A,
            omittingEmptySubsequences: true
        ) {
            do {
                guard let record = try parser.parse(line: Data(line)) else {
                    continue
                }
                var candidateAccumulator = accumulator
                guard let event = try candidateAccumulator.ingest(record) else {
                    accumulator = candidateAccumulator
                    continue
                }
                let components = calendar.dateComponents(
                    [.year, .month, .day],
                    from: event.occurredAt
                )
                guard let year = components.year,
                      let month = components.month,
                      let day = components.day else {
                    throw SessionUsageIndexerError.invalidLocalDay
                }
                accumulator = candidateAccumulator
                events.append(
                    StoredUsageEvent(
                        signature: event.signature,
                        occurredAt: event.occurredAt,
                        localDay: LocalDay(year: year, month: month, day: day),
                        usage: event.usage
                    )
                )
            } catch is SessionParseError {
                continue
            } catch is SessionUsageAccumulatorError {
                continue
            }
        }
        let cursor = FileCursor(
            pathHash: pathHash,
            deviceID: opened.snapshot.deviceID,
            inode: opened.snapshot.inode,
            committedOffset: committedOffset,
            counterState: accumulator.state
        )
        guard try snapshot(of: opened.handle) == opened.snapshot else {
            filesRequiringFullRescan.insert(pathHash)
            return 0
        }
        let inserted = try await store.ingest(events: events, cursor: cursor)
        filesRequiringFullRescan.remove(pathHash)
        return inserted
    }

    private func openRegularFile(at url: URL) throws -> OpenedFile {
        let before = try metadata(at: url)
        guard fileType(before) == mode_t(S_IFREG) else {
            throw SessionUsageIndexerError.invalidFileMetadata
        }
        let handle = try FileHandle(forReadingFrom: url)
        do {
            let snapshot = try snapshot(of: handle)
            guard let beforeDeviceID = Int64(exactly: before.st_dev),
                  let beforeInode = Int64(exactly: before.st_ino),
                  beforeDeviceID == snapshot.deviceID,
                  beforeInode == snapshot.inode else {
                throw SessionUsageIndexerError.fileChangedDuringOpen
            }
            return OpenedFile(
                handle: handle,
                snapshot: snapshot
            )
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func metadata(at url: URL) throws -> stat {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return Darwin.lstat(path, &value)
        }
        guard result == 0 else {
            throw SessionUsageIndexerError.invalidFileMetadata
        }
        return value
    }

    private func fileType(_ metadata: stat) -> mode_t {
        metadata.st_mode & mode_t(S_IFMT)
    }

    private func snapshot(of handle: FileHandle) throws -> FileSnapshot {
        var metadata = stat()
        guard Darwin.fstat(handle.fileDescriptor, &metadata) == 0,
              fileType(metadata) == mode_t(S_IFREG),
              let deviceID = Int64(exactly: metadata.st_dev),
              let inode = Int64(exactly: metadata.st_ino),
              let size = Int64(exactly: metadata.st_size),
              let modificationSeconds = Int64(exactly: metadata.st_mtimespec.tv_sec),
              let modificationNanoseconds = Int64(exactly: metadata.st_mtimespec.tv_nsec),
              let changeSeconds = Int64(exactly: metadata.st_ctimespec.tv_sec),
              let changeNanoseconds = Int64(exactly: metadata.st_ctimespec.tv_nsec),
              size >= 0 else {
            throw SessionUsageIndexerError.invalidFileMetadata
        }
        return FileSnapshot(
            deviceID: deviceID,
            inode: inode,
            size: size,
            modificationSeconds: modificationSeconds,
            modificationNanoseconds: modificationNanoseconds,
            changeSeconds: changeSeconds,
            changeNanoseconds: changeNanoseconds
        )
    }

    private func read(from handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let remaining = count - data.count
            guard let chunk = try handle.read(upToCount: remaining),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data
    }
}

private struct OpenedFile {
    let handle: FileHandle
    let snapshot: FileSnapshot
}

private struct FileSnapshot: Equatable {
    let deviceID: Int64
    let inode: Int64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}
