import CryptoKit
import Foundation

public struct SessionUsageAccumulator: Sendable {
    public private(set) var state: SessionCounterState

    public init(
        state: SessionCounterState = SessionCounterState(previousTotal: nil)
    ) {
        self.state = state
    }

    public mutating func ingest(
        _ record: SessionTokenRecord
    ) throws -> SessionTokenEvent? {
        let usage: TokenBreakdown
        if let lastUsage = record.lastUsage {
            usage = lastUsage
        } else if let totalUsage = record.totalUsage {
            usage = delta(current: totalUsage, previous: state.previousTotal)
        } else {
            return nil
        }

        state = SessionCounterState(
            previousTotal: record.totalUsage ?? state.previousTotal
        )
        return SessionTokenEvent(
            signature: signature(for: record),
            occurredAt: record.occurredAt,
            usage: usage
        )
    }

    private func delta(
        current: TokenBreakdown,
        previous: TokenBreakdown?
    ) -> TokenBreakdown {
        guard let previous else {
            return current
        }
        guard current.inputTokens >= previous.inputTokens,
              current.cachedInputTokens >= previous.cachedInputTokens,
              current.outputTokens >= previous.outputTokens else {
            return current
        }
        return TokenBreakdown(
            inputTokens: current.inputTokens - previous.inputTokens,
            cachedInputTokens: current.cachedInputTokens - previous.cachedInputTokens,
            outputTokens: current.outputTokens - previous.outputTokens
        )
    }

    private func signature(for record: SessionTokenRecord) -> Data {
        let milliseconds = Int64(
            (record.occurredAt.timeIntervalSince1970 * 1_000).rounded()
        )
        let stableInput = [
            "timestampMs=\(milliseconds)",
            "schema=\(record.schemaVariant)",
            "last=\(stableUsage(record.lastUsage))",
            "total=\(stableUsage(record.totalUsage))"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(stableInput.utf8))
        return Data(digest)
    }

    private func stableUsage(_ usage: TokenBreakdown?) -> String {
        guard let usage else {
            return "none"
        }
        return "\(usage.inputTokens),\(usage.cachedInputTokens),\(usage.outputTokens)"
    }
}
