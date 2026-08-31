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

    public init(store: any UsageStore) {
        self.store = store
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

        let canResume = existingCursor?.deviceID == opened.deviceID
            && existingCursor?.inode == opened.inode
            && (existingCursor?.committedOffset ?? -1) >= 0
            && (existingCursor?.committedOffset ?? -1) <= opened.size
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
        let unread = try opened.handle.readToEnd() ?? Data()
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
            guard let record = try parser.parse(line: Data(line)),
                  let event = try accumulator.ingest(record) else {
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
            events.append(
                StoredUsageEvent(
                    signature: event.signature,
                    occurredAt: event.occurredAt,
                    localDay: LocalDay(year: year, month: month, day: day),
                    usage: event.usage
                )
            )
        }
        let cursor = FileCursor(
            pathHash: pathHash,
            deviceID: opened.deviceID,
            inode: opened.inode,
            committedOffset: committedOffset,
            counterState: accumulator.state
        )
        return try await store.ingest(events: events, cursor: cursor)
    }

    private func openRegularFile(at url: URL) throws -> OpenedFile {
        let before = try metadata(at: url)
        guard fileType(before) == mode_t(S_IFREG) else {
            throw SessionUsageIndexerError.invalidFileMetadata
        }
        let handle = try FileHandle(forReadingFrom: url)
        do {
            var openedMetadata = stat()
            guard Darwin.fstat(handle.fileDescriptor, &openedMetadata) == 0,
                  fileType(openedMetadata) == mode_t(S_IFREG),
                  before.st_dev == openedMetadata.st_dev,
                  before.st_ino == openedMetadata.st_ino,
                  let deviceID = Int64(exactly: openedMetadata.st_dev),
                  let inode = Int64(exactly: openedMetadata.st_ino),
                  let size = Int64(exactly: openedMetadata.st_size),
                  size >= 0 else {
                throw SessionUsageIndexerError.fileChangedDuringOpen
            }
            return OpenedFile(
                handle: handle,
                deviceID: deviceID,
                inode: inode,
                size: size
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
}

private struct OpenedFile {
    let handle: FileHandle
    let deviceID: Int64
    let inode: Int64
    let size: Int64
}
