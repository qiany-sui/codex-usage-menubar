import Foundation

public protocol AppServerTransport: Actor {
    func start() async throws
    func send(line: Data) async throws
    func nextLine() async throws -> Data?
    func stop() async
}
