import Foundation
public struct LocalDay: Codable, Hashable, Comparable, Sendable {
 public let year: Int; public let month: Int; public let day: Int
 public init(year: Int, month: Int, day: Int) { self.year=year; self.month=month; self.day=day }
 public var iso8601: String { String(format: "%04d-%02d-%02d", year, month, day) }
 public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool { (lhs.year,lhs.month,lhs.day) < (rhs.year,rhs.month,rhs.day) }
}
