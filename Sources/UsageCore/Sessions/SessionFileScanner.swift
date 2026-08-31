import Darwin
import Foundation

public enum SessionFileScannerError: Error, Equatable, Sendable {
    case invalidModifiedSince
    case unreadablePath(Int32)
}

public struct SessionFileScanner: Sendable {
    public init() {}

    public func files(
        in codexHome: URL,
        modifiedSince: Date
    ) throws -> [URL] {
        guard modifiedSince.timeIntervalSince1970.isFinite else {
            throw SessionFileScannerError.invalidModifiedSince
        }

        var files: [URL] = []
        for name in ["sessions", "archived_sessions"] {
            let root = codexHome
                .appendingPathComponent(name, isDirectory: true)
                .standardizedFileURL
            guard let rootMetadata = try metadata(at: root),
                  fileType(rootMetadata) == mode_t(S_IFDIR) else {
                continue
            }
            var pendingDirectories = [root]
            while let directory = pendingDirectories.popLast() {
                let children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                for child in children {
                    let standardized = child.standardizedFileURL
                    guard let metadata = try metadata(at: standardized) else {
                        continue
                    }
                    let type = fileType(metadata)
                    if type == mode_t(S_IFDIR) {
                        pendingDirectories.append(standardized)
                    } else if type == mode_t(S_IFREG),
                              standardized.pathExtension == "jsonl",
                              modificationDate(metadata).timeIntervalSince1970
                                >= modifiedSince.timeIntervalSince1970 {
                        files.append(standardized)
                    }
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func metadata(at url: URL) throws -> stat? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return Darwin.lstat(path, &value)
        }
        guard result == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                return nil
            }
            throw SessionFileScannerError.unreadablePath(code)
        }
        return value
    }

    private func fileType(_ metadata: stat) -> mode_t {
        metadata.st_mode & mode_t(S_IFMT)
    }

    private func modificationDate(_ metadata: stat) -> Date {
        Date(
            timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)
                + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }
}
