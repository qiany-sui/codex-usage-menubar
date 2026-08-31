import Foundation

public struct SessionTokenRecord: Equatable, Sendable {
    public let occurredAt: Date
    public let lastUsage: TokenBreakdown?
    public let totalUsage: TokenBreakdown?
    public let schemaVariant: String

    public init(
        occurredAt: Date,
        lastUsage: TokenBreakdown?,
        totalUsage: TokenBreakdown?,
        schemaVariant: String
    ) {
        self.occurredAt = occurredAt
        self.lastUsage = lastUsage
        self.totalUsage = totalUsage
        self.schemaVariant = schemaVariant
    }
}

public struct SessionTokenEvent: Equatable, Sendable {
    public let signature: Data
    public let occurredAt: Date
    public let usage: TokenBreakdown

    public init(signature: Data, occurredAt: Date, usage: TokenBreakdown) {
        self.signature = signature
        self.occurredAt = occurredAt
        self.usage = usage
    }
}

public struct SessionCounterState: Codable, Equatable, Sendable {
    public let previousTotal: TokenBreakdown?

    public init(previousTotal: TokenBreakdown?) {
        self.previousTotal = previousTotal
    }
}

public enum SessionParseError: Error, Equatable, Sendable {
    case invalidTokenEvent
}
