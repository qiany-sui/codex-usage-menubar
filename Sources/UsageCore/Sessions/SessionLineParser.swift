import Foundation

public struct SessionLineParser: Sendable {
    private let timestamps = SessionTimestampParser()

    public init() {}

    public func parse(line: Data) throws -> SessionTokenRecord? {
        let tokenEvent: SessionTokenEnvelope
        do {
            tokenEvent = try JSONDecoder().decode(
                SessionTokenEnvelope.self,
                from: line
            )
        } catch {
            throw SessionParseError.invalidTokenEvent
        }
        guard tokenEvent.isTokenEvent else {
            return nil
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

        return SessionTokenRecord(
            occurredAt: occurredAt,
            lastUsage: lastUsage,
            totalUsage: totalUsage,
            schemaVariant: schemaVariant
        )
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
    let isTokenEvent: Bool
    let timestamp: String?
    let payload: Payload?

    private enum CodingKeys: String, CodingKey {
        case timestamp, payload
    }

    init(from decoder: any Decoder) throws {
        let routing = try SessionRoutingEnvelope(from: decoder)
        isTokenEvent = routing.type == "event_msg" && routing.payload?.type == "token_count"
        guard isTokenEvent else {
            timestamp = nil
            payload = nil
            return
        }
        // 共用一次 JSON 解码，仍先分流，避免解析无关消息的正文或 token 字段。
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        payload = try container.decodeIfPresent(Payload.self, forKey: .payload)
    }

    struct Payload: Decodable {
        let info: Info?
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
