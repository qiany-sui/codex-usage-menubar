import Foundation

enum CodexHomeBookmarkError: Error, Equatable {
    case invalidCodexHome
    case bookmarkCreationFailed
    case bookmarkResolutionFailed
}

enum CodexHomeBookmarkRestoreResult: Equatable {
    case available(URL)
    case needsSelection
}

@MainActor
protocol CodexHomeBookmarkStoring: AnyObject {
    func restore() throws -> CodexHomeBookmarkRestoreResult
    func save(_ url: URL) throws
    func clear()
    func releaseAccess()
}

@MainActor
final class CodexHomeBookmarkStore: CodexHomeBookmarkStoring {
    private let defaults: UserDefaults
    private let key: String
    private let encode: (URL) throws -> Data
    private let resolve: (Data) throws -> (url: URL, isStale: Bool)
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void

    private var activeURL: URL?

    static func isValidCodexHome(_ url: URL) -> Bool {
        let supportedRoots = ["sessions", "archived_sessions"]
        return supportedRoots.contains { directoryName in
            let candidate = url.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
    }

    init(
        defaults: UserDefaults = .standard,
        key: String = "codexHomeBookmark"
    ) {
        self.defaults = defaults
        self.key = key
        encode = { url in
            do {
                return try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                throw CodexHomeBookmarkError.bookmarkCreationFailed
            }
        }
        resolve = { data in
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return (url, isStale)
            } catch {
                throw CodexHomeBookmarkError.bookmarkResolutionFailed
            }
        }
        startAccess = { $0.startAccessingSecurityScopedResource() }
        stopAccess = { $0.stopAccessingSecurityScopedResource() }
    }

    init(
        defaults: UserDefaults,
        key: String,
        encode: @escaping (URL) throws -> Data,
        resolve: @escaping (Data) throws -> (url: URL, isStale: Bool),
        startAccess: @escaping (URL) -> Bool,
        stopAccess: @escaping (URL) -> Void
    ) {
        self.defaults = defaults
        self.key = key
        self.encode = encode
        self.resolve = resolve
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    func restore() throws -> CodexHomeBookmarkRestoreResult {
        guard let data = defaults.data(forKey: key) else {
            return .needsSelection
        }

        let resolution: (url: URL, isStale: Bool)
        do {
            resolution = try resolve(data)
        } catch {
            clear()
            return .needsSelection
        }

        let url = resolution.url.standardizedFileURL
        guard !resolution.isStale, Self.isValidCodexHome(url) else {
            clear()
            return .needsSelection
        }

        releaseAccess()
        if startAccess(url) {
            activeURL = url
        }
        return .available(url)
    }

    func save(_ url: URL) throws {
        let standardizedURL = url.standardizedFileURL
        guard Self.isValidCodexHome(standardizedURL) else {
            throw CodexHomeBookmarkError.invalidCodexHome
        }

        let data: Data
        do {
            data = try encode(standardizedURL)
        } catch {
            throw CodexHomeBookmarkError.bookmarkCreationFailed
        }

        releaseAccess()
        defaults.set(data, forKey: key)
    }

    func clear() {
        releaseAccess()
        defaults.removeObject(forKey: key)
    }

    func releaseAccess() {
        guard let activeURL else {
            return
        }

        stopAccess(activeURL)
        self.activeURL = nil
    }
}
