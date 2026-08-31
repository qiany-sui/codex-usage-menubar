import Foundation

public struct CodexHomeResolver: Sendable {
    public init() {}

    public func resolve(
        initializedHome: String?,
        environment: [String: String],
        homeDirectory: URL
    ) -> URL? {
        let stringCandidates = [initializedHome, environment["CODEX_HOME"]]
        for candidate in stringCandidates.compactMap({ $0 }) {
            guard NSString(string: candidate).isAbsolutePath else {
                continue
            }
            let url = URL(fileURLWithPath: candidate).standardizedFileURL
            if isDirectory(url) {
                return url
            }
        }

        let fallback = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
        guard fallback.isFileURL,
              fallback.path.hasPrefix("/"),
              isDirectory(fallback) else {
            return nil
        }
        return fallback
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }
}
