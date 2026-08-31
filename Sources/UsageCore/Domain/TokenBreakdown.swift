import Foundation
public struct TokenBreakdown: Codable, Equatable, Sendable {
 public let inputTokens: Int64; public let cachedInputTokens: Int64; public let outputTokens: Int64
 public init(inputTokens: Int64, cachedInputTokens: Int64, outputTokens: Int64) { self.inputTokens=inputTokens; self.cachedInputTokens=cachedInputTokens; self.outputTokens=outputTokens }
 public var totalTokens: Int64 { inputTokens + outputTokens }
 public static let zero = TokenBreakdown(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0)
 public static func +(lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown { TokenBreakdown(inputTokens: lhs.inputTokens+rhs.inputTokens, cachedInputTokens: lhs.cachedInputTokens+rhs.cachedInputTokens, outputTokens: lhs.outputTokens+rhs.outputTokens) }
}
