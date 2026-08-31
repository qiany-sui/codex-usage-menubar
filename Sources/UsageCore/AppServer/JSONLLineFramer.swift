import Foundation

public struct JSONLLineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[..<newlineIndex]))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }

    public mutating func finish() {
        buffer.removeAll(keepingCapacity: true)
    }
}
