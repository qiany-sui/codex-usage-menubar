import Foundation

public struct RPCErrorPayload: Codable, Equatable, Error, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?
}

public struct RPCIncomingMessage: Decodable, Sendable {
    public let jsonrpc: String?
    public let id: Int64?
    public let method: String?
    public let params: JSONValue?
    public let result: JSONValue?
    public let error: RPCErrorPayload?
}

public struct InitializeResult: Decodable, Equatable, Sendable {
    public let codexHome: String?
    public let platformFamily: String?
    public let platformOs: String?
    public let userAgent: String?
}

public struct RateLimitWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Int64?
}

public struct RateLimitBucket: Decodable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
}

public struct RateLimitsResponse: Decodable, Equatable, Sendable {
    public let rateLimits: RateLimitBucket
    public let rateLimitsByLimitId: [String: RateLimitBucket]?
}

public struct AccountUsageSummary: Decodable, Equatable, Sendable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let longestRunningTurnSec: Int64?
    public let currentStreakDays: Int64?
    public let longestStreakDays: Int64?
}

public struct AccountTokenUsageDailyBucket: Decodable, Equatable, Sendable {
    public let startDate: String
    public let tokens: Int64
}

public struct AccountUsageResponse: Decodable, Equatable, Sendable {
    public let summary: AccountUsageSummary
    public let dailyUsageBuckets: [AccountTokenUsageDailyBucket]?
}

public enum PatchField<Value: Sendable>: Sendable {
    case missing
    case value(Value?)
}

extension PatchField: Equatable where Value: Equatable {}

public struct RateLimitWindowPatch: Decodable, Sendable {
    public let usedPercent: PatchField<Double>
    public let windowDurationMins: PatchField<Int>
    public let resetsAt: PatchField<Int64>

    private enum CodingKeys: String, CodingKey {
        case usedPercent, windowDurationMins, resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.patchField(forKey: .usedPercent)
        windowDurationMins = try container.patchField(forKey: .windowDurationMins)
        resetsAt = try container.patchField(forKey: .resetsAt)
    }
}

public struct RateLimitBucketPatch: Decodable, Sendable {
    public let limitId: PatchField<String>
    public let limitName: PatchField<String>
    public let primary: PatchField<RateLimitWindowPatch>
    public let secondary: PatchField<RateLimitWindowPatch>

    private enum CodingKeys: String, CodingKey {
        case limitId, limitName, primary, secondary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitId = try container.patchField(forKey: .limitId)
        limitName = try container.patchField(forKey: .limitName)
        primary = try container.patchField(forKey: .primary)
        secondary = try container.patchField(forKey: .secondary)
    }
}

public struct RateLimitsUpdatedParams: Decodable, Sendable {
    public let rateLimits: RateLimitBucketPatch
}

public enum AppServerNotification: Sendable {
    case rateLimitsUpdated(RateLimitsUpdatedParams)
    case other(method: String)
}

public extension RateLimitWindow {
    func applying(_ patch: RateLimitWindowPatch) -> RateLimitWindow {
        RateLimitWindow(
            usedPercent: patch.usedPercent.value ?? usedPercent,
            windowDurationMins: patch.windowDurationMins.applying(to: windowDurationMins),
            resetsAt: patch.resetsAt.applying(to: resetsAt)
        )
    }

    static func applying(_ patch: RateLimitWindowPatch) -> RateLimitWindow? {
        guard let usedPercent = patch.usedPercent.value else { return nil }
        return RateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: patch.windowDurationMins.applying(to: nil),
            resetsAt: patch.resetsAt.applying(to: nil)
        )
    }
}

public extension RateLimitBucket {
    func applying(_ patch: RateLimitBucketPatch) -> RateLimitBucket {
        RateLimitBucket(
            limitId: patch.limitId.applying(to: limitId),
            limitName: patch.limitName.applying(to: limitName),
            primary: primary.applying(patch.primary),
            secondary: secondary.applying(patch.secondary)
        )
    }
}

public extension RateLimitsResponse {
    func applying(_ update: RateLimitsUpdatedParams) -> RateLimitsResponse {
        let mergedRateLimits = rateLimits.applying(update.rateLimits)
        let mergedByLimitID = rateLimitsByLimitId?.mapValues { bucket in
            bucket.limitId == mergedRateLimits.limitId
                ? bucket.applying(update.rateLimits)
                : bucket
        }
        return RateLimitsResponse(
            rateLimits: mergedRateLimits,
            rateLimitsByLimitId: mergedByLimitID
        )
    }
}

private extension KeyedDecodingContainer {
    func patchField<Value: Decodable & Sendable>(
        forKey key: Key
    ) throws -> PatchField<Value> {
        guard contains(key) else { return .missing }
        if try decodeNil(forKey: key) { return .value(nil) }
        return .value(try decode(Value.self, forKey: key))
    }
}

private extension PatchField {
    var value: Value? {
        guard case let .value(value) = self else { return nil }
        return value
    }

    func applying(to current: Value?) -> Value? {
        switch self {
        case .missing:
            return current
        case let .value(value):
            return value
        }
    }
}

private extension Optional where Wrapped == RateLimitWindow {
    func applying(_ patch: PatchField<RateLimitWindowPatch>) -> RateLimitWindow? {
        switch patch {
        case .missing:
            return self
        case .value(nil):
            return nil
        case let .value(.some(windowPatch)):
            return map { $0.applying(windowPatch) }
                ?? RateLimitWindow.applying(windowPatch)
        }
    }
}
