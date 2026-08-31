import Foundation

public struct SessionLineParser: Sendable {
    public init() {}

    public func parse(line: Data) throws -> SessionTokenRecord? {
        let routing: SessionRoutingEnvelope
        do {
            routing = try JSONDecoder().decode(
                SessionRoutingEnvelope.self,
                from: line
            )
        } catch {
            throw SessionParseError.invalidTokenEvent
        }

        guard routing.type == "event_msg",
              routing.payload?.type == "token_count" else {
            return nil
        }
        let tokenEvent: SessionTokenEnvelope
        do {
            tokenEvent = try JSONDecoder().decode(
                SessionTokenEnvelope.self,
                from: line
            )
        } catch {
            throw SessionParseError.invalidTokenEvent
        }
        guard let timestamp = tokenEvent.timestamp,
              let occurredAt = parseTimestamp(timestamp) else {
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

    private func parseTimestamp(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
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
    let timestamp: String?
    let payload: Payload?

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
