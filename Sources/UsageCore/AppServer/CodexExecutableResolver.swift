import Foundation

public struct CodexExecutableResolver: Sendable {
    public init() {}

    public func resolve(
        environment: [String: String],
        standardLocations: [URL] = [
            URL(
                fileURLWithPath:
                    "/Applications/ChatGPT.app/Contents/Resources/codex"
            )
        ]
    ) -> URL? {
        let pathCandidates = environment["PATH", default: ""]
            .split(separator: ":")
            .map {
                URL(fileURLWithPath: String($0))
                    .appendingPathComponent("codex")
            }
        return (pathCandidates + standardLocations)
            .map(\.standardizedFileURL)
            .first(where: isExecutableRegularFile)
    }

    private func isExecutableRegularFile(_ candidate: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard
            FileManager.default.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ),
            !isDirectory.boolValue,
            FileManager.default.isExecutableFile(atPath: candidate.path),
            let values = try? candidate.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
        else {
            return false
        }
        return true
    }
}
