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
        return (pathCandidates + standardLocations).first {
            FileManager.default.isExecutableFile(
                atPath: $0.standardizedFileURL.path
            )
        }?.standardizedFileURL
    }
}
