import Foundation

public struct SessionLineParser: Sendable {
    private let timestamps = SessionTimestampParser()

    public init() {}

    public func parse(line: Data) throws -> SessionTokenRecord? {
        if case let .token(record) = try parseEntry(line: line) { return record }
        return nil
    }

    enum Entry {
        case token(SessionTokenRecord)
        case model(String?)
    }

    func parseEntry(line: Data) throws -> Entry? {
        let tokenEvent: SessionTokenEnvelope
        do {
            tokenEvent = try JSONDecoder().decode(
                SessionTokenEnvelope.self,
                from: line
            )
        } catch {
            throw SessionParseError.invalidTokenEvent
        }
        switch tokenEvent.kind {
        case .other: return nil
        case let .model(model): return .model(model)
        case .token: break
        }
        guard let timestamp = tokenEvent.timestamp,
              let occurredAt = timestamps.parse(timestamp) else {
            throw SessionParseError.invalidTokenEvent
        }

        let lastUsage = try tokenEvent.payload?.info?.lastTokenUsage.map(tokenBreakdown)
        let totalUsage = try tokenEvent.payload?.info?.totalTokenUsage.map(tokenBreakdown)
        let schemaVariant = schemaVariant(
            lastUsage: lastUsage,
            totalUsage: totalUsage
        )

        return .token(SessionTokenRecord(
            occurredAt: occurredAt,
            lastUsage: lastUsage,
            totalUsage: totalUsage,
            schemaVariant: schemaVariant,
            quota: tokenEvent.payload?.rateLimits?.quota(at: occurredAt)
        ))
    }

    private func tokenBreakdown(
        from usage: SessionTokenEnvelope.TokenUsage
    ) throws -> TokenBreakdown {
        guard usage.inputTokens >= 0,
              usage.cachedInputTokens >= 0,
              usage.outputTokens >= 0,
              (usage.reasoningOutputTokens ?? 0) >= 0,
              usage.cachedInputTokens <= usage.inputTokens else {
            throw SessionParseError.invalidTokenEvent
        }

        return TokenBreakdown(
            inputTokens: usage.inputTokens,
            cachedInputTokens: usage.cachedInputTokens,
            outputTokens: usage.outputTokens
        )
    }

    private func schemaVariant(
        lastUsage: TokenBreakdown?,
        totalUsage: TokenBreakdown?
    ) -> String {
        switch (lastUsage, totalUsage) {
        case (.some, .some):
            return "last+total"
        case (.some, .none):
            return "last"
        case (.none, .some):
            return "total"
        case (.none, .none):
            return "none"
        }
    }
}

private struct SessionRoutingEnvelope: Decodable {
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String?
    }
}

private struct SessionTokenEnvelope: Decodable {
    enum Kind {
        case other, token, model(String?)
    }

    let kind: Kind
    let timestamp: String?
    let payload: Payload?

    private enum CodingKeys: String, CodingKey {
        case timestamp, payload
    }

    init(from decoder: any Decoder) throws {
        let routing = try SessionRoutingEnvelope(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch (routing.type, routing.payload?.type) {
        case ("turn_context", _):
            let context = try? container.decode(TurnContext.self, forKey: .payload)
            kind = .model(context?.modelIdentifier)
        case ("event_msg", "task_started"), ("event_msg", "task_complete"),
             ("event_msg", "turn_started"), ("event_msg", "turn_completed"),
             ("event_msg", "turn_aborted"):
            kind = .model(nil)
        case ("event_msg", "token_count"):
            kind = .token
        default:
            kind = .other
        }
        guard case .token = kind else {
            timestamp = nil
            payload = nil
            return
        }
        // 共用一次 JSON 解码，仍先分流，避免解析无关消息的正文或 token 字段。
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        payload = try container.decodeIfPresent(Payload.self, forKey: .payload)
    }

    private struct TurnContext: Decodable {
        private static let identifierCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-"
        )
        let model: String?

        var modelIdentifier: String? {
            guard let model, (1...128).contains(model.utf8.count),
                  model.unicodeScalars.allSatisfy(Self.identifierCharacters.contains)
            else { return nil }
            return model
        }
    }

    struct Payload: Decodable {
        let info: Info?
        let rateLimits: SessionRateLimits?

        private enum CodingKeys: String, CodingKey {
            case info
            case rateLimits = "rate_limits"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            info = try container.decodeIfPresent(Info.self, forKey: .info)
            // 附带额度损坏时仍保留有效的 Token 事件。
            rateLimits = try? container.decodeIfPresent(SessionRateLimits.self, forKey: .rateLimits)
        }
    }

    struct Info: Decodable {
        let lastTokenUsage: TokenUsage?
        let totalTokenUsage: TokenUsage?

        private enum CodingKeys: String, CodingKey {
            case lastTokenUsage = "last_token_usage"
            case totalTokenUsage = "total_token_usage"
        }
    }

    struct TokenUsage: Decodable {
        let inputTokens: Int64
        let cachedInputTokens: Int64
        let outputTokens: Int64
        let reasoningOutputTokens: Int64?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
        }
    }
}

private struct SessionRateLimits: Decodable {
    let limitID: String?
    let primary: Window?
    let secondary: Window?

    enum CodingKeys: String, CodingKey {
        case limitID = "limit_id"
        case primary, secondary
    }

    struct Window: Decodable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: Int64

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }

        var value: RateLimitWindow? {
            guard usedPercent.isFinite, usedPercent >= 0 else { return nil }
            return RateLimitWindow(usedPercent: usedPercent, windowDurationMins: windowMinutes, resetsAt: resetsAt)
        }
    }

    func quota(at timestamp: Date) -> QuotaSnapshot? {
        let response = RateLimitsResponse(
            rateLimits: RateLimitBucket(limitId: limitID ?? "codex", limitName: nil,
                                        primary: primary?.value, secondary: secondary?.value),
            rateLimitsByLimitId: nil
        )
        guard let quota = WeeklyQuotaSelector().select(from: response, fetchedAt: timestamp),
              quota.startsAt.timeIntervalSince(timestamp) <= 60, timestamp <= quota.resetsAt else { return nil }
        return quota
    }
}

// 格式化器只初始化一次；锁保护共享访问，保持解析器的 Sendable 契约。
private final class SessionTimestampParser: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional = ISO8601DateFormatter()
    private let wholeSeconds = ISO8601DateFormatter()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSeconds.formatOptions = [.withInternetDateTime]
    }

    func parse(_ timestamp: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: timestamp) ?? wholeSeconds.date(from: timestamp)
    }
}
